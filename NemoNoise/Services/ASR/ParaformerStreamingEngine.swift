import Foundation

final class ParaformerStreamingEngine: ASRService, @unchecked Sendable {
    private let recognizer: SherpaOnlineRecognizer
    private let punctuation: SherpaPunctuation?
    private var confirmedSegments: [String] = []

    init(modelDir: URL, punctuationModelPath: String? = nil) throws {
        let encoderPath = modelDir.appendingPathComponent("encoder.int8.onnx").path
        let decoderPath = modelDir.appendingPathComponent("decoder.int8.onnx").path
        let tokensPath  = modelDir.appendingPathComponent("tokens.txt").path
        let start = ContinuousClock.now
        guard let r = SherpaOnlineRecognizer(
            encoderPath: encoderPath,
            decoderPath: decoderPath,
            tokensPath: tokensPath
        ) else {
            LogService.error("Model init failed, encoder: \(encoderPath)", category: "ASR")
            throw ASRError.engineInitFailed
        }
        recognizer = r

        if let path = punctuationModelPath {
            punctuation = SherpaPunctuation(modelPath: path)
            if punctuation != nil {
                LogService.info("Punctuation model enabled", category: "ParaformerStreamingEngine")
            }
        } else {
            punctuation = nil
        }

        let elapsed = ContinuousClock.now - start
        LogService.info("Model loaded, init duration: \(elapsed.description)", category: "ParaformerStreamingEngine")
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        let text = recognizer.feed(samples: samples, sampleRate: Int32(sampleRate))

        if recognizer.isEndpoint {
            let segment = punctuate(text)
            confirmedSegments.append(segment)
            recognizer.resetStream()
            let fullText = (confirmedSegments + [text]).joined(separator: "")
            return TranscriptionResult(text: fullText, isFinal: false, emotion: nil)
        }

        let fullText = (confirmedSegments + [text]).joined(separator: "")
        return TranscriptionResult(text: fullText, isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        let text = recognizer.finalize()
        let segment = punctuate(text)
        if !segment.isEmpty {
            confirmedSegments.append(segment)
        }
        let fullText = confirmedSegments.joined(separator: "")
        return TranscriptionResult(text: fullText, isFinal: true, emotion: nil)
    }

    func reset() {
        confirmedSegments = []
        recognizer.startStream()
    }

    private func punctuate(_ text: String) -> String {
        guard !text.isEmpty, let punctuation else { return text }
        return punctuation.addPunctuation(to: text)
    }
}
