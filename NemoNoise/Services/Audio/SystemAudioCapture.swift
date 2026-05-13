import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let continuationBox = ContinuationBox()
    private var stream: SCStream?
    private let targetSampleRate: Double = 16000
    private var chunkCount: Int = 0
    private var lastLogTime: Date = .distantPast

    func start() async throws -> AsyncStream<AudioChunk> {
        guard CGPreflightScreenCaptureAccess() else {
            throw TranslationError.screenRecordingDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw TranslationError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 1

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.nemonoise.audio-capture"))

        let audioStream = AsyncStream<AudioChunk> { [weak self] continuation in
            self?.continuationBox.value = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { [weak self] in
                    try? await self?.stream?.stopCapture()
                    self?.stream = nil
                }
            }
        }

        try await stream.startCapture()
        self.stream = stream
        LogService.info("System audio capture started", category: "SystemAudioCapture")
        return audioStream
    }

    func stop() {
        continuationBox.value?.finish()
        Task { [weak self] in
            try? await self?.stream?.stopCapture()
            self?.stream = nil
        }
        LogService.info("System audio capture stopped", category: "SystemAudioCapture")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let samples = extractFloatSamples(from: sampleBuffer) else {
            LogService.warn("Failed to extract audio samples from CMSampleBuffer", category: "SystemAudioCapture")
            return
        }
        guard let resampled = resample(samples, sourceRate: 48000) else {
            LogService.warn("Failed to resample audio: \(samples.count) samples", category: "SystemAudioCapture")
            return
        }

        let rms = sqrt(resampled.reduce(0) { $0 + $1 * $1 } / Float(max(resampled.count, 1)))
        continuationBox.value?.yield(AudioChunk(samples: resampled, rmsLevel: rms))

        chunkCount += 1
        let now = Date()
        if now.timeIntervalSince(lastLogTime) >= 2.0 {
            LogService.info("Audio capture active: \(chunkCount) chunks, rms=\(String(format: "%.4f", rms))", category: "SystemAudioCapture")
            lastLogTime = now
        }
    }

    // MARK: - Audio Processing

    private func extractFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        let sampleCount = length / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return nil }

        var samples = [Float](repeating: 0, count: sampleCount)
        let status = samples.withUnsafeMutableBufferPointer { buffer in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        return samples
    }

    private func resample(_ samples: [Float], sourceRate: Double) -> [Float]? {
        guard let sf = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let df = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sf, to: df) else {
            return nil
        }

        let srcFrameCount = AVAudioFrameCount(samples.count)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: sf, frameCapacity: srcFrameCount) else { return nil }
        srcBuffer.frameLength = srcFrameCount
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress, let channelData = srcBuffer.floatChannelData else { return }
            channelData[0].initialize(from: base, count: samples.count)
        }

        let ratio = targetSampleRate / sourceRate
        let dstFrameCount = AVAudioFrameCount(Double(samples.count) * ratio) + 1
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: df, frameCapacity: dstFrameCount) else { return nil }

        var inputConsumed = false
        let status = converter.convert(to: dstBuffer, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        guard status != .error, let channelData = dstBuffer.floatChannelData else { return nil }
        let frameLength = Int(dstBuffer.frameLength)
        guard frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}
