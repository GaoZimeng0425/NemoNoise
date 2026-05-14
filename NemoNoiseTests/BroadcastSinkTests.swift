import XCTest
@testable import NemoNoise

final class RecordingSink: Sink, @unchecked Sendable {
    private(set) var delivered: [(text: String, isFinal: Bool)] = []
    func deliver(_ result: TranscriptionResult, isFinal: Bool) async {
        delivered.append((result.text, isFinal))
    }
}

final class BroadcastSinkTests: XCTestCase {
    func testDeliversToAllSinks() async {
        let a = RecordingSink()
        let b = RecordingSink()
        let broadcast = BroadcastSink([a, b])

        await broadcast.deliver(TranscriptionResult(text: "hello", isFinal: false, emotion: nil), isFinal: false)
        await broadcast.deliver(TranscriptionResult(text: "world", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(a.delivered.count, 2)
        XCTAssertEqual(b.delivered.count, 2)
        XCTAssertEqual(a.delivered.last?.text, "world")
        XCTAssertTrue(a.delivered.last?.isFinal == true)
    }

    func testEmptyBroadcastIsNoop() async {
        let broadcast = BroadcastSink([])
        await broadcast.deliver(TranscriptionResult(text: "x", isFinal: false, emotion: nil), isFinal: false)
        // No assertion needed; must not crash.
    }
}
