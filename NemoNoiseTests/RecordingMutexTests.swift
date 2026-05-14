import XCTest
@testable import NemoNoise

@MainActor
final class RecordingMutexTests: XCTestCase {

    func testInitiallyVacant() {
        let mutex = RecordingMutex()
        XCTAssertNil(mutex.current)
    }

    func testAcquireWhenVacantSucceeds() {
        let mutex = RecordingMutex()
        XCTAssertTrue(mutex.tryAcquire(.dictation))
        XCTAssertEqual(mutex.current, .dictation)
    }

    func testAcquireWhileHeldFails() {
        let mutex = RecordingMutex()
        _ = mutex.tryAcquire(.dictation)
        XCTAssertFalse(mutex.tryAcquire(.translation))
        XCTAssertEqual(mutex.current, .dictation)
    }

    func testReleaseByOwnerVacates() {
        let mutex = RecordingMutex()
        _ = mutex.tryAcquire(.dictation)
        mutex.release(.dictation)
        XCTAssertNil(mutex.current)
    }

    func testReleaseByOtherOwnerDoesNothing() {
        let mutex = RecordingMutex()
        _ = mutex.tryAcquire(.dictation)
        mutex.release(.translation)
        XCTAssertEqual(mutex.current, .dictation)
    }

    func testReleaseWhenVacantIsNoop() {
        let mutex = RecordingMutex()
        mutex.release(.dictation)
        XCTAssertNil(mutex.current)
    }

    func testAcquireAfterReleaseSucceeds() {
        let mutex = RecordingMutex()
        _ = mutex.tryAcquire(.dictation)
        mutex.release(.dictation)
        XCTAssertTrue(mutex.tryAcquire(.translation))
    }
}
