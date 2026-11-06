import XCTest
@testable import NemoNoise

nonisolated final class RecordingMutexTests: XCTestCase {

    @MainActor func testInitiallyVacant() {
        let mutex = RecordingMutex()
        XCTAssertNil(mutex.current)
    }

    @MainActor func testAcquireWhenVacantSucceeds() {
        let mutex = RecordingMutex()
        XCTAssertTrue(mutex.tryAcquire(.dictation))
        XCTAssertEqual(mutex.current, .dictation)
    }

    @MainActor func testAcquireWhileHeldFails() {
        let mutex = RecordingMutex()
        _ = mutex.tryAcquire(.dictation)
        XCTAssertFalse(mutex.tryAcquire(.translation))
        XCTAssertEqual(mutex.current, .dictation)
    }

    @MainActor func testReleaseByOwnerVacates() {
        let mutex = RecordingMutex()
        _ = mutex.tryAcquire(.dictation)
        mutex.release(.dictation)
        XCTAssertNil(mutex.current)
    }

    @MainActor func testReleaseByOtherOwnerDoesNothing() {
        let mutex = RecordingMutex()
        _ = mutex.tryAcquire(.dictation)
        mutex.release(.translation)
        XCTAssertEqual(mutex.current, .dictation)
    }

    @MainActor func testReleaseWhenVacantIsNoop() {
        let mutex = RecordingMutex()
        mutex.release(.dictation)
        XCTAssertNil(mutex.current)
    }

    @MainActor func testAcquireAfterReleaseSucceeds() {
        let mutex = RecordingMutex()
        _ = mutex.tryAcquire(.dictation)
        mutex.release(.dictation)
        XCTAssertTrue(mutex.tryAcquire(.translation))
    }
}
