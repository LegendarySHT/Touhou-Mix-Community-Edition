## MIDI视图
## 显示选中歌曲下的所有MIDI谱面列表
extends BaseScrollList

class_name MidiView

## 当前显示的MIDI列表
var current_midis: Array[MidiData] = []

var last_selection:int = -1 # 上一次选中的节点
var _collapsed: bool = false # 列表是否处于收起状态
var _prev_scroll: int = 0  # 上帧滚动位置，变化说明有人在动列表

@onready var indicator = get_node(PathRegistry.MIDI_VIEW_INDICATOR)
@onready var  previ_btn = get_node(PathRegistry.MIDI_VIEW_PREVI_BTN)
@onready var info_btn = get_node(PathRegistry.MIDI_VIEW_INFO_BTN)

# MidiView
@onready var midi_view = get_node(PathRegistry.MIDI_VIEW)

func _ready() -> void:
	work_state = UIStateManager.UIState.MIDI_VIEW
	snap_offset_y = 0
	# 设置直接相邻状态：切到不在此集合的状态时释放所有列表项封面
	# MIDI_VIEW 相邻：SONG_VIEW（返回歌曲列表）、TRACK_VIEW/PLAY_VIEW/SCORE_VIEW（演奏流程）
	# 切到 ALBUM_VIEW（级联删除跳转）/ SORTED_VIEW / STORE_VIEW / SETTINGS_VIEW 时释放封面
	set_adjacent_states([
		UIStateManager.UIState.SONG_VIEW,
		UIStateManager.UIState.TRACK_VIEW,
		UIStateManager.UIState.PLAY_VIEW,
		UIStateManager.UIState.SCORE_VIEW,
	])

	super._ready()

	# 注册主题应用者：指示点颜色随主题刷新（选中=暗色，未选中=亮色）
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）：刷新全部指示点颜色
func apply_theme() -> void:
	_apply_indicator_colors()

## 指示点颜色：active（选中）= text_primary，inactive = text_primary 半透明。
## 用 text_primary 而非写死白色，浅色模式下才会自动翻成深色点（写死白色在浅底上不可见）
func get_indicator_color(active: bool) -> Color:
	if ThemeMGR:
		var tp := ThemeMGR.get_color("text_primary")
		return tp if active else Color(tp.r, tp.g, tp.b, 0.28)
	return Color.WHITE if active else Color(1, 1, 1, 0.16)

## 按选中态刷新全部指示点颜色
func _apply_indicator_colors() -> void:
	if not is_instance_valid(indicator):
		return
	for i in indicator.get_child_count():
		var point := indicator.get_child(i) as ColorRect
		if point:
			point.color = get_indicator_color(i == selected_item)

# 加载midi
## preferred_id 非空时（导航恢复预选），构建完成后选中对应 midi；找不到或为空则默认选中第一项
func load_midi(midis: Array[MidiData], preferred_id: String = "") -> void:
	current_midis = midis
	_refresh_display()
	_setup_focus_neighbor()
	
	await get_tree().process_frame
	_collapsed = false
	_prev_scroll = scroll_vertical  # 重置滚动追踪
	if preferred_id != "":
		var target := -1
		for i in current_midis.size():
			if current_midis[i].id == preferred_id:
				target = i
				break
		select_item(target if target >= 0 else 0)
	else:
		select_item(0)
	for item in list_items:
		item.set_expanded(true)
	need_snap = true

func _setup_focus_neighbor():
	if container == null:
		return

	var left_node_path = previ_btn.get_path()
	var right_node_path = info_btn.get_path()
	
	var ln = container.get_child(-1).button
	var cn
	for i in container.get_children():
		cn = i.button
		ln.focus_neighbor_bottom = cn.get_path()

		cn.focus_neighbor_left = left_node_path
		cn.focus_neighbor_right = right_node_path
		cn.focus_neighbor_top = ln.get_path()
		ln = cn

# 返回当前的选择
func get_selection() -> MidiData:
	if selected_item == -1:
		GLogger.warning("未选择Midi", "MidiList")
		return null

	return current_midis[selected_item]

## 清理指定 MIDI 的运行时缓存（parsed_notes + GameSequence + 播放管理器）
## 用于切换 MidiList 项或离开 MidiView 时释放内存，避免浏览多个大 MIDI 后累积
## 注意：仅当 pm.current_midi_data == midi 时才 unload，避免误清其他 MIDI 的播放状态
func cleanup_midi_cache(midi: MidiData) -> void:
	if midi == null:
		return
	var ksm := KeySequenceManager.instance
	if ksm != null:
		ksm.clear_sequences()
	var pm := MidiPlaybackManager.instance
	if pm != null and pm.current_midi_data == midi and pm.has_method("unload_midi"):
		pm.unload_midi()
	midi.clear_parsed_notes()

func get_focus_node_path() -> NodePath:
	var node = get_selected_node()
	if node:
		return node.button.get_path()
	return ""

## 清空列表
func _clear_list() -> void:
	clear_items()

	# 清空指示器
	if indicator:
		for child in indicator.get_children():
			child.free() # 因为初始化指示器时根据索引位置来设置颜色的，所以得立即清除

	selected_item = -1

## 展开状态下被滚动了 → 立即收起
func _process(delta):
	super._process(delta)
	if not _collapsed and not _snap_active and scroll_vertical != _prev_scroll:
		_show_midi_list()
	_prev_scroll = scroll_vertical

func _show_midi_list(_index: int = -1) -> void:
	if current_midis.size() == 1:
		return
	if not _collapsed:
		# 展开 → 收起全部
		_collapsed = true
		if selected_item != -1:
			last_selection = selected_item
			get_selected_node().button.button_pressed = false
		selected_item = -1
		for item in list_items:
			item.set_expanded(false)
		need_snap = false
	else:
		# 收起 → 展开全部
		_collapsed = false
		_prev_scroll = scroll_vertical  # 重置滚动追踪
		var target := _index if _index >= 0 else last_selection
		if target >= 0 and target < list_items.size():
			selected_item = target
			last_selection = target
			get_selected_node().button.button_pressed = true
		for item in list_items:
			item.set_expanded(true)
		need_snap = true
		# 指示器移到选中项
		if indicator and selected_item != -1:
			AniMGR.create_managed_tween(self).tween_property(indicator, "offset_transform_position:y", _compute_indicator_offset(selected_item), 0.35)

func _previous() -> void:
	if current_midis.size() != 1:
		select_item(selected_item - 1)

func _next() -> void:
	if current_midis.size() != 1:
		select_item(selected_item + 1)

## 计算指示器偏移
func _compute_indicator_offset(index: int) -> float:
	var pitch: int = 29
	var count: int = indicator.get_child_count()
	if count <= 1:
		return 0.0
	@warning_ignore("integer_division")
	return (int(count / 2) - index) * pitch + pitch / 2

## 刷新显示
func _refresh_display() -> void:
	# 清空现有项
	_clear_list()

	# 添加新项
	var counter = 0
	var bg = ButtonGroup.new()

	for midi in current_midis:
		var item = create_and_add_item(midi.id, "midi")
		if item:
			# 添加指示器点
			var point = ColorRect.new()
			point.name = "Indicator"
			point.custom_minimum_size = Vector2(20, 20)
			point.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			point.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			point.color = get_indicator_color(false)

			indicator.add_child(point)

			item.setup_with_midi(self, midi, counter, bg)
			counter += 1
	# 首次默认选第一项后，按选中态统一着色
	_apply_indicator_colors()

func remove_selected_midi():
	var removed_index = selected_item
	current_midis.erase(get_selection())
	_refresh_display()
	_setup_focus_neighbor()

	if not list_items.size():
		UiStatMGR.go_back()
		return

	# 重建后默认选中并展开剩余项（与 load_midi 行为一致）
	await get_tree().process_frame
	_collapsed = false
	_prev_scroll = scroll_vertical
	var target = mini(removed_index, list_items.size() - 1)
	select_item(target)
	for item in list_items:
		item.set_expanded(true)
	if indicator:
		indicator.offset_transform_position.y = _compute_indicator_offset(selected_item)
	need_snap = true
