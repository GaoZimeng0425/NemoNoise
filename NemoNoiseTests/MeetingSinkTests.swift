import XCTest
@testable import NemoNoise

nonisolated final class MeetingSinkTests: XCTestCase {

    @MainActor
    final class StubMeetingWriter: MeetingWriter {
        var meetingLines: [MeetingLine] = []
        var meetingPartialMe: String = ""
        var meetingPartialThem: String = ""
    }

    @MainActor private func makeBoxWithStore() throws -> (MeetingStoreBox, MeetingTranscriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try XCTUnwrap(MeetingTranscriptStore(directory: dir))
        let box = MeetingStoreBox()
        box.current = store
        return (box, store, dir)
    }

    // MARK: - Partials

    @MainActor func testPartialUpdatesOnlyItsTrack() async throws {
        let (box, store, _) = try makeBoxWithStore()
        let writer = StubMeetingWriter()
        let meSink = MeetingSink(track: .me, target: writer, storeBox: box)
        let themSink = MeetingSink(track: .them, target: writer, storeBox: box)

        await meSink.deliver(TranscriptionResult(text: "me partial", isFinal: false, emotion: nil), isFinal: false)
        await themSink.deliver(TranscriptionResult(text: "them partial", isFinal: false, emotion: nil), isFinal: false)

        XCTAssertEqual(writer.meetingPartialMe, "me partial")
        XCTAssertEqual(writer.meetingPartialThem, "them partial")
        XCTAssertTrue(writer.meetingLines.isEmpty, "partials must not confirm lines")
        XCTAssertTrue(store.entries.isEmpty, "partials must not hit disk")
        store.finishFile()
    }

    // MARK: - Finals

    @MainActor func testFinalAppendsLineAndClearsTrackPartial() async throws {
        let (box, store, _) = try makeBoxWithStore()
        let writer = StubMeetingWriter()
        let themSink = MeetingSink(track: .them, target: writer, storeBox: box)

        await themSink.deliver(TranscriptionResult(text: "building up", isFinal: false, emotion: nil), isFinal: false)
        await themSink.deliver(TranscriptionResult(text: "final text", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertEqual(writer.meetingLines.count, 1)
        XCTAssertEqual(writer.meetingLines[0].track, .them)
        XCTAssertEqual(writer.meetingLines[0].text, "final text")
        XCTAssertEqual(writer.meetingPartialThem, "", "confirmed line must clear the track partial")
        XCTAssertEqual(store.entries.map(\.text), ["final text"], "finals must reach the JSONL store")
        store.finishFile()
    }

    @MainActor func testEmptyAndWhitespaceTextIsIgnored() async throws {
        let (box, store, _) = try makeBoxWithStore()
        let writer = StubMeetingWriter()
        let sink = MeetingSink(track: .me, target: writer, storeBox: box)

        await sink.deliver(TranscriptionResult(text: "", isFinal: false, emotion: nil), isFinal: false)
        await sink.deliver(TranscriptionResult(text: "   \n", isFinal: true, emotion: nil), isFinal: true)

        XCTAssertTrue(writer.meetingLines.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
        store.finishFile()
    }
    // MARK: - When the line was spoken

    @MainActor func testFinalUsesSpokenAtForLineAndStore() async throws {
        let (box, store, _) = try makeBoxWithStore()
        let writer = StubMeetingWriter()
        let sink = MeetingSink(track: .them, target: writer, storeBox: box)
        let spoken = Date(timeIntervalSinceNow: -20)

        await sink.deliver(TranscriptionResult(text: "said earlier", isFinal: true, emotion: nil, spokenAt: spoken),
                           isFinal: true)

        XCTAssertEqual(writer.meetingLines.first?.timestamp, spoken)
        XCTAssertEqual(store.entries.first?.ts, spoken)
        store.finishFile()
    }

    @MainActor func testFinalWithoutSpokenAtFallsBackToNow() async throws {
        let (box, store, _) = try makeBoxWithStore()
        let writer = StubMeetingWriter()
        let sink = MeetingSink(track: .me, target: writer, storeBox: box)

        await sink.deliver(TranscriptionResult(text: "now", isFinal: true, emotion: nil), isFinal: true)

        let ts = try XCTUnwrap(writer.meetingLines.first?.timestamp)
        XCTAssertLessThan(abs(ts.timeIntervalSinceNow), 2)
        store.finishFile()
    }

    /// A slow track's line lands after a fast track's later one; the panel
    /// shows them in the order they were spoken.
    @MainActor func testLateLineIsInsertedInSpokenOrder() async throws {
        let (box, store, _) = try makeBoxWithStore()
        let writer = StubMeetingWriter()
        let me = MeetingSink(track: .me, target: writer, storeBox: box)
        let them = MeetingSink(track: .them, target: writer, storeBox: box)
        let t0 = Date(timeIntervalSinceNow: -60)

        await them.deliver(TranscriptionResult(text: "second", isFinal: true, emotion: nil,
                                               spokenAt: t0.addingTimeInterval(10)), isFinal: true)
        await me.deliver(TranscriptionResult(text: "first", isFinal: true, emotion: nil,
                                             spokenAt: t0.addingTimeInterval(2)), isFinal: true)

        XCTAssertEqual(writer.meetingLines.map(\.text), ["first", "second"])
        store.finishFile()
    }
}
