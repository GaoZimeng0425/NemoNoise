import SwiftUI

/// Owns engine + pipeline lifecycle for the entire app. Constructs ONNX
/// engines on a background thread (Task.detached) and hops to MainActor to
/// bind them to controllers. Lives in App/ because it is the *assembly* peer
/// to RecordingController and TranslationController — see
/// docs/superpowers/specs/2026-05-16-pipeline-provider-design.md.
@MainActor @Observable
final class PipelineProvider {

    enum Readiness: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var dictation: Readiness = .loading
    private(set) var translation: Readiness = .loading

    private let factory: any ASREngineFactoring
    private let modelManager: ModelManager
    private let mutex: RecordingMutex
    private weak var recordingController: RecordingController?
    private weak var translationController: TranslationController?

    /// Cached so engine swaps from Settings don't re-pay the punctuator load.
    /// `nil` means the punctuation model is absent or failed to load —
    /// silent degradation, not retried on rebuild.
    private var cachedPunctuator: SherpaOfflinePunctuator?

    init(factory: any ASREngineFactoring,
         modelManager: ModelManager,
         mutex: RecordingMutex,
         recording: RecordingController,
         translation: TranslationController) {
        self.factory = factory
        self.modelManager = modelManager
        self.mutex = mutex
        self.recordingController = recording
        self.translationController = translation

        // Controllers stay ignorant of PipelineProvider. The rebuild request
        // arrives via an opaque closure that PipelineProvider installs here.
        recording.pipelineRebuildHandler = { [weak self] in self?.rebuildDictation() }
    }

    /// Called once from `NemoNoiseApp`. Loads engines on a background thread,
    /// then hops to MainActor to bind pipelines.
    func bootstrap() {
        let factory = self.factory
        let modelManager = self.modelManager
        Task.detached(priority: .userInitiated) { [weak self] in
            let punctuator = Self.makePunctuator(modelManager: modelManager)

            let primaryResult = Result<EngineBuild, Error> { try factory.makePrimary() }
            let fallback = factory.makeFallback()
            let translationResult = Result<EngineBuild, Error> { try factory.makeTranslation() }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cachedPunctuator = punctuator
                self.applyDictation(result: primaryResult, fallback: fallback, punctuator: punctuator)
                self.applyTranslation(result: translationResult, punctuator: punctuator)
                self.translationController?.startHotkeyMonitoring()
            }
        }
    }

    /// Rebuild dictation when the user changes engine choice in Settings.
    /// Reuses the cached punctuator and Apple Speech fallback.
    func rebuildDictation() {
        dictation = .loading
        let factory = self.factory
        let punctuator = self.cachedPunctuator
        Task.detached(priority: .userInitiated) { [weak self] in
            let primaryResult = Result<EngineBuild, Error> { try factory.makePrimary() }
            let fallback = factory.makeFallback()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyDictation(result: primaryResult, fallback: fallback, punctuator: punctuator)
            }
        }
    }

    // MARK: - Apply (MainActor)

    private func applyDictation(result: Result<EngineBuild, Error>,
                                fallback: (any ASREngine)?,
                                punctuator: SherpaOfflinePunctuator?) {
        switch result {
        case .failure(let error):
            dictation = .failed(error.localizedDescription)
            ToastWindowController.show("Dictation engine unavailable: \(error.localizedDescription)",
                                       style: .error, duration: 5)
        case .success(let build):
            if let recordingController {
                let postProcessors: [any PostProcessor] = punctuator.map {
                    [PunctuationProcessor(punctuator: $0)]
                } ?? []
                let pipeline = TranscriptionPipeline(
                    source: MicAudioSource(),
                    engine: build.engine,
                    postProcessors: postProcessors,
                    sink: OverlayProgressSink(target: recordingController),
                    fallback: fallback
                )
                recordingController.bind(pipeline: pipeline, mutex: mutex)
                let label: String
                if build.fallbackReason != nil {
                    label = "Apple"
                } else {
                    let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType)
                                 ?? AppDefaults.Defaults.engineType
                    label = Self.engineDisplayName(for: choice)
                }
                recordingController.currentEngineLabel = label
            }
            // Set readiness even if recordingController weak-ref is nil — in
            // production the controller outlives the provider, so this branch
            // only matters in tests that discard their controller references.
            dictation = .ready
            if let reason = build.fallbackReason {
                ToastWindowController.show(reason, style: .warning, duration: 5)
            }
        }
    }

    private func applyTranslation(result: Result<EngineBuild, Error>,
                                  punctuator: SherpaOfflinePunctuator?) {
        switch result {
        case .failure(let error):
            translation = .failed(error.localizedDescription)
            // Don't toast — translation is opt-in; surface in popover only.
            LogService.warn("Translation engine init failed: \(error.localizedDescription)",
                            category: "PipelineProvider")
        case .success(let build):
            if let translationController {
                var postProcessors: [any PostProcessor] = []
                postProcessors.append(
                    SentenceSegmenter(engine: build.engine)
                )
                if let punctuator {
                    postProcessors.append(PunctuationProcessor(punctuator: punctuator))
                }
                let translateProcessor = AsyncTranslateProcessor(
                    service: translationController.translationService,
                    writer: translationController
                )
                postProcessors.append(translateProcessor)
                let pipeline = TranscriptionPipeline(
                    source: SystemAudioSource(),
                    engine: build.engine,
                    postProcessors: postProcessors,
                    sink: SubtitleOverlaySink(target: translationController),
                    fallback: nil
                )
                translationController.bind(
                    pipeline: pipeline,
                    mutex: mutex,
                    translateProcessor: translateProcessor
                )
            }
            translation = .ready
        }
    }

    // MARK: - Punctuator

    private static func engineDisplayName(for choice: String) -> String {
        switch choice {
        case "apple":      return "Apple"
        case "sensevoice": return "SenseVoice"
        case "paraformer": return "Paraformer"
        case "qwen3":      return "Qwen3"
        case "cloud":      return "Cloud"
        default:           return "Apple"
        }
    }

    /// Called from `Task.detached` — `nonisolated` because the enclosing class
    /// is `@MainActor` but this helper does no MainActor work.
    nonisolated private static func makePunctuator(modelManager: ModelManager) -> SherpaOfflinePunctuator? {
        guard let dir = modelManager.modelPath(for: .punctuation) else { return nil }
        let path = dir.appendingPathComponent("model.onnx").path
        guard let punctuator = SherpaOfflinePunctuator(modelPath: path) else {
            LogService.warn("Failed to load punctuation model at \(path)",
                            category: "PipelineProvider")
            return nil
        }
        LogService.info("Punctuation processor enabled", category: "PipelineProvider")
        return punctuator
    }
}
