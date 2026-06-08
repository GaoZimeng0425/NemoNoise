# NemoNoise Commercialization Gap Analysis

**Date:** 2026-06-08
**Status:** Draft — for review
**Scope:** Non-functional quality gaps between current state and a commercial-grade product. Excludes payment / monetization features by request.
**Focus dimensions (user-selected):** Reliability & robustness · Product polish & UX · Performance & resource usage.

This is an **audit + roadmap** document, not a single-feature implementation spec. Each 🔴/🟡 item below is independent and gets its own implementation spec + plan when scheduled. Sequencing recommendation is at the end.

---

## What is already solid (excluded from gaps)

The pipeline core is genuinely well-factored, and several commercialization basics are already done:

- Clean composition `AudioSource → ASREngine → [PostProcessor] → Sink` with engine fallback wired into the pipeline (`TranscriptionPipeline.swift`).
- `RecordingMutex` enforces single-mode exclusion.
- **Cold-start warming is handled** — `PipelineProvider.bootstrap()` pre-builds engines and surfaces an "Engines warming up…" toast (`RecordingController.swift:187`).
- Model download/management (`ModelManager`), crash reporting (`Sentry`), onboarding UI, transcript history, mic selection, and toast-based non-modal feedback all exist.

These are not revisited below.

---

## Reliability & robustness

### 🔴 R1 — Audio device hot-swap is unhandled

**Evidence:** zero hits for `AVAudioEngineConfigurationChange`, `kAudioHardwarePropertyDefaultInputDevice`, or any device-change listener across `NemoNoise/`.

**Symptom:** When the default input device changes mid-recording (unplug AirPods, switch mic, dock/undock), the `AVAudioEngine` input tap silently stops delivering buffers. `TranscriptionPipeline.swift:58` (`for await chunk in audioStream`) simply stops receiving chunks — **no error thrown, stream never finishes, user gets no feedback**. The recording appears to "work" but produces nothing further.

**Note:** The 2026-05-12 commercial-readiness spec (line 88) explicitly promised "Audio device disconnected → stop recording, prompt reconnect." It was never implemented.

**Fix direction:** Observe `AVAudioEngine.configurationChange` (and/or a CoreAudio default-device property listener). On change during an active session: stop cleanly, surface a toast ("麦克风已断开 / 已切换输入设备"), and either auto-restart the tap on the new device or end the session gracefully. Decision for the implementation spec: auto-recover vs. stop-and-notify.

### 🔴 R2 — No audio-stall watchdog

**Evidence:** the pipeline read loop has no timeout; a dead tap produces an indefinite hang (compounds R1).

**Symptom:** If the tap stops yielding for any reason (device death, driver hiccup), the pipeline hangs forever with no recovery path.

**Fix direction:** A watchdog that detects "no `AudioChunk` received in N seconds while recording" and converts it into a surfaced `PipelineError` / toast. N tuned so normal silence (VAD gate may suppress) doesn't false-trigger — coordinate with the VAD gate so gated silence isn't mistaken for a stall.

### 🟡 R3 — Fallback drops the failing chunk and cannot recover it

**Evidence:** `TranscriptionPipeline.swift:75-80`.

**Symptom:** When the primary engine throws and the pipeline switches to fallback, the chunk that triggered the exception is discarded and never re-fed to the fallback engine. Switch is one-shot with no retry/backoff. Acceptable for short utterances; on longer speech a sentence fragment can be lost.

**Fix direction:** Re-feed the failing chunk to the fallback engine after `reset()`. Consider whether a transient primary error should retry-once before committing to fallback.

### 🟡 R4 — In-progress recording is not crash-recoverable

**Symptom:** If the app crashes mid-dictation, the partial transcript is lost entirely.

**Fix direction:** Persist a lightweight recoverable buffer (rolling partial transcript) so a relaunch can offer recovery. Natural pairing with the existing Sentry + transcript-history infrastructure. Lowest priority of the reliability set.

---

## Performance & resource usage

### 🔴 P1 — Offline engine re-decodes the entire buffer on every chunk (O(n²))

**Evidence:** `SherpaASREngine.swift:24-35` — each `feedChunk` does `accumulated.append(contentsOf: samples)` then `recognizer.decode(samples: snapshot)` where `snapshot` is the **entire** accumulated buffer.

**Symptom:** Per-chunk decode cost grows linearly with recording length → overall O(n²) compute, plus unbounded memory growth (`accumulated` never trimmed). Multi-minute offline recordings will visibly stutter and balloon memory.

**Fix direction:** Quantify first (instrument decode time vs. recording length). Then either: incremental/windowed decode, or — if the offline engine is batch-only by nature — defer decode to `finish()` and show waveform-only during recording (which the commercial-readiness spec already prescribes for non-streaming engines, but the accumulate-and-redecode-per-chunk path contradicts that intent).

### 🟢 P2 — Idle model residency (verify, not yet a confirmed gap)

**Open question:** Are engine models kept resident in memory between recordings for a menu-bar-resident app? Warming is good for latency, but a multi-hundred-MB resident footprint at idle is a reputation point for an always-on utility.

**Action:** Measure idle RSS with models loaded; decide on a release-after-idle policy if the footprint is large. May turn out to be a non-issue — measure before specing.

---

## Product polish & UX

### 🔴 U1 — No i18n infrastructure at all

**Evidence:** `NSLocalizedString` / `String(localized:)` hit count = **0**; no `.strings` or `.xcstrings` files anywhere; yet hardcoded CJK string literals exist in 5+ files.

**Symptom:** The app is effectively single-language (mixed zh/en hardcoded). No path to localization without a refactor.

**Fix direction:** Adopt a String Catalog (`.xcstrings`), extract user-facing strings, ship zh-Hans + en at minimum. This is a prerequisite for any non-Chinese market and for App Store presentation polish. Sizeable but mechanical once the catalog exists.

### 🟡 U2 — Accessibility (VoiceOver) is near-absent

**Evidence:** only 5 `accessibility*` references across the entire `UI/` layer.

**Symptom:** Custom views (overlay waveform, menubar view, capsule) lack VoiceOver labels/values. Affects both App Store review posture and the "commercial-grade" bar.

**Fix direction:** Audit pass adding `accessibilityLabel`/`accessibilityValue`/`accessibilityHint` to custom and image-only controls; mark decorative elements hidden. Pairs naturally with the U1 i18n pass (labels need localized strings).

---

## Recommended sequencing

Ordered by damage to commercial trust (a broken-feeling app erodes trust fastest):

1. **R1 + R2** — device hot-swap + stall watchdog. One implementation spec; they share the "active session interrupted" surface. Highest-impact: prevents the "looks recording but produces nothing" failure.
2. **P1** — offline re-decode. Quantify, then fix or defer-to-finish. Prevents the long-recording cliff.
3. **U1** — i18n base (String Catalog + zh/en). Unblocks market reach and polish.
4. **U2** — accessibility pass, bundled with or right after U1.
5. **R3, R4, P2** — fallback chunk recovery, crash-recoverable buffer, idle residency. Lower urgency; schedule after the above or as opportunistic improvements.

Each numbered item should go through brainstorming → spec → plan individually when picked up; this document is the parent audit they trace back to.
