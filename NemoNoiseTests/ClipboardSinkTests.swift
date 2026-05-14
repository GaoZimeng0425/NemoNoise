import XCTest
import AppKit
@testable import NemoNoise

final class ClipboardSinkTests: XCTestCase {
    func testDeliversFinalToClipboard() async {
        NSPasteboard.general.clearContents()
        let sink = ClipboardSink()
        await sink.deliver(TranscriptionResult(text: "hello clipboard", isFinal: true, emotion: nil), isFinal: true)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello clipboard")
    }

    func testIgnoresPartial() async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("existing", forType: .string)

        let sink = ClipboardSink()
        await sink.deliver(TranscriptionResult(text: "partial", isFinal: false, emotion: nil), isFinal: false)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "existing")
    }

    func testIgnoresEmptyText() async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("existing", forType: .string)

        let sink = ClipboardSink()
        await sink.deliver(TranscriptionResult(text: "", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "existing")
    }
}
