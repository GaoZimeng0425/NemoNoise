import Foundation

/// Mutual exclusion between dictation and translation modes. Either may hold
/// the mutex at any time; the other is blocked from starting until the holder
/// releases.
@MainActor
final class RecordingMutex {
    enum Owner: Equatable {
        case dictation
        case translation
    }

    private(set) var current: Owner?

    @discardableResult
    func tryAcquire(_ owner: Owner) -> Bool {
        guard current == nil else { return false }
        current = owner
        return true
    }

    func release(_ owner: Owner) {
        if current == owner { current = nil }
    }
}
