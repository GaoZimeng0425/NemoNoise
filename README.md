# NemoNoise

![CI](https://github.com/GaoZimeng0425/NemoNoise/actions/workflows/ci.yml/badge.svg)

macOS voice dictation app with real-time ASR. Press a hotkey, speak, and text is injected into the active app.

## Features

- **Multiple ASR engines**: Local SenseVoice (Sherpa-ONNX), Paraformer streaming, Apple Speech, cloud-based Alibaba Cloud Paraformer
- **Push-to-talk**: Right Cmd or Option to start/stop recording
- **Floating overlay**: Waveform animation during recording, transcript display after
- **Auto text injection**: Types recognized text directly into the focused app via Accessibility API
- **Engine auto-fallback**: If the chosen engine fails, silently switches to Apple Speech with a notification
- **Auto-updates**: Sparkle 2 integration checks for updates automatically
- **Crash reporting**: Sentry integration (opt-in, off by default)
- **Structured logging**: Per-session logging with log export and PII sanitization
- **First-launch onboarding**: 3-step setup for microphone, engine, and hotkey

## Installation

### Download

Download the latest DMG from [GitHub Releases](https://github.com/GaoZimeng0425/NemoNoise/releases/latest).

### Install

1. Open the downloaded `NemoNoise.dmg`
2. Drag **NemoNoise** to the **Applications** folder shortcut
3. Launch NemoNoise from Applications
4. On first launch, right-click the app and select **Open** (required for apps not from the App Store)

### First Run

On first launch, NemoNoise guides you through:
1. **Microphone permission** — required for voice input
2. **Engine selection** — choose between local (Paraformer) or built-in (Apple Speech)
3. **Hotkey setup** — Right Cmd or Option for push-to-talk

## Requirements

- **macOS 15.0** (Sequoia) or later
- **Xcode 16** (for building from source)

## Building from Source

```bash
# Clone
git clone https://github.com/GaoZimeng0425/NemoNoise.git
cd NemoNoise

# Build
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS'

# Test
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS'

# Create DMG
./build.sh
```

## License

MIT
