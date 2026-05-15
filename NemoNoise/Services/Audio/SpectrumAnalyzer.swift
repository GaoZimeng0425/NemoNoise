import Accelerate
import Foundation

final class SpectrumAnalyzer: @unchecked Sendable {
    private let binCount: Int
    private let sampleRate: Float
    private let fftSize: Int = 1024
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    private let bandEdges: [Int]

    private let minDb: Float = -60
    private let maxDb: Float = 0
    private let lowFreq: Float = 80
    private let highFreq: Float = 4000

    init(binCount: Int = 16, sampleRate: Float = 16000) {
        self.binCount = binCount
        self.sampleRate = sampleRate
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = hann

        let nyquist = sampleRate / 2
        let binHz = nyquist / Float(fftSize / 2)
        var edges: [Int] = []
        let logLow = log(lowFreq)
        let logHigh = log(highFreq)
        for i in 0...binCount {
            let f = exp(logLow + (logHigh - logLow) * Float(i) / Float(binCount))
            edges.append(min(fftSize / 2 - 1, max(1, Int(f / binHz))))
        }
        self.bandEdges = edges
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func analyze(_ samples: [Float]) -> [Float] {
        var buffer = [Float](repeating: 0, count: fftSize)
        let copyCount = min(samples.count, fftSize)
        for i in 0..<copyCount {
            buffer[i] = samples[i]
        }

        vDSP_vmul(buffer, 1, window, 1, &buffer, 1, vDSP_Length(fftSize))

        let halfSize = fftSize / 2
        var realp = [Float](repeating: 0, count: halfSize)
        var imagp = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var splitComplex = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buffer.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { cp in
                        vDSP_ctoz(cp, 2, &splitComplex, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        var sqrtMags = [Float](repeating: 0, count: halfSize)
        var count = Int32(halfSize)
        vvsqrtf(&sqrtMags, magnitudes, &count)

        var output = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            let lo = bandEdges[i]
            let hi = max(lo + 1, bandEdges[i + 1])
            var peak: Float = 0
            for j in lo..<hi where j < halfSize {
                if sqrtMags[j] > peak { peak = sqrtMags[j] }
            }
            let db = 20 * log10(max(peak, 1e-7))
            let clamped = min(maxDb, max(minDb, db))
            output[i] = (clamped - minDb) / (maxDb - minDb)
        }
        return output
    }
}
