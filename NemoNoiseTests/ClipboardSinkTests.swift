import XCTest
import AppKit
@testable import NemoNoise

/// Each test uses its own uniquely named pasteboard, never the user's clipboard.
nonisolated final class ClipboardSinkTests: XCTestCase {
    @MainActor func testDeliversFinalToClipboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let sink = ClipboardSink(pasteboard: pasteboard)
        await sink.deliver(TranscriptionResult(text: "hello clipboard", isFinal: true, emotion: nil), isFinal: true)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello clipboard")
    }

    @MainActor func testIgnoresPartial() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("existing", forType: .string)

        let sink = ClipboardSink(pasteboard: pasteboard)
        await sink.deliver(TranscriptionResult(text: "partial", isFinal: false, emotion: nil), isFinal: false)

        XCTAssertEqual(pasteboard.string(forType: .string), "existing")
    }

    @MainActor func testIgnoresEmptyText() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("existing", forType: .string)

        let sink = ClipboardSink(pasteboard: pasteboard)
        await sink.deliver(TranscriptionResult(text: "", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(pasteboard.string(forType: .string), "existing")
    }
}
