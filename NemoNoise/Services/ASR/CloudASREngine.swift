import Foundation

final class CloudASREngine: ASRService, @unchecked Sendable {
    let isStreaming = true

    private let apiKey: String
    private var accumulated: [Float] = []
    private let sampleRate = 16000

    private let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/audio/transcriptions")!

    init(apiKey: String) {
        self.apiKey = apiKey
        LogService.info("CloudASREngine initialized", category: "CloudASREngine")
    }

    func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        accumulated.append(contentsOf: samples)
        return TranscriptionResult(text: "", isFinal: false, emotion: nil)
    }

    func finish() async throws -> TranscriptionResult {
        defer { reset() }
        guard !accumulated.isEmpty else {
            return TranscriptionResult(text: "", isFinal: true, emotion: nil)
        }

        let wavData = floatSamplesToWAV(accumulated, sampleRate: sampleRate)
        let text = try await recognize(wavData: wavData)
        return TranscriptionResult(text: text, isFinal: true, emotion: nil)
    }

    func reset() {
        accumulated.removeAll(keepingCapacity: true)
    }

    // MARK: - API call

    private func recognize(wavData: Data) async throws -> String {
        let maxRetries = 2
        var lastError: Error?

        for attempt in 0...maxRetries {
            do {
                let text = try await sendRequest(wavData: wavData, attempt: attempt)
                return text
            } catch let error as CloudASRError {
                lastError = error
                switch error {
                case .authenticationFailed:
                    LogService.error("Auth failed, not retrying", category: "CloudASREngine")
                    throw error
                case .requestTimeout:
                    if attempt < maxRetries {
                        LogService.warn("Timeout, retry \(attempt + 1)/\(maxRetries)", category: "CloudASREngine")
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                case .serverError, .invalidResponse, .apiKeyNotSet:
                    throw error
                }
            }
        }
        throw lastError ?? CloudASRError.requestTimeout
    }

    private func sendRequest(wavData: Data, attempt: Int) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8)
        body.append(contentsOf: "paraformer-v2\r\n".utf8)
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(wavData)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        request.httpBody = body

        let startTime = ContinuousClock.now

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            LogService.error("Request failed: \(error.localizedDescription), retry: \(attempt)", category: "CloudASREngine")
            throw CloudASRError.requestTimeout
        }

        let elapsed = ContinuousClock.now - startTime
        guard let httpResp = response as? HTTPURLResponse else {
            LogService.error("Invalid response type", category: "CloudASREngine")
            throw CloudASRError.invalidResponse
        }

        let statusCode = httpResp.statusCode
        LogService.info("API response: status=\(statusCode), latency=\(elapsed.description), audio=\(wavData.count) bytes, retry=\(attempt)", category: "CloudASREngine")

        switch statusCode {
        case 200:
            return try parseResponse(data)
        case 401, 403:
            LogService.error("Auth failure: \(statusCode)", category: "CloudASREngine")
            throw CloudASRError.authenticationFailed
        default:
            LogService.error("Server error: \(statusCode)", category: "CloudASREngine")
            throw CloudASRError.serverError(statusCode)
        }
    }

    private func parseResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            LogService.error("Invalid JSON response", category: "CloudASREngine")
            throw CloudASRError.invalidResponse
        }

        // The /compatible-mode/v1/audio/transcriptions endpoint follows the OpenAI shape: { "text": "..." }.
        guard let text = json["text"] as? String else {
            LogService.error("Unexpected response format: \(String(data: data, encoding: .utf8) ?? "nil")", category: "CloudASREngine")
            throw CloudASRError.invalidResponse
        }
        LogService.info("Transcribed \(text.count) chars", category: "CloudASREngine")
        return text
    }

    // MARK: - WAV conversion

    private func floatSamplesToWAV(_ samples: [Float], sampleRate: Int) -> Data {
        let numChannels = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = numChannels * bytesPerSample
        let byteRate = sampleRate * blockAlign
        let dataSize = samples.count * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataSize)

        // RIFF header
        data.appendStr("RIFF")
        data.appendLE(UInt32(36 + dataSize))
        data.appendStr("WAVE")

        // fmt chunk
        data.appendStr("fmt ")
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1)) // PCM
        data.appendLE(UInt16(numChannels))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(byteRate))
        data.appendLE(UInt16(blockAlign))
        data.appendLE(UInt16(bitsPerSample))

        // data chunk
        data.appendStr("data")
        data.appendLE(UInt32(dataSize))

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            data.appendLE(Int16(clamped * 32767.0))
        }

        return data
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendStr(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
