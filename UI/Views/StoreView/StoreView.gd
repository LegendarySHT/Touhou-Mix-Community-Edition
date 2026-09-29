extends BaseScrollList

class_name StoreView

@onready var _top_bar: Control = get_parent().get_node("TopBar")
@onready var _bottom_bar: Control = get_parent().get_node("Bottom")

var _top_tween: Tween
var _bottom_tween: Tween
var _scroll_tween: Tween
var _top_visible := false
var _bottom_visible := false
var _last_scroll_vertical := 0

# 分页与远程加载状态
var _current_page: int = 1
var _total_charts: int = 0
var _page_limit: int = 20
var _is_loading: bool = false

# 搜索 / 排序状态
var _current_search: String = ""
var _current_sort: String = "uploaded_at"   # uploaded_at | download_count | play_count | like_count
var _current_order: String = "desc"          # asc | desc
var _search_debounce: SceneTreeTimer = null

# FilterBtn 选项 → 后端 sort 字段名映射
const _SORT_FIELDS := ["uploaded_at", "download_count", "play_count", "like_count"]

## 提示信息 Label（离线/连接失败/加载失败时显示在内容区域中央，替代本地示例数据）
var _message_label: Label = null

func _ready() -> void:
	work_state = UIStateManager.UIState.STORE_VIEW
	# 设置直接相邻状态：切到不在此集合的状态时释放所有列表项封面
	# STORE_VIEW 相邻：ALBUM_VIEW（侧栏返回）
	set_adjacent_states([
		UIStateManager.UIState.ALBUM_VIEW,
	])
	super._ready()

	# TopBar/Bottom 的进入动画由 AnimationManager.animate_ui_in("Store_View") 负责，
	# 这里不再设置 offset_top/offset_bottom 或调用 _toggle_top/_toggle_bottom，
	# 避免与 AnimationManager 的 offset_transform_position 动画冲突（懒加载时序下两者同时执行会导致 UI 异常）
	# _toggle_top/_toggle_bottom 仅在 _process 滚动检测时使用

	# 连接分页按钮
	var previ_btn := _bottom_bar.get_node_or_null("Previ") as Button
	var next_btn := _bottom_bar.get_node_or_null("Next") as Button
	if previ_btn and not previ_btn.pressed.is_connected(_on_previ_pressed):
		previ_btn.pressed.connect(_on_previ_pressed)
	if next_btn and not next_btn.pressed.is_connected(_on_next_pressed):
		next_btn.pressed.connect(_on_next_pressed)

	# 连接搜索 / 排序控件（TopBar 内）
	var line_edit := _top_bar.get_node_or_null("C/Search/HBoxC/LineEdit") as LineEdit
	if line_edit:
		if not line_edit.text_changed.is_connected(_on_search_text_changed):
			line_edit.text_changed.connect(_on_search_text_changed)
		if not line_edit.text_submitted.is_connected(_on_search_text_submitted):
			line_edit.text_submitted.connect(_on_search_text_submitted)
	var filter_btn := _top_bar.get_node_or_null("C/FilterBtn") as OptionButton
	if filter_btn and not filter_btn.item_selected.is_connected(_on_filter_selected):
		filter_btn.item_selected.connect(_on_filter_selected)
	var order_btn := _top_bar.get_node_or_null("C/HBoxC/OrderBtn") as TextureButton
	if order_btn and not order_btn.pressed.is_connected(_on_order_pressed):
		order_btn.pressed.connect(_on_order_pressed)

	_load_remote_charts()

	UiStatMGR.state_changed.connect(_on_state)

	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）
func apply_theme() -> void:
	var store := get_parent()
	if not store:
		return
	# TopBar — 垂直渐变 primary → primary_dark
	var topbar := store.get_node_or_null("TopBar") as Panel
	if topbar:
		var sb := topbar.get_theme_stylebox("panel")
		if sb is StyleBoxTexture:
			var tex := sb.texture as GradientTexture2D
			if tex and tex.gradient:
				tex.gradient.set_color(0, ThemeMGR.get_color("primary"))
				tex.gradient.set_color(1, ThemeMGR.get_color("primary_dark"))
	# TopBar/C/Search/Base — 四点 vertex_colors
	var search_base := store.get_node_or_null("TopBar/C/Search/Base") as Polygon2D
	if search_base:
		var p := ThemeMGR.get_color("primary")
		var pd := ThemeMGR.get_color("primary_dark")
		search_base.vertex_colors = PackedColorArray([
			p.lightened(0.1), p, pd, p.lightened(0.2),
		])
	# Bottom/Previ + Next — 深色模式用 primary_dark 基调；浅色模式用更亮的 primary，
	# 避免深蓝底配（浅色模式下翻深的）深色文字导致对比不足
	var nav_base := ThemeMGR.get_color("primary") if ThemeMGR.get_appearance() == "light" else ThemeMGR.get_color("primary_dark")
	for btn_name in ["Previ", "Next"]:
		var btn := store.get_node_or_null("Bottom/" + btn_name) as Button
		ThemeMGR._style_button_set_bg_color(btn, nav_base)
	# Bottom/Indicate — 页码标签背景 primary_light
	var indicate := store.get_node_or_null("Bottom/Indicate") as Label
	if indicate:
		var sb := indicate.get_theme_stylebox("normal")
		if sb is StyleBoxFlat:
			sb.bg_color = ThemeMGR.get_color("primary_light")

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)
	# 视图销毁时移除提示 Label，避免孤儿节点
	if _message_label != null:
		_message_label.queue_free()
		_message_label = null

## 从服务端加载 MIDI 列表
## 首次 _ready 和重新进入 STORE_VIEW（列表为空时）调用
## 离线/连接失败/加载失败时显示文字提示，不再回退到本地示例数据
func _load_remote_charts() -> void:
	if _is_loading:
		return
	_is_loading = true

	# 显示加载中状态
	var indicate_loading := _bottom_bar.get_node_or_null("Indicate") as Label
	if indicate_loading:
		indicate_loading.text = "加载中..."

	if ResMGR == null or NetManager.instance == null:
		# 资源/网络管理器未就绪
		_show_message("商店服务不可用")
		_update_page_indicator()
		_is_loading = false
		return

	if not NetManager.instance.is_online:
		# 区分"在线模式未开启"与"连接失败"
		if NetManager.instance.connect_state == NetManager.ConnectState.OFFLINE_MODE:
			_show_message("在线模式未开启")
		else:
			_show_message("无法连接到服务器")
		_update_page_indicator()
		_is_loading = false
		return

	var result: Dictionary = await ResMGR.get_chart_list(
		_current_page, _page_limit, _current_search,
		_current_sort, _current_order
	)

	if not result.get("ok", false):
		# 远程加载失败
		GLogger.warning("Failed to load remote charts: %s" % str(result.get("error", "")), "StoreView")
		_show_message("加载失败，请稍后重试")
		_update_page_indicator()
		_is_loading = false
		return

	# 远程加载成功，隐藏提示并渲染列表
	_hide_message()

	var data: Dictionary = result.data
	_total_charts = int(data.get("total", 0))
	var charts: Array = data.get("charts", [])

	# 清空旧列表项
	clear_items()

	# 为每个 chart 创建列表项
	for chart in charts:
		var store_item := create_and_add_item(str(chart.get("id", "")), "StoreMidiItem") as StoreMidiListItem
		if store_item:
			store_item.set_remote_display(chart)

	_update_page_indicator()
	_is_loading = false
	_last_scroll_vertical = scroll_vertical

## 在内容区域中央显示提示文字（替代离线本地示例数据）
## Label 作为 Store 子节点覆盖在 StoreMidiList 上方，offset 留出 TopBar/Bottom 空间
## 注意：使用 call_deferred 添加节点，因为 _ready 同步阶段父节点仍在构建子节点，
## 直接 add_child 会触发 "Parent node is busy setting up children" 错误
func _show_message(msg: String) -> void:
	clear_items()
	if _message_label == null:
		_message_label = Label.new()
		_message_label.name = "MessageLabel"
		_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_message_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_message_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_message_label.add_theme_font_size_override("font_size", 42)
		# 锚点占满 Store，再用 offset 留出 TopBar（约 180px）和 Bottom（约 100px）的空间
		_message_label.set_anchors_preset(Control.PRESET_FULL_RECT)
		_message_label.offset_top = 180
		_message_label.offset_bottom = -100
		get_parent().add_child.call_deferred(_message_label)
	_message_label.text = msg
	_message_label.visible = true

## 隐藏并移除提示 Label
func _hide_message() -> void:
	if _message_label != null:
		_message_label.queue_free()
		_message_label = null

## 更新分页指示器
func _update_page_indicator() -> void:
	var indicate = get_parent().get_node_or_null("Bottom/Indicate")
	if not indicate:
		return
	# 无数据时显示占位符，避免误导性的 "1/1"
	if _total_charts <= 0:
		indicate.text = "—"
		return
	var total_pages = max(1, ceili(float(_total_charts) / float(_page_limit)))
	indicate.text = "%d/%d" % [_current_page, total_pages]

func _on_state(old: UIStateManager.UIState, new: UIStateManager.UIState) -> void:
	if new == UIStateManager.UIState.STORE_VIEW:
		# 重新进入时若列表项已被 _cleanup 清空，重新加载远程列表
		if list_items.is_empty():
			_load_remote_charts()
		else:
			# 防御：列表项仍存在时（未走 _cleanup 路径），刷新下载状态，
			# 避免本地删除谱面后残留"已下载"显示
			for item in list_items:
				if item and is_instance_valid(item) and item is StoreMidiListItem:
					(item as StoreMidiListItem).refresh_download_state()
		return_to_top()
	# 退出 STORE_VIEW 时释放列表项
	if old == UIStateManager.UIState.STORE_VIEW and new != UIStateManager.UIState.STORE_VIEW:
		_cleanup()

## 释放视图内部资源（列表项 + 提示 Label），保留节点壳和信号连接
## 重新进入时由 _on_state 检测列表为空并调用 _load_remote_charts 重新加载
func _cleanup() -> void:
	clear_items()
	_hide_message()

func return_to_top() -> void:
	if _scroll_tween and _scroll_tween.is_running():
		_scroll_tween.kill()
	_scroll_tween = AniMGR.create_managed_tween(self)
	_scroll_tween.tween_property(self, "scroll_vertical", 0, 0.5) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_toggle_top(true)
	_toggle_bottom(false)

func _process(delta: float) -> void:
	super._process(delta)

	# 根据滚动方向触发
	if scroll_vertical > _last_scroll_vertical:
		_toggle_top(false)
		_toggle_bottom(true)
	elif scroll_vertical < _last_scroll_vertical:
		_toggle_top(true)
		_toggle_bottom(false)

	_last_scroll_vertical = scroll_vertical

func _toggle_top(_show: bool) -> void:
	if _top_visible == _show:
		return
	if _top_tween and _top_tween.is_running():
		_top_tween.kill()
		_top_tween = null
	_top_visible = _show
	var h := 150
	_top_tween = _slide(_top_bar, -h if not _show else 0, -h if not _show else 0)

func _toggle_bottom(_show: bool) -> void:
	if _bottom_visible == _show:
		return
	if _bottom_tween and _bottom_tween.is_running():
		_bottom_tween.kill()
		_bottom_tween = null
	_bottom_visible = _show
	var h := 90
	_bottom_tween = _slide(_bottom_bar, 5 if not _show else -h, h if not _show else 0)

func _slide(bar: Control, off_top: float, off_bottom: float) -> Tween:
	var t := AniMGR.create_managed_tween(self).set_parallel()
	t.tween_property(bar, "offset_top", off_top, 0.45).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(bar, "offset_bottom", off_bottom, 0.45).set_trans(Tween.TRANS_CUBIC)
	return t

func _input(event: InputEvent) -> void:
	# 键盘事件：焦点在本视图（或其子控件）内时，Godot GUI 链会正常送达 _gui_input，
	# 此时不再手动转发，避免 W/S 重映射被处理两次
	if event is InputEventKey and event.pressed:
		var focused := get_viewport().gui_get_focus_owner()
		if focused != null and (focused == self or is_ancestor_of(focused)):
			return
	# 鼠标事件：指针在本视图矩形内时同样由 GUI 链送达，避免滚轮等被处理两次
	elif event is InputEventMouse and get_global_rect().has_point(get_global_mouse_position()):
		return
	super._gui_input(event)

## 本地 MIDI 点击：跳转 MidiView
func on_midi_select(midi: MidiData):
	UiStatMGR.change_state(UIStateManager.UIState.MIDI_VIEW)
	EvtBus.midi_selected.emit.call_deferred(midi.id, midi)

## 远程 chart 点击：根据下载状态执行不同行为
func on_remote_chart_select(chart_hash: String) -> void:
	if ResMGR == null:
		return
	var state = ResMGR.get_download_state(chart_hash)
	match state:
		ResourceManager.DownloadState.DOWNLOADED:
			# 已下载：从本地查找 MidiData 并跳转
			_jump_to_midi_view(chart_hash)
		ResourceManager.DownloadState.NOT_DOWNLOADED, ResourceManager.DownloadState.FAILED:
			# 未下载或失败：触发下载
			_download_chart(chart_hash)
		ResourceManager.DownloadState.DOWNLOADING:
			pass  # 下载中，忽略

## 下载 chart 并更新 UI
func _download_chart(chart_hash: String) -> void:
	# 更新列表项状态为下载中
	_update_item_download_state(chart_hash, ResourceManager.DownloadState.DOWNLOADING)

	var result: Dictionary = await ResMGR.download_chart(chart_hash)

	if result.get("ok", false):
		_update_item_download_state(chart_hash, ResourceManager.DownloadState.DOWNLOADED)
		GLogger.info("Chart downloaded successfully: %s" % chart_hash, "StoreView")
	else:
		_update_item_download_state(chart_hash, ResourceManager.DownloadState.FAILED)
		GLogger.warning("Chart download failed: %s" % str(result.get("error", "")), "StoreView")

## 更新指定 hash 的列表项下载状态
func _update_item_download_state(chart_hash: String, state: int) -> void:
	for item in list_items:
		if item and is_instance_valid(item) and item is StoreMidiListItem:
			var store_item = item as StoreMidiListItem
			if store_item.chart_hash == chart_hash:
				store_item.download_state = state
				store_item._update_download_state_ui()

## 从本地查找已下载的 MidiData 并跳转 MidiView
func _jump_to_midi_view(chart_hash: String) -> void:
	# 直接用 hash 经 LookupChartKey 解析并水合单条，避免全量水合卡顿
	var midi: MidiData = DataMGR.get_midi_by_id(chart_hash)
	if midi:
		UiStatMGR.change_state(UIStateManager.UIState.MIDI_VIEW)
		EvtBus.midi_selected.emit.call_deferred(midi.id, midi)
		return
	# 如果 DataMGR 中没有（可能索引未刷新），尝试直接构建
	GLogger.warning("MidiData not found for hash %s, may need rescan" % chart_hash, "StoreView")

## 上一页按钮回调
func _on_previ_pressed() -> void:
	if _is_loading:
		return
	if _current_page > 1:
		_current_page -= 1
		_load_remote_charts()

## 下一页按钮回调
func _on_next_pressed() -> void:
	if _is_loading:
		return
	var total_pages: int = max(1, ceili(float(_total_charts) / float(_page_limit)))
	if _current_page < total_pages:
		_current_page += 1
		_load_remote_charts()

## 搜索输入回调（防抖 300ms，避免每次按键都打后端）
func _on_search_text_changed(new_text: String) -> void:
	_current_search = new_text
	if _search_debounce and _search_debounce.timeout.is_connected(_debounced_reload):
		_search_debounce.timeout.disconnect(_debounced_reload)
	_search_debounce = get_tree().create_timer(0.3)
	_search_debounce.timeout.connect(_debounced_reload)

## 回车提交搜索（立即触发，跳过防抖）
func _on_search_text_submitted(new_text: String) -> void:
	_current_search = new_text
	if _search_debounce and _search_debounce.timeout.is_connected(_debounced_reload):
		_search_debounce.timeout.disconnect(_debounced_reload)
	_search_debounce = null
	_current_page = 1
	_load_remote_charts()

func _debounced_reload() -> void:
	_search_debounce = null
	_current_page = 1
	_load_remote_charts()

## 排序字段切换（FilterBtn OptionButton: 0=上传时间, 1=下载数, 2=游玩数, 3=点赞数）
func _on_filter_selected(index: int) -> void:
	var idx := clampi(index, 0, _SORT_FIELDS.size() - 1)
	_current_sort = _SORT_FIELDS[idx]
	_current_page = 1
	_load_remote_charts()

## 正序 / 倒序切换（OrderBtn TextureButton toggle）
## button_pressed == true 对应 Ascent 图标（升序 asc）
## button_pressed == false 对应 Descent 图标（降序 desc）
func _on_order_pressed() -> void:
	var order_btn := _top_bar.get_node_or_null("C/HBoxC/OrderBtn") as TextureButton
	if order_btn:
		_current_order = "asc" if order_btn.button_pressed else "desc"
	else:
		_current_order = "asc" if _current_order == "desc" else "desc"
	_current_page = 1
	_load_remote_charts()
