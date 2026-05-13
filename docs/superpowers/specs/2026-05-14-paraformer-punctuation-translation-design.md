# Paraformer Endpoint Punctuation + Translation ASR Replacement

Date: 2026-05-14

## Background

Paraformer streaming engine outputs raw text without punctuation. A previous attempt (commit `8df17e0`) added a ct-transformer punctuation model (~300MB) but was rolled back due to model size.

The translation flow currently uses Apple Speech ASR (en-US) + Apple Translation API. This only handles English audio. We want to support mixed Chinese/English audio using Paraformer's bilingual capability.

## Goals

1. Add lightweight punctuation to Paraformer streaming output — zero additional model downloads
2. Replace Apple Speech ASR in TranslationController with Paraformer — support Chinese/English/mixed audio

## Design

### 1. Endpoint-based Punctuation

**Location:** `ParaformerStreamingEngine.swift` + `SherpaOnnxWrapper.swift`

**Mechanism:** sherpa-onnx streaming recognizer has built-in endpoint detection. When the speaker pauses beyond a threshold, an endpoint event fires, indicating a sentence boundary.

**Logic in `feedChunk()`:**
1. Feed audio samples to recognizer, get partial text
2. Check `isEndpoint` on the stream
3. If endpoint detected:
   - Append `"。"` to the partial text
   - Call `resetStream()` to start a fresh sentence
4. If not endpoint:
   - Return text as-is

**SherpaOnnxWrapper changes:** Restore `isEndpoint` and `resetStream()` on `SherpaOnlineRecognizer` (these were added in commit `8df17e0` and removed in working directory). The underlying C APIs (`SherpaOnnxOnlineStreamIsEndpoint`, `SherpaOnnxOnlineStreamReset`) are already available via the bridging header.

**Scope: sentence-period only.** No commas, question marks, or exclamation marks. Subtitle text is short-form; periods at sentence boundaries are sufficient. Comma rules are complex and error-prone — YAGNI.

### 2. Paraformer as Translation ASR Engine

**Location:** `TranslationController.swift`

**Current flow:**
```
Audio → AppleSpeechASREngine (en-US) → English text → Apple Translation (en→zh) → Chinese
```

**New flow:**
```
Audio → ParaformerStreamingEngine (bilingual) → text → Apple Translation (en→zh) → Chinese
```

**Changes in `startTranslation()`:**
- Replace `AppleSpeechASREngine(locale: "en-US")` with `ParaformerStreamingEngine(modelDir:)`
- Need `ModelManager` injected into `TranslationController` to resolve model path
- Audio capture (`AudioCaptureService`) unchanged
- Debounce mechanism unchanged (1.5s partial / immediate final)
- Apple Translation API call unchanged

**Language-aware translation skip:** Paraformer outputs Chinese or English depending on audio. Sending Chinese text through en→zh translation may produce incorrect results. Add a simple guard:
```swift
private func shouldTranslate(_ text: String) -> Bool {
    let asciiCount = text.unicodeScalars.filter { $0.isASCII && $0.isLetter }.count
    let totalLetters = text.unicodeScalars.filter { $0.isLetter }.count
    guard totalLetters > 0 else { return false }
    return Double(asciiCount) / Double(totalLetters) > 0.5
}
```
- ASCII letter ratio > 50% → translate (English audio)
- Otherwise → display directly (Chinese audio)

### 3. Fallback

If `ParaformerStreamingEngine` creation fails (model not downloaded, etc.), fall back to `AppleSpeechASREngine` — same pattern as `SpeechOrchestrator`.

### 4. UI

No changes to `SubtitleOverlayView`. Line 1 shows ASR raw output (original text), Line 2 shows translation result. When audio is Chinese, both lines show similar content — acceptable for subtitle use.

No new settings needed. Paraformer as translation ASR is an internal implementation detail.

## File Changes

| File | Change |
|------|--------|
| `SherpaOnnxWrapper.swift` | Restore `isEndpoint` + `resetStream()` on `SherpaOnlineRecognizer` |
| `ParaformerStreamingEngine.swift` | Add endpoint punctuation in `feedChunk()` |
| `TranslationController.swift` | Replace ASR engine with Paraformer, add `shouldTranslate()` guard, add fallback |

**3 files modified, 0 new files, 0 model downloads.**

## Risks

- **Apple Translation en→zh on Chinese text:** The `shouldTranslate()` guard mitigates this, but edge cases with mixed-language sentences may still produce odd translations. Can be refined based on testing.
- **Endpoint punctuation quality:** Only periods, no commas or question marks. Acceptable for subtitle use but not for transcript/document output.
