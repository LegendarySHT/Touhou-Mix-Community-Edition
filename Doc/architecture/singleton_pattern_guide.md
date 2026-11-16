# Manager 单例模式指南

> 适用版本：THMIX Community Edition（Godot 4.7 Mono）

## 目标

统一所有管理器访问方式，避免路径硬编码、重复实例和初始化时序问题。
启动顺序由 `Services/ServiceHub` 依赖图推导，不再依赖手写固定顺序。

## 三种初始化路径

### 1) Autoload 注册（`project.godot`）

| 别名 | 类 | 层 |
|---|---|---|
| `ServiceHub` | ServiceHub（**无 class_name**，经 autoload 节点名访问） | Services |
| `DataMGR` | DataManager | Core |
| `EvtBus` | EventBus | Core |
| `UiStatMGR` | UIStateManager | Core |
| `AniMGR` | AnimationManager | UI |
| `ThemeMGR` | ThemeManager | UI |
| `GLogger` | GameLogger | Utilities |
| `CoverLoader` | CoverLoaderClass | UI |
| `ChartDB` / `MidiCore` / `MeltySynth` / `PlaybackDisplay` | C# 数据/播放层 | Core |

特征：
- 引擎启动时自动实例化（`ServiceHub` 为第一位 autoload，先于其他管理器存在）
- `_ready()` 中 `add_to_group("singleton")`
- 全局通过别名（`DataMGR`、`EvtBus` 等）访问

被迁移的 6 个薄 autoload（`SkinMGR` / `ParticleMGR` / `CharaMGR` / `SortEngine` /
`TextScrollMGR` / `AudioBtDetector`）已迁出并改为 ServiceHub 在 core 阶段实例化，
经 `ServiceHub` 类型化成员访问（见第 2 节）。

### 2) ServiceHub 依赖图启动（`Main._initialize_core_systems()`）

`Main._initialize_core_systems()` 不再手写 `new() + add_child()` 固定顺序，而是：
1. `ServiceHub.adopt(...)` 收编已由引擎实例化的 autoload 锚点（`EvtBus` / `GLogger` / `ChartDB` / 等），作为依赖节点。
2. `ServiceHub.register(ServiceDef)` 声明管理器的创建方式与阶段；**依赖由各服务脚本顶部的
   `const SERVICE_ID / SERVICE_DEPS` 声明**，`register()` 时自动读取填入 `ServiceDef`，
   Main 不再手写 `deps`（需临时覆盖时给 `def.deps` 赋值并置 `def.deps_declared = true`）。
3. `ServiceHub.start_phase("core"/"pre"/"post")` 在入场动画前后分批实例化。

依赖顺序由服务脚本的 `SERVICE_DEPS` 推导，`phase` 只负责与入场动画切分；新增/调整依赖
改服务脚本自身即可，不需要动 Main 的注册处。

| 类 | 依赖（简化） | 说明 |
|---|---|---|
| `StorageManager` | — | 存储根恢复/迁移，必须先于配置加载 |
| `ConfigManager` | StorageManager | 配置加载；`ServiceHub.config`（未启动时自创） |
| `SkinMGR`(SkinManager) | PlaybackDisplay | 内容管理器：皮肤包扫描/预览；`ServiceHub.skin` |
| `ParticleMGR`(ParticleManager) | — | 粒子包扫描/预览/删除；`ServiceHub.particle` |
| `CharaMGR`(CharaManager) | — | 人物双源索引/立绘合成；`ServiceHub.chara` |
| `SortEngine`(SortingEngine) | — | 排序/筛选/搜索；类型用 `SortingEngine.X`，实例用 `ServiceHub.sort.X` |
| `TextScrollMGR` | — | 统一驱动 marquee 文本（有 `_process`，须入树）；`ServiceHub.textScroll` |
| `AudioBtDetector` | PlaybackDisplay | 蓝牙输出平台分发/延迟预设；`_ready` 连接 PlaybackDisplay |
| `FileSystemManager` | ConfigManager, ChartDB, SkinMGR, ParticleMGR, CharaMGR | 目录/索引扫描 |
| `ImportManager` | FileSystemManager | 触发「建目录→复制→导入→扫描」管线 |
| `FavoriteManager` / `ScoreCalculator` | DataMGR | 入场前轻量 |
| `KeySequenceManager` | ChartDB, DataMGR | 入场后 |
| `NetManager` → `AuthManager` → `ScoreManager` → `CommunityManager` → `MemoryGC` | 链式 | 联网相关，顺序敏感 |
| `VersionManager` / `ResourceManager` | （lazy） | 首次访问才创建 |

### 3) 懒加载服务（首次访问才创建）

只有 `VersionManager` / `ResourceManager` 走「首次访问才实例化」。统一由 `ServiceHub` 按 lazy 服务创建：
- 由 `ServiceHub.service(id)` 首次创建并挂到 `ServiceHub` 下的 `LazyServices` 子节点。
- 访问统一走 `ServiceHub.version` / `ServiceHub.resource`（getter 内经 `service(id)` 取回）。

`AudioRouteDetector`（`AudioBtDetector` 的懒子节点，仅 Windows 首次检测时实例化）仍按需创建。

要点：
- lazy 服务经 `ServiceHub.version` / `ServiceHub.resource` 访问 **永不为 null**（getter 会触发创建），
  调用方不要再写空守卫（死代码）。
- 非 lazy 服务若在对应阶段启动前被访问，`service(id)` 会按依赖图自动补齐启动其依赖前缀
  （`_ensure_started`）；仅当某依赖尚未就绪时才返回 null（调用方判空处理，不再报错）。
- 判断标准不是"引用次数少"，而是「首次使用是否晚于 Main 引导完成」。启动扫描期/首屏就要用到的
  内容管理器（`SkinMGR` / `ParticleMGR` / `CharaMGR` / `SortEngine` / `TextScrollMGR` / `AudioBtDetector`）
  在原是 autoload，现迁为 core 阶段实例化，由 `FileSystemManager` 扫描前按依赖图提前创建，
  启动语义与 autoload 一致（core 段先于 FS 扫描）。仅 `VersionManager` / `ResourceManager` 走懒加载。
- 注意视图 `_ready` 可能早于 core 段（如内联进 `Main.tscn` 的视图）：不要用 `@onready` 捕获
  服务实例（届时为 null），改用 getter 每次现取。

### 4) 纯静态工具类

- `PathHelper`：无实例，全部静态方法

## 标准访问方式

```gdscript
# autoload 别名（推荐，更简短）
var albums = DataMGR.albums
UiStatMGR.change_state(UIStateManager.UIState.SONG_VIEW)
GLogger.info("msg", "Tag")

# 服务统一经 ServiceHub 类型化成员访问（短名 + 静态类型，见 ServiceHub 门面）
ServiceHub.config.get_int("lane_count", 12)
ServiceHub.skin.get_skin_config(keys)
ServiceHub.particle.get_particle_list()
ServiceHub.chara.get_chara_list()
ServiceHub.textScroll.suspend_page(p)

# lazy 服务（首次访问才创建；getter 会自动创建）
ServiceHub.version.get_version_label()
ServiceHub.resource.get_download_state(chart_hash)
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
3. 若依赖配置，优先确保 `ConfigManager.load_and_set_current()` 已执行（由 ServiceHub core 阶段 `on_started` 保证）。

## 与 EventBus 的配合

管理器之间不直接串改内部状态，跨模块优先通过信号：

```gdscript
EvtBus.config_changed.connect(_on_config_changed)
EvtBus.data_loaded_complete.connect(_on_data_ready)
```

## 自检清单

- [ ] 是否全部使用 autoload 别名或 `ServiceHub.xxx`
- [ ] 是否移除了 `/root/...` 路径访问
- [ ] 是否在初始化时序正确后再调用
- [ ] 是否用 `EventBus` 处理跨模块事件

## 关联文档

- `architecture_overview.md`
- `initialization_sequence.md`
