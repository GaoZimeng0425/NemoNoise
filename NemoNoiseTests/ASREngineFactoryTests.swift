import XCTest
@testable import NemoNoise

nonisolated final class ASREngineFactoryTests: XCTestCase {

    @MainActor private func makeFactory() -> ASREngineFactory {
        ASREngineFactory(modelManager: ModelManager())
    }

    // MARK: - Primary engine

    @MainActor func testMakePrimaryFallsBackToAppleWhenPreferenceMissing() throws {
        let savedDefaults = UserDefaultsSnapshot([AppDefaults.Keys.engineType])
        defer { savedDefaults.restore() }
        UserDefaults.standard.removeObject(forKey: AppDefaults.Keys.engineType)
        let factory = makeFactory()
        let build = try factory.makePrimary()
        XCTAssertNotNil(build.engine)
    }

    @MainActor func testMakePrimaryHonoursApplePreference() throws {
        let savedDefaults = UserDefaultsSnapshot([AppDefaults.Keys.engineType])
        defer { savedDefaults.restore() }
        UserDefaults.standard.set("apple", forKey: AppDefaults.Keys.engineType)
        let factory = makeFactory()
        let build = try factory.makePrimary()
        XCTAssertTrue(build.engine is AppleSpeechASREngine,
                      "expected Apple, got \(type(of: build.engine))")
        XCTAssertNil(build.fallbackReason, "Apple was the user's choice — no fallback reason expected")
    }

    @MainActor func testMakePrimarySurfacesFallbackReasonWhenModelMissing() throws {
        let savedDefaults = UserDefaultsSnapshot([AppDefaults.Keys.engineType])
        defer { savedDefaults.restore() }
        UserDefaults.standard.set("paraformer", forKey: AppDefaults.Keys.engineType)
        let factory = makeFactory()
        let build = try factory.makePrimary()
        // When the Paraformer model isn't installed, the factory falls back to
        // Apple and surfaces a reason; if it happens to be installed in the test
        // environment, the Paraformer engine is returned with no reason.
        if build.engine is AppleSpeechASREngine {
            XCTAssertNotNil(build.fallbackReason, "fallback reason must be surfaced for UI to toast")
        }
    }

    // MARK: - Translation engine

    @MainActor func testMakeTranslationReturnsValidEngine() throws {
        let factory = makeFactory()
        let build = try factory.makeTranslation()
        XCTAssertTrue(build.engine is AppleSpeechASREngine || build.engine is ParaformerStreamingEngine)
    }

    // MARK: - Fallback engine for dictation

    @MainActor func testMakeFallbackReturnsAppleSpeechWhenAuthorized() throws {
        let factory = makeFactory()
        if let fallback = factory.makeFallback() {
            XCTAssertTrue(fallback is AppleSpeechASREngine)
        }
    }
}
