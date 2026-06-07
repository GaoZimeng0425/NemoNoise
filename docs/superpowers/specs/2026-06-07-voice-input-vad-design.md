# Voice-Input Quality: VAD Robustness Layer — Design

**Date:** 2026-06-07
**Status:** Draft (pending user review)
**North star:** 把 NemoNoise 的**听写(语音输入)**体验做到最好。
**Scope of this spec:** 听写链路(`MicAudioSource → engine → …`)的鲁棒性地基:一个可复用的
Silero VAD 核心 + 噪声门控 + pre-speech 缓冲。源头是参考项目 `LiveTranslate/vad_processor.py`,
对比见 `docs/livetranslate-comparison.md`。

> 不在本期范围:引擎本身的选择/质量(设置里已可切换)、标点/格式、文字注入(均已存在)。
> 翻译链路(`SystemAudioSource → …`)不在本期改动,但会复用同一套 VAD 核心。

## 背景与动机

"语音输入好不好"的杠杆排序(已与用户对齐):①引擎准不准 ②边说边出字 ③鲁棒性
④标点/格式 ⑤注入可靠。其中 **③鲁棒性是目前唯一完全空白、且对所有引擎都生效**的一块——
NemoNoise 当前**没有任何 VAD**(无 Silero 模型、`SherpaOnnxWrapper` 未包 VAD;模型描述符只有
senseVoice/paraformer/punctuation/qwen3)。

听写链路现状(`PipelineProvider.applyDictation`):
`MicAudioSource → engine(+Apple fallback) → [PunctuationProcessor] → OverlayProgressSink`,
其中 `RecordingController` 在 `finalize` 后把文本经 `TextInjector` 注入目标 App。

③ 鲁棒性的三个具体痛点:
- **吞首字**:引擎在你开口后才"热起来",开头辅音被吃。
- **杂音/停顿乱蹦字**:背景噪声、键盘声、静默期里,引擎会幻觉出文字。
- **首字与噪声共同拉低准确率**,尤其流式引擎逐帧解码时更敏感。

## 目标 / 非目标

**目标(本期):**
1. 引入可复用的 Silero VAD 能力(每帧人声置信度)。
2. 听写链路接入**噪声门控**:非人声帧在喂给引擎前替换为静音,既挡幻觉、又**不破坏**流式引擎
   自带的端点检测(`SherpaOnnxOnlineStreamIsEndpoint` 靠"听到静音"触发)。
3. **pre-speech 缓冲**:检测到开口时,把开口前 ~96ms 的真实音频补回去,不吞首字。
4. 对**所有**听写引擎生效(Apple / Paraformer / SenseVoice / Qwen3),管线/引擎协议零改动。

**非目标(留待后续):**
- 离线引擎(SenseVoice/Qwen3)的整段切分与增量出字 → Phase 2(见末尾)。
- 翻译链路接入 → 后续复用核心。
- VAD 参数的用户可调 UI → 先用代码内默认值(YAGNI)。
- 引擎选择/质量优化、标点/格式、注入 → 不在本工作流。

## 设计概览

核心思想:**VAD 做成 `AudioSource` 装饰器**,夹在真实麦克风源和引擎之间,只对音频流做
"门控 + 补首字"变换。它**不碰 `ASREngine` 协议、不碰 `TranscriptionPipeline`**——
`PipelineProvider` 里把 `MicAudioSource()` 换成 `VADGatedSource(inner: MicAudioSource())` 即可。

```
[ Phase 1 听写链路 ]
MicAudioSource
   └─▶ VADGatedSource ────────────────────────────────────────────┐
        每个变长 chunk:                                             │
          切成 512 样本窗口(Silero 原生窗口)                       │
          → VADConfidenceSource.confidence(window)  (Silero 每帧)   │
          → VADGate.step(window, conf):                            │
               · 静默/非人声  → 输出静音帧(zeros),引擎端点照常工作 │
               · 检测到开口   → 先吐 pre-speech 环形缓冲里的真实音频 │
               · 人声持续     → 原样输出                            │
        重新打包成 AudioChunk(samples, rms, spectrum) 往下游        │
   └────────────────────────────────────────────────────────────▶ engine → [Punctuation] → OverlayProgressSink → TextInjector
```

为什么用"替换成静音"而不是"丢弃静音帧":流式引擎(Paraformer)的端点检测依赖听到静音来判断
"这句说完了"。若直接丢弃静音帧,引擎永远听不到静音,端点检测就废了。喂零样本既保留了时序与
端点语义,又让引擎不会把噪声解码成文字。

## 组件(单一职责、可独立测试)

| 组件 | 类型 | 职责 | 依赖 | 测试 |
|---|---|---|---|---|
| `VADConfidenceSource` | 协议 | `confidence(for window:[Float]) -> Float`(0~1)、`reset()` | 无 | — |
| `SileroConfidenceSource` | class | 跑 Silero,出每帧人声概率 | sherpa/onnx + 模型 | 手动 QA |
| `EnergyConfidenceSource` | struct | RMS 归一化兜底(无模型时降级) | 无 | 单测 |
| `VADGate` | 纯逻辑 struct/class | 状态机:开口/收口判定 + pre-speech 环形缓冲 + 决定每窗口"原样/补缓冲/置零" | 无 IO | **纯单测** |
| `VADGatedSource` | class : `AudioSource` | 包真实源;切 512 窗口、驱动上面两者、重打包 chunk | inner `AudioSource` + `VADConfidenceSource` + `VADGate` | 单测(假源 + 脚本化置信度) |
| `VADConfig` | struct | 阈值/pre-speech 窗数等常量,默认值照搬 LiveTranslate | 无 | — |

`VADGate` 是 LiveTranslate 那套启发式的**精简版**(本期只需开口/收口 + pre-speech;完整的渐进/
自适应/谷点/密度/短段合并留到 Phase 2 的切分器)。

## 数据流细节与边界情况

- **变长 chunk → 512 窗口**:`MicAudioSource`/`SystemAudioSource` 给的 chunk 长度不定;
  `VADGatedSource` 内部维护样本累积器,凑满 512 才喂 VAD,不足 512 的尾巴留到下次。
- **重打包**:门控后的样本要重算 `rmsLevel`、`spectrum`(沿用 `SpectrumAnalyzer`),保证频谱条
  UI 行为不变(静音帧 RMS≈0,频谱平,符合直觉)。
- **录制起止**:`reset()` 在每次 `start()` 时清空环形缓冲与状态机(对齐引擎 `reset()` 时机)。
- **首字补偿与置零的配合**:静默期持续把真实窗口写进 pre-speech 环形缓冲(maxlen≈3 窗≈96ms),
  对外吐零;一旦判定开口,先把缓冲里的真实窗口依次吐出,再转入"原样输出"。

## 错误处理 / 降级

- **Silero 模型缺失或加载失败**:`VADGatedSource` 退化为 `EnergyConfidenceSource`(实时不中断),
  并 `LogService.warn` 一次。能量门控仍比"完全没有 VAD"好。
- **门控决策永不致命**:`VADGatedSource` 只做音频变换,不抛业务错误;最坏情况退化为"全透传"
  (等价于今天的行为),不影响识别。
- 与现有引擎 fallback 互不干扰(VAD 在源头,fallback 在引擎层)。

## 测试策略

- `VADGate`:纯单测,喂合成置信度序列断言——静默置零、开口时 pre-speech 真实窗口被前置且顺序正确、
  人声持续透传、收口回到置零。确定性、无 IO。
- `EnergyConfidenceSource`:已知 RMS 输入断言归一化输出。
- `VADGatedSource`:用假 `AudioSource`(吐脚本化样本)+ 假 `VADConfidenceSource`(脚本化置信度),
  断言输出 chunk 的样本被正确门控/补偿、512 切窗与尾巴处理正确。无 IO。
- `SileroConfidenceSource` 与真机听写:手动 QA(需模型)。验收口径:开口首字不丢;静默/敲键盘/
  背景音乐时不再蹦出幻觉文字;流式引擎端点(说完自动定稿)行为不退化。

## 模型与依赖

- 新增 Silero VAD 模型:`ModelManager` 加 `.sileroVad` 描述符 + 下载项(~2MB)。
- 取每帧概率的实现路径**留待 writing-plans 做小 spike**:sherpa-onnx 暴露的
  `SherpaOnnxVoiceActivityDetector` 是段级、自带静音逻辑,**不直接给每帧概率**。两条路:
  (a) 在 `SherpaOnnxWrapper` 薄加一层直接跑 Silero ONNX 拿每帧概率(倾向);
  (b) 直接用段级 VAD 输出(会丢失对每帧的精细控制,但 Phase 1 的"门控+补首字"基本够用)。
  `VADConfidenceSource` 这个 seam 让后端可换,不影响其余设计。

## Phase 2(记录,不在本期实现)

- `VADSegmenter`(完整 6 启发式:渐进静音 / 自适应 P75 / 置信度谷回溯 / 密度过滤 / 短段合并)
  + `VADSegmentingEngine`(`ASREngine` 装饰器,按段 `reset→feedChunk(整段)→finish` 跑离线引擎)
  → 让 SenseVoice/Qwen3 听写也能**边说边出字**、长句更准。
- 停顿处增量提交 / 增量注入。
- 翻译链路复用同一 VAD 核心。

## 验收标准(Phase 1)

1. 听写开口第一个字不再被吞(真机对比)。
2. 静默、敲键盘、背景音乐场景下不再蹦出幻觉文字。
3. 流式引擎(Paraformer)"说完自动定稿"行为不退化。
4. 无模型时自动降级到能量门控,不崩、不卡。
5. `VADGate` / `VADGatedSource` / `EnergyConfidenceSource` 单测齐全且 IO-free。
</content>
