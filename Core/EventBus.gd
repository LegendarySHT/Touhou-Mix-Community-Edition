## 全局事件总线
## 所有UI组件通过此总线进行通信，解除直接依赖
extends Node

class_name EventBus
@warning_ignore_start("unused_signal")
## ========== 数据事件 ==========
signal data_loaded_complete
signal album_selected(album_id: String)
signal song_selected(song_id: String)
signal midi_selected(midi_id: String, midi_data: MidiData)
signal enter_track_view_with(midi: MidiData)
signal start_game_with(midi: MidiData)

## ========== UI导航事件 ==========
## 设置页面及商店页面使用
signal page_left
signal page_right

## ========== 排序和筛选事件 ==========
signal sort_finished
signal search_query_changed(query: String)
## 当前生效的就地搜索词（Album/Song/Midi 就地筛选共享，跨视图导航保留；仅进入 SORTED_VIEW 时清空）
var current_search_query: String = ""

## ========== 设置和配置事件 ==========
signal settings_changed(setting_name: String, value: Variant)
## 配置项变更。只带 key：配置键全局唯一，section 属于 ini 排版细节，订阅者不该依赖它。
## key == "*" 表示全量重载（value 为 null），订阅者应重读自己关心的全部键。
signal config_changed(key: String, value: Variant)
signal theme_changed(theme_name: String)

## ========== 文件系统事件 ==========
signal midi_deleted(midi_id: String)
## 批量删除谱面（DelView 批量删除用，聚合一次通知，避免逐 id 触发 N 次视图刷新/收藏夹写盘）
signal midis_deleted(midi_ids: Array)
## charts 扫描缓存后台校验完成
## 参数：是否有变化（true 时 UI 应刷新列表）
## 启动时先从缓存恢复 charts_index 让用户立即操作，后台 worker 校验文件状态
## 校验完成后 emit 此信号；changed=true 表示发现了新增/删除/修改的文件夹，UI 需刷新
signal charts_cache_validated(changed: bool)
## 全量/增量扫描完成后，若发现谱面的 song_id / album_id 归属发生变更（结构变化）
## AlbumView / SongView 监听此信号并刷新；仅扫描完毕后统一 emit 一次，避免中间卡顿
signal charts_structure_changed

## ========== 收藏夹事件 ==========
## 收藏夹数据加载并验证完成
signal favorites_loaded
## 收藏夹数据更新（通用刷新触发）
signal favorites_updated
## 收藏夹创建
signal favorite_list_created(favorite_id: String)
## 收藏夹删除
signal favorite_list_deleted(favorite_id: String)
## 收藏夹重命名
signal favorite_list_renamed(favorite_id: String, new_name: String)
## MIDI 被添加到或移除出收藏夹
signal favorite_midi_changed(favorite_id: String, midi_id: String, added: bool)
## 请求浏览收藏夹内容（AlbumView 点击列表项时发出）
signal favorite_selected_for_browse(favorite_id: String)

## ========== 在线功能事件 ==========
## 登录状态变化：user_data 为 null 表示登出
signal auth_changed(user_data: Variant)
## 网络连接状态变化：online=true 表示服务端可达
signal online_status_changed(online: bool, message: String)
## 请求开始/结束（用于 UI 显示 loading）
signal online_request_started(endpoint: String)
signal online_request_finished(endpoint: String, success: bool)
## 连接状态变化（携带延迟数值）：state 对应 NetManager.ConnectState 枚举值，latency_ms=-1 表示未知
signal online_state_changed(state: int, latency_ms: int)
## 成绩上传成功（携带 midi_hash），用于触发个人信息统计刷新
signal score_uploaded(midi_hash: String)

## ========== 通知事件 ==========
## 顶部横幅通知请求（由 Main/NotiBanner 订阅）：外部模块不用知道节点路径
## 用便利函数 EvtBus.notify(text, on_click) 发出，on_click 在点击横幅时执行
signal notify_requested(text: String, on_click: Callable)
@warning_ignore_restore("unused_signal")

## 外部文件导入开始（拖入窗口 / 打开方式）。
## PlayView 订阅：打歌中收到导入请求时走正常退出流程，避免导入后仍停在打歌页。
signal import_started

func _ready() -> void:
	add_to_group("singleton")

## 便利函数：发出歌曲选择事件
func emit_song_selected(song_id: String) -> void:
	song_selected.emit(song_id)

## 便利函数：发出MIDI选择事件
func emit_midi_selected(midi_id: String, midi_data: MidiData) -> void:
	midi_selected.emit(midi_id, midi_data)

## 便利函数：广播“外部文件导入开始”
func emit_import_started() -> void:
	import_started.emit()

## 便利函数：弹一条顶部横幅通知（5 秒后自动收起，显示中再来消息会排队）
func notify(text: String, on_click: Callable = Callable()) -> void:
	notify_requested.emit(text, on_click)
