## MIDI列表项组件
## 继承自 CoverListItemBase，显示MIDI谱面信息（封面走 CoverLoader 异步加载）
extends CoverListItemBase

## 引用节点
@onready var status_label: Label = $VBoxC/HBoxC/status
@onready var midi_name_label: Label = $VBoxC/MidiName
@onready var author_label: Label = $VBoxC/HBoxC/Author
@onready var upload_info_label: Label = $UploadInfo

## MIDI数据
var midi_data: MidiData

## 展开动画补间
var expand_tween: Tween

var INDICATOR = PathRegistry.MIDI_VIEW_INDICATOR

## ========== 信息缓存（静态，跨实例共享）==========
## schema: { midi_id: { "time_str", "bpm_timeline", "timebase",
##                      "note_str"?, "mpp_str"? } }
## note_str / mpp_str 键缺席 → 需（重新）计算 Note 数量
static var _info_cache: Dictionary = {}

## 配置去抖：同一帧内多次 config_changed（切换难度写多个 Generator 键）合并为一次重算，
## 避免每次写键各自触发一次全量 generate_keys 造成主线程卡顿
var _recompute_pending: bool = false

func _ready() -> void:
	# MidiListItem 不使用封面视差滚动（封面静态显示，与 SongListItem 一致）
	_parallax_enabled = false
	# 给基类 cover_texture 赋值，启用 CoverLoader 异步加载/释放机制
	cover_texture = $cover
	if EvtBus:
		EvtBus.config_changed.connect(_on_config_changed)
	if UiStatMGR:
		UiStatMGR.state_changed.connect(_on_ui_state_changed)

func _update_display() -> void:
	# 初始化显示
	if not status_label:
		status_label = get_node("VBoxC/HBoxC/status")
	if not midi_name_label:
		midi_name_label = get_node("VBoxC/MidiName")
	if not author_label:
		author_label = get_node("VBoxC/HBoxC/Author")
	if not upload_info_label:
		upload_info_label = get_node("UploadInfo")
	status_label.text = midi_data.status
	midi_name_label.set_scroll_text(midi_data.name)
	author_label.text = midi_data.artist_name if not midi_data.artist_name.is_empty() else "Unknown"
	upload_info_label.text = "%s ● %s" % [_format_upload_date(midi_data.uploaded_date), midi_data.uploader_name]


## 将上传时间（UTC）转为东八区日期 "YYYY-MM-DD"；无法解析时回退原字符串前 10 位
func _format_upload_date(raw: String) -> String:
	var s := raw.strip_edges().trim_suffix("Z")
	if s.length() < 10:
		return s
	var ymd := s.substr(0, 10).split("-")
	if ymd.size() != 3:
		return s.substr(0, 10)
	var year := int(ymd[0])
	var month := int(ymd[1])
	var day := int(ymd[2])
	# 解析时分（兼容 "T" 或空格分隔，忽略秒/小数）
	var hour := 0
	var minute := 0
	if s.length() >= 16:
		var t := s.substr(11, 5).split(":")
		if t.size() >= 2:
			hour = int(t[0])
			minute = int(t[1])
	# UTC 加 8 小时 → 东八区墙钟
	minute += 8 * 60 + hour * 60
	@warning_ignore("integer_division")
	day += minute / (24 * 60)
	minute %= 60
	while day > _days_in_month(year, month):
		day -= _days_in_month(year, month)
		month += 1
		if month > 12:
			month = 1
			year += 1
	return "%04d-%02d-%02d" % [year, month, day]


func _days_in_month(year: int, month: int) -> int:
	const DAYS := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if month == 2 and (year % 400 == 0 or (year % 4 == 0 and year % 100 != 0)):
		return 29
	return DAYS[month - 1]


## 从MidiData初始化显示
func setup_with_midi(parent: MidiView, midi: MidiData, index: int, bg: ButtonGroup) -> void:
	midi_data = midi
	item_id = midi.id
	item_type = "midi"
	item_index = index

	button = self
	button.button_group = bg

	init_btn(button, parent)

	_update_display()
	# 启动封面异步加载（命中 WeakRef 缓存时同步应用零开销；未命中入 CoverLoader 队列）
	# 替代旧版同步 Image.load_from_file：6 万音符 MIDI 视图滚动时主线程不再读盘阻塞
	start_cover_load()

	btn_confirmed.connect(parent._show_midi_list)

	# if index == 0:
	# 	button.button_pressed = true

## 重写基类虚函数：返回封面文件路径（主线程调用，供异步加载器使用）
## 路径查询在主线程完成，后台线程只负责读盘
func _resolve_cover_path() -> String:
	if not midi_data:
		return ""
	var fs_mgr := FileSystemManager.instance
	if not fs_mgr:
		return ""
	return fs_mgr.get_cover_path_by_midiData(midi_data)

## 按钮切换回调
func on_item_button_toggled(toggled_on: bool):
	if not parent_node.current_midis.size() > 1 and not toggled_on:
		return
	# 展开状态下：按钮保持 pressed 却收到 false toggle → 拖拽取消，忽略
	#（ButtonGroup 正常切项时按钮会变 unpressed，只有拖拽才会有 pressed + false 的状态矛盾）
	if not toggled_on and not parent_node._collapsed and button.button_pressed:
		return
	# 更新该项的指示器颜色（开=高亮暗色，关=亮色，随主题）
	var indicator_node := get_node(INDICATOR)
	AniMGR.create_managed_tween(self).tween_property(indicator_node.get_child(item_index), "color", parent_node.get_indicator_color(toggled_on), 0.15)
	if toggled_on:
		# 切换到新 MIDI 项时，清理上一个 MIDI 的运行时缓存（parsed_notes + GameSequence + 播放管理器）
		# 避免浏览多个大 MIDI 后 parsed_notes 累积导致内存增长
		if parent_node.selected_item != -1 and parent_node.selected_item != item_index:
			var prev_midi = parent_node.get_selection()
			if prev_midi != null:
				parent_node.cleanup_midi_cache(prev_midi)
		parent_node.selected_item = item_index
		# 收起状态点击 → 自动展开全部；展开状态 → 直接吸附
		if parent_node._collapsed:
			parent_node._show_midi_list(item_index)
		else:
			parent_node.need_snap = true
			# 指示器移到新选中项（统一走 MidiList 的偏移计算，避免两处写死值不一致）
			AniMGR.create_managed_tween(self).tween_property(indicator_node, "offset_transform_position:y", parent_node._compute_indicator_offset(item_index), 0.35)
		_update_data_display()

## 设置展开/收起（由 MidiList._show_midi_list 批量调用）
func set_expanded(expanded: bool) -> void:
	if expand_tween:
		expand_tween.kill()
	# UploadInfo 仅展开时显示
	upload_info_label.visible = expanded
	var expa := 1 if expanded else 0
	expand_tween = AniMGR.create_managed_tween(self)
	expand_tween.set_ease(Tween.EASE_OUT)
	expand_tween.set_trans(Tween.TRANS_QUINT)
	expand_tween.set_parallel(true)
	expand_tween.tween_property(self, "custom_minimum_size", Vector2(self.custom_minimum_size.x, 150 + 250 * expa), 0.35)
	expand_tween.tween_property(midi_name_label, "theme_override_font_sizes/font_size", 30 + 10 * expa, 0.25)
	# 指示器颜色（选中=高亮暗色，其余=亮色，随主题）
	var indicator_node := get_node(INDICATOR)
	var highlight = expanded and (parent_node.selected_item == item_index)
	expand_tween.tween_property(indicator_node.get_child(item_index), "color", parent_node.get_indicator_color(highlight), 0.15)
	expand_tween.finished.connect(func():
		expand_tween.kill()
		expand_tween = null
	)


## 更新信息面板（入口）
func _update_data_display() -> void:
	var info_node: Control = get_node_or_null(PathRegistry.MIDI_VIEW_DETAIL_DATA)
	var description: RichTextLabel = get_node_or_null(PathRegistry.MIDI_VIEW_DESCRIPTION)
	if not (info_node and description):
		push_error("[MidiNode] Info Set Failed")
		return

	description.text = midi_data.description

	# --- 文件状态（无需解析，选中即刷新）---
	_refresh_file_data(info_node)

	# --- 缓存/计算数据 ---
	var entry: Dictionary = _info_cache.get(midi_data.id, {})

	info_node.get_node("PC1/BasicData/Duration").text = entry.get("time_str", "...")
	info_node.get_node("PC1/BasicData/Note").text = entry.get("note_str", "...")
	info_node.get_node("PC1/BasicData/NotePerMinute").text = entry.get("mpp_str", "...")

	# 如果缓存不完整，后台触发计算
	if not entry.has("time_str") or not entry.has("note_str"):
		_start_midi_compute()


## 刷新文件状态：TrackCtn / MidiHash / VocalState
func _refresh_file_data(info_node: Control) -> void:
	if not midi_data:
		return
	# TrackCtn：解析完成前可能无数据，显示占位
	info_node.get_node("PC2/FileData/TrackCtn").text = _format_track_count(midi_data)
	# MidiHash：midi 文件 md5（与曲包目录 {hash}_ 一致）
	info_node.get_node("PC2/FileData/MidiHash").text = midi_data.file_hash if not midi_data.file_hash.is_empty() else "—"
	# VocalState：解析人声路径后按 无文件/禁用/启用 显示状态
	info_node.get_node("PC2/FileData/VocalState").text = _get_vocal_state_text()


## 统计当前 MIDI 的轨道数量（= TrackView 解析出的非空 (track, channel) 轨道数）
func _format_track_count(midi: MidiData) -> String:
	var groups := midi.runtime_track_channel_notes
	var count := 0
	for key in groups:
		if not groups[key].is_empty():
			count += 1
	# 缓存字典可能缺失或带空分组（preparse/load_midi 缓存路径未同步时），
	# SOA 就绪且统计为 0 时直接从 SOA 重建并回写，确保轨道数可靠
	if count == 0 and midi.notes_soa != null and midi.notes_soa.size() > 0:
		groups = midi.notes_soa.grouped_indices()
		midi.runtime_track_channel_notes = groups
		count = 0
		for key in groups:
			if not groups[key].is_empty():
				count += 1
	if count <= 0:
		return "—"
	return "%d TRACK%s" % [count, "" if count == 1 else "S"]


## 计算人声状态文案：No Vocal File / Vocal Disabled / Vocal Enabled
func _get_vocal_state_text() -> String:
	# 复用 TrackView 的人声路径检测逻辑（检测已移至 MidiView）
	var resolved := VocalTrackController.resolve_vocal_path(midi_data)
	if resolved.is_empty():
		return "No Vocal File"
	return "Vocal Enabled" if midi_data.vocal_enabled else "Vocal Disabled"


## 触发后台计算（若已有解析结果则仅重算 Note，否则先解析再算）
func _start_midi_compute() -> void:
	var midi := midi_data
	if midi == null:
		return

	# 若音符数据已就绪（SOA 或旧对象路径；之前解析过或 PlaybackDisplay 加载过），直接算 Note 数量
	if midi.duration_ms > 0 and midi.has_notes():
		var entry: Dictionary = _info_cache.get(midi.id, {})
		# 补全 time 缓存（可能之前没建过）
		if not entry.has("time_str"):
			_fill_time_cache(midi, entry)
			_info_cache[midi.id] = entry
		# 重算 Note / MPP
		_compute_and_cache_notes(midi)
		return

	# 需要解析 MIDI 文件 ─ 交给 PlaybackDisplay 统一解析：
	# ensure_parsed 命中 C# 解析缓存时几乎零开销，未命中才真正解析。
	# 解析主体在 C#（纯 .NET、无场景树访问），故同步调用即可。
	var pm := PlaybackDisplay.instance
	if pm == null:
		return
	var ok: bool = pm.ensure_parsed(midi)

	if not ok:
		_info_cache[midi.id] = {"time_str": "—", "note_str": "—", "mpp_str": "—"}
		_apply_display()
		return

	# 构建并缓存 Time 字段（ensure_parsed 已回填 duration_ms/bpm_timeline 等）
	var entry: Dictionary = _info_cache.get(midi.id, {})
	_fill_time_cache(midi, entry)
	_info_cache[midi.id] = entry

	# 立即刷新均衡数据（Note 还没算完，先显示 ...）
	_apply_display()

	# 计算 Note / MPP（主线程，同步执行，游戏未运行时安全）
	_compute_and_cache_notes(midi)


## 填写 time_str（时长）与 bpm_timeline/timebase 到给定字典（不含 Note）
func _fill_time_cache(midi: MidiData, entry: Dictionary) -> void:
	# 时长
	if midi.duration_ms > 0:
		var s := int(midi.duration_ms / 1000.0)
		@warning_ignore("integer_division")
		entry["time_str"] = "%d:%02d" % [s / 60, s % 60]
	else:
		entry["time_str"] = "—"

	# 获取 bpm_timeline：优先使用 MidiData 自持，其次 PlaybackDisplay
	var timeline: Array = midi.bpm_timeline
	if timeline.is_empty():
		var pm := PlaybackDisplay.instance
		if pm and pm.current_midi_data == midi:
			timeline = pm.bpm_timeline

	# 缓存时间轴以供 Note 计算时传参
	entry["bpm_timeline"] = timeline
	entry["timebase"] = midi.midi_timebase


## 在主线程计算 Note / MPP 并写入缓存，完成后刷新显示
func _compute_and_cache_notes(midi: MidiData) -> void:
	var ksm := KeySequenceManager.instance
	if ksm == null or not midi.has_notes():
		return

	# 计算前先确保轨道配置已按简介完成初始化（幂等）：
	# 若首次进入 MidiView 时仍未初始化，统计口径会退化为"全部轨道"，
	# 与 TrackView / PlayView 的"按简介推荐轨道"不一致。
	var pm := PlaybackDisplay.instance
	if pm != null and not midi.is_track_config_initialized():
		pm.ensure_track_config_initialized(midi, midi.parsed_notes)

	# 构建 (track, channel) 启用集合，键格式："track:channel"
	# 走到这里时 _track_config_initialized 通常已为 true（ensure_track_config_initialized 幂等保证）；
	# 仅当 pm 不可用等极端情况下才保留 false=全部启用的兜底语义。
	# 注意：不能把 selected_track_configs 非空当作"已初始化"。from_json 曾为新 MIDI 写入占位
	# {0:[0]}，若据此过滤，音符全在第 1 轨之后的谱面（如 issue #62 的成对的神兽，音符在
	# track1/2）会在首次进入 MidiView 时错误显示 0 音符 / "-" NPM。
	var configs_initialized: bool = midi.is_track_config_initialized()
	var enabled_pairs: Dictionary = midi.get_enabled_pairs_flat() if configs_initialized else {}

	# 声明 entry 变量，传递缓存数据
	var entry: Dictionary = _info_cache.get(midi.id, {})
	
	# 全部禁用时直接写 0，不需要走 generate_keys
	if configs_initialized and enabled_pairs.is_empty():
		entry["note_str"] = "0"
		entry["mpp_str"] = "—"
		_info_cache[midi.id] = entry
		_apply_display()
		return

	# 按 (track, channel) 筛选音符：解析数据在 C# MidiCore 缓存，这里只取启用子集索引
	var path := midi.midi_file_path
	var enabled_indices: PackedInt32Array
	if not path.is_empty() and MidiCore.HasParsed(path):
		if configs_initialized:
			enabled_indices = MidiCore.GetEnabledIndices(path, midi.get_enabled_pair_keys())
		else:
			# 未初始化（极端兜底：如 pm 不可用）：全部纳入
			enabled_indices = MidiCore.GetAllIndices(path)
	else:
		enabled_indices = []

	if enabled_indices.is_empty():
		entry["note_str"] = "0"
		entry["mpp_str"] = "—"
		_info_cache[midi.id] = entry
		_apply_display()
		return

	# 异步生成（WorkerThreadPool 后台线程）；C# 直读其解析缓存，
	# cache_key 与 PlayView 喂法一致可互相命中
	var task_id := await ksm.generate_keys_async(
		path, enabled_indices, midi.id,
		midi.midi_timebase, midi.bpm_timeline
	)
	if task_id >= 0:
		await ksm.await_generate_keys(task_id)

	# 切换项守卫：await 期间用户可能已切到其他 MIDI 项，本 item 不再是选中项
	# 仍写入 _info_cache（缓存供下次使用），但 _apply_display 会自行判断是否刷新共享面板
	var count: int = ksm.seq_count()
	if count > 0 and midi.duration_ms > 0:
		entry["note_str"] = "%d" % count
		entry["mpp_str"] = "%.1f" % (count / (midi.duration_ms / 60000.0))
	else:
		entry["note_str"] = "%d" % count
		entry["mpp_str"] = "—"

	_info_cache[midi.id] = entry
	_apply_display()


## 将当前 midi_data 的缓存内容刷新到信息面板（仅当本 item 为选中项时有效）
func _apply_display() -> void:
	if not is_inside_tree() or midi_data == null:
		return
	if parent_node == null or parent_node.selected_item != item_index:
		return # 本 item 未展开，无需刷新共享面板

	var info_node: Control = get_node_or_null(PathRegistry.MIDI_VIEW_DETAIL_DATA)
	if info_node == null:
		return

	# 文件状态（解析完成后 TrackCtn 等才有数据）
	_refresh_file_data(info_node)

	var entry: Dictionary = _info_cache.get(midi_data.id, {})
	info_node.get_node("PC1/BasicData/Duration").text = entry.get("time_str", "...")
	info_node.get_node("PC1/BasicData/Note").text = entry.get("note_str", "...")
	info_node.get_node("PC1/BasicData/NotePerMinute").text = entry.get("mpp_str", "...")


## 配置变更：仅影响 Note 数量/连接关系的字段才清除缓存并重算
## Appearance 段中只有 generate_short_connect / generate_instant_connect / instant_connect_max_time / block_size
## 会影响谱面（连接合并、尺寸换算），block_skin_preset 等纯贴图字段不应触发重算
func _on_config_changed(key: String, section: String, _value: Variant) -> void:
	var should_recompute := false
	match section:
		"Generator", "Lane":
			should_recompute = true
		"Appearance":
			# 仅这些字段影响 Note 数量或 MPP 显示
			should_recompute = key in [
				"generate_short_connect",
				"generate_instant_connect",
				"instant_connect_max_time",
				"block_size",
			]
	if not should_recompute:
		return
	for mid_id in _info_cache.keys():
		_info_cache[mid_id].erase("note_str")
		_info_cache[mid_id].erase("mpp_str")
	# 若本 item 正展开，标记待重算并去抖：同一帧内多次配置变更只触发一次后台重算
	if parent_node and parent_node.selected_item == item_index and midi_data != null:
		var info_node = get_node_or_null(PathRegistry.MIDI_VIEW_DETAIL_DATA)
		if info_node:
			info_node.get_node("PC1/BasicData/Note").text = "..."
			info_node.get_node("PC1/BasicData/NotePerMinute").text = "..."
		_schedule_recompute()

## 配置变更后延迟到下一帧重算 Note（同一帧内多次 config_changed 合并为一次），
## 切换难度时 option_ui 会连续写 6 个 Generator 键，若不合并。
## 每次都会触发全量 generate_keys（66k 音符各阻塞主线程 200-800ms，累加即"卡好几秒"）。
func _schedule_recompute() -> void:
	if _recompute_pending:
		return
	_recompute_pending = true
	await get_tree().process_frame
	_recompute_pending = false
	if not is_inside_tree() or midi_data == null:
		return
	_start_midi_compute()


## 状态切换：从 TRACK_VIEW 返回 MIDI_VIEW → 轨道启用状态可能已变，清除 Note 缓存
func _on_ui_state_changed(old_state: UIStateManager.UIState, new_state: UIStateManager.UIState) -> void:
	if old_state == UIStateManager.UIState.TRACK_VIEW \
			and new_state == UIStateManager.UIState.MIDI_VIEW:
		for mid_id in _info_cache.keys():
			_info_cache[mid_id].erase("note_str")
			_info_cache[mid_id].erase("mpp_str")
		# 若本 item 正展开，立即重触发
		if parent_node and parent_node.selected_item == item_index and midi_data != null:
			var info_node = get_node_or_null(PathRegistry.MIDI_VIEW_DETAIL_DATA)
			if info_node:
				info_node.get_node("PC1/BasicData/Note").text = "..."
				info_node.get_node("PC1/BasicData/NotePerMinute").text = "..."
				# 人声开关/导入可能已变，立即刷新文件状态
				_refresh_file_data(info_node)
			# parsed_notes 已有，直接重算（不用启线程）
			_start_midi_compute()
