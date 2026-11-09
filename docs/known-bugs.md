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
| (待提交) fix | 修 #2、#8、#9、#10;新增会议记录模式 MVP(双轨采集 + JSONL/Markdown 落盘 + 实时转写浮层) |

- App 和测试都是 `SWIFT_VERSION = 6.0`,外加默认 MainActor 隔离和 Approachable Concurrency。
- 215 个单测全部通过，构建无并发警告。
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
| 5 | P2 | 蓝牙切换耗时超过 2 秒，或连续收到多次配置变更 | 会话被看门狗误判为卡死而终止(需真机验证) | `MicAudioSource.swift:308-314`(等待窗口内只重新配置一次)、`:328`(`reconfigureForRouteChange` 不重置看门狗) | 窗口内改为防抖后重新配置；配置成功后调用 `watchdog.recordActivity` |

### 评审报告、尚未逐条核实

| 级别 | 问题 | 位置 |
|---|---|---|
| P2 | Electron 等应用拿不到 AX 元素时，会跳过密码框检测，文字可能被粘贴进密码框 | `TextInjector.swift:166-186`;`isSecureField` 在 `:337` |
| P2 | 引擎降级到 Apple 后不重新判断要不要加标点，可能出现双标点(降级很少触发) | `PipelineProvider.swift:100` |
| P2 | VAD 门控没有滞回，可能吞掉词内的短停顿 | `VADGate.swift:35-42` |
| P2 | 正常停止时可能误弹错误提示并上报 Sentry(取消时序待验证) | `RecordingController.swift:245,305` |
| P3 | 翻译在途请求计数重置后，旧任务还会再减一次 | `AsyncTranslateProcessor.swift:61-72` |
| P3 | `.failed` 状态是死代码；浮窗控制器之间互相强引用 | `RecordingState.swift:8`、`OverlayWindowController.swift:6` |

### 评审遗留(2026-11-09 合并前评审,未修)

| 级别 | 问题 | 位置 |
|---|---|---|
| 中 | 粘贴恢复卡片 12s 内"再插入"复用共享注入器的当前目标:期间新开录音会把旧文本插到新目标;重试结果被丢弃;`text_too_long` 也提供无意义重试 | `PasteRecoveryCard.swift:20` |
| 中 | 每次听写都写剪贴板且未标 `org.nspasteboard.TransientType/ConcealedType`,剪贴板管理器会记录全部听写 | `OutputDispatcher.swift:41` |
| 中 | LLM 清洗守卫单向:只按输出词元算重合(数字被改"500→5000"、整段被摘要都能过);`withThrowingTaskGroup` 会等不响应取消的子任务,10s 看门狗可能超时不生效(功能默认关) | `TranscriptCleanupService.swift:80-145` |
| 中低 | 热启动不检查停放期间的设备/回声消除设置变化(切回"系统默认"麦克风、系统默认输入变更、VPIO 开关) | `MicAudioSource.swift:243-258,628` |
| 低 | 重建沿用旧会话起始时间,唤醒重建后紧接蓝牙 HFP 切换会落在沉降窗口外而中止会话 | `MicAudioSource.swift:847` |
| 低 | 零输入判定用 `abs > 1e-5` 而非精确零,VPIO/噪声门 USB 麦 3s 停顿可能误触发重建 | `MicAudioSource.swift:584` |
| 低 | 路由切换后旧采样率的暂存样本走新重采样器,产生一小段垃圾音频 | `MicAudioSource.swift:781` |
| 低 | 进程抽头"权限被拒"提示:首次会议 15s 无任何应用播放也会误报;`systemAudioTapProven` 置位后再撤销权限不再检测 | `ProcessTapAudioSource.swift:247-275` |
| 低 | 引擎最终释放不保证在退役队列上;3s 超时允许重叠 | `MicAudioSource.swift:19-22` |
| 低 | 引擎构建"后写者赢":慢的 bootstrap/压力重建可能覆盖更新的设置切换 | `PipelineProvider.swift:190-221` |
| 低 | 会议 Me 轨另载一份听写模型(互斥保证同时只跑一种模式,可复用);降级到 Apple 后其时间轴从 0 起与 `UtteranceClock` 错位;`MeetingSink` 每行 `synchronizeFile` 在主线程 | `PipelineProvider.swift`、`MeetingSink.swift` |
| 低 | Esc 事件 tap 跑在主 run loop,录音期间主线程卡顿会拖慢全系统按键;未处理 `.tapDisabledByUserInput` | `GlobalEscMonitor.swift` |
| 低 | 启动预热 en-US 资产,从不用翻译的用户也会下载 | `PipelineProvider.swift` bootstrap |
| 低 | App 包内未附第三方许可(cicada Apache-2.0 需随分发提供许可文本),应加入"关于/致谢" | — |
| 低 | 测试宿主即 App,测试日志写进用户真实日志 `~/.NemoNoise/logs`,干扰排查 | `LogService.swift` |

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
| 2 | 引擎重建换管:重建期间拒绝开录(`isEngineRebuilding`)、录音中 build 暂存到 `onReturnToReady` 再应用、`pipeline.start()` 的 `onTermination` 停掉音频源(带会话 token 防误杀新会话) | 待提交 |
| 8 | SystemAudioSource 停止竞态:`stop()`/`onTermination` 先在主线程取出 stream 再异步 `stopCapture` | 待提交 |
| 9 | `TranscriptionPipeline.stop()` 改 async,等旧 pump 排空再返回;`abortRecording` 等排空后才释放 mutex | 待提交 |
| 10 | dictation/translation/meeting 三方 `tryAcquire` 失败都弹 toast | 待提交 |
| — | **模型数据丢失**:`ModelManager.download()` 开下前先删旧目录、失败/取消再删一次,重新下载失败会毁掉可用安装(2026-06-25 三个 ASR 模型因此丢失)。改为临时目录暂存、成功后原子替换;失败时按磁盘实际状态恢复。设置页新增 Permissions 页与侧边栏样式,Models 页常显全部模型 | 待提交 |
| — | **快捷键无法录制**:KeyboardShortcuts 2.4.0 的 `Recorder` 本体是 NSSearchField,靠 `becomeFirstResponder` 安装的 local event monitor 拦 keyDown;在 macOS 26 上监视器收不到事件,控件退化成纯文本输入框(只能打字)。换自研 `ShortcutRecorderField`:普通 NSView 直接 override `keyDown(_:)` 捕获,录制期间把已注册热键暂存清空、结束/取消时恢复(Esc 取消、⌫ 清除),全局注册仍走 KeyboardShortcuts | 待提交 |
| — | **Toast 只剩图标**:macOS 26 上 `GlassEffectContainer` 不向 NSHostingView 报告固有尺寸,历史 48 条 toast 全是 0×0 面板,文字被裁光。加兜底测量(图标+文本+边距)作为尺寸下限 | 待提交 |
| — | **Apple 降级引擎静默失败无日志**:`SFSpeechRecognitionTask` 的错误回调(含限流、"no speech")不落日志,连续快速多次听写被限流时看起来像"录不上声音"且无从排查。错误回调统一记 `domain/code`(2026-11-07 首次真机连按 10 次,后 4 次全程零结果即此现象;模型重新下载后走本地引擎不受影响) | 待提交 |
| — | **快速按热键后麦克风永久楔死(P1,真机日志实锤)**:快速停启循环后,新会话的原始采样全为精确零(VAD speech=0、maxMicLevel=0),之后每次按键都录不上,持续数分钟;无 VPIO、无配置变更、无停滞,属 AVAudioEngine 快速停启后 HAL 输入楔死。修复:`MicAudioSource.start()` 距上次拆引擎不足 300ms 先沉降;采集开头原始采样连续 ≥1.5s 全精确零(真静音有 ADC 底噪,可安全区分)→ 当场重建引擎一次自愈,流不断。日志:`Input delivering only zeros` / `Audio engine rebuilt after zero-input` | 待提交 |
| — | **Apple 引擎换 SpeechAnalyzer(macOS 26 本地识别)**:原 `SFSpeechRecognizer` + `requiresOnDeviceRecognition=false` 走云端,连续短听写被 kAFAssistantErrorDomain 限流(真机日志 code=1110)。重写 `AppleSpeechASREngine` 内部:SpeechAnalyzer/SpeechTranscriber(volatileResults 流式)、AnalysisContext 热词偏置、AssetInventory 首用自动下载语言资产,类名/协议/调用方零改动;参照 yap(MIT)的用法。不再有云端限流;注意首次使用某语言会触发资产下载 | 待提交 |
| — | **SpeechAnalyzer 会话启动慢 + 吞尾音**(真机反馈):每个会话 begin 都重复 `installedLocales`/`reservedLocales` IPC 查询 → 按进程+语言缓存资产状态;`finish()` 固定 100ms 等待截断最后一句 → 改为等结果流结束(2s 超时兜底) | 待提交 |
| — | **新增:听写会话音频落盘 + 历史回放/重识别**:`SessionAudioRecorder` 把每段听写的原始(pre-VAD)16k 单声道音频写成 WAV(`Application Support/NemoNoise/Recordings/`),历史卡片新增 ▶ 播放和 Re-recognize(用本地 SpeechAnalyzer 重跑同一段音频并替换文字)——区分"麦克风问题还是识别问题"的地面真相;音频上限 100 条自动清理,删除记录联动删文件,中止/出错会话不保留 | 待提交 |
| — | **对标开源调研的三项落地(VoiceInk/FluidVoice/yap/OSW 模式)**:① `EngineRetirementDrain`——旧 AVAudioEngine 在专用串行队列析构、新引擎构建前 await 排干(替换原 300ms 盲等,确定性消灭双 IOUnit 抢 HAL 导致的全零楔死,FluidVoice 模式);② app 启动时 `AppleSpeechASREngine.prewarm()` 预热资产(zh+en,测试注入 no-op,yap/muesli 模式),首段听写不再卡资产查询;③ 失败会话音频保留并在日志给路径(OSW 模式),中止(too-short)仍丢弃 | 待提交 |
| — | **架构重构:引擎池 + 会话即弃(VoiceInk/FluidVoice 模式,2026-11-08)**:① `TranscriptionPipeline` 单会话化——每场会话新实例,删会话 token/onTermination 校验(#2 家族机制失去存在土壤);② 新 `DictationSession`(一次性对象)内聚计时/静默/ESC/会话音频;③ `PipelineProvider` 变引擎池——本地引擎+Silero 检测器常驻,`newDictationPipeline/newTranslationPipeline/newMeetingPipelines` 每次激活产廉价壳;设置换引擎=后台建好换池引用,录音中的会话持旧引擎跑完,**删 isEngineRebuilding/pendingDictationBuild/onReturnToReady 整条暂存链**;④ 翻译/会议控制器同步改工厂模式,不再复用管道实例。217 测试全绿 | 待提交 |
| — | **采集层四项加固(第二轮调研缺口,均已验证原始出处)**:① **渲染线程减负**(VoiceInk "render callback never locks")——tap 回调只做 memcpy(位模式传指针)进暂存区,重采样/FFT/零扫描/yield 全部移到专用串行队列,stopEngine 前队列栅栏保证尾音不丢;② **removeTap/stop 包 ObjC 异常桥**(muesli:路由重绑期间 removeTap 会死锁)——失败即弃图;③ **零输入检测扩展到全程**(muesli MeetingMicHealthTracker)——开头无音频 1.5s 触发自愈、会话中途连续 3s 精确零也触发,每会话一次;④ **休眠唤醒重建**(VoiceInk invalidate on wake)——didWake 时存活会话重建引擎。217 测试全绿 | 待提交 |
| — | **第三轮调研四项(2026-11-08)**:① **SpeechAnalyzer 绕过 VAD 门控**(yap/muesli 验证:门控零替换扰乱其端点/时间轴)——Apple 引擎直连原始麦克风,听写+会议 Me 轨两处装配;顺带消除该路径"词内短停顿吞字";② **Electron `AXManualAccessibility` 预激活**(FluidVoice)——检测 Electron Framework bundle 即开官方 AX 开关(0.2s 超时,按 bundleID 去重),密码框检测/AX 读对 Electron 生效;③ **注入前等待物理修饰键释放**(FluidVoice)——⌥热键未松开时合成 ⌘V 会变 ⌥⌘V,paste/keystroke 两条路径入口各等 ≤1.5s;④ **引擎加载后喂 1s 静音热身**(muesli)——CoreML 首解码的图编译挪到加载期,Apple 引擎除外(启动预热已覆盖)。217 测试全绿 | 待提交 |
| — | **第四轮调研落地(2026-11-08)**:① **内存压力卸载**(VoiceInk DispatchSourceMemoryPressure)——系统内存紧张且三模式空闲时卸载全部常驻引擎,下次会话工厂调用懒重建(Qwen3 940MB 常驻不再有 Jetsam 杀进程风险);② **会议面板滚动跟随状态机**(muesli)——NSClipView 通知判断是否在底部(±24pt),上翻时挂起新行、浮现"New messages"回顶按钮;③ **Esc 两段式取消**(yap)——第一次 Esc 只武装(浮层橙字提示),2.5s 内再按才停;④ **登录启动 Toggle**(Settings→General→Startup,SMAppService,以系统状态为准,requiresApproval 有提示);⑤ **会议完整转写窗口**——浮层新增展开按钮,打开可调大小窗口看全场(Me/Them 颜色+时间戳+Copy All,同样滚动状态机),会议结束自动关闭。217 测试全绿 | 待提交 |
| — | **第五批(2026-11-08,开放 #6/#7 关闭)**:① **#7 SenseVoice 每段解码两次**——根因:`SherpaASREngine.feedChunk` 带渐进预览解码,而它恒被 `VADSegmentingEngine` 包裹、每段又走一次 `finish()` 全量解码;`feedChunk` 改纯累积,每段只解一次(延迟/功耗减半);② **#6 解码占主线程**——`ParaformerStreamingEngine`/`PunctuationProcessor` 默认 MainActor 隔离,泵的 detached 任务调用时会跳回主线程推理;标 `nonisolated`,标点推理进 `Task.detached`(`TranscriptionResult` 同步标 nonisolated struct);③ **粘贴恢复卡片**(FluidVoice)——注入失败不再只弹提示,出现带 "Insert again" 一键重试的玻璃卡片(12s 自动消失);④ **转写耗时入库**——History 记录新增 durationSeconds,行内显示 `· 3.2s`,对比引擎延迟有据可查。217 测试全绿 | 待提交 |
| — | **第六批(2026-11-09):麦克风热启动 + LLM 转写清洗**:① **8s 热启动**(FluidVoice standby 模式)——`stop()` 正常停止不再立即拆引擎:非蓝牙输入时把已配置好的引擎存入进程级 `MicStandbyPool`(8s 窗口到期自动退役,系统休眠即弃),8s 内下次 `start()` 命中即只重装 tap+重启引擎,跳过引擎构建与 retirement-drain 等待(快速连按首音丢失的两个主要来源);格式/首选麦克风变化自动落回冷启动;蓝牙输入不进池(避免 HFP 呼叫模式钉死耳机);中断/自愈/abort 异常路径仍走硬拆除。注意:`MicStandbyPool` 的 timer 回调必须标 `@Sendable`(否则继承 MainActor 隔离,utility 队列触发即 dispatch_assert_queue 崩溃——踩过,见崩溃栈);测试里 retire 钩子可注入(测试进程碰未启动引擎的 inputNode 会陷 HAL 代理重试循环)。② **LLM 转写清洗(默认关,Settings→General→Transcript)**——新 `TranscriptCleanupService`:Apple Intelligence SystemLanguageModel(macOS 26 SDK 是 `LanguageModelSession(model:instructions:)` 构造、`respond(to: String)`,无 `makeSession`),插入前去口语词/修错字/修标点。守卫栈(yap+muesli):任何失败/超时(10s 看门狗)/模型不可用→原文照插;≥60% 内容词元保真 + 中文 2.5x/短句 4x 膨胀上限防幻觉;反注入前言 + `<transcript>` 包裹 + 输出去标签/去包裹引号;6000 字上限;History 永远存原始转写(诊断基准,清洗只影响插入文本)。235 测试全绿 | 待提交 |
| — | **第七批(2026-11-09,#3/#4 关闭)**:① **#3 切换模式 ESC 全局监听(P1)**——根因:浮窗是 nonactivatingPanel,键盘焦点始终在目标 App,`addLocalMonitorForEvents` 只能看见发给自己 App 的事件。新 `GlobalEscMonitor`:CGEventTap 挂 HID 层(`headInsertEventTap`+`defaultTap`),录音期间拦截并**消费** ESC(目标 App 不再同时收到两份),回调经 `MainActor.assumeIsolated` 上主线程(tap 源在主 runloop),超时被系统禁用自动重新 enable;tap 创建失败(无 AX 信任/沙盒拒绝)回落旧 local monitor,绝不双装(双装会让一次物理 ESC 触发两路,两段式取消瞬间"武装+停止")。编译坑:`@convention(c)` 回调里不能引用 `Self`(用字面量 53)。② **#4 按住说话首授权后录满 120s**——根因:授权弹窗吃掉松键事件,授权回调里 `startRecording()` 自动开录但停上手势已丢。改为:toggle 模式(单次按键手势完整)保持自动开录;push-to-talk 弹 toast「Microphone authorized — hold the hotkey to record」。会议模式按钮触发无此问题,不改。238 测试全绿 | 待提交 |
| — | **第八批(2026-11-09,真机反馈:内存压力卸载后卡"准备中")**——日志实锤:凌晨系统内存压力触发第四批的卸载逻辑,卸载后只有按热键才会懒重建,用户看面板永远显示"引擎一直在准备"。修复:压力卸载后 60s 自动重建(期间若已被懒重建路径处理则 no-op;压力持续则再次卸载,有界循环)。另澄清:该现象与本地模型无关(Apple 引擎不依赖本地模型)。238 测试全绿 | 待提交 |
| — | **第九批(2026-11-09 上午,真机实锤两发)**:① **开会议必崩(P1,ProcessTapAudioSource)**——崩溃栈:IOProc 回调在 `com.apple.audio.IOThread.client` 上 `dispatch_assert_queue_fail`——`AudioDeviceCreateIOProcIDWithBlock` 的闭包和格式监听闭包都没标 `@Sendable`,默认 MainActor 隔离模式下继承了主线程断言,CoreAudio IO 线程一调即 trap。会议 MVP 的遗留雷,此前进程抽头从未真机跑过(冒烟清单第 8 条一直没做),一跑现形。修复:两处闭包标 `@Sendable`(与麦克风 installTap 同一族,"@Sendable is load-bearing")。② **压力卸载空转("Preparing engines…" 卡一早上)**——截图+日志:机器整晨反复内存压力,每次都把常驻引擎卸掉重建,但用户没装本地模型,常驻的只有 Apple 引擎+Silero+标点(几 MB),卸载零收益纯折腾。修复:只有轻量引擎常驻时跳过卸载(日志 `only lightweight engines resident, keeping them`);装了本地大模型才真正卸。238 测试全绿 | 待提交 |
| — | **第十批(2026-11-09 上午,会议模式真机三连修)**:① **会议面板空壳**——`MeetingPanelController` 用 `sizingOptions = .preferredContentSize` + `setFrame(380×560)`,而 MeetingPanelView 根部是 maxWidth/maxHeight .infinity + glassEffect,macOS 26 上 preferred size 塌成 ~0(Toast 0×0 同族),窗口 380×560 里 SwiftUI 内容不可见。修复:`sizingOptions = []` + autoresizing(窗口驱动尺寸,SwiftUI 填满)。② **说中文出英文**——会议 Them 轨复用了翻译模式的 `makeTranslation()`,Apple 回退写死 en-US;用户中文语音若经系统音频回环(真实会议 App)进进程抽头,en-US 引擎把中文音译成英文("hold children"/"Sure, sure" 即此产物,JSONL 实锤)。修复:新增 `makeMeetingThem()`——Paraformer 可用则用,否则 Apple 引擎跟随听写语言偏好(默认 zh-CN),不再写死 en-US。③ **落行日志**——MeetingSink final 时记 `Meeting line (me/them): ...`,今后分轨排查有据。遗留观察:Me 轨(麦克风)在该场会议 90 秒零 final(音频流正常、zh-CN 会话已建)——待用户安静环境重测定位(嫌疑:输入设备为 352800Hz 的特殊设备/当时声音只走了系统回环)。238 测试全绿 | 待提交 |
| — | **第十一批(2026-11-09,会议面板双波形)**:面板头部加两个实时频谱波形——蓝=麦克风(Me)、绿=系统音频(Them),复用听写浮窗的 `SpectrumBarsView`(7 柱精简版);顺带修 `handleTrackEvent` 只认 `.partial` 不认 `.level` 的漏接(静音期电平全丢,旧圆点几乎不动的原因);`.level` 与 `.partial` 携带相同 RMS+频谱,两态都更新。Me/Them 电平数据此前就有,只是没接。238 测试全绿 | 待提交 |
| — | **第十二批(2026-11-09,首次点击即开会议)**:① 会议引擎轻量组合(Apple-only,无本地模型)改为**启动时即建**(bootstrap 后 buildMeetingIfNeeded,日志 `Meeting engines are lightweight — building eagerly`)——首次点 Start Meeting 直接开,无准备 toast、无需点第二次;重模型组合保持懒构建(内存考虑)。② 懒构建兜底:startMeeting 遇未就绪时启动单飞 autoStartTask 轮询(100ms×100=10s 上限),就绪即自动开会议,不再要求用户点第二次;meetingBuilt 失败路径由 popover 的 .failed 状态呈现。③ 顺带答复:仅麦克风说话 Them 也出字=用户声音经系统音频回环(待用户用绿色波形定位回环源:会议软件/监听/OBS/DAC 回路)。相关测试改写:testMeetingBuildsLazily… → testMeetingBuildsEagerlyWhenLightweight…。238 测试全绿 | 待提交 |
| — | **第十三批(2026-11-09,Apple 引擎逐句 final——SpeechAnalyzer 改写时丢失的契约)**:根因:`AppleSpeechASREngine` 把 transcriber 的逐句 isFinal 拼成一段增长的 partial,只在 `finish()` 时吐一次 final(旧 SFSpeech 版的逐句队列 `AppleSpeechFinalQueue` 成了死代码,`OverlayProgressSink` 注释里的契约已失效)。影响:① 会议 Me 轨用 Apple 时整场只有一行、停止时才落盘,崩溃即全丢,标点模型每个音频块重跑全文(很可能就是第十批"Me 轨 90 秒零 final");② 翻译/会议 Them 退回 Apple 时,`SentenceSegmenter` 按字符偏移切会被改写的 volatile,产生重复行/错切。修复:新纯值类型 `AppleSpeechTranscript`(每个 commit 恰好报告一次为 isFinal,partial 只含当前句,`TranscriptJoin` 拼接无 CJK 空格);`ASREngine.emitsSentenceFinals`(Apple=true),`SentenceSegmenter` 对此类引擎 partial 整句直通、不切;`TranscriptJoin` 标 nonisolated。新增 13 测试,251 全绿。**待真机验证**:Apple 引擎听写(浮窗逐句确认)、会议 Me 轨逐句落 JSONL、翻译字幕无重复 | 待提交 |
| — | **第十四批(2026-11-09,final 丢词守卫)**:SpeechAnalyzer 快语速时 final 会丢掉 draft 已听到的整段短语(cicada issue #1)。移植 cicada `HeardText.clean`/`fuller`(Apache-2.0,来源与改动注明于 `Utils/HeardText.swift` 文件头):`AppleSpeechTranscript.apply` 收到 final 时与最后一个 volatile 比较,draft 多出 ≥3 词(中文 ≥6 字)且 ≥1.15 倍则改用清洗后的 draft,日志 `Final dropped words the draft had`。`clean` 目前只用于被采纳的 draft,尚未作为通用 PostProcessor 接入。新增 9 测试(含 cicada 原用例),258 全绿 | 待提交 |
| — | **第十五批(2026-11-09,会议行带"开口时刻")**:原先行时间戳=送达时刻 `Date()`,两轨识别延迟差最多一个 VAD 段(30s),排序错乱、无法跨轨比对(EchoMatch 前提)。`TranscriptionResult` 新增 `audioStart`(会话音频秒)与 `spokenAt`(墙钟);管线内纯值类型 `UtteranceClock` 统计已喂音频、在 final 上盖章:引擎自带值优先(Apple 用 `result.range.start`;`VADSegmentingEngine` 用分段在流中的精确位置),否则取本句首个 partial 所在块,再否则取上一行结束;墙钟锚点=首块到达时刻减首块时长,两轨各自锚定、互不依赖启动延迟。`MeetingSink`/存储用 `spokenAt`,面板按开口时间插入,Markdown 导出排序,JSONL 仍按到达顺序追加(崩溃安全)。新增 15 测试,273 全绿。**待真机验证**:① SpeechAnalyzer 结果 range 是否从首个输入 buffer 起算;② 进程抽头在系统长时间静音时是否持续送 buffer——若不送,音频时钟会落后墙钟,对方轨时间整体偏早(cicada 遇到过,需按墙钟补静音) | 待提交 |
| — | **第十六批(2026-11-09,会议 Markdown 导出格式)**:真机导出的 .md 是 Swift 数组字面量 `["- 00:12 ...", ...]` 后跟字面量 `.joined(separator: ...)`——多行字符串里插值在 `})` 处闭合,`.joined` 落成正文;原测试只查 `contains` 漏检。改为插值外先拼行;新增逐行精确断言测试,274 全绿。另:2026-11-09 14:28 那场真机会议跑的是 11:47 的旧构建(早于第十三~十五批),其"对方 12s 硬切 / 停止时整场重复一行 / 我方仅停止时一行"正是第十三批修的问题,三批仍待新构建真机验证 | 待提交 |
| — | **第十七批(2026-11-09,新构建真机会议反馈)**:前几批真机验证通过(MD 逐行、停止不再整场重复、Me 轨逐句、行时间=开口时刻,如首行 06:43:00 送达、戳 06:42:41)。新修两项:① **对方轨/翻译双标点 `。。` `，，`**——会议 Them(`PipelineProvider` 原 :531)与翻译(:377)无条件挂 CT-Transformer,未查 `emitsPunctuation`,自带标点的 Apple 被二次加标点;新 `PipelineProvider.punctuator(for:from:)` 统一四处装配。② **上屏延迟 10–20s**——SpeechAnalyzer 无 `.fastResults` 时中文约每 11s 才报一次;`AppleSpeechASREngine(fastResults:)`,会议两轨与翻译开启,听写保持准确优先;工厂新增 `makeMeetingMe()`(会议 Me 不再复用听写的 `makePrimary`)。会话日志带 `fast=`。新增 8 测试,282 全绿。**EchoMatch 注意**:该场 Me 行"同意建议行进 20,000多个词的真实词典"与 Them 行文字高度重合但**是用户跟读**,不是回声——纯文本重合判定会误删,EchoMatch 需另寻信号(如外放检测/耳机状态)。**待真机验证**:延迟是否降到 ~1s、错字增加是否可接受 | 待提交 |
| — | **第十八批(2026-11-09,行首标点清理接入全部管线)**:开 `.fastResults` 后真机出现 `。记住它靠…`(Apple 在不确定句子是否结束时先提交上一句,句号落到下一段开头)与 `回来 ，直到`。新 `HeardTextProcessor`(包 `HeardText.clean`,保留 sequence/originalText/audioStart/spokenAt),挂到听写、翻译、会议 Me、会议 Them 四条管线末端:在 `SentenceSegmenter`、标点、术语纠错之后,翻译之前;partial 同样清理。注意 clean 会把连续点号统一为"…"。新增 5 测试,287 全绿。另观察到:开 fast 后 Apple 中文几乎不出逗号(未开时有),标点稀疏待定方案 | 待提交 |
| — | **第十九批(2026-11-09,撤回 `.fastResults`)**:第十七批对会议两轨+翻译开启的 `.fastResults` 真机无收益:用户感受不到实时文字变快;中文逗号几乎消失;已提交句的句号漏到下一行开头;短句跟读识别明显变差("惊现阿俊本尊/再见小蓝灯"→"京县阿俊再见小兰东","领域还在"→"两翼小虫","帮个忙"→"万个忙")。全部撤回(删 `fastResults` 参数与 `makeMeetingMe()`,会议 Me 回到 `makePrimary`),在 `AppleSpeechASREngine` 转写器配置处留注释记录证据防止重试;双标点修复与 `HeardTextProcessor` 保留。282 全绿。另:`AGENTS.md`/`CLAUDE.md` 新增规则——每次改动测试通过后直接运行 `./build.sh` 安装 | 待提交 |
| — | **第二十批(2026-11-09,合并前三路代码评审修复)**:对全部未提交改动按音频采集/引擎管线/输出输入分三路评审,修复——**输出/输入**:① 两段式 Esc 第二次按下调用的是 `stopRecording()`(会插入文本),改为 `abortRecording(reason:)` 丢弃+toast;② `GlobalEscMonitor` 不过滤键盘自动重复与修饰键(长按 Esc=武装+触发;⌘⌥Esc 强制退出被吞),新纯函数 `isCancelPress`;③ `ShortcutRecorderField` 用持久化的 `setShortcut(nil)` 暂停热键,非正常结束(关窗/退出/失焦)会永久清空两个热键(很可能就是"录音快捷键当前为空"的真因),改用 `KeyboardShortcuts.disable/enable`(不落盘),点击才开始录制,失去 key 窗口/离开窗口即结束;④ 无 AX 元素时补查 `IsSecureEventInputEnabled()`,不往密码框粘贴;⑤ 修饰键等待移到前台检查之前;⑥ 会议面板"New messages"手动滚到底不消失;⑦ `HeardText.clean` 不再合并换行、保留"-5"负号;新增 `LICENSES/cicada-Apache-2.0.txt`。**引擎/管线**:⑧ 内存压力卸载后会议工厂返回 nil、"开始会议"静默无反应——卸载时 `MeetingController.unbind()`,走"准备→自动开始";⑨ 卸载 60s 后盲目重建(压力未解除也重载 ~1GB)——改为监听 `.normal` 恢复后重建,`isLight(nil)` 视为轻量;⑩ 1s 静音热身在引擎已发布后运行,与新会话并发用同一引擎——移到构建任务内、发布前;⑪ 停止过程中的管线错误把状态翻回 `.ready`,新会话启动后被旧停止任务拆掉(mutex 被释放、麦克风常开)——`.processing` 期间忽略、互斥锁在 abort 排空后才释放;翻译控制器同型修复(比对 `activePipeline === pipeline`);⑫ `fuller` 守卫:draft 往往覆盖到 final 范围之外,改用 draft 会重复提交后半句——仅当 draft 结束时间不超过 final 结束时才替换,时间未知则信 final;⑬ 模型"原子替换"先删后移,移动失败即丢模型且不校验完整性——`ModelManager.installStaged`:校验必需文件 + `replaceItemAt`,暂存目录放在目标同卷。**音频采集**:⑭ 待机池会停放从未收到真实音频的(楔死)引擎,快速连按反复复用——仅 `sawAudio` 才停放;⑮ 自愈/唤醒重建等待排空后不复查会话,可能给已停止会话起无监听引擎;重建失败会话永久静默——复查 continuation 与会话标记,失败触发 `.audioStalled` 中断;⑯ `stop()` 先关流再排空处理队列,丢最后一截音频——改为先拆除排空再关流;⑰ 会话 WAV 头按排空前的帧数写、且在停麦前关闭文件——按实际文件长度回填,`endSession()` 移到 `finalize()` 之后。新增 8 测试,290 全绿,无并发警告。评审遗留项见"未修复 · 评审遗留"。另:#2 行与"300ms 沉降"行描述的机制已被引擎池/EngineRetirementDrain 取代,以本行为准 | 待提交 |

## 建议顺序

1. 真机冒烟测试(见下),确认 Swift 6 运行时没有隔离崩溃,重点跑会议模式新增项。
2. 修 #3、#4。都集中在 `RecordingController`,改动小，用户能直接感知。
3. 修 #6、#7(性能)。#5 需要戴蓝牙耳机在真机上复现。
4. 再逐条核实评审列表。

## 真机冒烟清单

1. 四个引擎各听写一次:SenseVoice、Qwen3、Paraformer、Apple。
2. 戴着 AirPods 录一次，应能正常录完。
3. 录音过程中拔掉或切换麦克风，应停止录音并弹出提示。
4. Apple 引擎首次授权语音识别(可先运行 `tccutil reset SpeechRecognition com.nemo.NemoNoise` 重置权限)。
5. 用翻译模式(系统音频)跑一次。
6. 在设置里下载一个模型，看进度条是否正常。
7. 在设置里切换引擎。
8. **会议模式**(新增):弹窗点 Start Meeting → 首次应弹「系统音频录制」授权(不是屏幕录制);播放一段视频同时说话 → 浮层出现 Me/Them 双色转写,`~/Library/Application Support/NemoNoise/Meetings/` 下 JSONL 持续增长;Stop Meeting → toast + Finder 里出现导出的 `.md`。
9. **会议互斥**(#10):会议进行中按听写热键 / 开翻译,应弹 "Audio is in use by another mode";反向(听写中开会议)同样。
10. **会议中换引擎**(#2):会议进行中在设置里切引擎,会议不受影响;再验证听写:设置里切引擎后立刻开录,应被拒绝并提示引擎切换中。
11. **快速启停**(#8/#9):快速 Stop Meeting 后立刻再 Start,新会话不应混入旧音频;翻译模式快速启停同理。
12. 会议中切输出设备(扬声器 ↔ AirPods),Them 轨应换格式继续收音(进程抽头自带 format-change 处理)。
13. **热启动(第六批)**:结束一次听写后 8s 内再按热键,日志应出现 `Capture parked for hot start` + `Capture hot-started from standby`,且第二次几乎无首音丢失;间隔 >8s 再按走冷启动(`Capture started`);戴 AirPods 听写后日志应是 `Bluetooth input — no standby`。
14. **LLM 清洗(第六批,需 Apple Intelligence)**:Settings→General→Transcript 打开开关,说一段带「嗯/呃」的话,插入文本应无口语词且语序不变;History 卡片里应仍是原始转写;问句(如「现在几点了」)不应被模型回答(守卫拦截后插入原文)。
15. **ESC 全局监听(第七批,#3)**:切换模式录音中,焦点保持在别的 App(如备忘录)时按 ESC:第一次浮层出现橙色提示,第二次停止录音;且目标 App 不应同时收到 ESC(如在关闭下拉菜单的场景验证)。
16. **首授权不空转(第七批,#4)**:`tccutil reset Microphone com.nemo.NemoNoise` 后按住说话:授权弹窗出现→授权,应弹「Microphone authorized」提示而非自动录满 120s。
17. **压力恢复(第八批)**:若出现"引擎一直在准备",60s 内应自动恢复 Ready(日志 `Rebuilding engines after memory-pressure unload`)。18. **会议真机回归(第九批修复后必须重做第 8 条)**:Start Meeting 不再崩;双轨转写、导出、互斥全链路。
