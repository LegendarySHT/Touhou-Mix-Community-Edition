# Manager 单例模式指南

> 适用版本：THMIX Community Edition（Godot 4.7.1 Mono）

## 目标

统一所有管理器访问方式，避免路径硬编码、重复实例和初始化时序问题。

## 四种初始化路径

### 1) Autoload 注册（`project.godot`）

| 别名 | 类 | 层 |
|---|---|---|
| `DataMGR` | DataManager | Core |
| `EvtBus` | EventBus | Core |
| `SortEngine` | SortingEngine | Core |
| `UiStatMGR` | UIStateManager | Core |
| `SkinMGR` | SkinManager | Core |
| `ParticleMGR` | ParticleManager | Core |
| `CharaMGR` | CharaManager | Core |
| `TextScrollMGR` | TextScrollMGR | Game |
| `AniMGR` | AnimationManager | UI |
| `ThemeMGR` | ThemeManager | UI |
| `GLogger` | GameLogger | Utilities |
| `CoverLoader` | CoverLoaderClass | UI |
| `AudioBtDetector` | AudioBtDetector | Utilities |
| `ChartDB` / `MidiCore` / `MeltySynth` / `PlaybackDisplay` | C# 数据/播放层 | Core |

特征：
- 引擎启动时自动实例化
- `_ready()` 中 `add_to_group("singleton")`
- 全局通过别名（`DataMGR`、`EvtBus` 等）或 `ClassName.instance` 访问

### 2) `Main.gd` 手动 `new() + add_child()`

| 类 | 说明 |
|---|---|
| `FileSystemManager` | 含 `static var instance`，`_ready()` 中赋值 |
| `ScoreCalculator` | 含 `static var instance`（如有） |
| `AudioManager` | 含 `static var instance`（如有） |
| `MidiPlaybackManager` | 含 `static var instance`（如有） |
| `KeySequenceManager` | 含 `static var instance`（如有） |
| `NetManager` | 在线连接和 HTTP 请求 |
| `AuthManager` | 登录态与鉴权请求 |
| `ScoreManager` | 本地成绩与成绩上传 |
| `CommunityManager` | MIDI 评价、评论、点赞与公开计数缓存 |

特征：
- 在 `Main._initialize_core_systems()` 按顺序创建
- 子节点 `_ready()` 后建立 `instance`

### 3) 懒加载单例 getter

首次访问 `Xxx.instance` 时才创建。按是否需要场景树分两种：

**a. 纯数据类（不进树）**

| 类 | 访问方式 |
|---|---|
| `ConfigManager` | `ConfigManager.instance` |

**b. 需要 `_process` / `get_tree()` / 信号（必须入树）**

统一由 `Utilities/LazyService.gd` 挂到 `/root/LazyServices` 下：

```gdscript
static var instance: Foo:
    get:
        if _instance == null:
            _instance = Foo.new()
            LazyService.mount(_instance, "Foo")
        return _instance
static var _instance: Foo = null
```

| 类 | 说明 |
|---|---|
| `VersionManager` | 只在关于页用 |
| `ResourceManager` | 只在商店页用；懒加载顺带修好了「`_ready` 早于 FileSystemManager」的空转 |
| `AudioRouteDetector` | `AudioBtDetector` 的懒子节点（`CSharp/AudioRouteDetector.tscn`），仅 Windows 首次检测时实例化 |

要点：
- `LazyService.mount` 在启动首帧会退化成延迟入树（root 正在建立主场景，处于 blocked 状态），
  因此首帧创建的服务 `_ready` 晚一帧；其余路径全部同步。
- 懒单例的 `instance` **永不为 null**，调用方不要再写 `if Xxx.instance == null` 守卫（死代码）。
- 判断标准不是"引用次数少"，而是「首次使用是否晚于 Main 引导完成」。启动扫描期就要用到的
  （`SkinMGR` / `ParticleMGR` / `CharaMGR`）、首屏转场就要用到的（`TextScrollMGR` / `AniMGR`）
  改成懒加载没有收益，保持 autoload。

### 4) 纯静态工具类

- `PathHelper`：无实例，全部静态方法

## 标准访问方式

```gdscript
# autoload 别名（推荐，更简短）
var albums = DataMGR.albums
UiStatMGR.change_state(UIStateManager.UIState.SONG_VIEW)
GLogger.info("msg", "Tag")

# 懒加载单例（必须用 .instance，首次访问才会创建）
ConfigManager.instance.get_int("lane_count", 12)
VersionManager.instance.get_version_label()
ResourceManager.instance.get_download_state(chart_hash)
```

## 禁止用法

```gdscript
# 不要这样做
var mgr = get_node("/root/Main/DataManager")
```

原因：
- 路径脆弱，场景结构变更后容易失效
- 运行时耦合高，不利于维护与测试

## 初始化安全建议

1. 在 `_ready()` 或数据就绪信号后访问依赖管理器。
2. 可能为空的单例先判空再调用。
3. 若依赖配置，优先确保 `ConfigManager.load_and_set_current()` 已执行（在 `Main._initialize_core_systems()` 第 2.5 步）。

## 与 EventBus 的配合

管理器之间不直接串改内部状态，跨模块优先通过信号：

```gdscript
EvtBus.config_changed.connect(_on_config_changed)
EvtBus.data_loaded_complete.connect(_on_data_ready)
```

## 自检清单

- [ ] 是否全部使用 autoload 别名或 `ClassName.instance`
- [ ] 是否移除了 `/root/...` 路径访问
- [ ] 是否在初始化时序正确后再调用
- [ ] 是否用 `EventBus` 处理跨模块事件

## 关联文档

- `architecture_overview.md`
- `initialization_sequence.md`
