extends CoverListItemBase
class_name StoreMidiListItem

# cover_texture 继承自 CoverListItemBase，在 _ready() 中赋值
# MidiName / Author 在 CoverPanel/Panel 下；Uploader / AlbumName / SongName 在 InfoPanel 下
@onready var title_text:Label = $CoverPanel/Panel/MidiName
@onready var author_text:Label = $CoverPanel/Panel/Author
@onready var uploader:Label = $InfoPanel/Uploader
@onready var album_name:Label = $InfoPanel/AlbumName
@onready var song_name:Label = $InfoPanel/SongName

signal init_finished

# midi数据
var midi_data:MidiData

## 资源哈希（用于下载和状态查询）
var chart_hash: String = ""

## 列表项原始数据（set_remote_display 收到的 ChartResponse 全量字典）：
## 供 get_download_hint() 提取下载预取字段（三请求并行用）
var chart_data: Dictionary = {}
## 下载状态
var download_state: int = 0  # ResourceManager.DownloadState
## 是否为远程 chart（非本地 MidiData）
var is_remote_chart: bool = false
## 脉冲动画 Tween（下载中提示）
var _pulse_tween: Tween
## 原始歌曲名（用于下载完成后恢复显示）
var _original_song_name: String = ""

func _ready() -> void:
	cover_texture = $CoverPanel/cover
	_parallax_enabled = false
	# StoreMidiNode 本身即 Button（原 PanelContainer + 子 Button 已合并）
	button = self
	parent_node = get_node(PathRegistry.STORE_MIDI_LIST)

	# 直接bind参数会传初始化时的值有点难绷
	# 通过实例变量读取，确保按下时获取最新值
	button.pressed.connect(func ():
		if is_remote_chart:
			parent_node.on_remote_chart_select(chart_hash)
		elif midi_data:
			parent_node.on_midi_select(midi_data)
	)

	await init_finished
	enable_selected_animation(button, parent_node)
	# 直接开始加载封面（不等列表构建完毕）
	start_cover_load()

	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 应用主题色（由 ThemeManager 广播调用 + 首次自调）
func apply_theme() -> void:
	if not ThemeMGR:
		return
	var surface_high := ThemeMGR.get_color("surface_high")
	var border := ThemeMGR.get_color("border")
	# 卡片四态（保留 tscn 预设的圆角/边框宽度/阴影，仅就地改色）
	for state in ["normal", "hover", "pressed"]:
		var sb := get_theme_stylebox(state)
		if sb is StyleBoxFlat:
			sb.bg_color = ThemeMGR._tint_keep_alpha(surface_high, sb.bg_color.a)
			sb.border_color = border
	# 封面底板
	var cover_panel := get_node_or_null("CoverPanel") as Panel
	if cover_panel:
		ThemeMGR._style_panel_set_bg_color(cover_panel, surface_high)
	# 注：封面底部浮层（深色渐隐）上的 MidiName/Author 的固定浅色由 .tscn 的 font_color override 提供
	# （TextScrollHelper 会锁定场景显式色），此处不再重复设置，避免与脚本刷新冲突

# 设置midi数据 传入无效值时重置
func set_display(midi: MidiData = null) -> void:
	var midi_changed: bool = midi_data != midi
	midi_data = midi
	var enable:bool = true if midi else false
	get_node("CoverPanel").visible = enable
	get_node("InfoPanel").visible = enable
	if enable:
		title_text.set_scroll_text(midi.name)
		author_text.text = midi.artist_name
		uploader.text = midi.uploader_name
		album_name.set_scroll_text(midi.album_name if not midi.album_name.is_empty() else "null")
		song_name.set_scroll_text(midi.song_name if not midi.song_name.is_empty() else "null")
	# midi 变化（含从 null 切到非 null）时刷新封面
	if midi_changed:
		if enable:
			# 切到新 midi：保留旧 texture 显示直到新封面加载完成
			switch_cover_data()
			start_cover_load()
		else:
			# 切到 null：彻底释放封面 texture，避免不可见项持有 Texture 引用阻止 GC
			release_cover()
	init_finished.emit()

## 重写基类虚函数：返回 MIDI 封面 Texture2D
func _get_cover_texture() -> Texture2D:
	if not midi_data:
		return null
	return FileSystemManager.instance.get_cover_by_midiData(midi_data)

## 重写基类虚函数：返回封面文件路径（主线程调用，供异步加载器使用）
func _resolve_cover_path() -> String:
	if not midi_data:
		return ""
	var fs_mgr := FileSystemManager.instance
	if not fs_mgr:
		return ""
	return fs_mgr.get_cover_path_by_midiData(midi_data)

## 设置远程 chart 数据显示（从服务端列表获取）
func set_remote_display(chart_data: Dictionary) -> void:
	self.chart_data = chart_data
	chart_hash = str(chart_data.get("hash", ""))
	is_remote_chart = true
	download_state = ResMGR.get_download_state(chart_hash)

	# 填充显示字段
	title_text.set_scroll_text(str(chart_data.get("title", "Unknown")))
	# MIG-1（2026-10-22）：服务端 ArtistName 已移除，MIDI 作者改读 midiAuthor
	author_text.text = str(chart_data.get("midiAuthor", ""))
	uploader.text = "Upload by " + str(chart_data.get("uploaderName", ""))
	album_name.set_scroll_text(str(chart_data.get("albumName", "null")))
	_original_song_name = str(chart_data.get("songName", "null"))
	song_name.set_scroll_text(_original_song_name)

	get_node("CoverPanel").visible = true
	get_node("InfoPanel").visible = true

	# 更新下载状态显示
	_update_download_state_ui()

	# 加载远程封面
	_load_remote_cover(chart_hash)

	init_finished.emit()

## 下载预取字段：商店列表项已带 ChartResponse 全量（列表/详情同源），
## 提取四键供 ResourceManager 三请求并行（元数据/MIDI/封面同时发起）。
## 非远程项或数据缺失时返回空字典 → 下载走串行回退路径
func get_download_hint() -> Dictionary:
	if not is_remote_chart or chart_data.is_empty():
		return {}
	return {
		"fileSize": int(chart_data.get("fileSize", 0)),
		"hasCover": bool(chart_data.get("hasCover", false)),
		"songName": str(chart_data.get("songName", "")),
		"difficulty": str(chart_data.get("difficulty", "")),
	}

## 更新下载状态的 UI 显示
func _update_download_state_ui() -> void:
	# 根据下载状态更新 song_name 标签文字
	# 已下载：显示 ▶ 前缀提示可游玩
	# 未下载：显示"点击下载"
	# 下载中：显示"下载中..."（带脉冲动画）
	# 失败：显示"下载失败，点击重试"
	match download_state:
		ResourceManager.DownloadState.DOWNLOADED:
			_stop_pulse_animation()
			# 显示播放图标前缀，提示可点击游玩；保留 set_remote_display 中设置的原始歌曲名
			# ⚠️ 曲名为空（服务端 songName 为空串，键存在故 .get 默认值不生效）时
			# 不能跳过 set_scroll_text，否则文本停留在"下载中..."——
			# 下载完成了 UI 却不刷新（2026-10-24 修复）
			var song_label := _original_song_name if not _original_song_name.is_empty() else "点击游玩"
			song_name.set_scroll_text("▶ " + song_label)
		ResourceManager.DownloadState.DOWNLOADING:
			song_name.set_scroll_text("下载中...")
			_start_pulse_animation()
		ResourceManager.DownloadState.NOT_DOWNLOADED:
			_stop_pulse_animation()
			song_name.set_scroll_text("点击下载")
		ResourceManager.DownloadState.FAILED:
			_stop_pulse_animation()
			song_name.set_scroll_text("下载失败，点击重试")

## 下载阶段 → 进度文案（与 ResourceManager.DownloadStage 对应）
func _stage_text(stage: int) -> String:
	match stage:
		ResourceManager.DownloadStage.METADATA:
			return "正在获取谱面信息"
		ResourceManager.DownloadStage.COVER:
			return "正在下载封面"
		ResourceManager.DownloadStage.MIDI:
			return "正在下载midi文件"
		ResourceManager.DownloadStage.JSON:
			return "正在写入谱面信息"
		ResourceManager.DownloadStage.RESCAN:
			return "正在刷新本地曲库"
	return "下载中"

## 更新下载进度显示（DOWNLOADING 期间的详细信息，由 StoreView 经 ResMGR 回调驱动）
## stage: ResourceManager.DownloadStage；percent: 0.0~1.0，<0 表示该阶段无字节进度
func set_download_progress(stage: int, percent: float) -> void:
	# 非下载中状态忽略：防完成前的迟到 tick 覆盖"▶ ..."终态文本
	if download_state != ResourceManager.DownloadState.DOWNLOADING:
		return
	var text := _stage_text(stage)
	if percent >= 0.0:
		text = "%s %d%%" % [text, int(round(percent * 100.0))]
	song_name.set_scroll_text(text)

## 启动脉冲动画（下载中提示）
func _start_pulse_animation() -> void:
	_stop_pulse_animation()
	var tween := AniMGR.create_managed_tween(self)
	tween.set_loops()
	tween.tween_property(song_name, "modulate:a", 0.3, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(song_name, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_pulse_tween = tween

## 停止脉冲动画
func _stop_pulse_animation() -> void:
	if _pulse_tween and _pulse_tween.is_valid():
		_pulse_tween.kill()
		_pulse_tween = null
	song_name.modulate.a = 1.0

## 从服务端加载远程封面
func _load_remote_cover(target_hash: String) -> void:
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	if cover_texture:
		cover_texture.visible = false
	var cover_url := "%s/api/charts/%s/cover" % [NetManager.instance.server_url, target_hash]
	HttpImageLoader.load(cover_url, self, func(tex: Texture2D) -> void:
		if not is_instance_valid(self):
			return
		if tex and cover_texture:
			cover_texture.texture = tex
			cover_texture.visible = true
	)

## 刷新下载状态（供 StoreView 下载完成后调用）
func refresh_download_state() -> void:
	if is_remote_chart and not chart_hash.is_empty():
		download_state = ResMGR.get_download_state(chart_hash)
		_update_download_state_ui()

func _exit_tree() -> void:
	_stop_pulse_animation()
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)
