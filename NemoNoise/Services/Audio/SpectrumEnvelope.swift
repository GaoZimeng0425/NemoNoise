import Foundation

/// Smooths a live spectrum for waveform display: fast attack, slower
/// release, so peaks jump out and decay visibly. Shared by the dictation
/// overlay and the translation subtitle meter so both feel identical.
nonisolated struct SpectrumEnvelope {
    /// Smoothed bins — the display state; read after each `apply`.
    private(set) var bins: [Float]

    private let dt: Float
    private let attackTau: Float
    private let releaseTau: Float

    init(binCount: Int = 16, dt: Float = 0.085, attackTau: Float = 0.06, releaseTau: Float = 0.20) {
        precondition(binCount > 0)
        self.bins = Array(repeating: 0, count: binCount)
        self.dt = dt
        self.attackTau = attackTau
        self.releaseTau = releaseTau
    }

    /// One meter frame: moves each bin toward `target` — attacking fast on
    /// a rising target, releasing slowly on a falling one. A target of a
    /// different length restarts from zeros at the new size.
    mutating func apply(_ target: [Float]) {
        if bins.count != target.count {
            bins = Array(repeating: 0, count: target.count)
        }
        for i in 0..<bins.count {
            let tau = target[i] > bins[i] ? attackTau : releaseTau
            let alpha = 1 - exp(-dt / tau)
            bins[i] += (target[i] - bins[i]) * alpha
        }
    }

    /// Back to silence (session end).
    mutating func reset() {
        for i in bins.indices { bins[i] = 0 }
    }
}
