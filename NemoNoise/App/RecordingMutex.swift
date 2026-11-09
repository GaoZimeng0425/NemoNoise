import Foundation

/// Mutual exclusion between dictation, translation, and meeting modes. Any one
/// may hold the mutex at a time; the others are blocked from starting until
/// the holder releases.
@MainActor
final class RecordingMutex {
    enum Owner: Equatable {
        case dictation
        case translation
        case meeting
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
