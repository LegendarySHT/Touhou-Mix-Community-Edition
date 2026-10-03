## 系统媒体会话（autoload，全局名 MediaSess）
##
## 把播放状态桥接到系统媒体控制（Android 通知栏/锁屏媒体键、Android Auto、
## Windows SMTC 控制中心），并把系统下发的 play/pause/seek/stop 命令回送给页面。
##
## 音频完全走 miniaudio 原生设备、不经过 Godot AudioServer，引擎内置的媒体集成
## 不可用，各平台需自行实现后端。后端统一契约：
##   signal command_received(action: String, position_ms: float)
##   func update_state(playing, position_ms, duration_ms, title, album, cover_png)
##   func clear()
## cover_png 为 PNG 字节（封面嵌入 MediaMetadata 需字节流，路径仅平台内部使用）
##
## 使用方式（播放页面按需注册；PlayView 不注册，以保留其切后台自动暂停行为）：
##   func _ready():
##       MediaSess.register_view(self)
##       MediaSess.command_received.connect(_on_media_command)
##   func _exit_tree():
##       MediaSess.unregister_view(self)
extends Node

## 系统媒体控制下发的命令。action: play / pause / toggle / stop / next / prev / seek
## position_ms 仅 seek 有效，其余为 -1
signal command_received(action: String, position_ms: float)

## 平台后端（惰性创建，见 _ensure_backend）
var _backend: Object = null
## 当前注册的播放页面（后注册者覆盖前者；同一时刻只有一个播放页面活跃）
var _view: Node = null
## 上次推送给系统的状态，用于节流与差异判定
var _last_pushed_position_ms: float = -1.0
var _last_pushed_playing: bool = false
## 位置推送节流累计时间
var _position_accum: float = 0.0
## 封面：按路径缓存 PNG 字节（读盘 + PNG 编码较慢，只在换曲时重算）
var _cover_png_cache: Dictionary = {}
var _cover_png_path: String = ""
var _cover_png: PackedByteArray = PackedByteArray()
## 封面加载在途标记（避免同一路径重复入队）
var _cover_loading_path: String = ""
const COVER_ITEM_ID := "media_session_cover"
## 位置推送节流间隔（秒）。系统侧按 playback_rate 自行外推，无需高频刷新
const POSITION_PUSH_INTERVAL: float = 0.5

func _ready() -> void:
	add_to_group("singleton")
	process_mode = Node.PROCESS_MODE_ALWAYS

	var mgr = MidiPlaybackManager.instance
	if mgr != null and not mgr.playback_state_changed.is_connected(_on_playback_state_changed):
		mgr.playback_state_changed.connect(_on_playback_state_changed)

## 注册播放页面：此后系统媒体控制可见，命令回送至该页面
func register_view(view: Node) -> void:
	if _view == view:
		return
	_view = view
	if _ensure_backend():
		_on_backend_ready()
	else:
		# 插件尚未注册（Android 异步注册），_process 会重试
		_backend_retry_frames = 0
	push_state(true)
	GLogger.info("Media session view registered: %s" % view.name, "SystemMediaSession")
	_log_backend_diagnostics()

## [诊断] 打印后端可用性，特别是前台服务状态（后台播放的前提）
func _log_backend_diagnostics() -> void:
	if _backend == null:
		GLogger.warning("[DIAG] media session backend unavailable on this platform", "SystemMediaSession")
		return
	if _backend.has_method("is_available"):
		GLogger.info("[DIAG] backend available=%s" % _backend.is_available(), "SystemMediaSession")
	if _backend.has_method("is_foreground_service_running"):
		var running: bool = _backend.is_foreground_service_running()
		GLogger.info("[DIAG] foreground service running=%s (false means NO background playback)" % running,
			"SystemMediaSession")
	if _backend.has_method("get_foreground_error"):
		var err: String = _backend.get_foreground_error()
		if not err.is_empty():
			GLogger.warning("[DIAG] last foreground error: %s" % err, "SystemMediaSession")

## 注销播放页面：系统媒体控制隐藏，不再接收命令
func unregister_view(view: Node) -> void:
	if _view != view:
		return
	_view = null
	if _backend != null:
		_backend.clear()
	_last_pushed_position_ms = -1.0
	_last_pushed_playing = false
	_backend_retry_frames = 0
	GLogger.info("Media session view unregistered", "SystemMediaSession")

## 当前是否有播放页面注册
func has_view() -> bool:
	return _view != null and is_instance_valid(_view)

## 向系统推送播放状态。force=true 时无视节流与差异判定
func push_state(force: bool = false) -> void:
	if not has_view() or _backend == null:
		return
	var mgr = MidiPlaybackManager.instance
	if mgr == null:
		return
	var playing: bool = mgr.is_playing
	if not force and playing == _last_pushed_playing \
			and absf(mgr.position_ms - _last_pushed_position_ms) < 1.0:
		return
	_last_pushed_playing = playing
	_last_pushed_position_ms = mgr.position_ms
	var meta := _build_metadata()
	_ensure_cover_loaded(meta["cover_path"])
	_backend.update_state(playing, mgr.position_ms, mgr.get_backend_duration_ms(),
		meta["title"], meta["album"], _cover_png)

func _process(delta: float) -> void:
	# 后端未就绪时持续重试（Android Java 插件在渲染线程上异步注册）
	if _backend == null:
		if not has_view():
			return
		_backend_retry_frames += 1
		if _backend_retry_frames > BACKEND_RETRY_MAX_FRAMES:
			if _backend_retry_frames == BACKEND_RETRY_MAX_FRAMES + 1:
				push_warning("[SystemMediaSession] backend unavailable after %d frames; " % BACKEND_RETRY_MAX_FRAMES
					+ "system media control disabled on this platform")
			return
		if _ensure_backend():
			GLogger.info("Media session backend became available after %d frames" % _backend_retry_frames,
				"SystemMediaSession")
			_on_backend_ready()
		return

	# 后台时 Godot 主循环暂停（Android 渲染线程被挂起），_process 不运行；
	# 此时系统侧按 playback_rate 外推位置，返回前台后此处补一次校正。
	if not has_view():
		return
	var mgr = MidiPlaybackManager.instance
	if mgr == null or not mgr.is_playing:
		return
	_position_accum += delta
	if _position_accum < POSITION_PUSH_INTERVAL:
		return
	_position_accum = 0.0
	push_state()

## 组装曲目元数据。曲名/专辑取自 MidiData
func _build_metadata() -> Dictionary:
	var mgr = MidiPlaybackManager.instance
	var data: MidiData = mgr.current_midi_data if mgr != null else null
	if data == null:
		return {"title": "", "album": "", "cover_path": ""}
	return {
		"title": data.song_name if not data.song_name.is_empty() else data.name,
		"album": data.album_name,
		"cover_path": _resolve_cover_path(data),
	}

## 封面路径：复用列表项同款接口（内部含 cover_hash 共享缓存）
func _resolve_cover_path(data: MidiData) -> String:
	var fs_mgr := FileSystemManager.instance
	if fs_mgr == null:
		return ""
	return fs_mgr.get_cover_path_by_midiData(data)

## 确保封面 PNG 已就绪。读盘 + PNG 编码较慢，走 CoverLoader 后台线程，
## 完成后回调再补推一次状态（此时 update_state 带封面）
func _ensure_cover_loaded(path: String) -> void:
	if path.is_empty():
		_cover_png = PackedByteArray()
		_cover_png_path = ""
		return
	if _cover_png_cache.has(path):
		_cover_png = _cover_png_cache[path]
		_cover_png_path = path
		return
	if _cover_loading_path == path:
		return  # 同路径在途
	var fs_mgr := FileSystemManager.instance
	if fs_mgr == null:
		return
	# res:// 封面在 PCK 内，同步读盘即可（导入资源解码很快）
	if path.begins_with("res://"):
		_load_cover_bytes(path)
		return
	_cover_loading_path = path
	CoverLoader.request_load(COVER_ITEM_ID, path, _on_cover_loaded)

## 把封面纹理编码为 PNG 字节
func _load_cover_bytes(path: String) -> void:
	var tex: Texture2D = FileSystemManager.instance.get_cached_cover_texture(path) if FileSystemManager.instance else null
	if tex == null:
		tex = load(path) as Texture2D
	var bytes := PackedByteArray()
	if tex != null:
		var img := tex.get_image()
		if img != null:
			if img.is_compressed():
				img.decompress()
			bytes = img.save_png_to_buffer()
	_cover_png_cache[path] = bytes
	_cover_png = bytes
	_cover_png_path = path

## CoverLoader 后台加载回调（主线程）
func _on_cover_loaded(path: String, texture: Texture2D, _version: int) -> void:
	if _cover_loading_path != path:
		return  # 期间已切歌，结果作废
	_cover_loading_path = ""
	var bytes := PackedByteArray()
	if texture != null:
		var img := texture.get_image()
		if img != null:
			if img.is_compressed():
				img.decompress()
			bytes = img.save_png_to_buffer()
	_cover_png_cache[path] = bytes
	_cover_png = bytes
	_cover_png_path = path
	# 封面后到，补推一次让系统卡片更新
	push_state(true)

func _on_playback_state_changed() -> void:
	push_state(true)

func _on_backend_command(action: String, position_ms: float) -> void:
	if not has_view():
		return
	GLogger.info("Media session command: %s (%.1f ms)" % [action, position_ms], "SystemMediaSession")
	command_received.emit(action, position_ms)
	# 外部命令后立刻回推权威状态，避免系统 UI 与实际播放短暂不一致
	push_state(true)

## 惰性创建平台后端。不支持的平台保持 null，所有调用点做 null 检查。
## Android 的 Java 插件由 Godot 在渲染线程上异步注册（queueOnRenderThread），
## 可能晚于本页 _ready，故拿不到时由 _process 继续重试。
func _ensure_backend() -> bool:
	if _backend != null:
		return true
	match OS.get_name():
		"Android":
			# Java GodotPlugin，由 addons/media_session 的导出插件注入 manifest meta-data 注册
			_backend = Engine.get_singleton("MediaSessionControl")
		"Windows":
			# 非 autoload：Android 目标不编译该 C# 文件（无 CsWinRT），故按需实例化
			var script: Script = load("res://CSharp/MediaSessionControlCs.cs")
			if script != null:
				var node: Object = script.new()
				if node is Node:
					add_child(node)
					_backend = node
		_:
			pass
	if _backend != null:
		if _backend.has_signal("command_received"):
			_backend.command_received.connect(_on_backend_command)
		return true
	return false

## 后端就绪后补做的初始化（通知权限请求 + 首次状态推送）
func _on_backend_ready() -> void:
	if _backend != null and _backend.has_method("ensure_notification_permission"):
		_backend.ensure_notification_permission()
	push_state(true)
	_log_backend_diagnostics()

## Android 插件注册重试次数（_process 每帧尝试，超过则放弃并告警）
var _backend_retry_frames: int = 0
const BACKEND_RETRY_MAX_FRAMES: int = 120
