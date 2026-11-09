import XCTest
@testable import NemoNoise

nonisolated final class MeetingTranscriptStoreTests: XCTestCase {

    @MainActor private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - JSONL

    @MainActor func testAppendWritesOneJSONLinePerEntry() throws {
        let dir = makeTempDir()
        let store = try XCTUnwrap(MeetingTranscriptStore(directory: dir))

        store.append(track: .me, text: "hello", at: Date(timeIntervalSince1970: 1000))
        store.append(track: .them, text: "hi there", at: Date(timeIntervalSince1970: 1001))
        store.finishFile()

        let content = try String(contentsOf: store.jsonlURL, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "one JSON object per line, got: \(content)")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(MeetingTranscriptStore.Entry.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first.track, "me")
        XCTAssertEqual(first.text, "hello")
        let second = try decoder.decode(MeetingTranscriptStore.Entry.self, from: Data(lines[1].utf8))
        XCTAssertEqual(second.track, "them")
        XCTAssertEqual(second.text, "hi there")
    }

    @MainActor func testEntriesPreserveAppendOrder() throws {
        let dir = makeTempDir()
        let store = try XCTUnwrap(MeetingTranscriptStore(directory: dir))

        store.append(track: .them, text: "one")
        store.append(track: .me, text: "two")
        store.append(track: .them, text: "three")

        XCTAssertEqual(store.entries.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(store.entries.map(\.track), ["them", "me", "them"])
        store.finishFile()
    }

    // MARK: - Markdown export

    @MainActor func testExportMarkdownWritesMeThemLines() throws {
        let dir = makeTempDir()
        let store = try XCTUnwrap(MeetingTranscriptStore(directory: dir))

        store.append(track: .me, text: "第一句")
        store.append(track: .them, text: "second line")
        let url = try XCTUnwrap(store.exportMarkdown())

        XCTAssertEqual(url.pathExtension, "md")
        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Meeting"), "missing header, got: \(markdown)")
        XCTAssertTrue(markdown.contains("[Me] 第一句"))
        XCTAssertTrue(markdown.contains("[Them] second line"))
    }

    /// The export is one Markdown list item per line — not the Swift array
    /// description followed by a stray `.joined(...)` (the interpolation used
    /// to close before `.joined`, leaving it as literal text).
    @MainActor func testExportMarkdownWritesOneListItemPerLine() throws {
        let dir = makeTempDir()
        let store = try XCTUnwrap(MeetingTranscriptStore(directory: dir))
        let t0 = store.startedAt

        store.append(track: .me, text: "第一句", at: t0.addingTimeInterval(1))
        store.append(track: .them, text: "second line", at: t0.addingTimeInterval(65))
        let url = try XCTUnwrap(store.exportMarkdown())

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(Array(lines.dropFirst()), ["- 00:01 [Me] 第一句", "- 01:05 [Them] second line"])
        XCTAssertTrue(lines.first?.hasPrefix("# Meeting — ") == true)
    }

    @MainActor func testExportMarkdownOrdersLinesBySpokenTime() throws {
        let dir = makeTempDir()
        let store = try XCTUnwrap(MeetingTranscriptStore(directory: dir))
        let t0 = store.startedAt

        store.append(track: .them, text: "later", at: t0.addingTimeInterval(30))
        store.append(track: .me, text: "earlier", at: t0.addingTimeInterval(5))
        let url = try XCTUnwrap(store.exportMarkdown())

        let markdown = try String(contentsOf: url, encoding: .utf8)
        let earlier = try XCTUnwrap(markdown.range(of: "00:05 [Me] earlier"))
        let later = try XCTUnwrap(markdown.range(of: "00:30 [Them] later"))
        XCTAssertLessThan(earlier.lowerBound, later.lowerBound)
        XCTAssertEqual(store.entries.map(\.text), ["later", "earlier"], "JSONL keeps arrival order")
    }

    // MARK: - StoreBox indirection

    @MainActor func testStoreBoxDropsAppendsWithoutSession() {
        let box = MeetingStoreBox()
        box.append(track: .me, text: "dropped")   // no current store — no crash
        XCTAssertNil(box.current)
    }

    @MainActor func testStoreBoxRoutesToCurrentStore() throws {
        let dir = makeTempDir()
        let store = try XCTUnwrap(MeetingTranscriptStore(directory: dir))
        let box = MeetingStoreBox()

        box.current = store
        box.append(track: .me, text: "routed")
        XCTAssertEqual(store.entries.map(\.text), ["routed"])

        // Session ends: the box detaches, later appends are dropped.
        box.current = nil
        box.append(track: .them, text: "ignored")
        XCTAssertEqual(store.entries.map(\.text), ["routed"])
        store.finishFile()
    }
}
