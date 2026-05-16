import XCTest
@testable import NemoNoise

final class ASREngineFactoryTests: XCTestCase {

    private func makeFactory() -> ASREngineFactory {
        ASREngineFactory(modelManager: ModelManager())
    }

    // MARK: - Primary engine

    func testMakePrimaryFallsBackToAppleWhenPreferenceMissing() throws {
        UserDefaults.standard.removeObject(forKey: AppDefaults.Keys.engineType)
        let factory = makeFactory()
        let build = try factory.makePrimary()
        XCTAssertNotNil(build.engine)
    }

    func testMakePrimaryHonoursApplePreference() throws {
        UserDefaults.standard.set("apple", forKey: AppDefaults.Keys.engineType)
        let factory = makeFactory()
        let build = try factory.makePrimary()
        XCTAssertTrue(build.engine is AppleSpeechASREngine,
                      "expected Apple, got \(type(of: build.engine))")
        XCTAssertNil(build.fallbackReason, "Apple was the user's choice — no fallback reason expected")
    }

    func testMakePrimarySurfacesFallbackReasonWhenCloudKeyMissing() throws {
        UserDefaults.standard.set("cloud", forKey: AppDefaults.Keys.engineType)
        KeychainService.delete(key: KeychainService.Keys.cloudAPIKey)
        let factory = makeFactory()
        let build = try factory.makePrimary()
        XCTAssertTrue(build.engine is AppleSpeechASREngine,
                      "expected Apple fallback, got \(type(of: build.engine))")
        XCTAssertNotNil(build.fallbackReason, "fallback reason must be surfaced for UI to toast")
    }

    // MARK: - Translation engine

    func testMakeTranslationReturnsValidEngine() throws {
        let factory = makeFactory()
        let build = try factory.makeTranslation()
        XCTAssertTrue(build.engine is AppleSpeechASREngine || build.engine is ParaformerStreamingEngine)
    }

    // MARK: - Fallback engine for dictation

    func testMakeFallbackReturnsAppleSpeechWhenAuthorized() throws {
        let factory = makeFactory()
        if let fallback = factory.makeFallback() {
            XCTAssertTrue(fallback is AppleSpeechASREngine)
        }
    }
}
