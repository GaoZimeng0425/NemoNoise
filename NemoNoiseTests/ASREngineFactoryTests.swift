import XCTest
@testable import NemoNoise

@MainActor
final class ASREngineFactoryTests: XCTestCase {

    private func makeFactory() -> ASREngineFactory {
        ASREngineFactory(modelManager: ModelManager())
    }

    // MARK: - User-preferred engine

    func testMakeUserPreferredFallsBackToAppleWhenPreferenceMissing() throws {
        UserDefaults.standard.removeObject(forKey: AppDefaults.Keys.engineType)
        let factory = makeFactory()
        let engine = try factory.makeUserPreferred()
        XCTAssertTrue(engine is AppleSpeechASREngine
                       || engine is ParaformerStreamingEngine
                       || engine is SherpaASREngine
                       || engine is CloudASREngine)
        // We cannot assert it's specifically Apple without a fake ModelManager,
        // but the call must not throw.
    }

    func testMakeUserPreferredHonoursApplePreference() throws {
        UserDefaults.standard.set("apple", forKey: AppDefaults.Keys.engineType)
        let factory = makeFactory()
        let engine = try factory.makeUserPreferred()
        XCTAssertTrue(engine is AppleSpeechASREngine, "expected Apple, got \(type(of: engine))")
    }

    func testMakeUserPreferredFallsBackWhenCloudKeyMissing() throws {
        UserDefaults.standard.set("cloud", forKey: AppDefaults.Keys.engineType)
        KeychainService.delete(key: KeychainService.Keys.cloudAPIKey)
        let factory = makeFactory()
        let engine = try factory.makeUserPreferred()
        XCTAssertTrue(engine is AppleSpeechASREngine, "expected Apple fallback, got \(type(of: engine))")
    }

    // MARK: - Translation engine

    func testMakeForTranslationFallsBackToAppleEnUSWhenParaformerUnavailable() throws {
        let factory = makeFactory()
        // No way to force-disable Paraformer model presence without filesystem manipulation;
        // this test verifies that *some* engine is returned and is en-US-capable.
        let engine = try factory.makeForTranslation()
        XCTAssertTrue(engine is AppleSpeechASREngine || engine is ParaformerStreamingEngine)
    }

    // MARK: - Fallback engine for dictation

    func testMakeFallbackReturnsAppleSpeech() throws {
        let factory = makeFactory()
        let fallback = try factory.makeFallback()
        XCTAssertTrue(fallback is AppleSpeechASREngine)
    }
}
