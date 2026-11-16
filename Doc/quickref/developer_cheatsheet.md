# 开发者速查表

## 单例访问

```gdscript
# autoload 别名
DataMGR
EvtBus
UiStatMGR
# 服务统一经 ServiceHub 类型化成员访问
ServiceHub.sort
ServiceHub.config
```

## 常用信号

```gdscript
EvtBus.data_loaded_complete.connect(_on_data_ready)
EvtBus.config_changed.connect(_on_config_changed)
UiStatMGR.state_changed.connect(_on_state_changed)
```

## 常用数据接口

```gdscript
DataMGR.get_all_albums()
DataMGR.get_songs_by_album(album_id)
DataMGR.get_midis_by_song(song_id)
ServiceHub.sort.search_midis(midis, keyword)
```

## 配置接口

```gdscript
ServiceHub.config.get_int("Audio", "master_volume", 80)
ServiceHub.config.set_value_and_notify("Audio", "master_volume", 70)
```

## 播放接口

```gdscript
# 播放门面为 autoload 别名 PlaybackDisplay（经 ServiceHub.playback 等价访问）
PlaybackDisplay.set_current(midi_data)
PlaybackDisplay.tick_to_ms(tick)
```

## 计分接口

```gdscript
ServiceHub.scoreCalc.record_judgment(judgment, block_type, timing_sec)
var acc = ServiceHub.scoreCalc.get_accuracy()
var snapshot = ServiceHub.scoreCalc.get_snapshot()
```

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
