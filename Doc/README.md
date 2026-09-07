# THMIX Community Edition 文档中心

> 更新时间：2026-09-07

本目录用于维护项目**当前有效**的技术文档，重点覆盖架构、关键功能和开发速查。

## 文档结构

### 1) 架构文档（`architecture/`）
- `architecture_overview.md`：系统分层、核心模块、数据流
- `singleton_pattern_guide.md`：Manager 单例访问规范
- `initialization_sequence.md`：`Main._initialize_core_systems()` 初始化顺序与依赖

### 2) 功能文档（`features/`）
- `midi_playback_implementation.md`：MIDI 播放后端与音源管理
- `soundfont_selection_feature.md`：SoundFont 扫描、选择与应用
- `note_visualizer_integration.md`：打歌可视化与 `KeySequenceManager` 集成要点
- `dynamic_portraits.md`：动态立绘素材协议、成绩反应与新角色接入

### 3) 快速参考（`quickref/`）
- `quick_start.md`：新开发者上手路径
- `developer_cheatsheet.md`：常用接口与排障速查
- `MIDI_PERSISTENCE_QUICK_REFERENCE.md`：`MidiData._runtime` 持久化
- `FILESYSTEM_MANAGER_GUIDE.md`：资源目录与文件系统初始化

## 文档维护规则

1. 文档描述必须以当前代码为准（优先核对 `Main.gd`、`Core/`、`Game/`、`Utilities/`）。
2. 禁止再引用已废弃内容（如 `ConfigLoader`、`NotesRenderer.gd`、`/root/Main/...` 硬编码路径）。
3. 功能类文档只保留“当前可运行实现”，历史修复过程请转移到提交记录。
4. 新增模块时，至少同步更新：
   - 本文件索引
   - 对应架构或功能文档
   - `quickref/developer_cheatsheet.md`

## 推荐阅读顺序

1. `quickref/quick_start.md`
2. `architecture/architecture_overview.md`
3. `architecture/initialization_sequence.md`
4. 对应功能文档（按开发任务选择）
