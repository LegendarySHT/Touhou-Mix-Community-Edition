# 架构总览

> 适用版本：THMIX Community Edition（Godot 4.7.1 Mono）

## 分层结构

项目采用三层结构：

1. `Core/`：数据模型、索引、排序、状态与事件
2. `Game/`：MIDI 播放、打歌流程、按键序列、计分
3. `UI/`：视图与组件（通过 `EventBus` / `UIStateManager` 协作）

跨层通信的原则：
- 全局管理器统一通过 autoload 别名或 `ClassName.instance` 访问
- 跨模块通知优先用 `EventBus` 信号
- UI 切换统一经 `UiStatMGR.change_state()`

## 核心管理器

### Core 层（autoload）
- `DataManager`（别名 `DataMGR`）：加载并组织 `albums/songs/midis`
- `EventBus`（别名 `EvtBus`）：全局事件总线（14 个信号）
- `SortingEngine`（别名 `SortEngine`）：排序、筛选、搜索
- `UIStateManager`（别名 `UiStatMGR`）：UI 状态机与历史栈
- `SkinManager`（别名 `SkinMGR`）：皮肤资源管理

### UI 层（autoload）
- `ThemeManager`（别名 `ThemeMGR`）：主题色、背景、字号统一管理
- `AnimationManager`（别名 `AniMGR`）：统一 Tween 管理

### Utilities 层（autoload）
- `GameLogger`（别名 `GLogger`）：统一日志输出

### Core 层（Main.gd 手动创建）
- `FileSystemManager`：初始化 `user://files` 目录并扫描资源（含 `static var instance`）

### Game 层（Main.gd 手动创建）
- `ScoreCalculator`：判定、准确率、评级
- `KeySequenceManager`：按键序列分类与可视化输入数据
- `NoteFallCalculator`：音符下落计算

> **播放侧已不在本层**：`MidiPlaybackManager` / `AudioManager` / `MidiPlaybackInterfaces` /
> `MeltySynthPlayerWrapper` 均已删除。播放真值在 **autoload `MeltySynth`（C# 播放器）**，
> GDScript 侧经 **autoload `PlaybackDisplay`** 访问；播放列表权威在 `MidiCore`（C#）。
> 播放器的分层设计见 `Doc/architecture/player_intent_api.md`。

### Utilities 层（懒加载）
- `ConfigManager`：唯一懒加载单例（`ConfigManager.instance`），统一 INI 读取/写入与通知
- `PathHelper`：纯静态工具类，跨平台路径（桌面/Android）

## 数据主链路

```text
FileSystemManager.initialize_directory_structure()
  -> 扫描 Charts/Soundfont/Skins/BackgroundImage
  -> 更新 charts_index 与资源索引

DataManager.load_all_midis_async()
  -> 读取 charts_index
  -> 构建 AlbumData / SongData / MidiData
  -> 发出 data_loaded

Main._on_data_loaded()
  -> EventBus.data_loaded_complete
  -> 各 View 开始绑定和渲染
```

## UI 状态枚举（`UIStateManager`）

```gdscript
enum UIState {
    NONE = -1,
    ALBUM_VIEW = 0,
    SONG_VIEW = 1,
    MIDI_VIEW = 2,
    TRACK_VIEW = 21,
    SORTED_VIEW = 3,
    STORE_VIEW = 4,
    SETTINGS_VIEW = 5,
    PLAY_VIEW = 6,
    SCORE_VIEW = 61,
}
```

## 关键约束

- 不要在业务代码中使用 `get_node("/root/..." )` 访问管理器，统一走 autoload 别名或 `ClassName.instance`。
- `ConfigManager` 是唯一懒加载单例特例，其他 Manager 按初始化流程就位。
- `DataManager.load_all_midis_async()` 前必须保证 `FileSystemManager` 资源扫描已完成或超时兜底（`Main._load_midi_data()` 内含等待逻辑）。
- 与播放时间有关的模块要明确单位（tick / ms / 秒），避免混用。
- 项目当前**不存在** `GameplayManager`，游戏流程由 `PlayView.gd`、`ScoreCalculator`、`KeySequenceManager` 协同承担（播放侧已移至 autoload `MeltySynth` / `PlaybackDisplay`）；文档中历史性地提及 `GameplayManager` 的内容已废弃。

## 关联文档

- `singleton_pattern_guide.md`
- `initialization_sequence.md`
- `../features/midi_playback_implementation.md`
