import XCTest
@testable import NemoNoise

nonisolated final class PipelineProviderTests: XCTestCase {

    // MARK: - Stubs

    /// In-memory factory whose behavior is configured per test. `Sendable` so
    /// the detached bootstrap task can capture it.
    final class StubFactory: ASREngineFactoring, @unchecked Sendable {
        var primaryResult: Result<EngineBuild, Error> = .success(.init(engine: StubEngine(), fallbackReason: nil))
        var translationResult: Result<EngineBuild, Error> = .success(.init(engine: StubEngine(), fallbackReason: nil))
        var meetingThemResult: Result<EngineBuild, Error> = .success(.init(engine: StubEngine(), fallbackReason: nil))
        var fallbackResult: (any ASREngine)? = nil

        func makePrimary() throws -> EngineBuild { try primaryResult.get() }
        func makeTranslation() throws -> EngineBuild { try translationResult.get() }
        func makeMeetingThem() throws -> EngineBuild { try meetingThemResult.get() }
        func makeFallback() -> (any ASREngine)? { fallbackResult }
    }

    /// `nonisolated` so `StubFactory` (nonisolated, like `ASREngineFactoring`)
    /// can create one in its property defaults.
    nonisolated final class StubEngine: ASREngine, @unchecked Sendable {
        let isStreaming = true
        func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
            TranscriptionResult(text: "", isFinal: false, emotion: nil)
        }
        func finish() async throws -> TranscriptionResult { TranscriptionResult(text: "", isFinal: true, emotion: nil) }
        func reset() {}
    }

    /// Offline-engine variant (Qwen3 / SenseVoice shape) for the routing rule.
    nonisolated final class OfflineStubEngine: ASREngine, @unchecked Sendable {
        let isStreaming = false
        func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
            TranscriptionResult(text: "", isFinal: false, emotion: nil)
        }
        func finish() async throws -> TranscriptionResult { TranscriptionResult(text: "", isFinal: true, emotion: nil) }
        func reset() {}
    }

    // MARK: - Helpers

    @MainActor private func makeProvider(factory: StubFactory = StubFactory())
        -> (PipelineProvider, RecordingController, TranslationController, MeetingController)
    {
        let mm = ModelManager()
        let mutex = RecordingMutex()
        let recording = RecordingController()
        let translation = TranslationController()
        let meeting = MeetingController()
        let provider = PipelineProvider(
            factory: factory,
            modelManager: mm,
            mutex: mutex,
            recording: recording,
            translation: translation,
            meeting: meeting
        )
        provider.appleAssetPrewarm = {}
        return (provider, recording, translation, meeting)
    }

    /// Poll readiness until it leaves `.loading` or timeout.
    @MainActor private func waitUntilReady(_ provider: PipelineProvider, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while provider.dictation == .loading || provider.translation == .loading {
            if Date() >= deadline { XCTFail("Provider did not leave .loading within \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Tests

    @MainActor func testInitialStateIsLoading() {
        let (provider, _, _, _) = makeProvider()
        XCTAssertEqual(provider.dictation, .loading)
        XCTAssertEqual(provider.translation, .loading)
    }

    @MainActor func testBootstrapTransitionsToReady() async throws {
        let (provider, _, _, _) = makeProvider()
        provider.bootstrap()
        try await waitUntilReady(provider)
        XCTAssertEqual(provider.dictation, .ready)
        XCTAssertEqual(provider.translation, .ready)
    }

    @MainActor func testTranslationFailureLeavesDictationReady() async throws {
        let factory = StubFactory()
        struct Boom: Error {}
        factory.translationResult = .failure(Boom())
        let (provider, _, _, _) = makeProvider(factory: factory)
        provider.bootstrap()
        try await waitUntilReady(provider)
        XCTAssertEqual(provider.dictation, .ready)
        if case .failed = provider.translation { /* ok */ } else {
            XCTFail("translation should be .failed but is \(provider.translation)")
        }
    }

    @MainActor func testDictationFailureSurfacesAsFailed() async throws {
        let factory = StubFactory()
        struct Boom: Error {}
        factory.primaryResult = .failure(Boom())
        let (provider, _, _, _) = makeProvider(factory: factory)
        provider.bootstrap()
        try await waitUntilReady(provider)
        if case .failed = provider.dictation { /* ok */ } else {
            XCTFail("dictation should be .failed but is \(provider.dictation)")
        }
    }

    @MainActor func testRebuildDictationReachesReadyAgain() async throws {
        let (provider, _, _, _) = makeProvider()
        provider.bootstrap()
        try await waitUntilReady(provider)

        provider.rebuildDictation()
        XCTAssertEqual(provider.dictation, .loading)
        try await waitUntilReady(provider)
        XCTAssertEqual(provider.dictation, .ready)
    }

    /// Engine-pool semantics: a rebuild that lands while a recording is live
    /// still completes (nothing is parked) — the running session keeps the old
    /// engine; the NEXT session picks up the new one via the factory.
    @MainActor func testRebuildDuringRecordingSwapsPoolNotSession() async throws {
        let savedDefaults = UserDefaultsSnapshot([AppDefaults.Keys.engineType])
        defer { savedDefaults.restore() }
        UserDefaults.standard.set("apple", forKey: AppDefaults.Keys.engineType)

        let (provider, recording, _, _) = makeProvider()
        provider.bootstrap()
        try await waitUntilReady(provider)
        XCTAssertEqual(recording.currentEngineLabel, "Apple")

        // A recording is live when the rebuild lands.
        recording.recordingState = .recording
        UserDefaults.standard.set("sensevoice", forKey: AppDefaults.Keys.engineType)
        provider.rebuildDictation()

        // The build completes immediately — no parking, no .loading stall.
        try await waitUntilReady(provider)
        XCTAssertEqual(provider.dictation, .ready)

        // The next session factory serves the new build (label follows).
        XCTAssertEqual(recording.currentEngineLabel, "SenseVoice")
    }

    @MainActor func testApplyDictation_setsLabelFromUserChoice() async throws {
        let savedDefaults = UserDefaultsSnapshot([AppDefaults.Keys.engineType])
        defer { savedDefaults.restore() }
        UserDefaults.standard.set("sensevoice", forKey: AppDefaults.Keys.engineType)

        let (provider, recording, _, _) = makeProvider()
        provider.bootstrap()
        try await waitUntilReady(provider)

        XCTAssertEqual(recording.currentEngineLabel, "SenseVoice")
    }

    @MainActor func testApplyDictation_labelFallsBackToAppleWhenBuildHasFallbackReason() async throws {
        let savedDefaults = UserDefaultsSnapshot([AppDefaults.Keys.engineType])
        defer { savedDefaults.restore() }
        UserDefaults.standard.set("sensevoice", forKey: AppDefaults.Keys.engineType)

        let factory = StubFactory()
        factory.primaryResult = .success(.init(engine: StubEngine(), fallbackReason: "model missing"))
        let (provider, recording, _, _) = makeProvider(factory: factory)
        provider.bootstrap()
        try await waitUntilReady(provider)

        XCTAssertEqual(recording.currentEngineLabel, "Apple")
    }

    // MARK: - Meeting assembly (lazy)

    /// Meeting pipelines build lazily: bootstrap leaves them unbuilt, and the
    /// first `buildMeetingIfNeeded` binds both tracks and flips `.ready`.
    @MainActor func testMeetingBuildsEagerlyWhenLightweightAndBindsBothTracks() async throws {
        let (provider, _, _, meeting) = makeProvider()
        provider.bootstrap()
        try await waitUntilReady(provider)

        // No local models installed (test ModelManager points at an empty
        // dir) → every meeting engine is Apple-stub light → bootstrap builds
        // them so the first "Start Meeting" click just works.
        let deadline = Date().addingTimeInterval(5)
        while provider.meeting == .loading {
            if Date() >= deadline { XCTFail("eager meeting build did not finish within 5s"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(provider.meeting, .ready)
        XCTAssertTrue(meeting.pipelinesReady, "both meeting pipelines must be bound by bootstrap")
        XCTAssertEqual(meeting.themEngineLabel, "Apple", "StubEngine is not Paraformer → Apple label")
    }

    /// A Settings engine change must invalidate the meeting pool: the
    /// engines a meeting uses can't outlive the choice they were built
    /// from. Lightweight (Apple-stub) meeting engines rebuild eagerly right
    /// after, so the next "Start Meeting" click just works again.
    @MainActor func testSettingsRebuildInvalidatesAndRebindsMeetingPool() async throws {
        let savedDefaults = UserDefaultsSnapshot([AppDefaults.Keys.engineType])
        defer { savedDefaults.restore() }
        UserDefaults.standard.set("apple", forKey: AppDefaults.Keys.engineType)

        let (provider, _, _, meeting) = makeProvider()
        provider.bootstrap()
        try await waitUntilReady(provider)
        let built = Date().addingTimeInterval(5)
        while provider.meeting == .loading {
            if Date() >= built { XCTFail("eager meeting build did not finish within 5s"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(meeting.pipelinesReady)

        UserDefaults.standard.set("sensevoice", forKey: AppDefaults.Keys.engineType)
        provider.rebuildDictation()

        // Invalidation is synchronous on the MainActor: the stale pool is
        // unbound before the background rebuild even starts.
        XCTAssertFalse(meeting.pipelinesReady, "a settings rebuild must invalidate the meeting pool")

        try await waitUntilReady(provider)
        let rebound = Date().addingTimeInterval(5)
        while !(meeting.pipelinesReady && provider.meeting == .ready) {
            if Date() >= rebound { XCTFail("meeting pool did not rebind after settings rebuild"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// A FAILED meeting-engine build resolves a waiting first-start instead
    /// of leaving it polling into silence: the controller drops the waiter
    /// and the meeting never begins.
    @MainActor func testMeetingEngineFailureResolvesWaitingStart() async throws {
        let factory = StubFactory()
        struct Boom: Error {}
        factory.meetingThemResult = .failure(Boom())

        // No bootstrap: meeting engines unbuilt, so startMeeting waits.
        let (provider, _, _, meeting) = makeProvider(factory: factory)
        meeting.startMeeting()
        XCTAssertFalse(meeting.isActive)

        let deadline = Date().addingTimeInterval(5)
        while provider.meeting == .loading {
            if Date() >= deadline { XCTFail("meeting build never resolved"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if case .failed = provider.meeting { /* expected */ } else {
            XCTFail("expected meeting .failed but is \(provider.meeting)")
        }
        XCTAssertEqual(meeting.meetingState, .idle, "a failed build must not begin a meeting")
        XCTAssertFalse(meeting.isActive)
    }

    // MARK: - Mic routing (dictation / meeting-Me engine-selection rule)

    /// The Apple-engine branch can't be exercised here (SpeechAnalyzer asset
    /// unavailable in tests) — it returns the mic source and engine unchanged.
    @MainActor func testMicRoutingStreamingEngineGetsGatedSource() {
        let routed = PipelineProvider.micRouting(engine: StubEngine(),
                                                 micSource: MicAudioSource(),
                                                 detector: EnergySpeechDetector())
        XCTAssertTrue(routed.source is VADGatedSource)
        XCTAssertTrue(routed.engine is StubEngine, "streaming engines are used as-is")
    }

    @MainActor func testMicRoutingOfflineEngineGetsSegmentingDecorator() {
        let routed = PipelineProvider.micRouting(engine: OfflineStubEngine(),
                                                 micSource: MicAudioSource(),
                                                 detector: EnergySpeechDetector(),
                                                 vadConfig: .meeting)
        XCTAssertFalse(routed.source is VADGatedSource,
                       "offline engines get the raw mic — segmentation happens at the engine")
        XCTAssertTrue(routed.engine is VADSegmentingEngine)
    }
}
