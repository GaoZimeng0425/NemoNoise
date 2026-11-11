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
    /// Meeting pipelines build lazily on first use, so engine memory is only
    /// paid when a meeting actually runs. Stays `.loading` until then.
    private(set) var meeting: Readiness = .loading

    private let factory: any ASREngineFactoring
    private let modelManager: ModelManager
    private let mutex: RecordingMutex
    private weak var recordingController: RecordingController?
    private weak var translationController: TranslationController?
    private weak var meetingController: MeetingController?
    private var meetingBuilt = false

    /// Cached so engine swaps from Settings don't re-pay the punctuator load.
    /// `nil` means the punctuation model is absent or failed to load —
    /// silent degradation, not retried on rebuild.
    private var cachedPunctuator: SherpaOfflinePunctuator?
    /// Launch-time SpeechAnalyzer asset warm-up; tests replace it with a
    /// no-op (the asset IPC is slow and network-dependent there).
    var appleAssetPrewarm: @Sendable () async -> Void = {
        // en-US backs the translation fallback, the current locale the
        // dictation fallback.
        Task { await AppleSpeechASREngine.prewarm(locale: "en-US") }
        Task { await AppleSpeechASREngine.prewarm() }
    }

    /// The resident dictation engine build — the expensive part (ONNX model
    /// in memory) that stays loaded across sessions. A Settings change
    /// rebuilds this in the background and swaps the reference; a session
    /// that is already recording keeps the old engine until it ends.
    private var dictationBuild: EngineBuild?
    private var dictationFallback: (any ASREngine)?
    private var dictationEngineLabel = "Apple"
    /// Resident translation engine build + shared translate processor.
    private var translationBuild: EngineBuild?
    private var translationTranslateProcessor: AsyncTranslateProcessor?
    /// Resident meeting engine builds — assembled into fresh pipelines on
    /// each meeting start.
    private var meetingBuilds: Optional<(me: EngineBuild,
                                         meFallback: (any ASREngine)?,
                                         them: EngineBuild,
                                         punctuator: SherpaOfflinePunctuator?)> = nil
    /// Set when engines were unloaded by memory pressure; the next session
    /// factory call rebuilds them lazily instead of failing silently.
    private var enginesUnloadedByPressure = false
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    /// Silero VAD detector — loading the ONNX model per session would be
    /// wasteful; one instance is shared (sessions are mutually exclusive and
    /// each `VADGatedSource.start()` resets it).
    private var cachedDetector: (any VADSpeechDetector)?

    init(factory: any ASREngineFactoring,
         modelManager: ModelManager,
         mutex: RecordingMutex,
         recording: RecordingController,
         translation: TranslationController,
         meeting: MeetingController) {
        self.factory = factory
        self.modelManager = modelManager
        self.mutex = mutex
        self.recordingController = recording
        self.translationController = translation
        self.meetingController = meeting

        // Controllers stay ignorant of PipelineProvider. The rebuild request
        // arrives via an opaque closure that PipelineProvider installs here.
        recording.pipelineRebuildHandler = { [weak self] in self?.rebuildDictation() }
        meeting.preparePipelines = { [weak self] in self?.buildMeetingIfNeeded() }
        observeMemoryPressure()
    }

    /// VoiceInk pattern: with resident models up to ~1 GB, a system memory
    /// squeeze would otherwise get the whole menu-bar app Jetsam-killed.
    /// On pressure, drop every engine (idle check first — a live session's
    /// pipelines hold their own engine references and finish unaffected);
    /// engines rebuild lazily on the next session, or as soon as pressure
    /// returns to normal.
    private func observeMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            // The source fires on level *changes* only: a fixed-delay reload
            // could put ~1 GB back while memory is still tight with no event
            // left to unload it again. Rebuild when the squeeze is over.
            if source?.data.contains(.normal) == true {
                self.rebuildAfterPressureIfNeeded()
                return
            }
            let dictationIdle = (self.recordingController?.recordingState ?? .ready) == .ready
            let translationIdle = !(self.translationController?.isActive ?? false)
            let meetingIdle = !(self.meetingController?.isActive ?? false)
            guard dictationIdle, translationIdle, meetingIdle else { return }

            // Unloading is only worth it when something heavy is resident.
            // With no local ASR models the pool is Silero + punctuator plus
            // Apple engines (a few MB total) — dropping it frees nothing but
            // churns the "engines warming up" state (observed live: repeated
            // pressure events left the menubar on "Preparing engines…" all
            // morning with nothing actually freed).
            // Nothing built (failed / already unloaded) holds no memory.
            func isLight(_ build: EngineBuild?) -> Bool {
                build.map { $0.engine is AppleSpeechASREngine } ?? true
            }
            let onlyLightEngines = isLight(self.dictationBuild)
                && isLight(self.translationBuild)
                && (self.meetingBuilds.map { isLight($0.me) && isLight($0.them) } ?? true)
            guard !onlyLightEngines else {
                LogService.info("Memory pressure — only lightweight engines resident, keeping them", category: "PipelineProvider")
                return
            }

            LogService.warn("Memory pressure — unloading resident engines", category: "PipelineProvider")
            self.enginesUnloadedByPressure = true
            self.dictationBuild = nil
            self.dictationFallback = nil
            self.translationBuild = nil
            self.translationTranslateProcessor = nil
            self.meetingBuilds = nil
            self.meetingBuilt = false
            self.meetingController?.unbind()
            self.dictation = .loading
            self.translation = .loading
            self.meeting = .loading

            // Recovery: the `.normal` branch above rebuilds when the squeeze
            // passes (without it the menubar sat on "engines warming up…"
            // after an overnight pressure event); a session started before
            // that rebuilds through the lazy path and clears the flag.
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Lazy pressure recovery: rebuild dictation + translation engines once.
    /// Meeting rebuilds through its own `preparePipelines` path.
    private func rebuildAfterPressureIfNeeded() {
        guard enginesUnloadedByPressure else { return }
        enginesUnloadedByPressure = false
        LogService.info("Rebuilding engines after memory-pressure unload", category: "PipelineProvider")
        let factory = self.factory
        let punctuator = self.cachedPunctuator
        Task.detached(priority: .userInitiated) { [weak self] in
            let primaryResult = Result<EngineBuild, Error> { try factory.makePrimary() }
            await Self.warmUp(primaryResult)
            let translationResult = Result<EngineBuild, Error> { try factory.makeTranslation() }
            let fallback = factory.makeFallback()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyDictation(result: primaryResult, fallback: fallback, punctuator: punctuator)
                self.applyTranslation(result: translationResult, punctuator: punctuator)
            }
        }
    }

    /// Called once from `NemoNoiseApp`. Loads engines on a background thread,
    /// then hops to MainActor to bind pipelines.
    func bootstrap() {
        let factory = self.factory
        let modelManager = self.modelManager
        Task.detached(priority: .userInitiated) { [weak self] in
            // Warm the SpeechAnalyzer assets (dictation fallback + translation
            // fallback) before anything needs them — the first session then
            // skips the slow asset IPC/download entirely. Injectable so tests
            // can stub it out (asset IPC is slow/unavailable there).
            await self?.appleAssetPrewarm()

            let punctuator = Self.makePunctuator(modelManager: modelManager)

            let primaryResult = Result<EngineBuild, Error> { try factory.makePrimary() }
            await Self.warmUp(primaryResult)
            let fallback = factory.makeFallback()
            let translationResult = Result<EngineBuild, Error> { try factory.makeTranslation() }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cachedPunctuator = punctuator
                self.applyDictation(result: primaryResult, fallback: fallback, punctuator: punctuator)
                self.applyTranslation(result: translationResult, punctuator: punctuator)
                self.translationController?.startHotkeyMonitoring()
                // With no local models every meeting engine is an Apple engine
                // and the build is nearly free — do it eagerly so the FIRST
                // "Start Meeting" click just works (no preparing toast, no
                // second click). Heavy local models keep the lazy path.
                if self.meetingEnginesAreLightweight() {
                    LogService.info("Meeting engines are lightweight — building eagerly", category: "PipelineProvider")
                    self.buildMeetingIfNeeded()
                }
            }
        }
    }

    /// Rebuild dictation engines when the user changes engine choice in
    /// Settings. Builds in the background and swaps the resident build when
    /// ready — a recording that is live simply keeps the old engine until it
    /// ends; the next session picks up the new one. No parking, no guards.
    func rebuildDictation() {
        dictation = .loading
        let factory = self.factory
        let punctuator = self.cachedPunctuator
        Task.detached(priority: .userInitiated) { [weak self] in
            let primaryResult = Result<EngineBuild, Error> { try factory.makePrimary() }
            await Self.warmUp(primaryResult)
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
            dictationBuild = nil
            dictation = .failed(error.localizedDescription)
            ToastWindowController.show("Dictation engine unavailable: \(error.localizedDescription)",
                                       style: .error, duration: 5)
        case .success(let build):
            dictationBuild = build
            dictationFallback = fallback
            let label = Self.primaryEngineLabel(for: build)
            dictationEngineLabel = label

            if let recordingController {
                recordingController.bind(
                    pipelineFactory: { [weak self] in self?.newDictationPipeline() },
                    engineLabel: { [weak self] in self?.dictationEngineLabel ?? "Apple" },
                    mutex: mutex
                )
                recordingController.currentEngineLabel = label
            }
            dictation = .ready
            if let reason = build.fallbackReason {
                ToastWindowController.show(reason, style: .warning, duration: 5)
            }
        }
    }

    /// A cheap per-session pipeline shell around the resident dictation
    /// engines: fresh audio source + gate each recording, shared engine.
    /// Called by the controller on every hotkey press.
    private func newDictationPipeline() -> TranscriptionPipeline? {
        guard let build = dictationBuild, let recordingController else {
            rebuildAfterPressureIfNeeded()
            return nil
        }

        let detector = sharedDetector()
        let routed = Self.micRouting(engine: build.engine,
                                     micSource: makeMicSource(),
                                     detector: detector,
                                     vadConfig: .default)

        return TranscriptionPipeline(
            source: routed.source,
            engine: routed.engine,
            postProcessors: Self.dictationProcessors(engine: build.engine, punctuator: cachedPunctuator),
            sink: OverlayProgressSink(target: recordingController),
            fallback: dictationFallback
        )
    }

    /// One detector instance shared across sessions (the ONNX model load is
    /// not free). Safe: sessions are mutually exclusive via the mutex and
    /// `VADGatedSource.start()` resets it each session.
    private func sharedDetector() -> any VADSpeechDetector {
        if let cachedDetector { return cachedDetector }
        let detector = makeDetector()
        cachedDetector = detector
        return detector
    }

    /// muesli pattern: the first decode pays one-time setup (graph compile /
    /// allocation), which lands as a stutter on the user's first utterance.
    /// Feed a second of silence while still loading. Runs inside the build
    /// task BEFORE the engine is published: warming a published engine raced
    /// a session that started meanwhile on the same engine (a reset wiping
    /// its segment; concurrent sherpa stream access). Skipped for
    /// SpeechAnalyzer (system-managed; the launch-time asset prewarm covers it).
    nonisolated private static func warmUp(_ result: Result<EngineBuild, Error>) async {
        guard case .success(let build) = result, !(build.engine is AppleSpeechASREngine) else { return }
        let engine = build.engine
        _ = try? await engine.feedChunk([Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        _ = try? await engine.finish()
        await MainActor.run { engine.reset() }
    }

    private func applyTranslation(result: Result<EngineBuild, Error>,
                                  punctuator: SherpaOfflinePunctuator?) {
        switch result {
        case .failure(let error):
            translationBuild = nil
            translation = .failed(error.localizedDescription)
            // Don't toast — translation is opt-in; surface in popover only.
            LogService.warn("Translation engine init failed: \(error.localizedDescription)",
                            category: "PipelineProvider")
        case .success(let build):
            translationBuild = build
            if let translationController {
                let translateProcessor = AsyncTranslateProcessor(
                    service: translationController.translationService,
                    writer: translationController
                )
                // Kept alive by the provider — the per-activation pipelines
                // below all share it.
                translationTranslateProcessor = translateProcessor
                translationController.bind(
                    pipelineFactory: { [weak self] in self?.newTranslationPipeline() },
                    mutex: mutex,
                    translateProcessor: translateProcessor
                )
            }
            translation = .ready
        }
    }

    /// A fresh per-activation translation pipeline (cheap shell; the engine
    /// and the translate processor are resident).
    private func newTranslationPipeline() -> TranscriptionPipeline? {
        guard let build = translationBuild, let translationController else {
            rebuildAfterPressureIfNeeded()
            return nil
        }
        var postProcessors: [any PostProcessor] = [
            SentenceSegmenter(engine: build.engine)
        ]
        if let punctuator = Self.punctuator(for: build.engine, from: cachedPunctuator) {
            postProcessors.append(PunctuationProcessor(punctuator: punctuator))
        }
        postProcessors.append(TranscriptTidyProcessor())
        if let translationTranslateProcessor {
            postProcessors.append(translationTranslateProcessor)
        }
        return TranscriptionPipeline(
            source: SystemAudioSource(),
            engine: build.engine,
            postProcessors: postProcessors,
            sink: SubtitleOverlaySink(target: translationController),
            fallback: nil
        )
    }

    // MARK: - Meeting assembly (lazy)

    /// True when every meeting engine would be an Apple engine (no local
    /// models installed) — the meeting build is then nearly free and can be
    /// done eagerly at launch instead of lazily on first use.
    private func meetingEnginesAreLightweight() -> Bool {
        let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType)
                         ?? AppDefaults.Defaults.engineType
        let primaryLight: Bool
        switch choice {
        case "sensevoice": primaryLight = modelManager.installedModelDir(for: .senseVoice) == nil
        case "paraformer": primaryLight = modelManager.installedModelDir(for: .paraformer) == nil
        case "qwen3":      primaryLight = modelManager.installedModelDir(for: .qwen3) == nil
        default:           primaryLight = true  // apple
        }
        // Them uses Paraformer when installed, otherwise Apple.
        let themLight = modelManager.installedModelDir(for: .paraformer) == nil
        return primaryLight && themLight
    }

    /// Builds the meeting pipelines on first use. Known MVP limitation: a
    /// Settings engine change does NOT rebuild these — the meeting keeps the
    /// engines it was built with until the app restarts.
    func buildMeetingIfNeeded() {
        guard !meetingBuilt else { return }
        meetingBuilt = true
        meeting = .loading
        let factory = self.factory
        let punctuator = self.cachedPunctuator
        Task.detached(priority: .userInitiated) { [weak self] in
            let meResult = Result<EngineBuild, Error> { try factory.makePrimary() }
            let meFallback = factory.makeFallback()
            let themResult = Result<EngineBuild, Error> { try factory.makeMeetingThem() }
            await MainActor.run { [weak self] in
                self?.applyMeeting(meResult: meResult,
                                   meFallback: meFallback,
                                   themResult: themResult,
                                   punctuator: punctuator)
            }
        }
    }

    private func applyMeeting(meResult: Result<EngineBuild, Error>,
                              meFallback: (any ASREngine)?,
                              themResult: Result<EngineBuild, Error>,
                              punctuator: SherpaOfflinePunctuator?) {
        guard let meetingController else {
            meetingBuilt = false
            meeting = .failed("Meeting controller unavailable")
            return
        }
        // Me track: the user's dictation engine with dictation-style assembly,
        // but the meeting VAD preset (longer hangover, 30 s hard cut).
        guard case .success(let meBuild) = meResult else {
            meetingBuilt = false
            if case .failure(let error) = meResult {
                meeting = .failed(error.localizedDescription)
                ToastWindowController.show("Meeting mic engine unavailable: \(error.localizedDescription)",
                                           style: .error, duration: 5)
            }
            return
        }
        // Them track: streaming engine over system audio (process tap, SCK
        // fallback inside), sentence-segmented with meeting tuning.
        guard case .success(let themBuild) = themResult else {
            meetingBuilt = false
            if case .failure(let error) = themResult {
                meeting = .failed(error.localizedDescription)
                ToastWindowController.show("Meeting system-audio engine unavailable: \(error.localizedDescription)",
                                           style: .error, duration: 5)
            }
            return
        }

        meetingBuilds = (me: meBuild, meFallback: meFallback, them: themBuild, punctuator: punctuator)

        let meLabel = Self.primaryEngineLabel(for: meBuild)
        let themLabel = themBuild.engine is ParaformerStreamingEngine ? "Paraformer" : "Apple"

        meetingController.bind(
            pipelineFactory: { [weak self] in self?.newMeetingPipelines() },
            mutex: mutex,
            meEngineLabel: meLabel,
            themEngineLabel: themLabel
        )
        meeting = .ready
    }

    /// Fresh per-meeting pipelines (cheap shells: new mic source, process
    /// tap, sinks; engines stay resident). Called on each meeting start.
    private func newMeetingPipelines() -> (mic: TranscriptionPipeline, system: TranscriptionPipeline)? {
        guard let builds = meetingBuilds, let meetingController else { return nil }
        let detector = sharedDetector()

        let micSource = MicAudioSource(onInterruption: { [weak meetingController] reason in
            Task { @MainActor in meetingController?.handleMicInterruption(reason) }
        })

        // Me track: the user's dictation engine with dictation-style assembly,
        // but the meeting VAD preset (longer hangover, 30 s hard cut).
        let meRouted = Self.micRouting(engine: builds.me.engine,
                                       micSource: micSource,
                                       detector: detector,
                                       vadConfig: .meeting)
        let micPipeline = TranscriptionPipeline(
            source: meRouted.source,
            engine: meRouted.engine,
            postProcessors: Self.dictationProcessors(engine: builds.me.engine, punctuator: builds.punctuator),
            sink: MeetingSink(track: .me, target: meetingController, storeBox: meetingController.storeBox),
            fallback: builds.meFallback
        )

        // Them track: streaming engine over system audio (process tap, SCK
        // fallback inside), sentence-segmented with meeting tuning.
        var themProcessors: [any PostProcessor] = [
            SentenceSegmenter(engine: builds.them.engine, silenceThreshold: 0.8, maxSegmentDuration: 12.0)
        ]
        if let punctuator = Self.punctuator(for: builds.them.engine, from: builds.punctuator) {
            themProcessors.append(PunctuationProcessor(punctuator: punctuator))
        }
        themProcessors.append(TranscriptTidyProcessor())
        let systemPipeline = TranscriptionPipeline(
            source: ProcessTapAudioSource(),
            engine: builds.them.engine,
            postProcessors: themProcessors,
            sink: MeetingSink(track: .them, target: meetingController, storeBox: meetingController.storeBox),
            fallback: nil
        )
        return (mic: micPipeline, system: systemPipeline)
    }

    /// The CT-Transformer punctuator to attach for `engine`, if any: none
    /// when the engine punctuates its own output (Apple, Qwen3) —
    /// re-punctuating doubles the marks (`。。`, `，，`). Every assembly site
    /// goes through here; generic so the rule is testable without a model.
    static func punctuator<P>(for engine: any ASREngine, from loaded: P?) -> P? {
        engine.emitsPunctuation ? nil : loaded
    }

    /// Dictation-style mic routing, shared by the dictation pipeline and the
    /// meeting Me track. SpeechAnalyzer handles silence itself — feeding it
    /// zero-substituted windows disturbs its endpointing and timeline, so it
    /// gets the raw mic (yap/muesli feed it unprocessed audio). Streaming
    /// engines (Paraformer, ours) keep the VAD-gated source — its
    /// silence-injection preserves their own endpointing. Offline engines
    /// (Qwen3 / SenseVoice) decode one segment per VAD cut, so they get the
    /// segmenting decorator with the caller's preset (`.default` dictation,
    /// `.meeting`: longer hangover + 30 s hard cut).
    static func micRouting(engine: any ASREngine,
                           micSource: any AudioSource,
                           detector: any VADSpeechDetector,
                           vadConfig: VADConfig = .default) -> (source: any AudioSource, engine: any ASREngine) {
        if engine is AppleSpeechASREngine {
            return (micSource, engine)
        }
        if engine.isStreaming {
            return (VADGatedSource(inner: micSource, detector: detector), engine)
        }
        return (micSource, VADSegmentingEngine(inner: engine, detector: detector, config: vadConfig))
    }

    /// The dictation-style post-processor chain: CT-Transformer punctuation
    /// (skipped when the engine already emits its own — re-punctuating
    /// self-punctuated text doubles/corrupts it, `。。` `？？` `。，`), then
    /// English-term corrections ("u爱" → "UI") on the final user-visible
    /// text, then TranscriptTidy.
    static func dictationProcessors(engine: any ASREngine,
                                    punctuator loaded: SherpaOfflinePunctuator?) -> [any PostProcessor] {
        var processors: [any PostProcessor] = Self.punctuator(for: engine, from: loaded).map { [PunctuationProcessor(punctuator: $0)] } ?? []
        processors.append(TextCorrectionProcessor(provider: { TextCorrections.active() }))
        processors.append(TranscriptTidyProcessor())
        return processors
    }

    /// Label for a primary build: the chosen engine's display name, or
    /// "Apple" when the build already fell back.
    private static func primaryEngineLabel(for build: EngineBuild) -> String {
        guard build.fallbackReason == nil else { return "Apple" }
        let choice = UserDefaults.standard.string(forKey: AppDefaults.Keys.engineType)
                     ?? AppDefaults.Defaults.engineType
        return engineDisplayName(for: choice)
    }

    // MARK: - Dictation source pieces

    /// Builds the VAD detector: Silero when its model is downloaded, otherwise
    /// the energy fallback (still better than no VAD), logging the degradation.
    /// A fresh detector per pipeline build — Silero state is per-session.
    private func makeDetector() -> any VADSpeechDetector {
        if let dir = modelManager.modelPath(for: .sileroVad),
           let silero = SileroSpeechDetector(modelPath: dir.appendingPathComponent("silero_vad.onnx").path) {
            LogService.info("Dictation VAD: Silero", category: "PipelineProvider")
            return silero
        }
        LogService.warn("Silero VAD model unavailable; using energy gate", category: "PipelineProvider")
        return EnergySpeechDetector()
    }

    /// The raw mic source with the audio-interruption hook wired to the
    /// recording controller.
    private func makeMicSource() -> MicAudioSource {
        MicAudioSource(onInterruption: { [weak recordingController] reason in
            Task { @MainActor in
                recordingController?.handleAudioInterruption(reason)
            }
        })
    }

    // MARK: - Punctuator

    private static func engineDisplayName(for choice: String) -> String {
        switch choice {
        case "apple":      return "Apple"
        case "sensevoice": return "SenseVoice"
        case "paraformer": return "Paraformer"
        case "qwen3":      return "Qwen3"
        default:           return "Apple"
        }
    }

    /// Called from `Task.detached` — `nonisolated` because the enclosing class
    /// is `@MainActor` but this helper does no MainActor work.
    nonisolated private static func makePunctuator(modelManager: ModelManager) -> SherpaOfflinePunctuator? {
        guard let dir = modelManager.installedModelDir(for: .punctuation) else { return nil }
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
