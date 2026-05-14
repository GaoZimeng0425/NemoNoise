# NemoNoise

[English](#english) | [中文](#中文)

---

<a id="english"></a>

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
- **Composable architecture**: ASR engines, audio sources, and post-processors are pluggable via the `TranscriptionPipeline` abstraction.

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

---

<a id="中文"></a>

![CI](https://github.com/GaoZimeng0425/NemoNoise/actions/workflows/ci.yml/badge.svg)

macOS 语音听写应用，支持实时语音识别。按下快捷键，开口说话，文字自动输入到当前使用的应用中。

## 功能特性

- **多引擎语音识别**：本地 SenseVoice（Sherpa-ONNX）、Paraformer 流式识别、Apple Speech、阿里云 Paraformer 云端识别
- **即按即说**：右 Command 或右 Option 键开始/停止录音
- **悬浮窗**：录音时显示波形动画，识别完成后展示转写文本
- **自动文本注入**：通过 Accessibility API 将识别文字直接输入到焦点应用
- **引擎自动降级**：所选引擎不可用时，静默切换至 Apple Speech 并弹出通知
- **自动更新**：集成 Sparkle 2，自动检查新版本
- **崩溃上报**：Sentry 集成（默认关闭，需手动开启）
- **结构化日志**：按会话隔离的日志系统，支持导出与隐私脱敏
- **首次启动引导**：三步完成麦克风授权、引擎选择和快捷键设置
- **可组合架构**：ASR 引擎、音频源、后处理通过 `TranscriptionPipeline` 抽象插拔

## 安装

### 下载

从 [GitHub Releases](https://github.com/GaoZimeng0425/NemoNoise/releases/latest) 下载最新 DMG。

### 安装步骤

1. 打开下载的 `NemoNoise.dmg`
2. 将 **NemoNoise** 拖入 **Applications** 文件夹快捷方式
3. 从启动台或 Applications 中打开 NemoNoise
4. 首次启动时，右键点击应用并选择 **打开**（非 App Store 应用需要此步骤）

### 首次使用

首次启动后，NemoNoise 会引导你完成以下设置：
1. **麦克风权限** — 语音输入必需
2. **引擎选择** — 选择本地（Paraformer）或内置（Apple Speech）引擎
3. **快捷键设置** — 右 Command 或右 Option 键即按即说

## 系统要求

- **macOS 15.0**（Sequoia）或更高版本
- **Xcode 16**（从源码构建时需要）

## 从源码构建

```bash
# 克隆仓库
git clone https://github.com/GaoZimeng0425/NemoNoise.git
cd NemoNoise

# 构建
xcodebuild build -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS'

# 测试
xcodebuild test -project NemoNoise.xcodeproj -scheme NemoNoise -destination 'platform=macOS'

# 打包 DMG
./build.sh
```

## 许可证

MIT
