# 核心系统初始化顺序

> 适用版本：THMIX Community Edition（Godot 4.7 Mono）

## 入口

初始化由 `Main._initialize_core_systems()` 统一执行。启动顺序由
`Services/ServiceHub` 依赖图（拓扑排序）推导，不再手写 `new()+add_child()` 固定清单；
下面前置项是隐含的依赖关系，而非硬编码顺序。ServiceHub 为 `project.godot` 第一位 autoload。

## 依赖图

```text
ServiceHub.adopt(autoload 锚点: EvtBus/GLogger/ChartDB/MeltySynth/PlaybackDisplay/
                 UiStatMGR/AniMGR/DataMGR/ThemeMGR/FocusMGR/CoverLoader)
                 # 已在引擎启动时进树，只登记（SkinMGR/ParticleMGR/CharaMGR/
                 # SortEngine/TextScrollMGR/AudioBtDetector 已从 autoload 迁出）

core 阶段（start_phase("core")）：
  StorageManager（recover_and_resolve 存储根）→ ConfigManager（懒单例，load+validate）
  → 内容管理器（SkinMGR/ParticleMGR/CharaMGR/SortEngine/TextScrollMGR/AudioBtDetector）
   → FileSystemManager → ImportManager
  ImportManager.on_started 触发 initialize_directory_structure()（建目录→复制默认资源
    → 导入外部文件 → 扫描资源），因此扫描前必已开 ChartDB、已有 SkinMGR/ParticleMGR/CharaMGR。
  另：脚本开头先建 VirtualKeyboardGuard 并 open_midi_inputs()（Android 跳过）。

入场动画 await（AnimationManager.DURATION_SLOW）

pre 阶段：FavoriteManager / ScoreCalculator（仅依赖 DataMGR）

post 阶段：KeySequenceManager → NetManager(set_online_mode) → AuthManager
           → ScoreManager → CommunityManager → MemoryGC
           （见 Main.gd 的 post_list 依赖表）

lazy（首次访问才创建）：VersionManager / ResourceManager（经 ServiceHub.version / ServiceHub.resource 访问）
```

## 关键依赖关系

### 配置先行
- `ConfigManager` 必须先完成 `load_and_set_current()`（由 core 阶段 `on_started` 保证）
- 否则后续管理器读取到的可能是空配置或旧值

### 文件系统先于数据加载
- `DataManager.load_all_midis_async()` 依赖 `FileSystemManager.charts_index`
- `_load_midi_data()` 内会等待 `resources_scanned` 就绪（最多 300 帧 / 5 秒超时兜底）
- `ImportManager` 依赖 `FileSystemManager`，其 `on_started` 才触发目录初始化管线，
  保证「外部文件导入」先于「资源扫描」。

### 先管理器后 UI
- `_init_ui()` 在所有核心管理器就位后执行
- 防止 View 在 `_ready()` 提前读取空状态
- `CommunityManager` 必须在 `NetManager`、`AuthManager`、`ScoreManager` 和 `ChartDB` 就绪后创建
- 注意：内联进 `Main.tscn` 的视图（如 SortedMidiView）其 `_ready` 早于 core 段，不要用
  `@onready` 捕获服务实例（届时为 null）；改用 ServiceHub getter 每次现取，运行期再访问。

### ChartDB
- 扫描前必须已由 Main `_chartdb_open()` 打开（autoload 锚点，随存储根迁移）

### ThemeManager
- ThemeManager 作为 autoload 在引擎启动时已就位
- 入场动画前 `register_theme_applier(self)` + `apply_theme()`（演示层，不在依赖图内）
- 视图实例化完成后 `_init_ui()` 调 `ThemeMGR.refresh_theme_only()` 广播主题

## 已连接的核心信号

`Main._connect_signals()`：
- `DataManager.data_loaded -> _on_data_loaded`
- `UIStateManager.state_changed -> _on_state_changed`
- `EventBus.settings_changed -> _on_settings_changed`
- `EventBus.config_changed -> _on_config_changed`

## 常见问题

### 1. 数据加载为空
优先检查：
- `FileSystemManager.resources_scanned` 是否完成
- `charts_index` 是否有条目
- `res://Resources/Charts/` 是否有合法谱面

### 2. 设置不生效
优先检查：
- 是否执行了 `ConfigManager.load_and_set_current()`
- 是否发出了 `EventBus.settings_changed` / `config_changed`
- `SettingsMapper` 的 UI 控件 ID ↔ INI section/key 映射是否正确

### 3. UI 状态异常
优先检查：
- 是否统一使用 `UiStatMGR.change_state()`
- 是否在 View 中重复修改状态历史

### 4. 主题未应用
优先检查：
- `ThemeMGR.is_loaded()` 是否为 true
- `_init_ui()` 末尾是否调用了 `ThemeMGR.refresh_all()`

## 关联文档

- `architecture_overview.md`
- `singleton_pattern_guide.md`
