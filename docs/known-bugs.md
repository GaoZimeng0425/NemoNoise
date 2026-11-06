# NemoNoise 已知 bug 与交接说明

最后更新:2026-11-06 · 分支 `chore/swift6-language-mode`(未推送，未开 PR)

给接手的会话：先读「当前状态」和「跑测试前必读」，再按「建议顺序」修。每修完一条，把它从「未修复」挪到「已修复」，写上提交号。

## 当前状态

| 提交 | 内容 |
|---|---|
| `39b2b43` fix(concurrency) | 系统回调显式标注隔离；配置变更通知和看门狗切回主线程(Bug #1) |
| `d993a82` chore | App target 切到 Swift 6 语言模式 |
| `69200d3` test | 修 5 个过期测试；测试不再改动用户的剪贴板、设置、模型目录 |
| `b65098b` chore | 测试 target 切到 Swift 6 语言模式 |

- App 和测试都是 `SWIFT_VERSION = 6.0`,外加默认 MainActor 隔离和 Approachable Concurrency。
- 200 个单测全部通过，构建无并发警告。
- **真机冒烟测试还没做**,清单在文末。
- `Package.resolved` 有一处 2026-06-25 留下的未提交改动(Sentry 8.58.3、Sparkle 2.9.3 等)。上面的构建和测试是在这些版本上验证的，要不要单独提交由用户决定。

## 跑测试前必读

测试宿主就是 NemoNoise.app 本身(bundle id 都是 `com.nemo.NemoNoise`),而本机安装的 App 实际不在沙盒里运行。所以测试里的 `UserDefaults.standard`、`NSPasteboard.general`、`~/Library/Application Support/NemoNoise/models` 都是**用户正在用的那一份**。

- 测试要写设置，先快照再恢复:`let saved = UserDefaultsSnapshot([key]); defer { saved.restore() }`(`NemoNoiseTests/UserDefaultsSnapshot.swift`)。
- 剪贴板用 `NSPasteboard.withUniqueName()`;模型目录用 `ModelManager(baseDir: 临时目录)`。
- 不要在测试里先 `TextInjector.captureTarget()` 再 `inject`:会向最前台的 App 发真实的 ⌘V。
- 新增测试后，先 `rg 'UserDefaults.standard|NSPasteboard.general|deleteModel|captureTarget' NemoNoiseTests` 查一遍再跑。

本机没有 Team YHT8FN67G3 的签名证书，跑测试要关签名:

```sh
xcodebuild test -scheme NemoNoise -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO
```

Swift 6 下测试的写法：测试类标 `nonisolated`,测试方法标 `@MainActor`。`setUp`/`tearDown` 用同步重写加 `MainActor.assumeIsolated`,闭包里不要捕获 `self`(会被数据竞争检查拒绝);也不要用 async 版本，每个用例会多出约 0.2 秒。需要主线程对象时在用例里本地创建，不要存成测试类的属性。

## 需要用户处理

- 录音快捷键当前为空，是被修复前的旧测试清掉的。需要在 设置 → Activation Key 里重新设置。

## 未修复

### 已核实的 bug

| # | 级别 | 触发场景 | 症状 | 位置 | 修复方向 |
|---|---|---|---|---|---|
| 2 | P1 | 在设置里换引擎后马上开录 | 这次录音丢失；旧管道的麦克风一直开着 | `PipelineProvider.swift:71`(`rebuildDictation`)、`:133`(`bind`);`RecordingController.swift:102` | 模型重建期间(`dictation == .loading`)拒绝开录；录音中不替换管道；`TranscriptionPipeline.start()` 给 continuation 加 `onTermination`,消费端退出就停掉音频源 |
| 3 | P1 | 切换模式下录音时按 ESC | 停不下来 | `RecordingController.swift:431`(`startEscMonitor`) | `addLocalMonitorForEvents` 只收本 App 的事件，而浮窗是 nonactivatingPanel,焦点在目标 App。改用全局监听，或录音期间临时注册一个全局快捷键 |
| 4 | P2 | 按住说话模式下首次授权麦克风 | 授权后自动开始录音，但松键事件已经丢了，一直录满 120 秒 | `RecordingController.swift:168-176` | 授权成功后不自动开录，提示“已授权，请重新按住说话” |
| 5 | P2 | 蓝牙切换耗时超过 2 秒，或连续收到多次配置变更 | 会话被看门狗误判为卡死而终止(需真机验证) | `MicAudioSource.swift:308-314`(等待窗口内只重新配置一次)、`:328`(`reconfigureForRouteChange` 不重置看门狗) | 窗口内改为防抖后重新配置；配置成功后调用 `watchdog.recordActivity` |
| 6 | P2 | 用 Paraformer 流式听写的全过程 | 解码和 CT-Transformer 标点都在主线程上跑，可能让浮窗卡顿(需 Instruments 验证) | `ParaformerStreamingEngine.swift:24-25`、`PunctuationProcessor.swift:16` | 引擎和标点处理器标 `nonisolated`,解码放进 `Task.detached`(参照 `SherpaASREngine`) |
| 7 | P2 | 用 SenseVoice 听写，每段超过 1 秒的语音 | 每段解码两次，延迟和功耗翻倍(Qwen3 不受影响) | `VADSegmentingEngine.swift:78-82`(`decodeSegment`) | 不要先调 `inner.feedChunk`;给离线引擎加一个只累积、不解码的入口 |
| 8 | P2 | 翻译模式停止后马上重开 | 旧的停止任务等 `stopCapture` 返回后才把 `stream` 置空，可能清掉新会话的引用，导致停不掉或中途断音 | `SystemAudioSource.swift:38-42`、`:52-57` | 在 `stop()` 和 `onTermination` 里先取出当前 stream 再交给 Task,不要在 Task 里读 `self.stream` |
| 9 | P3 | 快速轻点中止后立刻重按 | 旧的 pump 任务可能把少量旧音频块喂给刚重置的引擎 | `TranscriptionPipeline.swift:137-146`(`stop`) | `stop` 改成 async,等旧任务结束再返回 |
| 10 | P3 | 翻译进行中按听写热键 | 没有任何反馈 | `RecordingController.swift:191` | `tryAcquire` 失败时弹 toast |

### 评审报告、尚未逐条核实

| 级别 | 问题 | 位置 |
|---|---|---|
| P2 | Electron 等应用拿不到 AX 元素时，会跳过密码框检测，文字可能被粘贴进密码框 | `TextInjector.swift:166-186`;`isSecureField` 在 `:337` |
| P2 | 引擎降级到 Apple 后不重新判断要不要加标点，可能出现双标点(降级很少触发) | `PipelineProvider.swift:100` |
| P2 | VAD 门控没有滞回，可能吞掉词内的短停顿 | `VADGate.swift:35-42` |
| P2 | 正常停止时可能误弹错误提示并上报 Sentry(取消时序待验证) | `RecordingController.swift:245,305` |
| P3 | 翻译在途请求计数重置后，旧任务还会再减一次 | `AsyncTranslateProcessor.swift:61-72` |
| P3 | `.failed` 状态是死代码；浮窗控制器之间互相强引用 | `RecordingState.swift:8`、`OverlayWindowController.swift:6` |

### 其他已知问题

- 没有焦点元素时，注入会走 ⌘V,并显示和“插入成功”一样的提示，但文字可能没进任何输入框(剪贴板里有一份)。这条路径目前没有测试；要测，需要先给 `TextInjector` 注入一个粘贴函数。
- `docs/superpowers/specs/2026-06-08-commercialization-gaps-design.md` 里的 U1(无 i18n)、U2(无障碍)还没做。其中 P1(离线引擎 O(n²) 重解码)经 `VADSegmentingEngine` 包装后实际不成立。
- 工程 entitlements 开了沙盒，但本机已安装 App 的数据在沙盒之外(设置在 `~/Library/Preferences`,模型在 `~/Library/Application Support/NemoNoise/models`),需要确认发布版的签名配置。

## 已修复

| # | 问题 | 提交 |
|---|---|---|
| 1 | 配置变更通知和看门狗在后台线程操作 AVAudioEngine;原代码还在 CoreAudio 通知队列上释放 engine,`AVAudioEngine.h` 警告这样可能死锁 | `39b2b43` |
| — | 后台构建引擎时读取了主线程的 `ModelManager.states` | `39b2b43` |
| — | 引擎降级切换时 `EngineBox` 读写没有加锁 | `39b2b43` |
| — | 系统音频回调里的计数器和重采样器没有加锁 | `39b2b43` |
| — | 5 个系统回调在 Swift 6 下会直接崩溃 | `39b2b43` |
| — | 5 个过期测试；测试会改写用户的设置、剪贴板、模型目录 | `69200d3` |

## 建议顺序

1. 真机冒烟测试(见下),确认 Swift 6 运行时没有隔离崩溃。
2. 修 #2、#3、#4。都集中在 `RecordingController` / `PipelineProvider`,改动小，用户能直接感知。
3. 修 #8、#9。都是会话启停的时序问题，属同一类。
4. 修 #6、#7(性能)。#5 需要戴蓝牙耳机在真机上复现。
5. 再逐条核实评审列表。

## 真机冒烟清单

1. 四个引擎各听写一次:SenseVoice、Qwen3、Paraformer、Apple。
2. 戴着 AirPods 录一次，应能正常录完。
3. 录音过程中拔掉或切换麦克风，应停止录音并弹出提示。
4. Apple 引擎首次授权语音识别(可先运行 `tccutil reset SpeechRecognition com.nemo.NemoNoise` 重置权限)。
5. 用翻译模式(系统音频)跑一次。
6. 在设置里下载一个模型，看进度条是否正常。
7. 在设置里切换引擎。
