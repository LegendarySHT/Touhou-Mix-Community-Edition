# 开发者速查表

## 单例访问

```gdscript
DataManager.instance
EventBus.instance
UIStateManager.instance
SortingEngine.instance
ConfigManager.instance
```

## 常用信号

```gdscript
EventBus.instance.data_loaded_complete.connect(_on_data_ready)
EventBus.instance.config_changed.connect(_on_config_changed)
UIStateManager.instance.state_changed.connect(_on_state_changed)
```

## 常用数据接口

```gdscript
DataManager.instance.get_all_albums()
DataManager.instance.get_songs_by_album(album_id)
DataManager.instance.get_midis_by_song(song_id)
SortingEngine.instance.search_midis(midis, keyword)
```

## 配置接口

```gdscript
ConfigManager.instance.get_int("Audio", "master_volume", 80)
ConfigManager.instance.set_value_and_notify("Audio", "master_volume", 70)
```

## 播放接口

```gdscript
MidiPlaybackManager.instance.set_soundfont("GeneralUser-GS.sf2")
var pos_ms = MidiPlaybackManager.instance.get_position_ms()
```

## 计分接口

```gdscript
ScoreCalculator.instance.record_judgment(judgment, block_type, timing_sec)
var acc = ScoreCalculator.instance.get_accuracy()
var snapshot = ScoreCalculator.instance.get_snapshot()
```

## 动态立绘

```gdscript
ConfigManager.instance.set_value_and_notify("Chara", "chara_id", chara_key)
CharaMGR.get_portrait(chara_key, 0)
CharaMGR.get_motion_config(chara_key)
CharaMGR.get_score_reaction(chara_key, final_rank)
```

- 使用 `DynamicPortrait.show_character()` 或 `show_result()`，宿主入场完成后 `set_active(true)`，离开时 `set_active(false)`。
- `motion` / `score_reactions` 均为可选字段；不要改变原有 `rating` 的整数表情协议，也不要在 ScoreView 硬编码人物 ID。
- 素材规格、完整示例与生命周期约束见 `Doc/features/dynamic_portraits.md`。

## 禁止事项

- 不要使用 `get_node("/root/..." )` 查找管理器
- 不要在 View 中直接改其他 Manager 内部数据
- 不要混用 tick/ms/sec 而不转换

## 快速定位

- 初始化：`Main.gd`
- 事件：`Core/EventBus.gd`
- 状态：`Core/UIStateManager.gd`
- 数据：`Core/DataManager.gd`
- 文件系统：`Core/FileSystemManager.gd`
- 播放：`Game/MidiPlaybackManager.gd`
- 人物资源：`Core/CharaManager.gd`
- 动态立绘：`UI/Components/DynamicPortrait.gd`
