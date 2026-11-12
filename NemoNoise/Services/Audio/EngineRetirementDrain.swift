import AVFoundation

/// AVAudioEngine teardown can block on internal IOUnit queues, and its
/// deallocation may overlap the next engine's start — two IOUnits briefly
/// holding the HAL input is what wedges the input into all-zeros after a
/// fast stop→start. Retired engines therefore die on this dedicated serial
/// queue, and a new engine waits for the queue to drain before it is built
/// (FluidVoice's AudioEngineRetirementDrain pattern).
nonisolated final class EngineRetirementDrain: Sendable {
    nonisolated(unsafe) static let shared = EngineRetirementDrain()
    private let queue = DispatchQueue(label: "nemo.engine-retirement")
    private init() {}

    /// Hand over the engine's last strong reference; it deallocates on the
    /// serial queue.
    func retire(_ engine: AVAudioEngine?) {
        guard let engine else { return }
        queue.async { _ = engine }
    }

    /// Resume when every earlier retirement has finished deallocating
    /// (serial-queue barrier), or after `timeout` at the latest.
    func waitDrained(timeout: TimeInterval = 3) async {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [queue] in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    queue.async { cont.resume() }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
