# MIDI 播放实现说明

> ## ⚠️ 本文档描述的是**重构前**架构，多数内容已失效
>
> 下列组件**已被删除**，正文中仍以它们为主语，请勿据此改代码：
> `Game/MidiPlaybackManager.gd`、`Game/MidiPlaybackInterfaces.gd`、
> `CSharp/MeltySynthPlayerWrapper.gd`、`Game/AudioManager.gd`。
>
> **当前权威文档**：
> - 播放器分层设计与播放相关改动 → `Doc/architecture/player_intent_api.md`
> - 现状总览（autoload / 手动单例 / 音频架构）→ `CLAUDE.md`
>
> 现状速览：播放真值是 **autoload `MeltySynth`（C# 播放器，分部 Transport / Playlist /
> BackgroundAdvance / MiniaudioBridge）**；GDScript 侧经 **autoload `PlaybackDisplay`**
> 访问；播放列表权威在 `MidiCore`（C#）；音频输出走 miniaudio 原生库，不经 Godot 音频总线。
>
> 本文档保留仅供参考（历史上的后端切换与时间同步思路）。若要恢复为"活文档"，
> 应整体改写而不是局部修补。

## 目标

统一描述当前 MIDI 播放链路：后端初始化、音源加载和时间同步。

## 主要组件

- `Game/MidiPlaybackManager.gd`：播放入口、SoundFont 扫描/切换
- `Game/MidiPlaybackInterfaces.gd`：播放后端接口层
- `CSharp/MeltySynthPlayer.cs` + `CSharp/MeltySynthPlayerWrapper.gd`：MeltySynth 后端（唯一后端）
- `CSharp/MidiParserNative.cs`：C# 原生 SMF 解析器（替代原 `addons/midi/SMF.gd`），供 `Utilities/MidiParser.gd` 解析 MIDI 文件使用，同时一次性提取 (track, channel) → {bank, program} 乐器映射

## 后端机制

当前仅使用 MeltySynth（C#）后端，由 `MidiPlaybackManager._initialize_backend()` 在启动时初始化。
历史上曾存在的 `addons`（GDScript MidiPlayer）后端已下线，不再支持运行时切换。

## 人声统一输出链路（2026-08-15）

人声不再走 Godot `AudioStreamPlayer`，而是与 MIDI 共用 miniaudio 同一条设备回调：

- C 桥（`addons/miniaudio/native/miniaudio_bridge.c`）：内置 `ma_decoder` 解码 WAV/MP3/OGG/FLAC（OGG/Vorbis 通过捆绑的 `thirdparty/stb_vorbis/stb_vorbis.c` 启用），生产者线程按 2048 帧块填充约 1 秒环形缓冲，`ma_device_callback` 在 C# 数据回调后把人声混入 `pOutput`。
- C#（`MiniaudioNative.cs` / `MeltySynthPlayer.MiniaudioBridge.cs`）：暴露 `load/play/pause/stop/seek/set_volume/get_position/get_length/is_playing/is_finished` 等 vocal API；自然结束时发 `vocal_finished` 信号。
- GDScript（`AudioManager.gd` + `MidiPlaybackManager.gd`）：`AudioManager` 成为纯门面层，转发到 `MidiPlaybackManager` 的 `play_vocal_file / stop_vocal_file / unload_vocal / seek_vocal / set_vocal_playing` 等；`vocal_offset_ms` 语义不变。
- 时间语义：人声位置按设备时钟计时 = 已混音帧 + 欠载期间设备推进但未混音的帧，与 MIDI 使用同一时钟；欠载时把欠账帧从环形缓冲丢弃以追平内容（不等轮询同步），`skip_frames` 用于 MIDI post-seek 静音期间同步丢弃人声帧。
- 已知限制：部分格式（如 OGG）可能无法报告总长度，`get_vocal_length_ms()` 返回 `-1`，此时 GDScript 跳过 seek 上限钳制。

## 设置变更联动

`MidiPlaybackManager` 监听 `EventBus.settings_changed`，响应以下设置变更：

- `soundfont_select`：重新加载音源
- `use_system_stopwatch`：切换系统时钟模式
- `max_polyphony`：重新设置复音数并重载 SoundFont（必要时恢复播放）

## SoundFont 处理

- 启动时扫描可用音源（用户目录 + 内置目录）
- 提供 `set_soundfont(name)` 统一切换接口
- 配置缺失时回退默认音源

## 时间单位约定（重点）

不同模块时间单位不同，联调时必须统一：

- `MidiPlaybackManager`：tick / 毫秒（推荐使用 `get_position_ms()`）
- `PlayView.gd` / `NoteFallCalculator`：秒（游戏内主时钟）
- `KeySequenceManager`：毫秒（通常由 `game_time * 1000` 转换）

> 注：项目当前不存在 `GameplayManager`，游戏时间由 `PlayView` 与 `NoteFallCalculator` 维护。

## 排障建议

1. 无声音：检查 SoundFont 文件是否存在、路径是否正确。
2. 时序错位：确认 tick/ms/sec 是否混用。

## 关联文档

- `soundfont_selection_feature.md`
