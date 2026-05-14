import AVFoundation

/// Float32 mono → mono resampler.
///
/// Owns a single `AVAudioConverter` for a fixed source-sample-rate / target pair.
/// Each call to `resample` performs one-shot conversion of a complete chunk.
/// Marked `@unchecked Sendable` because `AVAudioConverter` is safe under serial
/// use (one tap thread / one `SCStream` queue per instance).
final class AudioResampler: @unchecked Sendable {
    let sourceRate: Double
    let targetRate: Double
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(sourceRate: Double, targetRate: Double) {
        guard sourceRate > 0, targetRate > 0,
              let sf = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let tf = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: sf, to: tf)
        else { return nil }
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        self.sourceFormat = sf
        self.targetFormat = tf
        self.converter = conv
    }

    /// Resample raw float samples. Returns `nil` on conversion error.
    func resample(_ samples: [Float]) -> [Float]? {
        guard !samples.isEmpty else { return [] }

        let srcCount = AVAudioFrameCount(samples.count)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: srcCount) else { return nil }
        srcBuffer.frameLength = srcCount
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress, let channelData = srcBuffer.floatChannelData else { return }
            channelData[0].initialize(from: base, count: samples.count)
        }

        let ratio = targetRate / sourceRate
        let dstCount = AVAudioFrameCount(Double(samples.count) * ratio) + 1
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: dstCount) else { return nil }

        return resample(buffer: srcBuffer, into: dstBuffer)
    }

    /// Resample from a pre-filled `AVAudioPCMBuffer`. Useful when the source comes
    /// from an `AVAudioEngine` tap and the buffer already exists.
    func resample(buffer src: AVAudioPCMBuffer) -> [Float]? {
        let ratio = targetRate / src.format.sampleRate
        let dstCount = AVAudioFrameCount(Double(src.frameLength) * ratio) + 1
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: dstCount) else { return nil }
        return resample(buffer: src, into: dstBuffer)
    }

    private func resample(buffer src: AVAudioPCMBuffer, into dst: AVAudioPCMBuffer) -> [Float]? {
        var inputConsumed = false
        let status = converter.convert(to: dst, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return src
        }
        guard status != .error, let channelData = dst.floatChannelData else { return nil }
        let frameLength = Int(dst.frameLength)
        guard frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}
