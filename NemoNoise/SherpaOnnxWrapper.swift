import Foundation

// Minimal Swift wrapper around the sherpa-onnx C API.
// Covers offline SenseVoice recognition and online (streaming) Paraformer recognition.

struct SherpaOnnxResult {
    let text: String
    let lang: String      // "zh", "en", "ja", "ko", "yue"
    let emotion: String   // "HAPPY", "SAD", "ANGRY", "NEUTRAL", "FEARFUL", "DISGUSTED", "SURPRISED"
    let event: String     // "Speech", "BGM", "Laughter", etc.
}

final class SherpaOfflineRecognizer {
    private let recognizer: UnsafePointer<SherpaOnnxOfflineRecognizer>

    /// - Parameters:
    ///   - modelPath: Path to `model.int8.onnx`
    ///   - tokensPath: Path to `tokens.txt`
    init?(modelPath: String, tokensPath: String) {
        // Strings need to be alive only for the duration of SherpaOnnxCreateOfflineRecognizer.
        // The C library copies them internally.
        var ptr: UnsafePointer<SherpaOnnxOfflineRecognizer>?

        modelPath.withCString { cModel in
            tokensPath.withCString { cTokens in
                "auto".withCString { cLang in
                    "cpu".withCString { cProvider in
                        "greedy_search".withCString { cDecoding in

                            var senseVoice = SherpaOnnxOfflineSenseVoiceModelConfig()
                            senseVoice.model = cModel
                            senseVoice.language = cLang
                            senseVoice.use_itn = 1

                            var modelConfig = SherpaOnnxOfflineModelConfig()
                            modelConfig.tokens = cTokens
                            modelConfig.sense_voice = senseVoice
                            modelConfig.num_threads = 2
                            modelConfig.provider = cProvider

                            var featConfig = SherpaOnnxFeatureConfig()
                            featConfig.sample_rate = 16000
                            featConfig.feature_dim = 80

                            var config = SherpaOnnxOfflineRecognizerConfig()
                            config.feat_config = featConfig
                            config.model_config = modelConfig
                            config.decoding_method = cDecoding

                            ptr = SherpaOnnxCreateOfflineRecognizer(&config)
                        }
                    }
                }
            }
        }

        guard let p = ptr else { return nil }
        recognizer = p
    }

    func decode(samples: [Float], sampleRate: Int32 = 16000) -> SherpaOnnxResult {
        let stream = SherpaOnnxCreateOfflineStream(recognizer)!
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxAcceptWaveformOffline(stream, sampleRate, buf.baseAddress, Int32(samples.count))
        }

        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let r = SherpaOnnxGetOfflineStreamResult(stream) else {
            return SherpaOnnxResult(text: "", lang: "", emotion: "", event: "")
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(r) }

        return SherpaOnnxResult(
            text:    r.pointee.text    .map { String(cString: $0) } ?? "",
            lang:    r.pointee.lang    .map { String(cString: $0) } ?? "",
            emotion: r.pointee.emotion .map { String(cString: $0) } ?? "",
            event:   r.pointee.event   .map { String(cString: $0) } ?? ""
        )
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }
}

// MARK: - Online (streaming) Paraformer

final class SherpaOnlineRecognizer {
    private let recognizer: UnsafePointer<SherpaOnnxOnlineRecognizer>
    private var stream: UnsafePointer<SherpaOnnxOnlineStream>?

    /// - Parameters:
    ///   - encoderPath: Path to `model_quant.onnx`
    ///   - decoderPath: Path to `decoder_quant.onnx`
    ///   - tokensPath:  Path to `tokens.txt`
    init?(encoderPath: String, decoderPath: String, tokensPath: String) {
        var ptr: UnsafePointer<SherpaOnnxOnlineRecognizer>?

        encoderPath.withCString { cEncoder in
            decoderPath.withCString { cDecoder in
                tokensPath.withCString { cTokens in
                    "cpu".withCString { cProvider in
                        "greedy_search".withCString { cDecoding in

                            var paraformer = SherpaOnnxOnlineParaformerModelConfig()
                            paraformer.encoder = cEncoder
                            paraformer.decoder = cDecoder

                            var modelConfig = SherpaOnnxOnlineModelConfig()
                            modelConfig.paraformer = paraformer
                            modelConfig.tokens = cTokens
                            modelConfig.num_threads = 2
                            modelConfig.provider = cProvider

                            var featConfig = SherpaOnnxFeatureConfig()
                            featConfig.sample_rate = 16000
                            featConfig.feature_dim = 80

                            var config = SherpaOnnxOnlineRecognizerConfig()
                            config.feat_config = featConfig
                            config.model_config = modelConfig
                            config.decoding_method = cDecoding
                            config.enable_endpoint = 1
                            config.rule1_min_trailing_silence = 2.4
                            config.rule2_min_trailing_silence = 1.2
                            config.rule3_min_utterance_length = 20

                            ptr = SherpaOnnxCreateOnlineRecognizer(&config)
                        }
                    }
                }
            }
        }

        guard let p = ptr else { return nil }
        recognizer = p
    }

    func startStream() {
        stream.map { SherpaOnnxDestroyOnlineStream($0) }
        stream = SherpaOnnxCreateOnlineStream(recognizer)
    }

    /// Feed a chunk. Returns the current partial text.
    func feed(samples: [Float], sampleRate: Int32 = 16000) -> String {
        guard let s = stream else { return "" }
        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxOnlineStreamAcceptWaveform(s, sampleRate, buf.baseAddress, Int32(samples.count))
        }
        decodeReady()
        return currentText()
    }

    /// Signal end of audio, drain remaining frames, return final text.
    func finalize() -> String {
        guard let s = stream else { return "" }
        SherpaOnnxOnlineStreamInputFinished(s)
        decodeReady()
        let text = currentText()
        SherpaOnnxDestroyOnlineStream(s)
        stream = nil
        return text
    }

    private func decodeReady() {
        guard let s = stream else { return }
        while SherpaOnnxIsOnlineStreamReady(recognizer, s) != 0 {
            SherpaOnnxDecodeOnlineStream(recognizer, s)
        }
    }

    private func currentText() -> String {
        guard let s = stream,
              let r = SherpaOnnxGetOnlineStreamResult(recognizer, s) else { return "" }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(r) }
        return r.pointee.text.map { String(cString: $0) } ?? ""
    }

    deinit {
        stream.map { SherpaOnnxDestroyOnlineStream($0) }
        SherpaOnnxDestroyOnlineRecognizer(recognizer)
    }
}
