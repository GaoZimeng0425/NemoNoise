import AVFoundation
import CoreMedia
import os
import ScreenCaptureKit

final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, @unchecked Sendable {
    private let continuationBox = ContinuationBox()
    private var stream: SCStream?
    private static let sourceSampleRate: Double = 48000
    private static let targetSampleRate: Double = 16000
    // Used only from the SCStream sample-handler queue (the output callback).
    private let resampler = AudioResampler(sourceRate: SystemAudioSource.sourceSampleRate, targetRate: SystemAudioSource.targetSampleRate)
    private let logState = OSAllocatedUnfairLock(initialState: (chunkCount: 0, lastLogTime: Date.distantPast))
    private let analyzer = SpectrumAnalyzer(binCount: 16, sampleRate: 16000)

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
        config.sampleRate = Int(Self.sourceSampleRate)
        config.channelCount = 1

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.nemonoise.audio-capture"))

        let audioStream = AsyncStream<AudioChunk> { [weak self] continuation in
            self?.continuationBox.value = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Take the stream out synchronously BEFORE awaiting: reading
                    // self.stream after stopCapture() returns could instead clear
                    // a newer session's reference (stop/restart race).
                    let stream = self.stream
                    self.stream = nil
                    try? await stream?.stopCapture()
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
        // Extract the current stream on the main actor and hand the Task an
        // owned reference — never read self.stream inside the Task after
        // stopCapture() returns, or a quick restart stores a NEW stream here
        // and this stale teardown nulls it.
        let stream = self.stream
        self.stream = nil
        Task {
            try? await stream?.stopCapture()
        }
        LogService.info("System audio capture stopped", category: "SystemAudioCapture")
    }

    // MARK: - SCStreamOutput

    // `nonisolated`: ScreenCaptureKit calls this on the sample-handler queue.
    // SCStreamOutput isn't Sendable, so a main-actor witness would be asserted
    // (and trap) at runtime under Swift 6.
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
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
        let spectrum = analyzer.analyze(resampled)
        continuationBox.value?.yield(AudioChunk(samples: resampled, rmsLevel: rms, spectrum: spectrum))

        let logCount: Int? = logState.withLock { state in
            state.chunkCount += 1
            let now = Date()
            guard now.timeIntervalSince(state.lastLogTime) >= 2.0 else { return nil }
            state.lastLogTime = now
            return state.chunkCount
        }
        if let logCount {
            LogService.info("Audio capture active: \(logCount) chunks, rms=\(String(format: "%.4f", rms))", category: "SystemAudioCapture")
        }
    }

    // MARK: - Audio Processing

    nonisolated private func extractFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
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
