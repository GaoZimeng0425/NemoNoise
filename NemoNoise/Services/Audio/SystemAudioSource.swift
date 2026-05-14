import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class SystemAudioSource: NSObject, SCStreamOutput, @unchecked Sendable {
    private let continuationBox = ContinuationBox()
    private var stream: SCStream?
    private let sourceSampleRate: Double = 48000
    private let targetSampleRate: Double = 16000
    private lazy var resampler: AudioResampler? = AudioResampler(sourceRate: sourceSampleRate, targetRate: targetSampleRate)
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
        config.sampleRate = Int(sourceSampleRate)
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
        guard let resampled = resampler?.resample(samples) else {
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

}
