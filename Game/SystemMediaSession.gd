## 系统媒体会话（autoload，全局名 MediaSess）
##
## 把播放状态桥接到系统媒体控制（Android 通知栏/锁屏媒体键、Android Auto、
## Windows SMTC 控制中心），并把系统下发的 play/pause/seek/stop 命令回送给页面。
##
## 音频完全走 miniaudio 原生设备、不经过 Godot AudioServer，引擎内置的媒体集成
## 不可用，各平台需自行实现后端。后端统一契约：
##   signal command_received(action: String, position_ms: float)
##   func update_state(playing, position_ms, duration_ms, title, album, cover_png, end_action)
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
## 用户在系统媒体控件点上下首，且当前播放列表为空（尚无歌单）时发出，
## 请求打开音乐播放器页。判定留在本层：MidiPlaybackManager 不该知道 UI 存在。
signal open_player_requested

## 平台后端（惰性创建，见 _ensure_backend）
var _backend: Object = null
## 当前注册的播放页面（后注册者覆盖前者；同一时刻只有一个播放页面活跃）
var _view: Node = null
## 上次推送给系统的状态，用于节流与差异判定
var _last_pushed_position_ms: float = -1.0
var _last_pushed_playing: bool = false
## 位置推送节流累计时间
var _position_accum: float = 0.0
## 封面：按路径缓存 PNG 字节（读盘 + PNG 编码较慢，只在换曲时重算）。
## 必须限量：单张无损 PNG 约 0.5-1.5MB，无上限会让常驻内存随听歌数线性膨胀（实测 native heap 上百 MB）。
const COVER_CACHE_MAX := 6
var _cover_png_cache: Dictionary = {}
var _cover_png_lru: Array[String] = []
var _cover_png_path: String = ""
var _cover_png: PackedByteArray = PackedByteArray()
## 元数据缓存（曲名/专辑/封面路径），按当前歌曲引用失效。
## push_state 每 0.5s 跑一次，而 _resolve_cover_path 含 C# DB 查询 + 磁盘 stat（~3ms），
## 元数据只在换歌时才变，不能每次推送都重查
var _meta_song: MidiData = null
var _meta_cached: Dictionary = {}
## 位置推送节流间隔（秒）。系统侧按 playback_rate 自行外推，无需高频刷新
const POSITION_PUSH_INTERVAL: float = 0.5

func _ready() -> void:
	add_to_group("singleton")
	process_mode = Node.PROCESS_MODE_ALWAYS

	_ensure_manager_signals()

## 确保已订阅 manager 的状态信号。连接建立后不再重复，故可安全每帧调用。
func _ensure_manager_signals() -> void:
	var mgr = MidiPlaybackManager.instance
	if mgr == null:
		return
	if not mgr.playback_state_changed.is_connected(_on_playback_state_changed):
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

## 注销播放页面：系统媒体控制隐藏，并停止播放。
##
## 停止播放是当前明确的行为（离开播放器页即退出播放）。命令本身由
## MidiPlaybackManager 执行、不依赖页面，所以这里只负责"没有页面 = 没人听"。
func unregister_view(view: Node) -> void:
	if _view != view:
		return
	_view = null
	var mgr := MidiPlaybackManager.instance
	if mgr != null and mgr.is_playing:
		mgr.stop()
	if _backend != null:
		_backend.clear()
	_last_pushed_position_ms = -1.0
	_last_pushed_playing = false
	_backend_retry_frames = 0
	GLogger.info("Media session view unregistered (playback stopped)", "SystemMediaSession")

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
	# 元数据只在换歌时重建（DB 查询 + 封面 stat ~3ms，位置推送每 0.5s 一次不能每次都查）
	if mgr.current_midi_data != _meta_song or _meta_cached.is_empty():
		_meta_song = mgr.current_midi_data
		_meta_cached = _build_metadata()
	_ensure_cover_loaded(_meta_cached["cover_path"])
	_backend.update_state(playing, mgr.position_ms, mgr.get_backend_duration_ms(),
		_meta_cached["title"], _meta_cached["album"], _cover_png, mgr.get_track_end_action())

func _process(delta: float) -> void:
	# MidiPlaybackManager 由 Main 在 autoload 之后创建，_ready 时可能尚未实例化，
	# 导致状态信号根本没连上（表现为「进了播放器页后媒体控件不再更新」）。每帧补连一次。
	_ensure_manager_signals()
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

	_poll_backend_command()

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

## 确保封面 PNG 已就绪。同步读盘 + PNG 编码（结果缓存，每封面一次）：
## 异步加载的回调依赖主循环，后台主循环停摆时永远不返回，
## 表现为系统卡片只能显示已缓存的封面，故这里必须同步补齐。
func _ensure_cover_loaded(path: String) -> void:
	if path.is_empty():
		_cover_png = PackedByteArray()
		_cover_png_path = ""
		return
	if _cover_png_cache.has(path):
		_cover_png = _cover_png_cache[path]
		_cover_png_path = path
		_cover_png_lru.erase(path)
		_cover_png_lru.append(path)
		return
	_load_cover_bytes(path)

## 把封面编码为 PNG 字节。优先复用纹理缓存；未缓存时文件路径直接解码 Image
## （不建 GPU 纹理，任何线程可跑），res:// 封面在 PCK 内只能经 ResourceLoader 取
func _load_cover_bytes(path: String) -> void:
	var bytes := PackedByteArray()
	var tex: Texture2D = FileSystemManager.instance.get_cached_cover_texture(path) if FileSystemManager.instance else null
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		if path.begins_with("res://"):
			var loaded := load(path) as Texture2D
			img = loaded.get_image() if loaded != null else null
		else:
			img = Image.load_from_file(_globalize_path(path))
	if img != null:
		if img.is_compressed():
			img.decompress()
		bytes = img.save_png_to_buffer()
	_cache_cover_bytes(path, bytes)
	_cover_png = bytes
	_cover_png_path = path

## 写入封面缓存并维持 LRU：超出上限时淘汰最久未用的一张
func _cache_cover_bytes(path: String, bytes: PackedByteArray) -> void:
	if _cover_png_cache.has(path):
		_cover_png_cache.erase(path)
	_cover_png_cache[path] = bytes
	_cover_png_lru.append(path)
	while _cover_png_lru.size() > COVER_CACHE_MAX:
		_cover_png_cache.erase(_cover_png_lru.pop_front())

func _globalize_path(path: String) -> String:
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	return path

func _on_playback_state_changed() -> void:
	push_state(true)

func _poll_backend_command() -> void:
	# 后端命令的收取方式因平台而异：Java 侧在 UI 线程 emitSignal，可直接连；
	# C# 侧 [Signal] 不会注册为 Godot 信号，只能轮询。
	if _backend.has_signal("command_received"):
		return
	if not _backend.has_method("poll_command"):
		if not _poll_warned:
			_poll_warned = true
			push_warning("[SystemMediaSession] backend has neither command_received signal nor poll_command")
		return
	var res: Array = _backend.poll_command()
	if res.is_empty():
		return
	var action: String = res[0]
	var pos: float = float(res[1]) if res.size() > 1 else -1.0
	GLogger.info("[DIAG] polled command: %s (%.1f ms)" % [action, pos], "SystemMediaSession")
	_on_backend_command(action, pos)

var _poll_warned: bool = false

## 跳转到播放器页。当前在 TrackView 时先一次性退回 AlbumView，避免把 TrackView
## 留在返回栈里（否则从播放器返回会回到音轨页，语义不对）。
func _navigate_to_player() -> void:
	if UiStatMGR.current_state == UIStateManager.UIState.MUSIC_PLAYER_VIEW:
		return
	if UiStatMGR.current_state == UIStateManager.UIState.TRACK_VIEW:
		UiStatMGR.go_back_to(UIStateManager.UIState.ALBUM_VIEW)
	# stash=false：不再把当前页压栈，返回键从播放器直接回 AlbumView
	UiStatMGR.change_state(UIStateManager.UIState.MUSIC_PLAYER_VIEW, false)
	GLogger.info("Navigated to music player view", "SystemMediaSession")

## 用户播放列表(A)为空时，把当前正在播放的曲子写进「正常通道的单曲槽」(B) 当起点。
## 只写 B、不落盘、不碰 A：区分"用户还没配列表"与"列表播到尾"（后者由 has_next() 为 false 表达）。
func _ensure_playlist_has_current() -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr == null or mgr.current_midi_data == null:
		return
	if not mgr.playlist.is_empty():
		return
	var data: MidiData = mgr.current_midi_data
	var key := data.chart_key if not data.chart_key.is_empty() else data.id
	if key.is_empty():
		return
	# 正常播放场景：只把当前曲设为"现在要播什么"，不落盘、不改循环
	mgr.start_session([data] as Array[MidiData], 0, false)
	GLogger.info("Playlist seeded with current song: %s" % data.name, "SystemMediaSession")

func _on_backend_command(action: String, position_ms: float) -> void:
	# 日志放在守卫之前：否则页面已注销时会静默返回，看不出命令是否到达
	GLogger.info("Media session command: %s (%.1f ms) has_view=%s" % [action, position_ms, has_view()],
		"SystemMediaSession")
	if not has_view():
		return
	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		# 上下首按「用户播放列表」(A) 走：先确保 A 就绪（内存空则读盘恢复，仍空则借单曲槽那首）。
		# 此时正在播的多半是正常通道的单曲槽(B)，切歌就等于"开始播放 A"，与进入播放页一致。
		if action == "next" or action == "prev":
			mgr.ensure_user_playlist()
		# 全部命令统一由中心执行器处理：seek/play/pause/stop/toggle 不依赖当前页面是谁
		# （此前只有订阅了 command_received 的 TrackView 会处理，播放器页拖卡片进度条
		# 一类命令会被静默丢弃）。
		var consumed := mgr.handle_media_command(action, position_ms)
		# 上下首但确实无歌可切：把当前这首作为单曲槽起点
		if not consumed and (action == "next" or action == "prev"):
			if has_view():
				_ensure_playlist_has_current()
			else:
				if not mgr.enter_user_playlist_from_head():
					_ensure_playlist_has_current()
	# 上下首一律进播放器页——这是该页面的入口语义，与歌单是否为空无关。
	# 之前只在歌单为空时跳转，导致退出播放器页后在 TrackView 点上下首
	# 会按列表切歌却留在原页面。
	if action == "next" or action == "prev":
		open_player_requested.emit()
		_navigate_to_player()
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
		# Java 后端在 UI 线程 emitSignal，直接连即可；C# 后端的 [Signal] 不会注册为
		# Godot 信号（has_signal 为 false，EmitSignal 静默成功），只能由 _process 轮询
		# poll_command 取走。
		if _backend.has_signal("command_received") \
				and not _backend.command_received.is_connected(_on_backend_command):
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
