extends Control
class_name Shortcut_Menu

static var instance:Shortcut_Menu

# 收藏夹列表项场景
const FAVOR_ITEM_SCENE := preload("res://UI/Components/ShortCutMenu/favorListItem.tscn")

# 新建收藏夹状态
var _is_creating: bool = false

func _ready() -> void:
	instance = self
	# 初始为收起态：内容区整体隐藏。只把 alpha 淡到 0 的话控件仍参与拾取，
	# 看不见的按钮照样点得到
	%BgPanel.visible = false
	_apply_page_focus()
	_setup_focus_tab_bar()
	# 连接按钮点击事件
	%SortTabBtn.toggled.connect(_on_menu_tab_btn_toggled.bind(%SortTabBtn))
	%FavorListTabBtn.toggled.connect(_on_menu_tab_btn_toggled.bind(%FavorListTabBtn))

	# 按键退出事件
	UiStatMGR.state_changed.connect(_on_state_changed)

	# 按钮聚焦事件
	%SortTabBtn.focus_entered.connect(_on_focus_enter.bind(%SortTabBtn))
	%FavorListTabBtn.focus_entered.connect(_on_focus_enter.bind(%FavorListTabBtn))

	# 收藏夹相关
	%AddBtn.pressed.connect(_on_add_btn_pressed)
	EvtBus.favorites_loaded.connect(_refresh_favor_list)
	EvtBus.favorites_updated.connect(_refresh_favor_list)
	EvtBus.favorite_list_created.connect(_refresh_favor_list)
	EvtBus.favorite_list_deleted.connect(_refresh_favor_list)
	EvtBus.favorite_list_renamed.connect(_refresh_favor_list)
	EvtBus.favorite_midi_changed.connect(_refresh_favor_list)

func _on_focus_enter(btn: Button):
	if btn.button_pressed:
		return
	# 鼠标点击场景：按下按钮会先 grab focus 触发本回调，若此刻自动按下，
	# 会在鼠标松开时被按钮自身的 toggle 再翻转一次，导致面板展开又立刻收起。
	# 鼠标正按住按钮时跳过自动按下（点击释放自会 toggle），仅对键盘导航（Tab/方向键）生效。
	if btn.is_hovered() and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return
	await get_tree().create_timer(0.1).timeout
	# 焦点已经移走（快速 Tab 穿过两个标签）时不再按下：否则会用已经过时的意图把面板切回去
	if not btn.button_pressed and btn.has_focus():
		btn.button_pressed = true

func _on_state_changed(old_state: UIStateManager.UIState, new_state: UIStateManager.UIState) -> void:
	var valid_state = [UIStateManager.UIState.ALBUM_VIEW, UIStateManager.UIState.SONG_VIEW]
	if new_state != UIStateManager.UIState.SORTED_VIEW and not (old_state in valid_state and new_state in valid_state):
		%SortTabBtn.button_pressed = false
		%FavorListTabBtn.button_pressed = false
	# 仅进入排序筛选页（SORTED_VIEW）清空搜索词；其余导航（含进出 MidiView）保留就地搜索
	if new_state == UIStateManager.UIState.SORTED_VIEW:
		%SearchEdit.text = ""
		if EvtBus.current_search_query != "":
			EvtBus.current_search_query = ""
			EvtBus.search_query_changed.emit("")
	# 从 MidiView 返回 SongView 仍保留就地搜索词时，自动展开快捷菜单以显示当前筛选状态
	if old_state == UIStateManager.UIState.MIDI_VIEW and new_state == UIStateManager.UIState.SONG_VIEW:
		if EvtBus.current_search_query != "" and not %SortTabBtn.button_pressed:
			%SortTabBtn.button_pressed = true

## 展开态面板高度（含顶部 120 的标签条）与收起态只剩标签条的高度。
const PANEL_H_OPEN := 825.0
const PANEL_H_BAR := 120.0

## 展开状态可能在同一帧里连续变化（互斥标签先取消再按下），合并成一次处理：
## 否则中间的「两个标签都没按下」会被当成全部收起，面板缩回只剩标签条
var _menu_state_pending := false

func _on_menu_tab_btn_toggled(_toggled_on: bool, _btn: Button) -> void:
	if _menu_state_pending:
		return
	_menu_state_pending = true
	_apply_menu_state.call_deferred()

func _apply_menu_state() -> void:
	_menu_state_pending = false
	var sort_pressed: bool = %SortTabBtn.button_pressed
	var favor_pressed: bool = %FavorListTabBtn.button_pressed
	var closing := not sort_pressed and not favor_pressed

	# 展开时立即恢复内容区；收起要等淡出结束再整块隐藏
	%BgPanel.visible = true

	# 同名 tween：切页时旧的动画连同回调一起作废，不会和新动画抢同一批属性
	var tween := AniMGR.create_managed_tween(self, "menu_panel")
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_QUINT)
	tween.set_parallel(true)

	tween.tween_property(%SortTabBtn, "custom_minimum_size",
		Vector2(120 + 310 * (1 if sort_pressed else 0), 120), 0.45)
	tween.tween_property(%FavorListTabBtn, "custom_minimum_size",
		Vector2(120 + 310 * (1 if favor_pressed else 0), 120), 0.45)
	# 高度按当前 offset_top 算：面板在 Main 里是"距顶 75"定位的，写死绝对值会错位
	tween.tween_property(self, "offset_bottom", offset_top + (PANEL_H_BAR if closing else PANEL_H_OPEN), 0.35)
	tween.tween_property(%BgPanel, "self_modulate:a", 0.0 if closing else 1.0, 0.45)
	if closing:
		tween.chain().tween_callback(func() -> void:
			if _is_all_off():
				%BgPanel.visible = false
		)
	else:
		tween.tween_property(%PageContent, "offset_transform_position:x", (-655 if favor_pressed else 0), 0.5)

	# 两页并排，靠平移切换，页内可见性不动，只切焦点：
	# 没展开的那一页整页不可聚焦，两个标签都收起时除标签按钮外全部不可聚焦
	_apply_page_focus()

func _is_all_off() -> bool:
	if %SortTabBtn.button_pressed or %FavorListTabBtn.button_pressed:
		return false
	return true

# ========== 标签栏 ==========

## 两个标签按钮注册成标签栏：面板内按 Tab 切换页签，与其他页面的标签栏一致
var _tab_bar: FocusTabBar = null

func _setup_focus_tab_bar() -> void:
	_tab_bar = FocusTabBar.new()
	_tab_bar.root = %Btns
	_tab_bar.page_root = self
	_tab_bar.buttons_fn = _tab_buttons
	_tab_bar.current_fn = _current_tab_index
	_tab_bar.select_fn = _select_tab
	# 面板是页面上的附属区域：焦点不在面板里时，Tab 不该被它抢去切面板页签
	_tab_bar.only_when_focused = true
	FocusMGR.register_tab_bar(_tab_bar)

func _tab_buttons() -> Array:
	return [%SortTabBtn, %FavorListTabBtn]

## 当前页下标：焦点停在标签按钮上时以它为准（此时面板可能刚收起，没有展开页）
func _current_tab_index() -> int:
	var focused := FocusMGR.focused_control()
	if focused == %FavorListTabBtn:
		return 1
	if focused == %SortTabBtn:
		return 0
	return 1 if %FavorListTabBtn.button_pressed else 0

## 切到第 i 页：直接展开目标页，不等聚焦后的延时自动按下
func _select_tab(index: int) -> void:
	var btns := _tab_buttons()
	if index < 0 or index >= btns.size():
		return
	var btn: Button = btns[index]
	if not btn.button_pressed:
		btn.button_pressed = true

## 面板内控件的原始焦点模式：切页只改 focus_mode，不动可见性与布局
var _page_focus_backup: Dictionary = {}

## 按当前展开状态决定两页的控件能不能被焦点选中
func _apply_page_focus() -> void:
	for key in _page_focus_backup.keys():
		if not is_instance_valid(key):
			_page_focus_backup.erase(key)
	var sort_on: bool = %SortTabBtn.button_pressed
	var favor_on: bool = %FavorListTabBtn.button_pressed
	var dropped := _set_page_focus(%SortPage, sort_on and not favor_on)
	dropped = _set_page_focus(%FavorPage, favor_on) or dropped
	# 焦点原本就在被关掉的那一页上：引擎会直接丢焦点，落到当前页签按钮上
	if dropped:
		_focus_tab_button()

## 设置单页内控件的可聚焦状态，返回是否关掉了正持有焦点的控件
func _set_page_focus(page: Control, enabled: bool) -> bool:
	var dropped := false
	for node in _collect_controls(page):
		if not _page_focus_backup.has(node):
			_page_focus_backup[node] = node.focus_mode
		var original: Control.FocusMode = _page_focus_backup[node]
		var mode: Control.FocusMode = original if enabled else Control.FOCUS_NONE
		if mode == node.focus_mode:
			continue
		if not enabled and node.has_focus():
			dropped = true
		node.focus_mode = mode
	return dropped

## 面板内没有可聚焦内容时把焦点放到当前页签按钮
func _focus_tab_button() -> void:
	# 面板已全部收起：焦点不留在面板里，交给焦点路由落到当前页面
	if _is_all_off():
		return
	var btn: Button = %FavorListTabBtn if %FavorListTabBtn.button_pressed else %SortTabBtn
	if btn.focus_mode == Control.FOCUS_NONE:
		return
	btn.grab_focus.call_deferred()

func _collect_controls(root: Node) -> Array[Control]:
	var out: Array[Control] = []
	for child in root.get_children():
		if child is Control:
			out.append(child as Control)
		out.append_array(_collect_controls(child))
	return out

# ========== 转场动画 ==========

## 15° 倾斜对应的水平偏移量（与 AnimationManager.tan15 保持一致）
const _TAN15 := tan(deg_to_rad(15))

## 播放进/出场转场动画（供 AnimationManager 与 PlayerInfo 等外部调用）
## exit=true: 退场（移出 + 隐藏）；exit=false: 入场（显示 + 移回）
## 注意：仅做位移与显隐，不重置内部按钮状态（与原 AnimationManager 行为一致）
func play_transition_animation(exit: bool) -> Tween:
	var target_offset := Vector2(500 * _TAN15, -500)
	if exit:
		var t := AniMGR.animate_offset_to(self, target_offset, 0.25, "MenuBarPosition")
		t.finished.connect(func() -> void:
			visible = false
		)
		return t
	# 入场：从偏移位置移回原位
	visible = true
	offset_transform_position = target_offset
	return AniMGR.animate_offset_back(self, 0.25, "MenuBarPosition")

## 收起已展开的快捷面板（排序/收藏页），供 PlayerInfo 展开等外部场景调用
## 通过复位 toggle 按钮触发 _on_menu_tab_btn_toggled 的既有收起动画
func collapse_panel() -> void:
	if %SortTabBtn.button_pressed:
		%SortTabBtn.button_pressed = false
	if %FavorListTabBtn.button_pressed:
		%FavorListTabBtn.button_pressed = false

# 筛选按钮部分
var sortByStatus: SortEngine.SortStatField = SortEngine.SortStatField.ALL
var sortByData: SortEngine.SortDataField = SortEngine.SortDataField.DOWNLOAD_COUNT
var sortDirection: SortEngine.SortDirection = SortEngine.SortDirection.ASCENDING

# icon_set2.png 各筛选图标 region（80x80）：第三行状态 / 第四行升降序 / 第五行数据
const _STATUS_REGION := {
	SortEngine.SortStatField.ALL: Rect2(0, 160, 80, 80),
	SortEngine.SortStatField.PENDING: Rect2(80, 160, 80, 80),
	SortEngine.SortStatField.APPROVED: Rect2(160, 160, 80, 80),
	SortEngine.SortStatField.INCLUDED: Rect2(240, 160, 80, 80),
	SortEngine.SortStatField.DEAD: Rect2(320, 160, 80, 80),
}
const _ASC_REGION := Rect2(0, 240, 80, 80)
const _DESC_REGION := Rect2(80, 240, 80, 80)
const _DATA_REGION := {
	SortEngine.SortDataField.DOWNLOAD_COUNT: Rect2(0, 320, 80, 80),
	SortEngine.SortDataField.TRIAL_COUNT: Rect2(80, 320, 80, 80),
	SortEngine.SortDataField.UP_COUNT: Rect2(160, 320, 80, 80),
	SortEngine.SortDataField.UPLOADED_DATE: Rect2(240, 320, 80, 80),
}
# 数据可切换字段顺序（按第五行图标顺序，已移除收藏/默认排序）
var _data_fields: Array = [
	SortEngine.SortDataField.DOWNLOAD_COUNT,
	SortEngine.SortDataField.TRIAL_COUNT,
	SortEngine.SortDataField.UP_COUNT,
	SortEngine.SortDataField.UPLOADED_DATE,
]

func _on_status_pressed() -> void:
	# 未进入 SortedMidiView：本此点击仅进入视图并应用当前筛选状态，不切换字段
	if UiStatMGR.current_state != UiStatMGR.UIState.SORTED_VIEW:
		SortEngine.set_sort_mode(sortByStatus, sortByData, sortDirection)
		UiStatMGR.change_state(UiStatMGR.UIState.SORTED_VIEW)
		return
	# 已进入：Midi状态循环切换（第三行图标）
	sortByStatus=(sortByStatus+1)%5 as SortEngine.SortStatField
	(%StateBtn.icon as AtlasTexture).region = _STATUS_REGION[sortByStatus]
	SortEngine.set_sort_mode(sortByStatus, sortByData, sortDirection)

# 数据筛选（第五行图标循环）
func _on_data_pressed() -> void:
	# 未进入 SortedMidiView：本此点击仅进入视图并应用当前筛选状态，不切换字段
	if UiStatMGR.current_state != UiStatMGR.UIState.SORTED_VIEW:
		SortEngine.set_sort_mode(sortByStatus, sortByData, sortDirection)
		UiStatMGR.change_state(UiStatMGR.UIState.SORTED_VIEW)
		return
	# 已进入：在当前可用字段内循环
	var cur := _data_fields.find(int(sortByData))
	var next := (cur + 1) % _data_fields.size() if cur >= 0 else 0
	sortByData = _data_fields[next] as SortEngine.SortDataField

	(%DataBtn.icon as AtlasTexture).region = _DATA_REGION[sortByData]
	SortEngine.set_sort_mode(sortByStatus, sortByData, sortDirection)

func _on_ordering_pressed() -> void:
	# 未进入 SortedMidiView：本此点击仅进入视图并应用当前筛选状态，不切换字段
	if UiStatMGR.current_state != UiStatMGR.UIState.SORTED_VIEW:
		SortEngine.set_sort_mode(sortByStatus, sortByData, sortDirection)
		UiStatMGR.change_state(UiStatMGR.UIState.SORTED_VIEW)
		return
	# 已进入：升序/降序循环切换（第四行图标）
	sortDirection = (sortDirection + 1) % 2 as SortEngine.SortDirection
	(%OrderingBtn.icon as AtlasTexture).region = _ASC_REGION if sortDirection == SortEngine.SortDirection.ASCENDING else _DESC_REGION
	SortEngine.set_sort_mode(sortByStatus, sortByData, sortDirection)


func _on_search_query(query: String = "") -> void:
	var q: String = query if query else %SearchEdit.text
	EvtBus.current_search_query = q
	EvtBus.search_query_changed.emit(q)


# ========== 收藏夹相关 ==========

## 刷新收藏夹列表
func _refresh_favor_list(_arg1 = null, _arg2 = null, _arg3 = null) -> void:
	if not FavoriteManager.instance:
		return
	# 记住当前聚焦项：重建会销毁节点，重建后恢复焦点（如重命名完成后的场景）
	var focused_id := ""
	for child in %FavorList.get_children():
		if child is FavorListItem and child.has_focus():
			focused_id = child.favorite_id
			break
	# 清空现有列表项
	for child in %FavorList.get_children():
		child.queue_free()
	# 重新填充
	var target_item: FavorListItem = null
	for fav in FavoriteManager.instance.favorites:
		var item = FAVOR_ITEM_SCENE.instantiate()
		%FavorList.add_child(item)
		item.setup(fav, FavorListItem.Mode.BROWSE)
		item.favor_item_clicked.connect(_on_favor_item_clicked)
		if fav.id == focused_id:
			target_item = item
	# 重建后恢复焦点到原项
	if target_item:
		target_item.grab_focus()
	# 新建的项要跟随当前展开状态决定是否可聚焦
	_apply_page_focus()


## AddBtn 点击：根据当前状态切换新建/确认
func _on_add_btn_pressed() -> void:
	if _is_creating:
		_confirm_create()
	else:
		_enter_create_mode()


## 进入新建模式：显示文本框，切换图标为 confirm
func _enter_create_mode() -> void:
	_is_creating = true
	%NameEdit.text = ""
	%NameEdit.visible = true
	# 切换 AddBtn 图标为 confirm
	%AddBtn.icon.region = Rect2(0, 80, 80, 80)
	%NameEdit.grab_focus()


## 确认创建：读取文本，创建收藏夹，恢复 AddBtn 图标
func _confirm_create(_new_text: String = "") -> void:
	if not _is_creating:
		return
	var fav_name: String = %NameEdit.text.strip_edges()
	%NameEdit.visible = false
	_is_creating = false
	# 切换 AddBtn 图标回 add
	%AddBtn.icon.region = Rect2(160, 80, 80, 80)
	# 创建收藏夹
	if not fav_name.is_empty():
		FavoriteManager.instance.create_favorite(fav_name)


## 点击收藏夹项：跳转到 SortedMidiView 浏览
func _on_favor_item_clicked(fav_id: String) -> void:
	if fav_id.is_empty():
		return
	EvtBus.favorite_selected_for_browse.emit(fav_id)
	if UiStatMGR.current_state != UiStatMGR.UIState.SORTED_VIEW:
		UiStatMGR.change_state(UiStatMGR.UIState.SORTED_VIEW)
	%FavorListTabBtn.button_pressed = false
