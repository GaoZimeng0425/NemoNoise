# NemoNoise Architecture

NemoNoise is built around a single composition: `AudioSource → ASREngine → [PostProcessor] → Sink`. Two scenarios — dictation and translation — are different configurations of the same `TranscriptionPipeline`.

## Pipeline shape

```
+--------------+   chunks   +-----------+  results  +---------------+  results  +-------+
|  AudioSource | ─────────▶ | ASREngine | ────────▶ | PostProcessor | ────────▶ | Sink  |
+--------------+            +-----------+           +---------------+           +-------+
                                  │
                                  └── if it throws and fallback is set: switch to fallback engine
```

Only `TranscriptionPipeline` knows about composition. Engines and sources don't know each other; sinks don't know engines.

## Key files

| Concern | File |
|---------|------|
| Composition | `Services/Pipeline/TranscriptionPipeline.swift` |
| Audio sources | `Services/Audio/AudioSource.swift` + `MicAudioSource.swift` + `SystemAudioSource.swift` |
| ASR engines | `Services/ASR/ASREngine.swift` + 4 implementations |
| Engine factory | `Services/ASR/ASREngineFactory.swift` |
| Sinks | `Services/Pipeline/Sink.swift`, `BroadcastSink.swift`, `Services/Sinks/*` |
| Post-processors | `Services/Pipeline/PostProcessor.swift`, `Services/PostProcessors/*` |
| App wiring | `App/NemoNoiseApp.swift` (assembly), `App/RecordingController.swift`, `App/TranslationController.swift` (UI adapters), `App/RecordingMutex.swift` |

## How to add a new ASR engine

1. Create `Services/ASR/<Name>Engine.swift` conforming to `ASREngine` (3 methods: `feedChunk`, `finish`, `reset`).
2. Add a case in `ASREngineFactory.makeUserPreferred()` matched on the engine type string from Settings.
3. Add a user-facing toggle in `UI/Settings/SettingsView.swift`.
4. Write engine unit tests.

No pipeline code needs to change.

## How to add a new audio source

1. Create `Services/Audio/<Name>Source.swift` conforming to `AudioSource` (2 methods: `start`, `stop` returning `AsyncStream<AudioChunk>`).
2. Resample to 16 kHz Float mono if your source produces other formats (see `AudioResampler`).
3. Plug it into a pipeline configuration in `NemoNoiseApp` for whatever flow uses it.

No pipeline code needs to change.

## How to add a new post-processor

1. Create `Services/PostProcessors/<Name>Processor.swift` conforming to `PostProcessor` (1 method: `process(_:isFinal:) -> TranscriptionResult?`).
2. Return `nil` to pass through unchanged.
3. Insert into the relevant pipeline's `postProcessors` array in `NemoNoiseApp`.

No other code needs to change.

## Cross-mode exclusion

`RecordingMutex` (in `App/`) is acquired by whichever controller starts first; the other is blocked until release. Both controllers `defer { mutex.release(...) }` (dictation) or release on stop/error (translation) so every terminal path releases.

## Error handling

Pipeline emits semantic errors via `PipelineError`:
- `.sourceUnavailable` — mic/screen permission, no audio hardware
- `.engineFailedFatally` — primary engine and fallback both failed
- `.finalizeFailed` — `finish()` threw

Controllers map these to user-facing presentation (NSAlert, Toast) — pipeline never displays UI. Engine-specific errors (`AppleSpeechError.siriDisabled`, `CloudASRError.authenticationFailed`) are caught at the controller layer for tailored UX.

## Testing strategy

| Layer | Test type |
|-------|-----------|
| Protocols | conformance + interface tests with fakes |
| `TranscriptionPipeline` | IO-free unit tests using `MockAudioSource` + `MockASREngine` |
| Sinks | unit tests with stub targets |
| Real engines | manual QA — they require model files or network |
| Real audio sources | manual QA — they require mic/screen permission |
