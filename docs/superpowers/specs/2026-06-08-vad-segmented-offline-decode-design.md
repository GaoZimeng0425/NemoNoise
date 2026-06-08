# VAD-Segmented Offline Decode (VAD Phase 2) — Design

**Date:** 2026-06-08
**Status:** Draft (pending user review)
**North star:** 让离线引擎(Qwen3 / SenseVoice)的听写做到**边说边出字**且**长句更准**——
缩小与商业化听写应用的体验差距。
**Parent:** 这是 `2026-06-07-voice-input-vad-design.md` 末尾明确记录的 **Phase 2**
(`VADSegmenter` + `VADSegmentingEngine`)。复用 Phase 1 的 Silero VAD 核心。

---

## 背景与动机

用户反馈两个问题(均发生在 **Qwen3 离线引擎**下):
1. **语音识别不精准**:常见字也会出现错字 / 乱码。
2. **非流式输出等待太长**:松开热键后要等整段解码,跟商业化应用差距明显。

排查结论(已与用户对齐):

- **延迟是结构性的。** `Qwen3ASREngine` 把整个会话音频累积到 `accumulated`,在 `finish()`
  里**一次性解码全部**(`Qwen3ASREngine.swift:39-51`)。Qwen3-ASR 是 **LLM 解码器式 ASR**
  (`max_total_len=512`、`max_new_tokens=128`),逐 token 自回归生成,单次解码成本随说话时长增长,
  且所有等待都堆在最后、全程零反馈。
- **不精准很可能是同一个根因。** LLM-ASR 模型训练于**短音频片段**(通常 <30s)。把数分钟的整段
  音频喂进 0.6B 模型,会超出其能力窗口 → 常见字也乱码 / 幻觉。**这未必是 int8 量化问题。**

**因此 Approach A(VAD 切分)一招同时治两者**:在自然停顿处把语音切成短段,每段独立解码——
解码更快(延迟),且每段音频都落在模型训练长度内(准确率)。int8→fp16 从"主修复"降级为
"短段仍乱码时才验证"的次级杠杆(本期不做,见 §8)。

### 现状链路(`PipelineProvider.applyDictation`)

```
MicAudioSource → VADGatedSource(Phase 1 门控) → engine(+Apple fallback)
  → [PunctuationProcessor] → OverlayProgressSink → (finalize 后)TextInjector
```

Phase 1 的 `VADGatedSource` 把非人声帧**置零**,目的是不破坏**流式**引擎自带的端点检测——
对**离线**引擎而言,置零没有意义(离线引擎没有"听静音定稿"的语义)。

---

## 目标 / 非目标

**目标(本期):**
1. 新增 `VADSegmenter`(纯逻辑切分状态机)+ `VADSegmentingEngine`(`ASREngine` 装饰器),
   让离线引擎按段解码、**停顿处增量提交文字**。
2. 离线链路(Qwen3 / SenseVoice)接入切分引擎;**不碰 `TranscriptionPipeline`、不碰 `ASREngine`
   协议**——只在 `PipelineProvider` 里按引擎类型选择包装方式。
3. 复用 Phase 1 的 `SileroSpeechDetector` / `VADConfig` / pre-speech 首字补偿。

**非目标(留待后续):**
- int8→fp16 模型对比与下载(见 §8,documented follow-up)。
- 流式引擎(Paraformer)/ Apple 链路改动:维持 Phase 1 `VADGatedSource` 不变。
- 翻译链路(`SystemAudioSource`)接入。
- LiveTranslate 那套完整 6 启发式(渐进静音 / 自适应 P75 / 置信度谷回溯 / 密度过滤 / 短段合并)
  的全部——本期只做"onset + min-silence 收口 + min-speech 去抖 + max-segment 强切"四件,YAGNI。
- VAD 参数用户可调 UI:先用代码内 `VADConfig` 默认值。

---

## 设计概览

核心:**把"切分 + 按段解码"做成 `ASREngine` 装饰器**,包在真实离线引擎外面。它内部自带 VAD
检测(复用 Silero detector),所以离线链路**不再需要 `VADGatedSource`**——切分引擎自己消费
原始麦克风音频并完成端点判定。

```
[ Phase 2 离线听写链路 ]
MicAudioSource
   └─▶ VADSegmentingEngine(inner: Qwen3, detector: Silero)   ← 作为 pipeline 的 engine
          feedChunk(变长 samples):
            切成 512 窗口 → detector.isSpeech(window) → VADSegmenter.step(window, isSpeech)
              · onset      → 开新段,前置 pre-speech 96ms 真实音频
              · 人声持续    → 累积进当前段缓冲
              · 静默 ≥ minSilence → 收口,产出 .segment([Float])
              · 时长 ≥ maxSegment → 强制收口(防 run-on 解码膨胀)
            每收一段 → inner.reset → inner.feedChunk(整段) → inner.finish() 得文字
                     → 追加到 committed 全文 → 返回 TranscriptionResult(全文, isFinal:false)
          finish():flush 尾段 → 追加 → 返回全文 isFinal:true(供注入)
   └──────────────────▶ [PunctuationProcessor] → OverlayProgressSink → TextInjector
```

**为何离线路替换而非叠加 `VADGatedSource`**(已与用户确认):置零只服务流式端点检测,离线无用;
叠加会让 Silero 跑两遍且逻辑割裂。替换后**单一 VAD 实例**、职责清晰、无双重 VAD。

---

## 组件(单一职责、可独立测试)

| 组件 | 类型 | 职责 | 依赖 | 测试 |
|---|---|---|---|---|
| `VADSegmenter` | 纯逻辑 class | 状态机:onset / 人声持续 / min-silence 收口 / min-speech 去抖 / max-segment 强切;维护当前段缓冲 + pre-speech 环形缓冲;产出 `SegmenterEvent` | 无 IO | **纯单测** |
| `VADSegmentingEngine` | class : `ASREngine` | 包离线 inner 引擎 + Silero detector + `VADSegmenter`;切 512 窗、驱动检测/切分、按段跑 inner 解码、累积 committed 全文、产出渐进结果 | inner `ASREngine` + `VADSpeechDetector` + `VADSegmenter` | 单测(mock inner + 脚本化 detector) |
| `VADConfig`(扩展) | struct | 新增 `minSilenceMs` / `minSpeechMs` / `maxSegmentMs` | 无 | — |

### `VADSegmenter` 事件

```
enum SegmenterEvent {
    case buffering          // 还在攒当前段,无输出
    case segment([Float])   // 一段收口,交出该段的语音样本(含 pre-speech 前缀)
}
```

`step(window:isSpeech:) -> SegmenterEvent`。纯函数式状态推进,确定性、无 IO、无时钟依赖
(时长以"窗口数 × windowSize / 16000"换算,不读真实时间——可被单测精确驱动)。

---

## 数据流细节与边界情况

- **变长 chunk → 512 窗口**:沿用 Phase 1 做法,`VADSegmentingEngine` 内维护样本累积器,凑满 512
  才喂 detector;不足 512 的尾巴留到下次 `feedChunk`。
- **pre-speech 首字补偿**:静默期持续把真实窗口写进 pre-speech 环形缓冲(maxlen≈3 窗≈96ms);
  onset 时把缓冲前置到段首,避免吞首字(语义同 Phase 1 `VADGate`)。
- **min-speech 去抖**:人声持续时长不足 `minSpeechMs`(~200ms)即转静默的段视为噪声,丢弃不解码。
- **min-silence 收口**:人声后连续静默达 `minSilenceMs`(~600ms)才判定段结束(hangover),
  避免句中正常停顿被切碎。
- **max-segment 强切**:单段语音时长达 `maxSegmentMs`(~15s)无停顿时强制收口,保证任何一次
  inner 解码都落在模型短音频窗口内(同时治延迟与准确率)。
- **解码串行化**:inner 离线引擎非可重入。第 N 段解码与用户说第 N+1 段可并行(后台),但
  **两次解码绝不重叠**——用串行 async 队列/单一 Task 链保证顺序与互斥。
- **输出语义:追加已提交段**(已与用户确认)。各段音频互不重叠 → **纯拼接,无 overlap/dedup**
  (区别于流式的 partial-replace)。overlay 文字只增不变、不闪烁。`PunctuationProcessor` 照常对
  每次结果运行。
- **录制起止**:`reset()` 在每次 `start()` 清空 segmenter 状态、committed 全文、inner 引擎状态
  (对齐现有引擎 reset 时机)。
- **isStreaming**:`VADSegmentingEngine.isStreaming = false`(它仍是离线引擎的包装;但通过渐进
  partial 实现了"边说边出字"的观感)。

---

## 错误处理 / 降级

- **单段解码失败**:`LogService.warn` 记录并**跳过该段**,继续会话——一段坏音频不应终结整次听写。
- **inner 引擎硬失败**(init 失败等)在装饰器构造期暴露,沿用工厂层既有降级;运行期由
  `TranscriptionPipeline` 既有的 Apple fallback 兜底(VAD 在引擎层内部,与 pipeline fallback 不冲突)。
- **Silero 模型缺失**:同 Phase 1,detector 退化为 `EnergySpeechDetector`(切分仍可工作,精度略降),
  `LogService.warn` 一次。
- **切分决策永不致命**:最坏情况退化为"整段一次解码"(等价今天行为),不崩不卡。

---

## 接入点(`PipelineProvider.applyDictation`)

按选中引擎类型分支:

- **离线(Qwen3 / SenseVoice)**:`MicAudioSource → VADSegmentingEngine(inner: 离线引擎, detector: Silero)`。
  **不再包 `VADGatedSource`。**
- **流式(Paraformer)/ Apple**:维持 Phase 1 `MicAudioSource → VADGatedSource(detector: Silero) → engine`。

两条路复用同一个 Silero detector 构造逻辑。引擎类型可由 `ASREngine.isStreaming` 或工厂选择推断。

---

## 测试策略

- **`VADSegmenter`(纯单测,核心)**:喂脚本化 `(window, isSpeech)` 序列,断言:
  - onset 开段且 pre-speech 真实窗口被前置、顺序正确;
  - 句中短停顿(< minSilence)不切段;静默达 minSilence 才产出 `.segment`;
  - 人声时长 < minSpeech 的 blip 被丢弃、不产段;
  - 连续人声达 maxSegment 触发强制收口;
  - `reset()` 回到初始态。确定性、无 IO、无时钟。
- **`VADSegmentingEngine`(单测)**:mock inner 引擎(记录每次 `feedChunk`/`finish` 调用、返回
  预设文字)+ 脚本化 detector,断言:
  - 每收一段触发一次 inner `reset→feedChunk(整段)→finish`;
  - committed 全文按段**追加**累积,partial 文字只增;
  - `finish()` flush 尾段并返回完整全文 `isFinal:true`;
  - 解码串行(mock 记录的调用顺序无重叠);
  - 单段解码抛错被吞、后续段继续。
- **手动真机 QA**:① 边说边出字延迟明显下降(松键到定稿只等最后一段);② 长句/多句不再乱码;
  ③ 长录音无卡顿、内存不膨胀;④ 首字不丢;⑤ 流式/Apple 链路行为不退化。

---

## 验收标准(Phase 2)

1. 离线引擎听写在停顿处**增量出字**(真机可见 overlay 文字分段增长)。
2. 松开热键后的等待仅为"最后一段解码",不随总录音时长线性增长。
3. 多句 / 长句场景常见字乱码显著减少(短段解码落在模型能力窗口内)。
4. 无 Silero 模型时降级为能量切分,不崩不卡。
5. `VADSegmenter` / `VADSegmentingEngine` 单测齐全且 IO-free。
6. 流式(Paraformer)/ Apple 链路行为不退化(回归现有 VAD 测试)。

---

## §8 后续(documented follow-up,不在本期)

- **int8 → fp16 准确率杠杆**:若短段解码后常见字仍乱码,A/B 对比非 int8 的 Qwen3 build
  (下载体积更大,需新增 `ModelManager` 描述符 / 切换 archive URL),量化字错率后再决定是否切换。
- 增量**注入**(停顿处把已定稿段提前注入目标 App,而非全部等 finalize)。
- 翻译链路复用 `VADSegmenter`。
- LiveTranslate 完整切分启发式(自适应阈值 / 谷点回溯 / 短段合并)。
