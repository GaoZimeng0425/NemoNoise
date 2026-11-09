# NemoNoise Architecture

NemoNoise is built around a single composition: `AudioSource → ASREngine → [PostProcessor] → Sink`. Three scenarios — dictation, translation, and meeting recording — are different configurations of the same `TranscriptionPipeline`.

## Pipeline shape

```
+--------------+   chunks   +-----------+  results  +---------------+  results  +-------+
|  AudioSource | ─────────▶ | ASREngine | ────────▶ | PostProcessor | ────────▶ | Sink  |
+--------------+            +-----------+           +---------------+           +-------+
                                  │
                                  └── if it throws and fallback is set: switch to fallback engine
```

Only `TranscriptionPipeline` knows about composition. Engines and sources don't know each other; sinks don't know engines.

## The three modes

| | Dictation | Translation | Meeting |
|---|---|---|---|
| Sessions | seconds, hotkey-bound | minutes–hours | hours, no duration cap |
| Source(s) | `MicAudioSource` (± VAD gate) | `SystemAudioSource` (SCK) | **two pipelines**: mic ("Me") + `ProcessTapAudioSource` ("Them", falls back to SCK) |
| Engine | user's choice (4) | Paraformer streaming / Apple en-US | Me = user's choice, Them = translation engine |
| Segmentation | `VADConfig.default` (15 s hard cut) | `SentenceSegmenter` 0.8 s / 6 s | `VADConfig.meeting` (30 s) / `SentenceSegmenter` 0.8 s / 12 s |
| Sink | `OverlayProgressSink` | `SubtitleOverlaySink` | `MeetingSink` × 2 (one per track) |

Meeting mode is *two* `TranscriptionPipeline` instances owned by `MeetingController`, both writing through track-labeled `MeetingSink`s into one `MeetingTranscriptStore` (JSONL appended per confirmed line, Markdown exported on stop; the per-session store is swapped via `MeetingStoreBox` since pipelines are built once and reused). Physical track separation — mic vs system audio — stands in for speaker diarization: Me = whoever is on this Mac's mic, Them = the far side. Meeting engines build lazily on first start (`PipelineProvider.buildMeetingIfNeeded`) so engine memory is only paid when a meeting actually runs; a Settings engine change does not rebuild them until app restart (known MVP limitation).

`ProcessTapAudioSource` captures system audio via a Core Audio process tap (macOS 15+) under the audio-only "System Audio Recording" TCC consent — no Screen Recording permission. If the tap can't be created it falls back to the SCK-based `SystemAudioSource`.

## Key files

| Concern | File |
|---------|------|
| Composition | `Services/Pipeline/TranscriptionPipeline.swift` |
| Audio sources | `Services/Audio/AudioSource.swift` + `MicAudioSource.swift` + `SystemAudioSource.swift` + `ProcessTapAudioSource.swift` |
| ASR engines | `Services/ASR/ASREngine.swift` + 4 implementations |
| Engine factory | `Services/ASR/ASREngineFactory.swift` |
| Sinks | `Services/Pipeline/Sink.swift`, `BroadcastSink.swift`, `Services/Sinks/*` |
| Meeting persistence | `Services/Meeting/MeetingTranscriptStore.swift` (JSONL + Markdown + `MeetingStoreBox`) |
| Post-processors | `Services/Pipeline/PostProcessor.swift`, `Services/PostProcessors/*` |
| App wiring | `App/NemoNoiseApp.swift` (assembly), `App/RecordingController.swift`, `App/TranslationController.swift`, `App/MeetingController.swift` (UI adapters), `App/RecordingMutex.swift` |

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

`RecordingMutex` (in `App/`) is acquired by whichever controller starts first; the others are blocked until release. All three controllers release on every terminal path (dictation defers, translation and meeting release after their pipelines drain on stop/error). A failed `tryAcquire` surfaces a toast.

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
