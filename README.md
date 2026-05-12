# NemoNoise

![CI](https://github.com/GaoZimeng0425/NemoNoise/actions/workflows/ci.yml/badge.svg)

macOS voice dictation app with real-time ASR. Push-to-talk with a hotkey, speak, and text is injected into the active app.

## Features

- **Multiple ASR engines**: Local SenseVoice (Sherpa-ONNX), Paraformer streaming, Apple Speech, cloud-based Paraformer
- **Push-to-talk**: Right Cmd or Option to record
- **Floating overlay**: Waveform during recording, transcript after
- **Auto text injection**: Types text directly into the focused app via Accessibility
- **Auto-updates**: Sparkle 2 integration
- **Crash reporting**: Sentry (opt-in)

## Requirements

- macOS 15.0+
- Xcode 16

## Building

```bash
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS'
```

## Testing

```bash
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS'
```
