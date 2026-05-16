import XCTest
@testable import NemoNoise

@MainActor
final class PipelineProviderTests: XCTestCase {

    // MARK: - Stubs

    /// In-memory factory whose behavior is configured per test. `Sendable` so
    /// the detached bootstrap task can capture it.
    final class StubFactory: ASREngineFactoring, @unchecked Sendable {
        var primaryResult: Result<EngineBuild, Error> = .success(.init(engine: StubEngine(), fallbackReason: nil))
        var translationResult: Result<EngineBuild, Error> = .success(.init(engine: StubEngine(), fallbackReason: nil))
        var fallbackResult: (any ASREngine)? = nil

        func makePrimary() throws -> EngineBuild { try primaryResult.get() }
        func makeTranslation() throws -> EngineBuild { try translationResult.get() }
        func makeFallback() -> (any ASREngine)? { fallbackResult }
    }

    final class StubEngine: ASREngine, @unchecked Sendable {
        let isStreaming = true
        func feedChunk(_ samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
            TranscriptionResult(text: "", isFinal: false, emotion: nil)
        }
        func finish() async throws -> TranscriptionResult { TranscriptionResult(text: "", isFinal: true, emotion: nil) }
        func reset() {}
    }

    // MARK: - Helpers

    private func makeProvider(factory: StubFactory = StubFactory())
        -> (PipelineProvider, RecordingController, TranslationController)
    {
        let mm = ModelManager()
        let mutex = RecordingMutex()
        let recording = RecordingController()
        let translation = TranslationController()
        let provider = PipelineProvider(
            factory: factory,
            modelManager: mm,
            mutex: mutex,
            recording: recording,
            translation: translation
        )
        return (provider, recording, translation)
    }

    /// Poll readiness until it leaves `.loading` or timeout.
    private func waitUntilReady(_ provider: PipelineProvider, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while provider.dictation == .loading || provider.translation == .loading {
            if Date() >= deadline { XCTFail("Provider did not leave .loading within \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Tests

    func testInitialStateIsLoading() {
        let (provider, _, _) = makeProvider()
        XCTAssertEqual(provider.dictation, .loading)
        XCTAssertEqual(provider.translation, .loading)
    }

    func testBootstrapTransitionsToReady() async throws {
        let (provider, _, _) = makeProvider()
        provider.bootstrap()
        try await waitUntilReady(provider)
        XCTAssertEqual(provider.dictation, .ready)
        XCTAssertEqual(provider.translation, .ready)
    }

    func testTranslationFailureLeavesDictationReady() async throws {
        let factory = StubFactory()
        struct Boom: Error {}
        factory.translationResult = .failure(Boom())
        let (provider, _, _) = makeProvider(factory: factory)
        provider.bootstrap()
        try await waitUntilReady(provider)
        XCTAssertEqual(provider.dictation, .ready)
        if case .failed = provider.translation { /* ok */ } else {
            XCTFail("translation should be .failed but is \(provider.translation)")
        }
    }

    func testDictationFailureSurfacesAsFailed() async throws {
        let factory = StubFactory()
        struct Boom: Error {}
        factory.primaryResult = .failure(Boom())
        let (provider, _, _) = makeProvider(factory: factory)
        provider.bootstrap()
        try await waitUntilReady(provider)
        if case .failed = provider.dictation { /* ok */ } else {
            XCTFail("dictation should be .failed but is \(provider.dictation)")
        }
    }

    func testRebuildDictationReachesReadyAgain() async throws {
        let (provider, _, _) = makeProvider()
        provider.bootstrap()
        try await waitUntilReady(provider)

        provider.rebuildDictation()
        XCTAssertEqual(provider.dictation, .loading)
        try await waitUntilReady(provider)
        XCTAssertEqual(provider.dictation, .ready)
    }
}
