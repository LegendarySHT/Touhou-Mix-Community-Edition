# 核心系统初始化顺序

> 适用版本：THMIX Community Edition（Godot 4.7.1 Mono）

## 入口

初始化由 `Main._initialize_core_systems()` 统一执行。

## 顺序（必须保持）

```text
1.   GameLogger（autoload，已就位）
1.1  VirtualKeyboardGuard.new() + add_child()   # Android 软键盘遮挡修复，无对外 API
2.   ConfigManager.instance（懒加载）
2.5  ConfigManager.clear_cache() + load_and_set_current()   # 关键：其他 Manager 依赖配置
2.75 ThemeManager（autoload，已就位）— 检查 ThemeMGR.is_loaded() 并打日志
3.   FileSystemManager.new() + add_child() + initialize_directory_structure()
4.   EventBus（autoload，已就位）
5.   UIStateManager（autoload，已就位）
6.   AnimationManager（autoload，已就位）
7.   SortingEngine（autoload，已就位）
8.   DataManager（autoload，已就位）
9.   ScoreCalculator.new() + add_child()
10.  AudioManager.new() + add_child()
11.  MidiPlaybackManager.new() + add_child()
12.  KeySequenceManager.new() + add_child()
12.5 NetManager.new() + add_child()
12.6 AuthManager.new() + ScoreManager.new() + add_child()
12.7 CommunityManager.new() + add_child()
13.  _init_ui() -> _connect_signals() -> _load_configuration() -> _load_midi_data()
```

> 注：SkinManager（`SkinMGR`）同为 autoload，引擎启动时已就位，不在 `Main._initialize_core_systems()` 中显式调用。
>
> 懒加载单例（`VersionManager` / `ResourceManager`）不在本序列里：它们由各自的使用方首次访问
> `Xxx.instance` 时创建，挂到 `/root/LazyServices` 下。详见 `singleton_pattern_guide.md`。

## 关键依赖关系

### 配置先行
- `ConfigManager` 必须先完成 `load_and_set_current()`
- 否则后续管理器读取到的可能是空配置或旧值

### 文件系统先于数据加载
- `DataManager.load_all_midis_async()` 依赖 `FileSystemManager.charts_index`
- `_load_midi_data()` 内会等待 `resources_scanned` 就绪（最多 300 帧 / 5 秒超时兜底）

### 先管理器后 UI
- `_init_ui()` 在所有核心管理器就位后执行
- 防止 View 在 `_ready()` 提前读取空状态
- `CommunityManager` 必须在 `NetManager`、`AuthManager`、`ScoreManager` 和 `ChartDB` 就绪后创建

### ThemeManager
- ThemeManager 作为 autoload 在引擎启动时已就位
- `Main._initialize_core_systems()` 仅在 2.75 步检查 `ThemeMGR.is_loaded()` 输出日志
- 所有 View 实例化完成后，`_init_ui()` 末尾调用 `ThemeMGR.refresh_all()` 应用主题

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
