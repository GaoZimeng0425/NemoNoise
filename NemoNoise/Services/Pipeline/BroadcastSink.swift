import Foundation

/// Fans out each delivery to every child sink in order. Children should not
/// throw; if one fails silently (e.g. logs internally), the others still run.
final class BroadcastSink: Sink {
    private let sinks: [any Sink]

    init(_ sinks: [any Sink]) {
        self.sinks = sinks
    }

    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        for sink in sinks {
            await sink.deliver(result, isFinal: isFinal)
        }
    }
}
