# 播放器意图 API 重构设计方案

> 状态：**设计稿（未实施）** ｜ 基准 commit：`50512063`（工作区含未提交改动）
> 适用版本：THMIX Community Edition（Godot 4.7.1 Mono / miniaudio）
> 本文只描述方案，不含实现。文中**「已核实」**= 读过代码并与行号对应；**「推断」**= 由代码行为归纳、未逐行验证。

---

## 0. 摘要

问题不是"某个函数写错了"，而是**职责切在语言边界上**：C# 播放器持有全部真实状态，GDScript 只看得见其中两个布尔值（`is_playing`/`is_paused`），却被要求替播放器做状态转移决策。

本方案把切分线从"语言边界"移到**状态边界**：

1. C# 成为唯一的状态机所有者。GDScript 只发**意图**（想做什么），不收**机制**（怎么做）。
2. GDScript 不再调任何设备恢复方法，改为**订阅** C# 发出的状态/打断信号。
3. 位置读取从"四个同名不同义的函数"收敛为**一个快照结构 + 一张用途表**。
4. 新增完整状态快照 `get_playback_snapshot()`，让"此刻到底在哪个状态"成为可断言的事实而非注释。
5. 机制动词（`play`/`resume`/`stop`/`recover_audio_output`/`resume_audio_output_in_place_or_recreate`/`recreate_audio_output`）对 GDScript 关闭。

净效果：**GDScript 侧需要改动的调用点约 60 处，集中在 6 个文件**，爆炸半径可控。

---

## 1. 问题陈述

### 1.1 根因：三个状态机，一个观察窗

C# 内部实际并行运行三个互相耦合的状态机（**已核实**）：

| # | 状态机 | 实现载体 | 取值 |
|---|---|---|---|
| 1 | 传输 | `playing`、`_paused`、`_currentOffsetMs`、`_sequencerStarted` | 预卷（负时间轴）/ 播放 / 暂停 / 曲终 / 停止 |
| 2 | 音频设备 | `_audioOutput`（`MiniaudioAudioOutputBridge`） | 有效 / 已 Stop / **已失效**（`ma_bridge_start` 返回非 Ok，`AudioStartFailed=true`） |
| 3 | sequencer | `_sequencer`（`MidiFileSequencer`）+ `_sequencerStarted` | 未起播 / 运行中 / `EndOfSequence` 闩锁 |

而 GDScript 能观察到的只有状态机 #1 的两个布尔：`is_playing()`（=`playing` 字段）、`is_paused()`。**#2 和 #3 对 GDScript 完全不可见**（已核实 `Game/PlaybackDisplay.gd:607-610`）。

于是 GDScript 被迫用"机制动词 + 启发式推断"来间接操纵状态：

- 想表达"开始预卷"→ 只能 `seek(负数)`
- 想表达"继续"→ 只能 `resume()`
- 想判断"设备是不是坏了"→ 只能看"位置是不是 0.5s 没动"
- 想决定"要不要恢复设备"→ 只能猜

**这不是代码质量问题，而是接口把不可观测的状态暴露成了可调用的动作。**

### 1.2 位置读取：四个出口，实际只有两个值，命名严格误导

（**已核实**）`Game/PlaybackDisplay.gd:711-718`：

```gdscript
func get_position_ms()          -> MeltySynth.get_visual_position_ms()
func get_realtime_position_ms() -> MeltySynth.get_visual_position_ms()   # 同上
func get_visual_position_ms()   -> MeltySynth.get_visual_position_ms()   # 同上
func get_raw_position_ms()      -> MeltySynth.get_raw_position_ms()      # 唯一不同
```

三个名字指向同一个值，剩下一个指向另一个值。**这四个值本身都是正确的**，问题出在名字：

| 现有名字 | 真实身份 | 谁在用 | 评注 |
|---|---|---|---|
| `get_visual_position_ms()` | **判定钟**（扣掉 `_audioDelayMs` 后的"听到的位置"） | 判定、显示、进度条 | **名字是误称**："visual" 让人以为它是"仅用于画面"的量 |
| `get_raw_position_ms()` | **音频回调渲染钟**（不扣延迟、不锚墙钟） | 人声同步、停滞检测 | 名字反而更"通用"，实则专用 |
| `get_position_ms()` / `get_realtime_position_ms()` | 前者的别名 ×2 | `PlayView` / `FlowArea` | 两个别名，无法从名字判断同上 |

于是 **`PlayerDisplay.get_position_ms()` 拿到的其实就是判定钟，这是正确的**——`FlowArea._get_realtime_position_ms()` 也是正确的。真正的缺陷是**命名导致的认知负担**：`FlowArea.gd:129` 的旧注释把 `get_position_ms()` 描述为"包含缓冲补偿"，`CLAUDE.md` 则要专门写一句"只有 `get_visual_position_ms()`（判定/可视化）扣减该延迟"来防止误读。

**为什么"判定必须扣这个延迟"：**

设设备/蓝牙延迟 `d`（蓝牙预设默认 200ms，`PlaybackDisplay.gd:595`）。

- 回调钟（raw）记录"**已经渲染出来**"的音频位置。渲染 ≠ 听到，raw 超前真实听觉 `d`。
- 在墙钟时刻 `T`，用户**听到**的是 `T - d` 那一刻渲染的音频 → 此刻 raw 钟读数 = `T + d`。

| 口径 | 在墙钟 `T` 的读数 | 与"听到的声音"对齐？ |
|---|---|---|
| `AudioMs`（raw，不扣 `d`） | `T + d` | **超前 2d ≈ 400ms** ✗ |
| `get_visual_position_ms()`（扣 `d`）= 判定钟 | `T` | ✓ |

玩家踩点踩的是**听到的声音**，判定必须用 `T` → **必须扣**。Perfect 窗口 ≤50ms；不扣的话 200ms 延迟下音符判在 400ms 之外，整个判定体系崩塌。

**最直接的反证是校准功能自己**：`DelayAdjust` 让玩家跟着节拍点，调出的值就是"让点击判成 Perfect 的偏移量"。若判定不扣它，校准就只影响画面、对判定无效——那这个功能没有存在的意义。

> **结论（已订正）**：`JudgeMs`（扣延迟）与 `RawTimelineMs`（不扣延迟）需要分离，这点成立；但**"判定被校准延迟污染"是误报**。`get_visual_position_ms()` 扣延迟是正确设计，本方案**不改变任何数值行为**，只消除命名歧义、给每个值一个专属名字、并让"该用哪个"从注释变成签名。

**命名陷阱（值得留档，因为它是本方案初稿误报的真正根因）**：

> 现有 API 里名为 `get_visual_position_ms()` 的函数**返回的不是"判定钟"，而是"再扣一次校准延迟的显示钟"**；而架构文档又说"判定/可视化扣减该延迟"。两者叠加的结果是：**任何按名字推断语义的人都会得出"判定用了显示钟"的错误结论**（本方案初稿的 §1.2 就是这么误报的）。而 `PlaybackDisplay.get_realtime_position_ms()` 转发到的正是这个"再扣一次"的口径 —— 名字与内容完全对不上。
>
> 这正是本次要消除的问题之一：**按用途命名**（判定 / 显示 / 原始 / 校准值），而不是按历史实现命名。

### 1.3 八条已知故障的统一形状

| # | 现象 | 一句话根因 |
|---|---|---|
| 1 | 开局音符全 Miss、要几十秒恢复 | **一个函数顺手改了时间轴语义**：`get_visual_position_ms()` 里 `Math.Max(0.0, …)` 把预卷负值钳成 0 |
| 2 | 从播放器页进打歌，判定钟从几十秒起跳 | **两条分支写同一状态，只有一条写了**：`seek_ms()` 正值分支设 `_seekAnchorMs`，负值分支没设 |
| 3 | 预卷期间 `get_position_ms()` 恒返回 0 | **两个读函数分支顺序不一致**：`get_position_ms()` 把预卷判断排在 seek-hold 之后；`get_raw_position_ms()` 排在前 |
| 4 | 每次整桥重建都误判"采样率变了"→ 重置 sequencer | **成员被无条件覆盖**：`EnsureAudioInitialized()` 里 `_sampleRate = AudioServer.GetMixRate()` 把设备原生率探测结果冲掉（`MeltySynthPlayer.cs:277` vs `299-302`） |
| 5 | 来电恢复后 MIDI 从头播、人声回到原处 | **对称操作只做了一半**：`RecreateAudioOutputBridge()` 恢复人声位置，漏了 MIDI 位置 |
| 6 | 一进 PlayView 就被判曲终抬去结算 | **一个动词两种语义**：`resume()` 在预卷状态下必须"什么都不做"，被打上"续播"的行为后设备被提前拉起 → 回调渲染全 0 → `end-of-sequence latched` |
| 7 | "人声与 MIDI 不同步"一整类问题 | **"要不要人声"被编码成动词**（`resume()` vs `resume_with_vocal()`），而它本该是**状态** |
| 8 | 从暂停菜单继续 → 曲首重播 | **调用方替播放器判断"该不该重起预卷"**，判据（`_game_started`）与真实状态（预卷是否已消费）不是同一件事 |

归纳成一句：

> **每一个故障都是"某处代码基于对另一个状态机的错误假设，做了一个它没有资格做的状态转移决策"。**

具体来说，故障 1/2/3 是"读接口在不同状态下返回值语义不一致"；4/5 是"状态被分段维护，某一段被漏掉"；6/7/8 是"机制动词在多状态下含义不同，而调用点无从判断当前状态"。

### 1.4 最强证据：`resume()` 的 3 个调用点，3 套互斥的前置契约

（**已核实**，行号对应工作区当前内容）

| 调用点 | 前置动作 | 期望语义 | 期望"设备恢复"行为 |
|---|---|---|---|
| `UI/Views/PlayView/PlayView.gd:498`（`is_pause` setter） | 可能刚 `seek(-1700)`（开局），也可能没有（暂停续播） | **二义**：预卷启动 **或** 续播 | 必须 **不拉起设备**（预卷） / 必须拉起设备（续播） |
| `UI/Views/TrackView/TrackView.gd:1032` | `resume()` 在 `seek(resume_pos_ms)` **之前** | 续播 + 位置恢复 | 必须拉起设备 |
| `UI/Views/MusicPlayerView/MusicPlayerView.gd:300` | `resume()` 在 `seek(resume_pos_ms)` **之后**（且带 `deferred_play_pending` 判据） | 续播 + 位置恢复 | 必须拉起设备 |

目前区分"预卷启动"与"续播"的唯一判据是 C# 内部的 `_currentOffsetMs < 0.0`（`MeltySynthPlayer.cs:2852`、`1078`）——**这是隐式契约**：没有任何签名、类型或文档表达它，它之所以成立，仅仅因为"调用者恰好在之前 seek 过一个负数"。

> 顺带证实：`TrackView` 与 `MusicPlayerView` 都写了同一条"先 `resume()` 再 `seek(pos)`"的补丁，`TrackView.gd:1033` 的注释把它解释为"音源重载会把后端合成器位置清零"。**两处重复的补丁正说明接口缺了一个意图。**

### 1.5 设备恢复决策目前散落在 3 处（不是我原先以为的 4 处）

**已核实**（注意：任务描述里"`PlaybackDisplay.gd:636` 调 `resume_audio_output_in_place_or_recreate()`"已**过时**——工作区版本 `Game/PlaybackDisplay.gd:633-641` 已删除该调用，并留下注释"不要在 GDScript 侧决定'要不要拉起音频设备'"）：

| 位置 | 调用 | 语境 |
|---|---|---|
| `Main.gd:62-64` | `MeltySynth.recover_audio_output()` | `NOTIFICATION_APPLICATION_RESUMED/FOCUS_IN` 且当前在 PLAY_VIEW |
| `UI/Views/PlayView/PlayView.gd:556` | `resume_audio_output_in_place_or_recreate()` | 音频焦点 GAIN |
| `UI/Views/PlayView/PlayView.gd:254` | `resume_audio_output_in_place_or_recreate()` | 位置停滞检测分支 |
| `Game/PlaybackDisplay.gd:575-580`（4 处，但非"恢复"） | `recreate_audio_output()` | Windows 输出端点切换跟随 |

**并且已经有一处决策在 C# 里了**（已核实）：`MeltySynthPlayer.BackgroundAdvance.cs:210-227` 的**音频存活看门狗**——"`playing` 且回调计数停滞 → `maStall.Play()`"。这是同一件事的第五个决策点，而且它已经做对了（决策留在唯一能看到设备状态的地方）。

**结论：本方案不是发明新架构，而是把已经存在的正确模式（看门狗）推广到全部路径。**

### 1.6 两条并行的装配路径，同一件事两种拼法

（**已核实**）

```
打歌：  load_midi → start_session([midi],0,false,loop_file=false) → seek(-1700) → pause() → resume()
试听：  load_midi → start_session([midi],0,false)（loop_file 默认 true）  → play()
续播：  start_session(...,false) → resume() → seek(resume_pos_ms)
```

三点观察：

1. "加载某曲并开始播放"这一个意图，用了 `load_midi`/`start_session`/`seek`/`pause`/`resume`/`play` 六种动词拼装。
2. `play()` 路径**完全没有预卷**，`resume()` 路径靠隐式的负 offset 表达预卷——**同一个概念在两条路径上由不同机制承载**。
3. 三个布尔（`persist` / `loop_file` / "是否预卷"）混在位置参数里，其中 `loop_file` 默认值还**反向**了语义（`Playlist.cs:24-26` 的注释说明"默认 true 以保住 TrackView/播放器页，只有 PlayView 显式传 false"）。

### 1.7 一个真实未被记录的问题：粒子精灵表常驻 VRAM（顺手修复，**独立于本次 API 重构**）

（设备实测 + 代码核实）

**实测数据**（Android 设备资源监视器，一局打歌后）：

| 精灵表 | 尺寸 | 解码占用 |
|---|---|---|
| `Particles/Diamond-Rainbow/base.png` | 2048×2560 | 20 MiB |
| `Particles/Diamond-Orange/base.png` | 2048×2560 | 20 MiB |
| `Particles/BoxBurst/base.png` | 2048×2048 | 16 MiB |
| **合计** | — | **56 MiB**（进程视频内存共 130.4 MiB，占 43%） |

**已核实的三件事**：

1. 这些确实是**精灵表（帧序列）**，不是单张大图——`particle.ini` 的 `size=256` 是**单帧边长**，2048×2560 → 8×10 = 80 帧。
2. **已做 VRAM 压缩**，格式上无优化空间——`base.png` 2368 KiB / 5.24 M px ≈ **3.6 bpp**，属 ETC2 级别压缩。指望"换压缩格式"或"缩小尺寸"都是死路（会直接损失特效画质）。
3. 真正的问题是**生命周期**：`FlowArea.prewarm_spark_packs()` 在开局前按本局用到的特效把整表 `load()` 进 `ParticleManager._base_texture_cache` / `_emitter_texture_cache`，而**离开打歌页后从不释放**。此前唯一能清掉它的路径是 `MemoryGC` 的后台内存压力回收（已核实 `Core/MemoryGC.gd:209-211` 调 `ParticleMGR.clear_texture_cache()`）——**前台正常打完一局回到菜单，那 56 MiB 会一直挂着。**

**已在工作区修复**（`Core/ParticleManager.gd:418` 的 `clear_texture_cache()` 早已存在，缺的只是调用点）：在 `PlayView._on_state_changed` 离开 `PLAY_VIEW` 的统一清理分支（`PlayView.gd:337` `flow_area.clear_flow_area()` 之后）补了：

```gdscript
if ParticleMGR != null:
    ParticleMGR.clear_texture_cache()
```

**取舍已记在代码注释里**（`PlayView.gd:338-348`）：去 `SCORE_VIEW` 也一并释放——代价是重试时多约 0.2s 预热，收益是结算页省下 56 MiB。预热发生在预卷之前的准备动画期（最长 3s），不影响对局。

> **归属说明**：这是**独立的顺手修复**，与 §1.1–§1.6 的状态机/接口问题无因果关联。它**不进入 §6 迁移映射表**，也不属于 §8 的任何实施阶段。列在这里只是因为它同样源于"某个资源的生命周期没有明确归属"这一共同主题，值得与本次重构一并被记住。

---

## 2. 设计目标与非目标

### 2.1 目标

| # | 目标 | 可验证判据 |
|---|---|---|
| G1 | 状态转移决策权 100% 在 C# | `grep` 全仓 `.gd` 不再出现 `recover_audio_output` / `recreate_audio_output` / `resume_audio_output_in_place_or_recreate` / `play_transport` / `resume_with_vocal` |
| G2 | GDScript 只发意图、收信号 | 所有 `.gd` 对播放器的写操作都落在 `PlaybackIntent` 命名空间内的方法上 |
| G3 | 位置读取只有一条路，且所有生命阶段合法 | `get_playback_position()` 在预卷/播放/暂停/曲终四态下均返回**未被钳制**的值；预卷期间 `transport_ms < 0`；**每个字段的数值与今天对应口径逐毫秒等价**（纯归属明确化，不改行为） |
| G4 | "不同意图的相似行为"在类型层面不可混淆 | 没有 `resume()`；取而代之的是 `resume_at()`（带位置）与 `start_performance()`（带起始模式），编译器/参数个数即可区分 |
| G5 | 状态可观测 | `get_playback_snapshot()` 一次返回 phase / 三个状态机 / 位置 / 打断，GDScript 不再猜 |
| G6 | 设备恢复只有一个决策点 | 决策函数只被 `FocusChanged` / `AppResumed` / `Watchdog` / `EndpointChanged` 四个内部事件触发 |

### 2.2 非目标

- ❌ 不改 miniaudio 桥、音频回调、RingBuffer、native 层。
- ❌ 不改判定算法、键序列生成、计分。
- ❌ **不改任何位置的数值行为**。§5.1 的位置重构是**改名 + 归属明确化**，`JudgeMs` 在当前取值下与今天的 `get_visual_position_ms()` 逐毫秒等价（见 §1.2 订正）。
- ❌ 不改播放列表会话模型（`MidiCore` 两槽 A/B、`RepeatMode`）——它已经是"状态而非动词"的正面样板。
- ❌ 不合并 `PlaybackDisplay` autoload。它仍是 GDScript 门面，但要**减薄**：转发信号 + 缓存快照，不再做决策。
- ❌ 不追求"删掉所有旧方法"。旧方法保留为 shim（带告警），删除是后续独立步骤。

---

## 3. 新 API 设计（C#）

### 3.1 命名与分层原则

三类方法，命名规则不同：

| 类别 | 前缀 | 谁可调 | 例子 |
|---|---|---|---|
| **意图（Intent）** | 动词短语，描述"用户/页面想做什么" | GDScript ✓ | `start_performance` / `resume_at` / `set_vocal_intent` |
| **查询（Query）** | `get_*` / `is_*` | GDScript ✓ | `get_playback_snapshot` / `get_playback_position` |
| **机制（Mechanism）** | 现有名词 + 动作 | **C# 内部**，GDScript ✗ | `play` / `resume` / `recover_audio_output` |

关键约束：**意图方法名里禁止出现机制词**（`play`/`pause`/`resume`/`stop`/`recover`/`recreate`/`transport`）。意图方法名描述的是**玩家/页面视角的事件**。

### 3.2 类型定义

```csharp
// ============ 播放阶段（唯一权威） ============
public enum PlaybackPhase
{
    Idle        = 0,  // 无曲目、无会话
    Preparing   = 1,  // 会话已装配、文件已载入，尚未在时间轴上（offset==0 且未起播）
    PreRolling  = 2,  // 负时间轴倒计时；sequencer 刻意停着，设备刻意停着
    Playing     = 3,  // sequencer 运行中、设备运行中
    Paused      = 4,  // sequencer 停着（位置保留）、设备已 Stop
    Ended       = 5,  // 自然曲终、非循环会话且未起播；位置停在曲尾
    Stopped     = 6,  // 显式结束；位置归 0
}

// ============ 会话类型（决定曲终行为 + 是否落盘） ============
public enum SessionKind
{
    Performance = 0,  // 打歌一局：曲终即停，交给结算；不落盘；不文件级循环
    Preview     = 1,  // 音轨试听：文件级循环；不落盘
    PlayerPage  = 2,  // 播放器页：文件级循环 + 落盘 + 列表可推进
}

// ============ 起始方式（替代"seek 负数"这个隐式协议） ============
public enum PlaybackStartMode
{
    PreRollFromNoteFall = 0,  // 由 C# 用 [Generator] note_fall_time 自行算预卷时长
    PreRollMs           = 1,  // 显式预卷毫秒（负值）；仅调试/测试用
    AtCurrentOffset     = 2,  // 从当前位置开始；位置未知则从 0
    AtMs                = 3,  // 从指定非负位置开始
    DeferToCaller       = 4,  // 只装配到 Preparing，由调用方随后显式下发起始意图
}

// ============ 设备状态（独立于传输状态） ============
public enum AudioDeviceState
{
    Absent      = 0,  // 桥尚未创建
    Stopped     = 1,  // 桥存在，ma_device 已 Stop（正常：暂停/预卷）
    Running     = 2,  // ma_device 运行中
    StartFailed = 3,  // 最近一次 ma_bridge_start 失败 → 流已失效，只有整桥重建能救
}

// ============ 打断（由播放器判定并广播） ============
public enum PlaybackInterruptReason
{
    None             = 0,
    AudioFocusLoss   = 1,  // 焦点丢失（来电/他人播放）→ 播放器已自行暂停
    DeviceLost       = 2,  // 音频钟停滞且未到曲终 → 播放器已自行尝试恢复
    AppBackgrounded  = 3,  // 应用进后台
    OutputEndpointChanged = 4,  // Windows 默认输出端点改变
}
```

```csharp
/// <summary>一次取全的播放状态快照。GDScript 侧只读、不再逐项拼凑。</summary>
[GlobalClass]
public partial class PlaybackSnapshot : RefCounted
{
    // —— 状态机 #1：传输 ——
    [Export] public int    Phase;                   // PlaybackPhase
    [Export] public bool   SequencerRunning;        // 状态机 #3
    [Export] public bool   MidiLoaded;
    [Export] public bool   HasEverStarted;          // 本会话是否已跨越预卷（替代 PlayView._session_started）
    [Export] public string CurrentKey = "";

    // —— 状态机 #2：音频设备 ——
    [Export] public int    DeviceState;             // AudioDeviceState
    [Export] public double LatencyMs;

    // —— 位置（见 §5.1 用途表） ——
    //
    // 【这套钟是两套，不是三套】
    //   JudgeMs / VisualMs：判定·感知轴（扣掉校准延迟）
    //   RawTimelineMs     ：原始时间轴（sequencer 的时间域，无任何扣减）
    // 每个字段都必须显式暴露：跨时间域取值是真实存在过的 bug（见 §11 A8）。
    [Export] public double JudgeMs;           // 判定 · 感知钟
                                              //   = 墙钟锚点推进 − 设备延迟 − 校准延迟
                                              //   = 现有 get_position_ms() − _audioDelayMs
                                              //   = 现有 get_visual_position_ms()（去掉钳制后）
    [Export] public double VisualMs;          // 【与 JudgeMs 同值】显示钟
                                              //   保留独立字段是为了让调用点按"用途"取用而非按实现；
                                              //   将来若真要给显示与判定不同口径，只改这里，不动调用点。
                                              //   ⚠ 当前**恒等于** JudgeMs，不是"现在就有两个不同的数"
    [Export] public double RawTimelineMs;     // 原始时间轴 = 现有 get_raw_position_ms()
                                              //   供"必须活在 sequencer 时间域"的用途：状态恢复、诊断
    [Export] public double AudioMs;           // 音频回调渲染钟（不扣延迟、不锚墙钟）
                                              //   仅供人声同步与停滞检测
    [Export] public double PendingSeekMs;     // NaN = 无待处理 seek
    [Export] public double PrerollRemainingMs;// 预卷剩余（负 offset 的绝对值）；非预卷为 0

    // —— 汇总量 ——
    [Export] public double DurationMs;
    [Export] public double AudioDelayMs;      // 当前生效的校准延迟；仅供诊断/显示，不参与判定
    [Export] public int    InterruptReason;   // PlaybackInterruptReason（None=无）
    [Export] public bool   Paused;
    [Export] public bool   Playing;
}
```

```csharp
/// <summary>位置查询的返回值（可选：供只需要时间的调用点少建一个对象）。</summary>
[GlobalClass]
public partial class PlaybackPosition : RefCounted
{
    [Export] public double JudgeMs;         // 判定 · 感知轴（扣校准延迟）
    [Export] public double VisualMs;        // 与 JudgeMs 同值（用途可读性）
    [Export] public double RawTimelineMs;   // 原始时间轴（sequencer 的时间域）
    [Export] public double AudioMs;         // 音频回调渲染钟
    [Export] public bool   IsPreRoll;
}
```

### 3.3 意图方法签名（GDScript 可调）

```csharp
// ============ A. 会话装配（一次调用完成"载入 + 配置 + 设定会话语义"）============

/// <summary>开一局打歌。内部：set_file → apply_chart_audio_config → 会话=Performance（不落盘/不循环）
/// → 按 startMode 摆好时间轴。返回 false 表示曲目解析失败。</summary>
public bool start_performance(string chartKey, string midiPath, PlaybackStartMode startMode);

/// <summary>音轨试听。会话=Preview（文件级循环、不落盘）+ 立即起播。</summary>
public bool start_preview(string chartKey, string midiPath);

/// <summary>播放器页会话（落盘、列表可推进、文件级循环）。</summary>
public bool start_player_session(string chartKey, string midiPath);

/// <summary>只装配不起播：载入 + 应用配置 + 设定会话语义，停在 Preparing。
/// startMode 为 DeferToCaller 的等价物，供"加载后可能不播"的路径使用。</summary>
public bool prepare_session(string chartKey, string midiPath, SessionKind kind);

// ============ B. 起始 / 暂停 / 续播（意图动词，带位置）============

/// <summary>开始播放会话，按 mode 决定起始位置。预卷由玩家自己计时，GDScript 不再算负值。</summary>
public bool begin_playback(PlaybackStartMode mode, double atMs = -1.0);

/// <summary>暂停（保留位置、释放设备、暂停人声）。</summary>
public void request_pause(PlaybackInterruptReason reason = PlaybackInterruptReason.None);

/// <summary>从暂停/中断中继续。【会自行决定是否就地拉起设备、是否整桥重建】</summary>
public void resume_from_pause();

/// <summary>续播并定位到指定位置。顺序由 C# 保证（先定位再起播），
/// 取代现有"resume() 然后 seek()"两处补丁。</summary>
public void resume_at(double positionMs);

/// <summary>把播放位置挪到指定位置（非负）。时间轴原值语义，不做校准扣减。
/// 这是"时间轴操作"，不隐含任何播放/暂停状态转移。</summary>
public void set_playback_position(double positionMs);

/// <summary>重开当前会话的预卷（"准备阶段呼出菜单后继续"用）。仅在 PreRolling/Preparing 合法，
/// 其他阶段记录告警并忽略 —— 从机制上根治"从暂停菜单继续 → 曲首重播"。</summary>
public bool restart_preroll();

/// <summary>结束会话：停设备、停 sequencer、会话语义复位、位置归 0。</summary>
public void end_session();

// ============ C. 人声（状态而非动词）============

/// <summary>人声是否参与播放。取代 pause_with_vocal/resume_with_vocal/set_vocal_playing 的动词分裂。</summary>
public void set_vocal_intent(bool enabled);

/// <summary>人声相对 MIDI 的时间偏移（毫秒）。</summary>
public void set_vocal_offset_ms(double offsetMs);

// ============ D. 音频焦点与打断（GDScript 只订阅，不做决策）============

/// <summary>音频焦点变化。C# 自己决定暂停/恢复/重建，并广播 playback_interrupted / playback_resumed。</summary>
public void notify_audio_focus_changed(int state);

/// <summary>应用回到前台。</summary>
public void notify_app_resumed();

/// <summary>系统默认输出端点改变（Windows）。</summary>
public void notify_output_endpoint_changed();

// ============ E. 查询（无副作用）============

public PlaybackSnapshot get_playback_snapshot();
public PlaybackPosition get_playback_position();
public float get_backend_duration_ms();          // 保留
public bool  is_device_usable();                 // DeviceState == Running || Stopped
```

### 3.4 语义契约：每个方法在四个状态下的行为

**图例**：`—` = 无操作；`◐` = 有操作但不动时间轴；`●` = 会改变时间轴或设备运行态。

#### `begin_playback(mode, atMs)`

| 当前 phase | `PreRollFromNoteFall` / `PreRollMs` | `AtCurrentOffset` / `AtMs` | `DeferToCaller` |
|---|---|---|---|
| `Idle`（无曲） | 返回 `false`，日志告警 | 返回 `false` | 返回 `false` |
| `Preparing` | ● 置 `_currentOffsetMs = -preroll`，`playing = true` → `PreRolling`；**设备与 sequencer 均不启动** | ● 定位后起 sequencer + 起设备 → `Playing` | ◐ 返回 `true`，不改状态 |
| `PreRolling` | ● **重启预卷**（覆盖当前剩余）→ 仍 `PreRolling` | ● 丢弃预卷、从目标位置起播 → `Playing` | — |
| `Playing` | ◐ 仅重置预卷计时（不停止当前播放）→ `PreRolling`；**这是"重开一局"的显式意图，不是意外** | ◐ 定位到目标位置 → 仍 `Playing` | — |
| `Paused` | ● 从预卷起点重新开始 → `PreRolling` | ● 定位后起设备 → `Playing` | — |
| `Ended` | ● 从预卷起点重开 → `PreRolling` | ● 定位后从当前会话重播 → `Playing` | — |
| `Stopped` | 同 `Preparing`（若曲仍在）否则 `false` | 同 `Preparing` | ◐ `true` |

> **关键不变量（预卷）**：进入 `PreRolling` 时，`sequencerRunning == false` **且** `deviceState == Stopped`。只有 `_Process` 检测到 `_currentOffsetMs >= 0` 跨零点时，才**在同一次状态转移里**启动 sequencer + 启动设备 + 复位 offset。
>
> 这条不变量正是 bug 6 的根治：`resume_from_pause()`（或任何其他入口）在 `PreRolling` 下**不可能**把设备拉起来，因为它必须先经过 `begin_playback` 才允许改变 phase。

#### `request_pause(reason)`

| 当前 phase | 行为 |
|---|---|
| `PreRolling` | ● 冻结预卷倒计时（`playing = false`），设备本来就停着 → `Paused`；`PrerollRemainingMs` 保留 |
| `Playing` | ● 落一次真实位置（`RenderedPosition - latency`）→ 停设备 → 停 sequencer（释放在响声部）→ `Paused` |
| `Paused` | — |
| `Ended` / `Stopped` | — （返回，不改 phase） |

#### `resume_from_pause()`

| 当前 phase | 行为 | 设备动作 |
|---|---|---|
| `PreRolling` | ◐ 恢复倒计时（`playing = true`）→ 仍 `PreRolling` | **— 什么都不做**（不变量：预卷期间设备必须停着） |
| `Paused`（原为播放中） | ● 起 sequencer（若未起）+ 起设备 + 恢复人声 → `Playing` | ● 就地 `Play()`；仅当 `AudioStartFailed` 时才整桥重建 |
| `Paused`（原为预卷中） | 由 `PrerollRemainingMs > 0` 判定 → 回落为预卷分支 | — |
| `Preparing` | ◐ 等价 `begin_playback(AtCurrentOffset)` | ● |
| `Idle` / `Stopped` | 返回 `false`，日志告警（不做隐式起播） | — |
| `Ended` | 返回 `false`（曲终已决，重播必须显式 `begin_playback`） | — |

> **`resume_from_pause()` 不再接收位置参数，也不再被期望"顺手恢复位置"**——需要定位就用 `resume_at(pos)`。这消灭了 `TrackView.gd:1032-1035` 与 `MusicPlayerView.gd:300-303` 两处"先 resume 再 seek"的补丁。

#### `resume_at(positionMs)`

顺序**由 C# 保证**：`set_playback_position(pos)` → 若此刻设备已失效则就地 `Play()` → 失败则整桥重建并恢复位置 → 若 sequencer 未起则起 → 恢复人声（按 offset 门控）。任何 phase 下都合法，`positionMs` 会被钳到 `[0, length]`。

#### `end_session()`

任何 phase 都合法。停设备、停 sequencer、`_currentOffsetMs = 0`、`_lastPositionMs = 0`、`_paused = false`、人声 `StopVocal()` + 复位 `_vocalDisabledByUser`、会话语义复位、phase → `Idle`。**不广播媒体通知撤销**（那是 `clear_media_notification()` 的职责，两者分开——现在 `PlaybackDisplay.stop()` 把两件事混在一起，已核实 `PlaybackDisplay.gd:638-644`）。

#### `set_vocal_intent(enabled)`

| 参数 | 行为 |
|---|---|
| `true` | 若位于 `Playing` 且未过人声起点 → 交给偏移门控放行；否则立即 `ResumeVocal()`。同时清 `_vocalDisabledByUser` |
| `false` | 置 `_vocalDisabledByUser = true` + `PauseVocal()`。**不停止、不卸载**解码器（下次开启不重解码） |

> 取代 `PlaybackDisplay.start_vocal_playback()` / `stop_vocal_playback()` 的动词对（已核实 `PlaybackDisplay.gd:971-991`）。它俩现在做的事完全一样：**翻转一个布尔**——只是名字写成了动词。

#### `notify_audio_focus_changed(state)`（C# 内部决策表）

| `state` | phase == `Playing` | phase == `PreRolling` | phase ∈ {`Paused`,`Ended`,`Idle`} |
|---|---|---|---|
| `0` GAIN | ◐ 确保设备在跑（`DeviceWatchdog` 口径），**不改变位置** | — （预卷不需要焦点） | — |
| `1` TRANSIENT | ● `request_pause(AudioFocusLoss)` → 发 `playback_interrupted(true, AudioFocusLoss)` | — | — |
| `2` DUCK | ● 降到 `ducking_volume`，**不暂停**（发 `volume_ducked(true)`） | — | — |
| `3` LOSS | ● `end_session()` → 发 `playback_interrupted(true, AudioFocusLoss)` | — | — |

其余 `notify_*` 同理，全部在 C# 内闭环，不向 GDScript 请求任何动作。

### 3.5 设备恢复的唯一决策点

```csharp
/// <summary>
/// 音频设备健康决策的唯一入口。四个触发源：FocusGain / AppResumed / Watchdog / EndpointChanged。
/// 返回是否发生了状态转移。
///
/// 决策顺序（顺序本身是不变量的一部分）：
///   1. phase == PreRolling  → 直接返回 false。【预卷期间设备必须停着】
///   2. bridge == null       → EnsureAudioInitialized()
///   3. deviceState == Running 且 !AudioStartFailed → 返回 false
///   4. 尝试就地 Play()
///   5. AudioStartFailed     → RecreateAudioOutputBridge()，并恢复 MIDI 位置 **与人声位置**
///   6. 发 playback_device_state_changed
/// </summary>
private bool EvaluateAudioDeviceHealth(DeviceTrigger trigger);
```

`recover_audio_output()` / `recreate_audio_output()` / `resume_audio_output_in_place_or_recreate()` **降级为 private**。它们在 C# 内部仍被 `EvaluateAudioDeviceHealth` 使用。

---

## 4. 信号契约

### 4.1 信号清单

命名约定：payload 用 `int` 传枚举（Godot 信号不直接支持 enum），GDScript 侧配一份镜像常量。

```csharp
// —— 会话/装配 ——
[Signal] public delegate void session_preparedEventHandler(string chart_key, int kind);
[Signal] public delegate void session_endedEventHandler(string chart_key);

// —— 阶段（取代"靠布尔推断"）——
[Signal] public delegate void playback_phase_changedEventHandler(int phase, int previous_phase, string reason);

// —— 打断（取代"GDScript 决定恢复"）——
[Signal] public delegate void playback_interruptedEventHandler(int reason, double at_position_ms, int phase);
[Signal] public delegate void playback_resumedEventHandler(int reason, double at_position_ms);

// —— 设备健康 ——
[Signal] public delegate void playback_device_state_changedEventHandler(int state, bool rebuilt);

// —— 保留（语义不变）——
[Signal] public delegate void current_song_changedEventHandler(string chart_key);
[Signal] public delegate void transport_changedEventHandler();
[Signal] public delegate void playback_state_changedEventHandler();
[Signal] public delegate void playlist_changedEventHandler();
[Signal] public delegate void playlist_index_changedEventHandler(int index);
[Signal] public delegate void repeat_mode_changedEventHandler(int mode);
[Signal] public delegate void playlist_user_editedEventHandler();
[Signal] public delegate void deferred_play_resumedEventHandler();
[Signal] public delegate void soundfont_reload_completedEventHandler();
[Signal] public delegate void midi_finishedEventHandler();
[Signal] public delegate void vocal_finishedEventHandler();
[Signal] public delegate void audio_focus_changedEventHandler(int state);  // 降级为"通知性"信号
```

### 4.2 发射时机与消费方响应

| 信号 | 何时发 | payload | GDScript 消费方应做什么 |
|---|---|---|---|
| `playback_phase_changed` | 每次 phase 转移（含 `PreRolling → Playing` 跨零点） | `phase`, `previous`, `reason`（`"preroll_cross_zero"` / `"user_pause"` / `"focus_loss"` / `"song_ended"` …） | PlayView：只在 `Playing → Paused` 且 reason 非 user 时弹暂停菜单；TrackView：`Paused` 时停 `_process`；播放器页：刷新按钮态 |
| `playback_interrupted` | phase 因外部原因变化时 | `reason`, `at_position_ms`, `phase` | PlayView：`_show_pause_menu()` + 记录"是被打断的"（**不再调任何恢复方法**） |
| `playback_resumed` | C# 自行恢复成功后 | `reason`, `at_position_ms` | PlayView：关菜单 + `_visual_time_needs_anchor = true` + 强制重读快照 |
| `playback_device_state_changed` | 设备状态变化 / 整桥重建完成 | `state`, `rebuilt` | **无人需要响应**（诊断用）；`rebuilt == true` 时 PlayView 可打一条日志便于对表 |
| `midi_finished` | 后端自然曲终（**全局信号，不区分是谁在放**） | — | PlayView：`_on_game_finished()`。⚠️ **订阅必须跟随本页活跃状态**，见下方「跨页误触发」 |
| `audio_focus_changed` | 焦点变化 | `state` | **降级为纯诊断**。PlayView 不再据此做任何动作（C# 已自行处理），仅日志 |

#### ⚠️ 原则：后端全局信号必须由"活跃页"订阅，不能常驻

`midi_finished` / `vocal_finished` / `audio_device_*` 这类信号由**播放后端**发出，**不区分是谁在放**。
而本项目里"谁在放"至少有两种合法情形：打歌页（PlayView 驱动）与播放器页（背景播放 + 列表推进）。

**若消费方在 `_ready()` 里常驻订阅，就会跨页误触发。** 已发生的真实案例：
PlayView 常驻订阅 `midi_finished` → 播放器页一首放完 → PlayView 的 `_on_game_finished` 被触发 →
内部 `playback_mgr.stop()` 把后端停掉 → **播放器页不再自动切下一首**。

**规则**：这类信号的订阅必须在 `state == 本页对应状态` 时建立、离开时解除；
并且 handler 内部还要再判一次"当前播放是否归本页驱动"（双保险，防止状态切换时序窗口）。
新增后端信号时请一并遵守 —— 这是本方案要消除的"一个东西混了不同地方的特殊逻辑"的典型。

### 4.3 信号顺序保证

对一次"焦点丢失"事件，发射顺序**固定**为：

```
playback_phase_changed(Playing → Paused, "focus_loss")
playback_interrupted(reason=AudioFocusLoss, at_position_ms=<冻结位置>, phase=Paused)
playback_state_changed()          ← 兼容旧消费方
```

→ 保证 GDScript 在收到 `playback_interrupted` 时 `get_playback_snapshot().Phase` **已经是** `Paused`。同理，恢复时 `playback_resumed` 发出后 phase 已为 `Playing`。

> 这条顺序保证让 GDScript 可以安全地在信号回调里读快照，不必用 `call_deferred` 绕时序。

---

## 5. 状态快照与位置用途表

### 5.1 位置：一个入口，两套钟，一个用途表

**设计方案：不再提供四个"位置读取函数"，只提供 `get_playback_position()`（或从 `PlaybackSnapshot` 取）。**

**核心事实（逐行核实）：这套钟是两套，不是三套。**

| 口径 | 公式 | 用途域 |
|---|---|---|
| **判定 · 感知轴** | 墙钟锚点推进（锚点由音频参考慢速校准）− `latencyMs`（设备内部延迟）− `_audioDelayMs`（校准延迟） | 判定 + 显示 |
| **原始时间轴** | sequencer 的渲染钟，无任何扣减 | sequencer 状态恢复、诊断 |

`get_position_ms()` 只扣设备延迟；`get_visual_position_ms()` 在此基础上**再扣校准延迟**；`get_raw_position_ms()` 不扣任何东西。**没有第三个"仅用于显示"的钟**——`CLAUDE.md:344` 的原文"只有 `get_visual_position_ms()`（判定/可视化）扣减该延迟"已经说明：**它同时是判定钟和显示钟**。

> ⚠️ **`JudgeMs` 与 `VisualMs` 当前恒等。** 保留两个名字不是"现在就有两个不同的数"，而是让调用点**按用途取用**（"我要判定位置" / "我要显示位置"），并为将来可能的差异化留一个不必改调用点的落点。任何把它们描述成"两个不同的值"的文档都是错的。

| 用途 | 用哪个字段 | 现有代码位置 | 为什么 |
|---|---|---|---|
| **判定**（音符过线、判定窗口、Miss 判定） | `JudgeMs` | `PlayView.gd:214,226`、`FlowArea.gd:1424` | **必须扣掉校准延迟**：玩家踩的是"听到的声音"，而原始回调钟超前听觉 `d`（§1.2 的算术论证）。今天的 `get_visual_position_ms()` 就是这个口径，**数值不变** |
| **显示 / 渲染**（音符下落、进度条、HUD） | `VisualMs` | `PlayView.gd:215`、NoteDisplayer | **与 `JudgeMs` 同值**（判定与画面必须同步，否则玩家会看到"音符在线上但判不到"）。分开命名是为了用途可读 + 未来可分化 |
| **状态恢复**（桥重建后把 sequencer 拉回原位） | `RawTimelineMs` | `MeltySynthPlayer.RecreateAudioOutputBridge()` | **sequencer 活在原始时间轴上**。用 `JudgeMs` 去 seek sequencer 会恒定偏早一个设备延迟，**且每恢复一次叠加一次**——这是真实发生过的 bug，见 §11 A8 |
| **人声同步** | `AudioMs` | `MeltySynthPlayer.Transport.cs:685`（内部） | 人声由同一条音频回调消费，必须与回调同一时钟。同属原始时间域，`RawTimelineMs` 亦可，但 `AudioMs` 语义更专一（不含墙钟外推） |
| **停滞检测** | `AudioMs` | `PlayView.gd:231` | 音频中断时停止增长的只有它（判定钟已是墙钟，不会停滞） |
| **曲终判定** | `JudgeMs` 对比 `get_backend_duration_ms()` | `PlayView.gd:238-240` | 与进度条口径一致 |
| **调试对表 / 预卷负值** | `RawTimelineMs`（或 `JudgeMs`） | `_start_pre_roll_now()` 的回读日志 | 二者在预卷期间均为负 |

**为什么必须把两套钟都暴露出来，而不能只留一个**：`RecreateAudioOutputBridge()` 的真实 bug 就是**跨时间域取值**（拿判定钟去 seek 活在原始时间轴上的 sequencer）。只暴露一个"位置"会让这类错误在类型层面无法被发现。

**不变量**：

- 预卷期间 `JudgeMs < 0`、`VisualMs < 0`、`RawTimelineMs < 0`（**永不钳制到 0**）；`AudioMs` 为 `_lastPositionMs` 的稳定值。
- 暂停期间所有字段返回"冻结位置"；`JudgeMs` 与 `VisualMs` 恒等。
- 曲终后 `JudgeMs == VisualMs == duration`（或 `_lastPositionMs`）。
- `PendingSeekMs` 非 NaN 时，`JudgeMs`/`VisualMs`/`RawTimelineMs` 立即返回 seek 目标（现在 `get_position_ms()` 与 `get_raw_position_ms()` 的第一个分支都这么做，两者一致）。

**统一分支顺序（修复 bug 3）**：所有字段从**同一份 `ResolveTimeline()` 私有函数**派生，分支顺序固定为：

```
1. pendingSeek 非 NaN        → 全部返回 pendingSeek
2. _currentOffsetMs < 0      → 全部返回 _currentOffsetMs（预卷；设备停着，不再判 seek-hold）
3. seek-hold 帧 && !seek落盘 → 全部返回 _lastPositionMs
4. !playing                  → 全部返回 _lastPositionMs
5. sequencer 未起            → 全部返回 _lastPositionMs
6. 正常                       → judged = 墙钟锚点 − 设备延迟 − audioDelay（负值原样透出）
                                visual = judged（同值）
                                raw    = sequencer.RenderedPosition（无扣减）
                                audio  = RenderedPosition（不锚墙钟）
```

现有 `get_position_ms()` 与 `get_raw_position_ms()` 的分支顺序差异（bug 3）在同一函数内自然消失。

> **数值等价性验收（必须有）**：阶段 0 落地的 `JudgeMs` 必须与今天的 `get_visual_position_ms()`（去掉 `Math.Max` 钳制后）**在同一时刻逐毫秒相等**；`RawTimelineMs` 必须与今天的 `get_raw_position_ms()` 逐毫秒相等。这是本节的唯一硬指标——若不等，说明分支顺序或扣减项抄错了。

> ### ⚠️ 阶段 0 实测更正：「不钳制负值」目前只做到一部分
>
> 阶段 0 用真机路径实测后发现，上面几处写的"任何 phase 都不钳制负值"**比现状严格**：
>
> | 位置来源 | 现状 | 说明 |
> |---|---|---|
> | 预卷分支（`_currentOffsetMs < 0`） | **已原样透出负值** ✓ | 早前修过，`get_position_ms()` / `get_raw_position_ms()` / `get_visual_position_ms()` 三者逐值相等（实测 `-400.0`） |
> | `get_visual_position_ms()` 的 `Math.Max(0.0, pos - _audioDelayMs)` | 仅剩 `0 <= pos < _audioDelayMs` 这一段被钳成 0 | 实测样本：`JudgeMs=-116.85` 而 `visual=0.00`。阶段 3 去掉这处钳制即达标 |
> | `get_position_ms()` **正常分支**内的 `Math.Max(0.0, wallRawMs - latencyMs)` | **仍在**，阶段 0 不允许改（属改行为） | 这是与 §5.1 第 6 行"永不钳制"的**最后一处差距**，留待阶段 2/3 处理 |
>
> 另有一条实现约束（阶段 0 踩到）：文档要求的"seek-hold 帧内所有字段返回 `_lastPositionMs`"与现状不符 ——
> `get_raw_position_ms()` 在 playing && sequencerStarted 时直接返回 `sequencer.RenderedPosition`，**不看 hold 帧**。
> 阶段 0 按代码取（故 `RawTimelineMs`/`AudioMs` 在 hold 窗口内可能是渲染钟≈0 而非 seek 目标）。
> 若要让两者一致，必须改既有 getter，属改行为，须在阶段 3 明确决策。

### 5.2 快照查询

```gdscript
# GDScript 侧推荐用法：每帧读一次，缓存整个对象
var _snap: PlaybackSnapshot

func _process(delta: float) -> void:
    _snap = PlaybackDisplay.instance.get_playback_snapshot()
    if _snap.Phase == PlaybackPhase.Playing:
        current_time = _snap.JudgeMs       # 判定
        hud.set_progress(_snap.VisualMs)   # 显示（当前与 JudgeMs 同值）

    # 停滞检测：不再需要"猜"，直接问设备状态
    if _snap.DeviceState == AudioDeviceState.StartFailed:
        pass  # 什么都不做 —— C# 自己会修
```

`Game/PlaybackDisplay.gd` 侧配套：

```gdscript
## phase 枚举镜像（与 C# PlaybackPhase 严格同序）
enum Phase { IDLE, PREPARING, PREROLLING, PLAYING, PAUSED, ENDED, STOPPED }
enum DeviceState { ABSENT, STOPPED, RUNNING, START_FAILED }
enum Interrupt { NONE, AUDIO_FOCUS_LOSS, DEVICE_LOST, APP_BACKGROUNDED, OUTPUT_ENDPOINT_CHANGED }

func get_playback_snapshot() -> PlaybackSnapshot:
    return MeltySynth.get_playback_snapshot() if MeltySynth != null else null
```

> `PlaybackDisplay` 从"135 个转发方法"减薄为"**1 个快照 + 11 个信号转发 + 意图转发**"。这是减薄而非重写的直接收益，也是本方案对 GDScript 侧最大的可读性改善。

---

## 6. 调用点迁移映射表

### 6.1 盘点修正（与任务描述的两处差异）

1. **外部消费者不止 5 个文件。** 已核实 `UI/Views/MusicPlayerView/MusicPlayerView.gd:300` 调 `mgr.resume()`、`:303` 调 `mgr.seek()`、`PlaylistPanel.gd:454` 调 `mgr.start_session_keys()`。播放器页**确实碰传输**。
2. **设备恢复是 3 处不是 4 处**（`PlaybackDisplay.gd:636` 那处已在工作区版本删除，见 §1.5）。

完整的外部写操作文件：`PlayView.gd`、`TrackView.gd`、`MusicPlayerView.gd` + `PlaylistPanel.gd` + `LibraryLayer.gd`、`Main.gd`、`PlaybackDisplay.gd`（门面自身）。读操作额外有 `PlayView/FlowArea.gd`、`TrackView/VocalTrackController.gd`。

### 6.2 `UI/Views/PlayView/PlayView.gd`

| 行 | 旧调用 | 新调用 | 为什么 |
|---|---|---|---|
| 168-169 | `playback_mgr.midi_finished.connect(_on_game_finished)` | **订阅跟随本页活跃状态**（进入 PLAY_VIEW 订阅、离开退订） | ⚠️ 初稿写"不变/语义已正确"是**漏判**：`midi_finished` 是后端全局信号，播放器页放完一首同样会发，而 `_on_game_finished` 内部会 `stop()` 掉后端播放 → 真机表现为"在播放器页一首放完直接不切歌了"。另在 `_on_game_finished` 内加"不归本页管就直接返回"的守卫 |
| 172-174 | `audio_focus_changed.connect(_on_audio_focus_changed)` | 删除，改连 `playback_interrupted` + `playback_resumed` + `playback_phase_changed` | **本方案核心改动**：焦点决策收归 C# |
| 214 | `current_time = playback_mgr.get_position_ms()` | `current_time = _snap.JudgeMs` | **保持扣延迟口径，仅改名**。`get_position_ms()` 转发到扣延迟口径是**正确的**（见 §1.2）；改动纯粹是"别名 → 有名字的字段" |
| 215 | `hud.set_progress(current_time)` | `hud.set_progress(_snap.JudgeMs)` | 与判定同源（判定/画面必须同步），数值不变 |
| 231 | `playback_mgr.get_raw_position_ms()` | `_snap.AudioMs` | 语义显式化，值不变 |
| 238 | `playback_mgr.get_backend_duration_ms()` | 不变（或 `_snap.DurationMs`） | — |
| 242-243 | `_on_game_finished()`（停滞在曲尾） | 不变 | — |
| 244-266 | `elif OS.get_name() == "Android"`：暂停 + `resume_audio_output_in_place_or_recreate()` + 检查 `is_playing` 决定是否自动继续 | **整段删除** | 这正是"GDScript 决定要不要恢复设备"。C# 的 `DeviceWatchdog` + `EvaluateAudioDeviceHealth` 接管；GDScript 只等 `playback_interrupted` / `playback_resumed` |
| 332 | `playback_mgr.stop()`（离开 PLAY_VIEW） | `playback_mgr.end_session()` | `stop()` 是机制词；`end_session()` 表达"这局结束" |
| 412, 417 | `set_manual_control_from_core` / `clear_manual_control_notes` | 不变 | 与状态转移无关 |
| 496 | `playback_mgr.pause()` | `playback_mgr.request_pause()` | 意图化（`reason` 默认 `None` = 用户主动） |
| 498 | `playback_mgr.resume()` | `if _snap.Phase == Phase.PREROLLING: playback_mgr.resume_from_pause()  else: playback_mgr.resume_from_pause()` | **二义性消除后两者其实同调**——但语义由 C# 的 phase 决定。GDScript 不再需要关心是哪种（见下方 ★） |
| 509-512 | `if not _session_started: _start_pre_roll_now(...)` | `if not _snap.HasEverStarted: playback_mgr.restart_preroll()` | `_session_started` 与"预卷是否已消费"是两码事（bug 8）。改用 C# 的权威标志 + 有守卫的 `restart_preroll()` |
| 530 | `playback_mgr.is_playing` | `_snap.Playing` | — |
| 545-567 | `_on_audio_focus_changed(state)` 整个方法 | **删除**，改为两个薄回调：`_on_playback_interrupted(reason, pos, phase)` → `_show_pause_menu()`；`_on_playback_resumed(reason, pos)` → 关菜单 + `_visual_time_needs_anchor = true` | 焦点语义归 C# |
| 586 | `_session_started = false` | `_session_started = false`（保留，供"准备阶段呼菜单"判断）/ 或直接用 `_snap.HasEverStarted` | 二选一，见 ★ |
| 612 | `playback_mgr.ensure_audio_focus()` | **删除** | 焦点申请在 C# 的会话装配里自动完成 |
| 619 | `playback_mgr.ensure_parsed(midi)` | 不变（显示侧解析缓存，与播放器无关） | — |
| 622 | `_load_and_convert_midi_notes(midi)` | 不变 | 显示侧 |
| 627 | `playback_mgr.start_session([midi],0,false,false)` | 合并进下一行 | 装配与会话语义合并为一次意图 |
| 641-642 | `_pre_roll_ms = 0.0; _start_pre_roll_now("prepare")` | `playback_mgr.start_performance(key, path, PlaybackStartMode.PreRollFromNoteFall)` | GDScript 不再计算/传递预卷毫秒（见 §9 争议 1） |
| 645 | `is_pause = true` | 不变（UI 态） | — |
| 655 | `playback_mgr.set_sync_threshold(...)` | 不变 | 人声同步阈值，与状态转移无关 |
| 685 | `warmup_manual_path()` | 不变 | — |
| 690 | `prepare_vocal_playback()` | 删除（已是 `pass` 空实现，`PlaybackDisplay.gd:995`） | 死代码 |
| 720-725 | `_start_pre_roll_now("game start"); ...; is_pause = false` | `playback_mgr.begin_playback(PlaybackStartMode.PreRollFromNoteFall)` 然后 `is_pause = false` | **一个意图取代"重算预卷 + 显式起播"两步** |
| 734 | `playback_mgr.load_midi(midi_data)` | 由 `start_performance`/`prepare_session` 内部完成 | 消除"载入"与"装配"两阶段 |
| 838 | `playback_mgr.seek(_pre_roll_ms)`（负值） | 删除；预卷只能经 `begin_playback`/`restart_preroll` | **负 seek 从公开 API 移除**（见 §9 争议 1） |
| 842 | 日志回读 `playback_mgr.position_ms` | `_snap.VisualMs` | 对表更准（`position_ms` 现在走的是"再扣一次校准延迟"的口径，`VisualMs` 与之等价） |
| 1029 | `playback_mgr.is_playing` | `_snap.Playing` | — |
| 1085 | `playback_mgr.stop()`（`_on_game_finished`） | `playback_mgr.end_session()` | 同上 |

**★ 关于 `is_pause` setter（498 行）的争议取舍**：消除二义性后，`resume_from_pause()` 在两个分支下**调用相同、行为由 phase 决定**，这看起来"没区分"。要不要保留 GDScript 侧的区分？

我的结论：**不保留**。理由是"区分意图"的目的不是"让调用点看起来不同"，而是"让调用点**不可能**表达错误的意图"。`resume_from_pause()` 在 `PreRolling` 下什么都不做，是因为**播放器自己知道**现在是预卷——这比"GDScript 记得自己刚才 seek 过负数"可靠得多。真正的意图区分体现在 `begin_playback`（起始）vs `resume_from_pause`（继续）vs `restart_preroll`（重开预卷）三者的**独立存在**上。

### 6.3 `UI/Views/TrackView/TrackView.gd`

| 行 | 旧调用 | 新调用 | 为什么 |
|---|---|---|---|
| 80 | `midi_playback_manager.get_backend_volume_db()` | 不变 | — |
| 92-93 | `soundfont_changed.connect` | 不变 | — |
| 96-104 | 连 `deferred_play_resumed`/`transport_changed`/`current_song_changed` | 不变，另加 `playback_phase_changed` | 音符显示跟随 phase 而非 `deferred_play_pending` 布尔 |
| 196-199 | `ensure_parsed` + `load_midi` | 合并为 `playback_mgr.start_preview(key, path)`（`await` 后仍需 `await process_frame`） | 装配一次完成 |
| 207 | `start_session([midi],0,false)` | 已被 `start_preview` 吸收 | `loop_file` 默认值反向的坑消失 |
| 255 | `midi_playback_manager.play()` | 已被 `start_preview` 吸收 | — |
| 260-261 | `if not deferred_play_pending: _set_note_displayers_process(true)` | `if _snap.Phase == Phase.PLAYING: ...`，并在 `playback_phase_changed` 里重判 | 不再用"推迟播放"这个间接布尔描述"在不在播" |
| 328 | `midi_playback_manager.seek(target_ms)` | `set_playback_position(target_ms)` | 纯时间轴操作，不含状态转移 |
| 332, 357, 359, 775, 787, 820-821 | `position` / `position_ms` | `_snap.JudgeMs`（扣延迟口径，与今天的 `get_visual_position_ms()` 等价） | 统一口径，数值不变 |
| 367 | `is_playing and not deferred_play_pending` | `_snap.Playing` | — |
| 411, 418, 433, 450 | 音量设置 | 不变 | — |
| 501, 514, 542, 707, 723 | `set_track_channel_mute*` | 不变 | — |
| 563 | `set_track_channel_volume` | 不变 | — |
| 598, 645-646 | 乐器查询/设置 | 不变 | — |
| 667-670 | `position_ms` → `load_midi` → `seek(pos)` → `play()` | `playback_mgr.resume_at(current_pos)` | **三行补丁收敛成一个意图动词**（这是本方案收益最直观的一处） |
| 774-775 | `is_playing` + `position_ms` | `_snap.Playing` + `_snap.JudgeMs` | — |
| 801 | `get_backend_duration_ms()` | 不变 | — |
| 816, 843 | `is_playing` | `_snap.Playing` | — |
| 993 | `unregister_view(self)` | 不变 | — |
| 996 | `midi_playback_manager.stop()` | `end_session()` | — |
| 1005 | `register_view(self)` | 不变 | — |
| 1011 | `start_session([current_midi_data],0,false)` | `start_preview(key, path)` | — |
| 1015-1019 | `is_soundfont_reload_pending()` 分支 + 等 `soundfont_reload_completed` | 保留，但 `_resume_after_settings_return()` 内部改用 `resume_at(resume_pos_ms)` | — |
| 1031-1035 | `resume_pos_ms = position_ms; resume(); seek(resume_pos_ms)` | `playback_mgr.resume_at(playback_mgr.get_playback_position().JudgeMs)` | **顺序 bug 的结构性消除**：C# 保证"先定位再起播" |
| 1038-1039 | `deferred_play_pending` 判断 | `_snap.Phase == Phase.PLAYING` | — |
| 1063, 1086, 1090 | `set_vocal_offset_ms` / `apply_vocal_offset` | 不变 | — |
| 1104, 1109, 1186, 1190, 1193 | SoundFont/预设查询 | 不变 | — |

### 6.4 `UI/Views/TrackView/VocalTrackController.gd`

| 行 | 旧调用 | 新调用 | 为什么 |
|---|---|---|---|
| 183-184 | `if is_playing: start_vocal_playback()` | `playback_mgr.set_vocal_intent(true)` | 动词 → 状态。**`is_playing` 守卫可以删掉**：C# 自己知道在不在播 |
| 198-202 | `if is_playing: start_vocal_playback()/stop_vocal_playback()` | `playback_mgr.set_vocal_intent(on)` | 同上，分支消失 |

### 6.5 `UI/Views/MusicPlayerView/MusicPlayerView.gd`

| 行 | 旧调用 | 新调用 | 为什么 |
|---|---|---|---|
| 127, 163 | `unregister_view` / `register_view` | 不变 | — |
| 288-289 | `MidiCore.GetCount()` / `ensure_user_playlist()` | 不变 | 播放列表已是"状态"模型的正面样板 |
| 292-293 | `begin_user_session()` / `align_index_to_current()` | 不变 | — |
| 294-295 | `mgr.is_playing` | `_snap.Playing` | — |
| 298-304 | `if mgr.is_paused: resume_pos_ms = mgr.position_ms; mgr.resume(); if ...: mgr.seek(resume_pos_ms)` | `if _snap.Paused: mgr.resume_at(_snap.JudgeMs)` | **又一处"先 resume 再 seek"补丁收敛**（播放器页是第三处） |
| 308 | `play_playlist_index(mgr.playlist_index)` | 不变 | — |
| 349, 354 | `handle_media_command("prev"/"next")` | 不变 | 媒体命令通道已是正确形态（GDScript 零决策） |
| 368 | `handle_media_command("play"/"pause")` | 不变 | — |
| 383 | `set_repeat_mode(want)` | 不变 | — |

`PlaylistPanel.gd:454` 的 `start_session_keys(keys, 0)` → 保留（列表编辑接口，语义清晰），但改名 `set_playlist_keys(keys, 0)` 以去掉"session"这个装配词。

### 6.6 `Main.gd`

| 行 | 旧调用 | 新调用 | 为什么 |
|---|---|---|---|
| 58-59 | `PlaybackDisplay.instance.refresh_audio_delay()` | 保留（GDScript 读配置 → 下发校准值，属"显示校准"不属"设备恢复"） | — |
| 62-64 | `MeltySynth.recover_audio_output()` | `MeltySynth.notify_app_resumed()` | **决策收归 C#**；GDScript 只报告"应用回前台了"这个事实 |
| 227-229 | `AudioManager.new()` | 建议一并删除（见 §11 A3） | `AudioManager` 现在只是 8 个 `PlaybackDisplay`/`MeltySynth` 转发（已核实 `Game/AudioManager.gd:20-60`，共 60 行），无外部消费者 |
| 294-295 | `load_soundfont_from_config()` / `preload_soundfont()` | 保留 | 音源加载与状态转移无关 |
| 378-382 | `push_global_playback_config()` / `refresh_audio_delay()` | 保留 | 配置下发 |
| 475-478, 499, 535 | `set_soundfont(...)` | 保留 | — |
| 558-560 | `set_max_polyphony()` + `reload_soundfont_preserving_position()` | 保留 | C# 已自行"保位置"，形态正确 |

### 6.7 `Game/PlaybackDisplay.gd`（门面减薄）

| 行 | 旧内容 | 新内容 |
|---|---|---|
| 25-40 | 12 个 `signal` 声明 | 保留 11 个 + 新增 5 个（`playback_phase_changed` / `playback_interrupted` / `playback_resumed` / `playback_device_state_changed` / `session_*`），`audio_focus_changed` 保留但标注"仅诊断" |
| 54-90 | `_ready()` 里 `_forward(...)` 11 次 | 增加到 16 次 |
| 607-624 | `is_playing` / `is_paused` / `position_ms` / `position` / `deferred_play_pending` 属性 | 保留为**只读兼容属性**（内部走快照），加 `@warning_ignore` + 注释标注废弃 |
| 628-630 | `play()` | 改为 `begin_playback(AtCurrentOffset)` 的薄包装（供播放器页"确保在播"语义） |
| 631-632 | `pause()` | `request_pause()` |
| 633-641 | `resume()` | **删除**，改由调用方按意图选 `resume_from_pause()` / `resume_at()` |
| 638-639 | `stop()` | 拆成 `end_session()`（停）+ `clear_media_notification()`（撤通知） |
| 642-644 | `stop()` 里 `abandon_audio_focus()` | 收进 C# `end_session()` |
| 658-699 | `request_audio_focus` / `ensure_audio_focus` / `abandon_audio_focus` / `_ensure_focus_listener` / `_on_java_audio_focus_changed` | **整块移到 C#**（`RegisterCommandSignalIfAny` 已经连了 Java 信号，已核实 `Transport.cs:96` 的注释） |
| 707-708 | `seek(pos)` | `set_playback_position(pos)` |
| 711-718 | 四个位置函数 | **全部删除**，改 `get_playback_position()` / `get_playback_snapshot()` |
| 719-720 | `get_backend_duration_ms()` | 保留 |
| 779-781 | `start_session` / `start_session_keys` | 保留（列表接口） |
| 971-991 | `start_vocal_playback` / `stop_vocal_playback` | 合并为 `set_vocal_intent(on)` |
| 995-996 | `prepare_vocal_playback()` | 删除 |
| 1020-1023 | `recover_audio_output()` / `recreate_audio_output()` | **删除**（C# private） |
| 1029-1035 | `load_midi()` | 保留显示侧部分（`set_current`），播放侧改为调意图方法 |

### 6.8 `UI/Views/PlayView/FlowArea.gd`

| 行 | 旧调用 | 新调用 | 为什么 |
|---|---|---|---|
| 129 | 注释"这个时间来自 `PlaybackDisplay.get_position_ms()`" | 更新为 `JudgeMs` | 注释与实现对齐 |
| 986, 1024, 1036, 1046, 1110, 1210, 1278, 1314, 1366 | `_get_realtime_position_ms()` | `_judge_ms`（由 PlayView 每帧推送，或 FlowArea 自己持快照） | 判定入口统一到 `JudgeMs`（**扣延迟口径，与现状数值一致**）。目的是消除命名歧义与四个出口，**不改变任何数值行为** |
| 1424-1427 | `_get_realtime_position_ms()` 实现（调 `get_realtime_position_ms()`） | 改为读缓存的快照字段，**不做每调用点重建对象** | 判定路径是热路径，不能每次 `new RefCounted` |

> **性能约束（重要）**：`FlowArea` 的判定入口每帧被调用多次（键盘/触摸/取消/长条释放）。快照对象**必须每帧只获取一次**并在 `PlayView._process` 里推给 `FlowArea`，不能让 `_get_realtime_position_ms()` 每调用一次就 `new PlaybackSnapshot()`。方案：`PlaybackDisplay` 内部**复用同一个快照对象**（`_snapshot_cache`，每帧/每次 `get_playback_snapshot()` 原地更新字段并返回同引用）。

---

## 7. 分层规则与回归防护

### 7.1 禁止从 GDScript 调用的方法

| C# 方法 | 处理 | 替代 |
|---|---|---|
| `play()` | → private | `begin_playback()` |
| `play_transport()` | → private | `begin_playback()` |
| `resume()` | → private | `resume_from_pause()` / `resume_at()` |
| `resume_with_vocal()` | → private | `resume_from_pause()` |
| `pause()` | → private | `request_pause()` |
| `pause_with_vocal()` | → private | `request_pause()` |
| `stop()` | → private | `end_session()` |
| `stop_transport()` | → private | `end_session()` |
| `seek()` / `seek_ms()` | 保留 public（兼容），但负值路径**加运行时告警** | `set_playback_position()` |
| `recover_audio_output()` | → private | `notify_app_resumed()` |
| `recreate_audio_output()` | → private | `notify_output_endpoint_changed()` |
| `resume_audio_output_in_place_or_recreate()` | → private | 无（C# 内部） |
| `set_vocal_playing()` | → private | `set_vocal_intent()` |
| `play_vocal_file()` / `stop_vocal_file()` / `seek_vocal()` | 保留（TrackView 人声导入需要路径级操作） | `set_vocal_intent()` |

### 7.2 三层防护（由强到弱）

**第 1 层：语言层隔离（最强）**
把机制动词设为 `private`。GDScript 调不到 = 编译期就不存在这条路径。**代价**：C# 内部调用点需改名（`_play` / `ResumeInternal`），且 `PlaybackDisplay.gd` 必须同步改完，不能分批。

**第 2 层：运行时调用来源检测（推荐先做）**
本项目已有的模式是"不引入 `[Obsolete]`"（已核实全仓 `.cs` 零处使用）。且 Godot 4 的 C# 源生成器对 `[Obsolete]` 的处理方式需要实测验证（**推断**：可能连 C# 侧都告警刷屏，反而淹没日志）。

因此建议自建一层轻量守卫，与项目现有 `push_warning` 习惯一致：

```csharp
/// <summary>机制动词守卫：GDScript 侧调用时打告警（附调用点提示），C# 内部调用不受影响。</summary>
private void WarnIfCalledFromScript([System.Runtime.CompilerServices.CallerMemberName] string caller = "")
{
    // GDScript→C# 的调用会经过 Godot 的 MethodBind 派发，栈顶不会是 C# 类型。
    // 用一次轻量栈探测；命中即 push_warning（含 caller 名），不阻断执行（先观测，后收紧）。
    if (!IsInvokedFromManagedCode())
    {
        GD.PushWarning($"[MeltySynthPlayer] 机制动词 '{caller}' 被 GDScript 调用；" +
                       $"请改用意图 API（见 Doc/architecture/player_intent_api.md §3.3）");
    }
}
```

在每个机制动词首行调用它。**先只告警不阻断**（第 2 阶段），跑一个版本后（第 4 阶段）把命中项全部修掉，再切到第 1 层（`private`）。

**第 3 层：静态检查（CI/本地脚本）**
一条 `grep` 脚本，与 §2.1 的 G1 判据一致：

```powershell
# 声明式回归门：GDScript 侧不得出现机制动词与设备恢复方法
$banned = 'MeltySynth\.(play_transport|pause_with_vocal|resume_with_vocal|stop_transport|recover_audio_output|recreate_audio_output|resume_audio_output_in_place_or_recreate)|\.seek\(-|PlaybackDisplay\.instance\.resume\('
Get-ChildItem -Recurse -Filter *.gd | Where-Object { $_.FullName -notmatch '\\(addons|\.godot|\.codebuddy)\\' } |
    Select-String -Pattern $banned
# 期望：零输出
```

### 7.3 分层规则表

| 层 | 允许 | 禁止 |
|---|---|---|
| C# `MeltySynthPlayer` | 一切 | — |
| C# `PlaybackInterfaces`/外部 C# | 意图 + 查询 | 直接改 `playing`/`_paused` 字段 |
| `PlaybackDisplay.gd` | 转发意图、转发信号、缓存快照 | 任何 `if <播放状态>: <做设备/传输决策>` |
| 视图（PlayView/TrackView/MusicPlayerView） | 发意图、订阅信号、读快照 | 调机制动词、调设备恢复、算预卷毫秒 |
| `FlowArea` | 读 `JudgeMs` | 直接访问 `MeltySynth` |

**`PlaybackDisplay.gd` 的判定式**：任何以 `is_playing` / `is_paused` / `deferred_play_pending` 为条件的**写操作**都必须先问一句"这个判断是不是本该由播放器做？"。本方案已把现存的 6 处（`PlaybackDisplay.gd:575-580`、`PlayView.gd:244-266`、`PlayView.gd:255`、`MusicPlayerView.gd:366`、`TrackView.gd:1015`、`VocalTrackController.gd:183`）逐一处理。

---

## 8. 分阶段实施计划

### 阶段 0：只加不改（1 个 PR，零行为变化）

**内容**
- 新增 `PlaybackPhase` / `SessionKind` / `PlaybackStartMode` / `AudioDeviceState` / `PlaybackInterruptReason` 枚举。
- 新增 `PlaybackSnapshot` / `PlaybackPosition` 类。
- 新增 `get_playback_snapshot()` / `get_playback_position()`；内部**复用现有逻辑**：`ResolveTimeline()` 用现有 `get_position_ms()` 的分支顺序，但把 `Math.Max(0.0, ...)` 换成"负值透出"。
- `PlaybackDisplay` 转发这两个查询。
- 旧 API 全部保持原样。

**验证**
- `PlayView` 临时在 `_process` 里打一条日志：`phase / JudgeMs / RawTimelineMs / AudioMs / DeviceState`。
- 跑一局完整游戏，人工核对：预卷期间 `JudgeMs < 0`、`RawTimelineMs < 0` 且 `Phase == PREROLLING`；跨零点时 `Phase` 恰好变化一次。
- 跑一次来电打断，核对 `DeviceState` 在打断期间变 `StartFailed`。
- **不改任何判定/显示取值**，所以判定手感应与改动前**完全一致**——若不一致，说明 `ResolveTimeline()` 的分支顺序抄错了。

### 阶段 1：设备恢复决策收归 C#（独立 PR，风险最高）

**内容**
- `EvaluateAudioDeviceHealth(trigger)` + 四个触发源接入。
- `notify_audio_focus_changed` / `notify_app_resumed` / `notify_output_endpoint_changed` 上线。
- 发 `playback_interrupted` / `playback_resumed` / `playback_device_state_changed`。
- 改 `Main.gd:62-64`、`PlayView.gd:244-266`、`PlayView.gd:545-567`。
- 机制动词加第 2 层告警守卫。

**验证**
- `grep`：`.gd` 中零处 `recover_audio_output` / `recreate_audio_output` / `resume_audio_output_in_place_or_recreate`。
- 手动场景（**逐条必测**）：
  1. 打歌中全屏来电 → 挂断 → 声音恢复且**位置连续**（不是从头）。
  2. 打歌中切后台 → 回前台 → 同一首歌位置连续。
  3. **预卷期间**来电（在准备动画那 3 秒内）→ 恢复后**不能**被判曲终。
  4. 打歌中拔/插蓝牙（Windows）→ 端点跟随、位置连续。
  5. 打歌中暂停 → 继续 → 位置连续（**不能**回曲首）。
  6. 准备阶段呼出暂停菜单 → 继续 → 预卷应从眼前重新跑一遍（`restart_preroll()` 路径）。
- 回归门：跑 3 次"打歌一半来电"，日志里应**只有一条** "device recovered" 记录（`EvaluateAudioDeviceHealth` 未被多路重复触发）。

### 阶段 2：意图动词 + 会话装配（大改动，纯重构）

**内容**
- `start_performance` / `start_preview` / `start_player_session` / `prepare_session`。
- `begin_playback` / `request_pause` / `resume_from_pause` / `resume_at` / `set_playback_position` / `restart_preroll` / `end_session`。
- `set_vocal_intent` / `set_vocal_offset_ms`。
- 迁移 §6 全部调用点。
- **负 seek 从公开路径移除**（`seek_ms` 保留但负值加告警）。

**验证**
- 三条路径的黄金路径手工回归：打歌 / 音轨试听 / 播放器页续播。
- 重点验证 §6.3 的 `resume_at` 与 §6.5 的 `resume_at` —— 这两处原本是"先 resume 再 seek"的补丁，改后应仍从暂停位置继续（**不能**从 0）。
- TrackView `_update_preview()`（原 667-670 三行）改后：切乐器后预览应从当前位置继续，不从头。
- 静态门：§7.2 第 3 层脚本零输出。

### 阶段 3：位置读取统一（**纯改名与归属明确化，零数值变化**）

**内容**
- 删 `PlaybackDisplay` 的四个位置函数。
- `PlayView` / `FlowArea` 迁到快照字段（`JudgeMs` / `VisualMs` / `AudioMs` / `RawTimelineMs`）。
- `FlowArea` 的判定入口改读 `JudgeMs`。

**验证**

> **本阶段不改变任何数值行为。** `JudgeMs` 就是今天的 `get_visual_position_ms()`（`get_position_ms()` / `get_realtime_position_ms()` 的同一实现），`AudioMs` 就是今天的 `get_raw_position_ms()`。判定扣校准延迟是**正确设计**（§1.2），本阶段**不动它**。

验收判据（**两种校准情况下，改动前后判定结果与手感都必须完全一致**）：

1. **关闭校准**（`audio_playback_delay = 0`，普通输出）：改动前后同一谱面的判定结果（Perfect/Great/Good/Bad/Miss 计数）、准确率、最大连击**逐项一致**。
2. **开启蓝牙预设**（`audio_playback_delay_bt = 200`）：同样**逐项一致**。
   - ⚠️ 这里**不能**验收成"改动后更准"——那是 §1.2 误报会导向的错误实施（去掉了本该扣的延迟）。判定在两种情况下都应保持原样。
3. **延迟校准流程（`DelayAdjust`）复验**：校准后的值必须**同时**影响判定与画面（这是该功能存在的意义）；不得出现"只影响画面、判定无效"。
4. **边界稳定性**：曲终前 100ms 内、暂停期间、seek 刚下单的 10 个 hold 帧内，`JudgeMs` / `RawTimelineMs` / `AudioMs` 都不出现跳变；预卷期间 `JudgeMs < 0`、`RawTimelineMs < 0`（**不被钳制**）。
5. **数值等价性硬指标**：阶段 0 已落地的 `JudgeMs` 与阶段 3 迁移后的取值，在同一时刻**逐毫秒相等**（这是"零数值变化"的直接证明）。

### 阶段 4：收紧与清理

**内容**
- 机制动词从"告警"切到 `private`（或 `internal`）。
- 删除 `PlaybackDisplay` 中已无消费者的兼容属性/方法。
- 删 `Game/AudioManager.gd` + `Main.gd:227-229`（**独立确认无运行时消费者**）。
- 更新 `Doc/architecture/architecture_overview.md` 与 `Doc/features/midi_playback_implementation.md`（见 §11）。

**验证**：全量手工回归（打歌/试听/播放器页/设置页进出/存储迁移/截图无异常）+ CI 静态门。

---

## 9. 风险与回归面

| # | 风险 | 影响面 | 缓解 |
|---|---|---|---|
| R1 | **阶段 1 改变打断恢复时序**，可能出现"恢复成功但 UI 还停在暂停菜单"或反之 | 高（打歌中断是玩家最敏感的路径） | 信号顺序保证（§4.3）+ 阶段 0 的快照日志作为对表基准；保留旧路径一个版本作为 flag 回退（`Playback/legacy_device_recovery`） |
| R2 | **阶段 3 改变判定取值** | 高（判定是核心体验） | 单独阶段 + 关闭校准时做"零差异"验收（§8 阶段 3）；不停留在"看起来更好"的主观判断 |
| R3 | `PlaybackSnapshot` 每帧 `new` 造成 GC 压力 | 中（判定热路径） | `PlaybackDisplay` 复用单例对象原地更新（§6.8 性能约束）；GDScript 侧只在 `_process` 读一次 |
| R4 | 负 seek 移除后，某条未审计的路径失效 | 中 | 阶段 2 保留 `seek_ms` 的负值分支 + 告警；阶段 4 才收紧 |
| R5 | C# 侧 `_paused` / `playing` 字段的外部写入者被遗漏 | 中 | 全仓 `grep` `\.playing\s*=` / `_paused\s*=`（**已核实**：目前仅 `MeltySynthPlayer*.cs` 内部与 `Transport.cs` 写） |
| R6 | `evaluate_device_health` 被多路重复触发 → 反复重建 | 中 | 幂等 + 重建后的冷却窗口（建议 ≥1s）；`playback_device_state_changed(rebuilt=true)` 打日志，用 §8 阶段 1 的"只一条记录"判据验收 |
| R7 | `[GlobalClass]` + `[Export]` 的 `RefCounted` 在 Godot 4.7 Mono 上的字段可读性 | 中（**未实测**，推断可行） | 阶段 0 第一件事就是实测：GDScript 能否读到 `snap.JudgeMs`。若不可行，退回 `Godot.Collections.Dictionary` + GDScript 侧薄包装（代价：失去字段补全，但语义不变） |
| R8 | 播放器页的 `_ensure_playing` 分支逻辑比预想复杂 | 低 | 已核实 288-308 行；改动仅限 298-304 一处 |
| R9 | 文档与代码继续漂移（本方案本身也会过时） | 低 | 本文档标注"设计稿/未实施"，实施后由实施者改状态并修 §11 的两份文档 |

---

## 10. 我不认同你的倾向的地方

### 争议 1：**负值 seek 应当从公开 API 中彻底消失**（我比你更激进）

你的倾向里保留了"准备预卷"作为意图动词，但也保留了 `seek` 作为位置操作。我建议更进一步：

- **预卷不是"seek 到负数"**。它是 `PlaybackStartMode.PreRollFromNoteFall` 这一个起始模式，由 C# 用 `[Generator] note_fall_time` 自行计算时长。
- **`PlayView` 不该知道 `-1700` 这个数是怎么来的**。现在 `PlayView.gd:836-837` 从配置读 `note_fall_time` 再算 `-(1000 + t*1000)`——**这是播放器的时序知识泄漏到视图层**，而且和 `NoteFallCalculator`（显示侧的下落时间）是**两份独立的读数**。一旦两者不一致（比如某处改了 note_fall_time 的读取键），预卷时长与下落时间就会错配，表现为"第一批音符不在屏幕外生成"。
- **`seek_ms()` 的负值分支应只保留给内部的位置恢复**（`RestoreSequencerPositionAfterBridgeRecreate`），并加运行时告警。

理由：bug 1/2/3 全都发生在"负值 seek"这条路径上。它承担了不该承担的语义（状态转移），而状态转移的合法入口只有一个。**保留它是保留 bug 的温床。**

### 争议 2：**"位置读取只有一条路"不应理解为"一个数"，也不应理解为"判定与显示是两个不同的数"**

你写的是"位置读取必须只有一条路，返回值语义一致"。我同意"一条路"，但正确的结构化方式是**按用途命名 + 保留两套钟**：

- `JudgeMs` / `VisualMs`：判定 · 感知轴（**当前恒等**，分开命名只为用途可读与未来可分化）。
- `RawTimelineMs`：原始时间轴（sequencer 的时间域）。
- `AudioMs`：音频回调渲染钟。

**必须保留两个不同的钟，理由是有一个真实 bug 就栽在跨时间域取值上**（见 §11 A8）：`RecreateAudioOutputBridge()` 曾用判定轴去 seek 活在原始时间轴上的 sequencer，导致恢复后位置恒定偏早一个设备延迟、且每恢复一次叠加一次。**只暴露一个"位置"会让这类错误在类型层面无法被发现。**

正确解读是：**一个入口方法，返回一个结构化结果，每个字段有唯一用途**（§5.1 的用途表）。"语义一致"指的是"所有字段在所有 phase 下都合法、都不被钳制、分支顺序相同"，而不是"数值相同"——也**不是**"字段越多越好"。

**我初稿的误报（已订正，留档于此）**：我曾断言"`PlayView` 的判定钟 `get_position_ms()` 转发到 `get_visual_position_ms()`，因此判定被扣掉了视觉校准延迟，这是个未记录的 bug"。**这是错的**——扣校准延迟是判定**必须**做的（§1.2 的算术论证），`get_visual_position_ms()` 就是判定钟。我犯这个错的根因是**按函数名推断语义**：名字里的 "visual" 让我以为它是"仅用于画面"的量。这恰好印证了 §1.2 的命名陷阱——**如果连专门审计它的人都会被名字骗，调用点的作者更不可能幸免。**

### 争议 3：**不建议引入显式状态机"类"（如 `IState`/`StateBase` 模式）**

你提到"比如引入显式状态机"作为可能更好的切法。我建议**不要**：

- 现有代码已经有**三个**状态机，其中两个（设备、sequencer）由原生/库对象承载，无法纳入一个统一的状态类。
- 定义 `IPlaybackState` 式抽象需要迁移 ~30 个字段的读写，收益是"结构更漂亮"，风险是"**每个字段的时序假设都要重新验证一遍**"——而 §1.3 的八条 bug 全都是时序假设出错。
- 更划算的做法是**把状态显式化而不是把状态机对象化**：一个 `PlaybackPhase` 枚举 + 一个"phase 只在何处转移"的约束（§3.4 的契约表）+ 一个快照。这样每个 transfer 都是可 grep 的（`SetPhase(` 的所有调用点），而字段仍在原处。

**结论：用枚举 + 契约 + 快照做"轻量状态显式化"，不引入状态类继承体系。**

### 争议 4：**"让 GDScript 只订阅不问"——我同意方向，但要保留一个"问"**

你说"让 GDScript 只订阅不问"。完全"只订阅"会让 `FlowArea` 无从拿到判定时间——判定必须**同步**读当前值，不能等信号。

我的表述是：**GDScript 只订阅"发生了什么"，只询问"现在是什么"。** 前者是信号，后者是快照。两者都不含决策。这个区分很重要，因为"只订阅不问"字面上会导向"每帧等一个位置信号"，那是更糟的设计。

### 争议 5：**`resume()` 的二义性不该靠"拆成两个动词"消解，而该靠"phase 判定"消解**

这是本次最有争议的取舍，我在 §6.2 ★ 里给了倾向，这里说清反方观点：

**反方**（可能更符合你"区分不同意图"的本意）：把 `resume()` 拆成 `resume_pre_roll()` 和 `resume_from_pause()` 两个**显式不同**的动词，让调用点必须自己声明意图。好处：意图在调用点可见、可疑调用一眼能看出。

**我的结论是反对拆成两个"继续"动词**，因为：
1. `PlayView.gd:498` 的调用点**在编译期无法知道**自己该用哪个——它取决于 `_game_started`，而那个变量本身已经错过两次（bug 8）。拆成两个动词只会把选择权推回给**最没有能力做这个选择的调用点**。
2. 真正需要"声明意图"的地方是**起始**（`begin_playback` / `restart_preroll`），那里意图是明确的。而"继续"永远只有一个意图：**从当前状态继续**。它为什么会有两种行为，是因为**播放器处于两个不同状态**——这正是 phase 要解决的问题，不是动词要解决的问题。
3. 拆动词的代价是：调用点必须维护"我现在是哪种继续"这个第二份状态，而它**必然**会与 C# 的 phase 漂移。bug 6 就是这么来的。

**换句话说：`resume()` 的病不是"名字太少"，而是"GDScript 被要求提供它无法掌握的信息"。加名字治不了这个病，给状态才能。**

---

## 11. 附带发现（超出本次范围，建议一并处理）

| # | 发现 | 证据 | 建议 |
|---|---|---|---|
| A1 | **`Doc/features/midi_playback_implementation.md` 描述的是重构前架构**，全文仍以 `MidiPlaybackManager` / `MidiPlaybackInterfaces` / `AudioManager` 为主要组件，并称 `CSharp/MeltySynthPlayerWrapper.gd` 存在 | 已核实该文档 1-60 行；`MidiPlaybackInterfaces.gd` / `MeltySynthPlayerWrapper.gd` 已不存在 | **该文档需要同步修订或标记废弃**。以代码为准（本方案 §6 全部结论以代码为依据） |
| A2 | **`Doc/architecture/architecture_overview.md:38-42` 列出的 Game 层管理器已过时**（`AudioManager` / `MidiPlaybackManager`） | 已核实 `MeltySynthPlayer.Transport.cs` / `PlaybackDisplay.gd` 已是唯一播放路径 | 同上 |
| A3 | **`Game/AudioManager.gd` 仍然存在**（60 行，8 个纯转发方法），与 CLAUDE.md"`AudioManager` 已删"矛盾 | 已核实 `Main.gd:227-229` 创建它、`Game/AudioManager.gd:20-60` 全部是 `PlaybackDisplay`/`MeltySynth` 转发、**无外部消费者调用 `audio_manager.*`** | 随阶段 4 一并删除；同步修正 CLAUDE.md |
| A4 | **`Doc/README.md` 缺本文档的索引条目** | 已核实 `Doc/` 无 `design/` 目录；本方案按组织归属落在 `Doc/architecture/` | 需在 `Doc/README.md` 的"架构文档"清单补一行（本文档属设计方案，实施完成后应改状态标注） |
| A5 | **`PlaybackDisplay.gd` 有 135 个方法、1067 行，绝大多数是单行转发** | 已核实（`^func` + `^var ` 共 162 处） | 本方案顺带把它减薄到约 60 处；更进一步可考虑用 `@forward` 风格的批量转发注释约定，但**不建议**在本次做（会与迁移冲突） |
| A6 | **`PlaybackDisplay.gd:129` 等注释仍指向旧函数名** | 已核实 | 随阶段 3 一并更新 |
| A7 | **`_codebuddy/worktrees/` 内存在旧版代码副本**，静态 `grep` 会命中噪声 | 已核实（`.codebuddy/worktrees/bg-c3b2ab1a/`） | 静态检查脚本须排除 `.codebuddy`（§7.2 已含） |
| A8 | **跨时间域取值 bug：`RecreateAudioOutputBridge()` 用判定轴去 seek 活在原始时间轴上的 sequencer** | 已核实：工作区版本 `MeltySynthPlayer.cs:447` 现为 `get_raw_position_ms()`，其上方注释（:442-446）明说"拿判定钟去 seek sequencer = 位置恒定偏早一个设备延迟，每恢复一次就叠加一次"。**已在工作区修复。** | **这是 `JudgeMs` / `VisualMs`（判定轴）与 `RawTimelineMs`（原始轴）必须分开暴露的直接证据**（§5.1 用途表"状态恢复"行）。任何"只留一个位置接口"的方案都会让这类错误重新变得不可见。 |
| A9 | **`MeltySynthPlayer.cs:439-440` 的注释与紧随其后的代码矛盾** | 已核实：:439-440 写"用判定钟口径（`get_position_ms`）…正是'打断前听到的位置'"，而 :442-447 改用了 `get_raw_position_ms()` 并说明前者是错的。**旧的错误结论没被删掉**，两句并存 | 删除 :439-440（否则下一位读者会照着错的那句改回去）。这正是 §1.2 "命名陷阱"在代码注释层面的复现 |

---

## 12. 已核实 / 推断 声明汇总

**已核实（读过代码并对应行号）**
- 三个状态机及其不可观测性（`MeltySynthPlayer.cs:72,107-112,2852`；`MeltySynthPlayer.MiniaudioBridge.cs:858-873`；`PlaybackDisplay.gd:607-610`）
- 四个位置函数中三个转发到同一 C# 函数（`PlaybackDisplay.gd:711-718`）
- `resume()` 的 3 个调用点与 3 套前置契约（`PlayView.gd:498`、`TrackView.gd:1032`、`MusicPlayerView.gd:300`）
- 设备恢复决策的当前位置（`Main.gd:62-64`、`PlayView.gd:254,556`、`PlaybackDisplay.gd:575-580`）与 `PlaybackDisplay.gd:636` 已被工作区改动移除
- 已存在于 C# 的"决策在播放器内"正例：后台设备看门狗（`BackgroundAdvance.cs:210-227`）
- 现有信号清单（`Transport.cs:84-96`）
- 会话两槽模型与 `loop_file` 默认值反向（`MeltySynthPlayer.Playlist.cs:15-26,79-94`）
- `prepare_vocal_playback()` 是空实现（`PlaybackDisplay.gd:995-996`）
- `AudioManager.gd` 仍存在且无外部消费者（`Main.gd:227-229`；`Game/AudioManager.gd:20-60`，60 行 / 8 个纯转发方法）
- 全仓 C# 零处 `[Obsolete]`
- `end-of-sequence` 闩锁机制（`MiniaudioBridge.cs:426-466`）

**已核实且结论更正**
- **§1.2 的位置口径（初稿误报，已订正）**：初稿断言"判定路径叠加了校准延迟"，**结论是错的**。已核实的事实为：`PlaybackDisplay.gd:711-718` 的三个位置函数转发到同一 C# 函数；`Transport.cs:1233-1241` 的 `get_visual_position_ms()` = `get_position_ms() - _audioDelayMs`；`MeltySynthPlayer.cs:2015` 的 `get_position_ms()` 已扣 `latencyMs`；`get_raw_position_ms()`（:2119）无任何扣减。
  **更正理由**：`get_visual_position_ms()` **就是判定钟**（`CLAUDE.md:344`"只有 `get_visual_position_ms()`（判定/可视化）扣减该延迟"），判定**必须**扣该延迟（§1.2 的算术论证 + `DelayAdjust` 功能的存在意义）。误报根因是**按函数名推断语义**——这段经历本身已作为"命名陷阱"留档在 §1.2。
  **推论**：本方案对位置的处理是**纯改名与归属明确化，零数值变化**（§2.2、§8 阶段 3）。

**推断（由代码行为归纳，未逐行验证）**
- §7.2 第 2 层的"调用栈探测能区分 GDScript/C# 调用来源"：**未实测**，需在阶段 1 验证；若不可行，直接跳到第 1 层（`private`）。
- §9 R7 的 `[GlobalClass]` + `[Export]` RefCounted 在 Godot 4.7 Mono 上的 GDScript 可读性：**未实测**。
- §1.7 的粒子内存实测数据（56 MiB / 130.4 MiB / 3.6 bpp）来自设备资源监视器读出的数值，**未在本地复现**。
- 各调用点的行号取自工作区当前内容（含未提交改动）；提交前请以 diff 后的实际行号为准。

---

## 关联文档

- `architecture_overview.md`（**§38-42 的 Game 层清单已过时，见 §11 A2**）
- `../features/midi_playback_implementation.md`（**描述重构前架构，见 §11 A1**）
- `initialization_sequence.md`（autoload `MeltySynth` / `PlaybackDisplay` 的初始化位置）
- `../quickref/developer_cheatsheet.md`
