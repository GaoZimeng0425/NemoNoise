# LiveTranslate vs NemoNoise —— 实现对比与移植路线

对比对象:`LiveTranslate/`(Python / Windows,系统音频实时翻译)与本项目 NemoNoise
(Swift / macOS,听写 + 翻译)。结论:**两者不是简单的谁更好**——NemoNoise 软件架构更干净,
LiveTranslate 在实时翻译这个领域问题上更成熟。

## LiveTranslate 架构(运行时形态)

```
主线程 (Qt event loop): Tray / Overlay / ControlPanel / SubtitleWindow / LogWindow
        ▲ Qt signals (update_streaming / add_message / update_stats)
[capture_thread] _capture_loop
   AudioCapture.get_audio() 32ms chunk(512@16k)+ mic 混音
   → VADProcessor.process_chunk()  (Silero VAD)
        ├─ 累积中且超过 interim_interval → enqueue("interim")
        └─ 静音/超长切出一段           → enqueue("vad_flush", segment)
   → asr_queue (maxsize=16, 满了丢最旧)
[asr_thread] _asr_loop
   ├─ "interim"   → _do_interim_asr(): peek 整缓冲 ▸ 整段重跑 ASR ▸ pysbd 断句
   │                 ▸ 提交完整句 ▸ trim_front(已消费音频+0.3s) ▸ 去回声重复
   └─ "vad_flush" → _process_segment(): 整段 ASR(最终结果)
   → ThreadPoolExecutor(8+) _translate_async → Translator.translate_iter()(流式)
   → OpenAI 兼容 API + TranscriptWriter 落盘
```

## 它真正领先的地方(NemoNoise 当前缺失)

1. **VAD 切分启发式(护城河)** —— `vad_processor.py`,6 个叠加策略:
   - Pre-speech 环形缓冲(~96ms,补回开头辅音,避免吞字)
   - 渐进式静音(缓冲越长越短的停顿即可切:<3s 全量 / 3-6s 半量 / 6-10s 1/4)
   - 自适应静音(最近 50 次停顿 P75×1.2,动态 0.3~2.0s)
   - 回溯切分(到 max 时找平滑置信度最低谷切,余下留下一段)
   - 语音密度过滤(<25% chunk 过阈值 → 当噪声丢弃)
   - 短段合并(不足 min 不丢,留缓冲跟下次拼接)
2. **让离线 ASR 流式化的 interim 机制** —— peek 累积缓冲整段重跑 → pysbd 断句 →
   只提交完整句 → 按 word timestamp/比例 trim 已消费音频(留 0.3s 防重识别)→
   `_strip_committed_overlap` 去回声重复。让任何离线引擎表现得像流式。
3. **翻译链路工程化** —— 逐字流式显示、JSON schema 结构化、多轮上下文(context_turns)、
   重复循环检测(RepetitionError)、per-model overrides/extra_body/no_think、代理、
   prompt 预设、prompt 里显式纠正 ASR 错误、token/成本统计。
4. **运维健壮性** —— 内存诊断+上限告警(FunASR C 端泄漏)、ASR 队列丢最旧背压、
   噪声/语言过滤、运行时热切引擎 + 设备迁移。

## NemoNoise 更好的地方

- **架构/可测试性**:协议组合 `AudioSource→ASREngine→[PostProcessor]→Sink`,只有 Pipeline
  知道组合;Mock 做 IO-free 单测。加引擎=1 文件 + 工厂 1 个 case。
  LiveTranslate 是 1700 行 `main.py` + ~40 字段 god object。
- **真·流式 ASR**:sherpa online 帧级流式 + 内建 endpoint,partial 白拿,不需要 trim/echo 体操。
- **并发安全**:Swift actor / Sendable / 结构化并发 vs Python 线程 + 多锁 + 手动队列去重。
- **引擎 fallback**:内建在 Pipeline,语义化 PipelineError。

> 关键洞察:LiveTranslate 那套 interim/trim/echo-dedup 的复杂度,部分正是因为它**没有**原生
> 流式引擎,只能用工程手段补。NemoNoise 已有流式引擎,不需要那套复杂度——这是架构选择带来的简化。

## 移植路线(按性价比)

1. **VAD 切分启发式(最值得)** —— 做成 `VADSegmenter`,插在 source 后 / 作为前置处理。
   ⚠️ 设计冲突:NemoNoise 用 sherpa **online** 引擎自带 endpoint,直接套 VAD 会与引擎端点检测
   打架。需先定方案(详见下方"待定设计"或后续 brainstorm 产出)。
2. **翻译流式显示 + 重复检测** —— 在 `AsyncTranslateProcessor` 加流式回填 + RepetitionError。
3. **多轮上下文翻译(context_turns)** —— 提升连续语境连贯性。
</content>
</invoke>
