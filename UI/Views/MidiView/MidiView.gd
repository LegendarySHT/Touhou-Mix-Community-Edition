extends HBoxContainer

# 主要节点
@onready var midi_list: MidiView = $LeftArea/InfoWindow/HBoxC/MidiList
@onready var option_list: VBoxContainer = $OptionPanel/VBoxC
@onready var description: RichTextLabel = $LeftArea/InfoWindow/HBoxC/Description

# 下面的三个主要按钮
@onready var main_btns: HBoxContainer = $LeftArea/MainBtn
@onready var track_view_btn: Button = $LeftArea/MainBtn/TrackViewBtn
@onready var play_btn: Button = $LeftArea/MainBtn/PlayBtn
@onready var favor_list_btn: Button = $LeftArea/MainBtn/FavorListBtn

# RightArea 滑动面板
@onready var option_panel: PanelContainer = $OptionPanel
@onready var favor_panel: PanelContainer = $OptionPanel/VBoxC/TabView/FavorPanel
@onready var score_list: ScoreList = $OptionPanel/VBoxC/TabView/Rank/ScoreList
@onready var comment_area: VBoxContainer = $OptionPanel/VBoxC/TabView/Comment
@onready var tab_container: TabContainer = $OptionPanel/VBoxC/TabView
@onready var tab_btn: HBoxContainer = $OptionPanel/VBoxC/TabBtn

# MidiListItem 脚本引用（用于访问其 static var _info_cache）
const _MidiListItem = preload("res://UI/Views/MidiView/MidiListItem.gd")

# 收藏夹面板状态
var _favor_panel_visible: bool = false
var _prev_tab_idx: int = 0
var _is_animating: bool = false
# 退回 SongView 时标记，等退出动画完毕后由 restore_panel_state() 执行清理
# 避免动画播放过程中列表已被清空
var _pending_cleanup: bool = false

# midi信息框左边的三个按钮
@onready var left_btns: Array[Button] = [$LeftArea/InfoWindow/HBoxC/Left/PreviBtn, $LeftArea/InfoWindow/HBoxC/Left/Fold/Btn, $LeftArea/InfoWindow/HBoxC/Left/NextBtn]

# midi信息框右边的两个按钮
@onready var info_btn: Button = $LeftArea/InfoWindow/HBoxC/Right/InfoBtn
@onready var delete_btn: Button = $LeftArea/InfoWindow/HBoxC/Right/DelBtn

# 显示midi的各种数值的地方，但是更新不在这个脚本进行
@onready var detail_data_area: VBoxContainer = $LeftArea/DetailData
# 点击info按钮后显示以下按钮组，用于跳转到浏览器
@onready var redirect_btns: FlowContainer = $LeftArea/RedirectButtons

# 管理器
@onready var data_manager: DataManager = DataMGR
@onready var event_bus: EventBus = EvtBus

var showing_info: bool = false

func _ready() -> void:
	if not (track_view_btn and favor_list_btn and play_btn):
		push_error("[MidiViewInit] Failed to find main btn")
		return

	# 连接事件
	event_bus.song_selected.connect(_on_song_selected)
	event_bus.midi_selected.connect(_on_midi_selected)
	# 监听 UI 状态变化，进入 MIDI_VIEW 时若 FavorPanel 可见则刷新
	UiStatMGR.state_changed.connect(_on_state_changed)

	# 按钮的焦点逻辑
	for i in left_btns:
		i.focus_entered.connect(func():
			i.focus_neighbor_right = midi_list.get_focus_node_path()
		)
	play_btn.focus_entered.connect(func():
		play_btn.focus_neighbor_top = midi_list.get_focus_node_path()
	)

	# 右面板 tab 切换时刷新 Tab 循环焦点
	for b in tab_btn.get_children():
		if b is Button:
			b.toggled.connect(func(_on: bool): _update_focus_neighbors())
	_update_focus_neighbors()

	# 注册主题应用者并首次着色
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）
func apply_theme() -> void:
	ThemeMGR._style_midi_individual_nodes(self)

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

## 更新 Midi 视图 Tab 循环焦点 + InfoBtn 左邻居
## 左区（MidiList 项 + HBoxC 四周按钮）Tab → PlayBtn → 右面板选中 tab → MidiList 选中项，三者循环
## InfoBtn 左邻居总指向 MidiList 当前选中项（修复其自动按几何指到选中项上一节点）
## 由 _ready / MidiList 选中变化（selection_changed 信号）/ 右面板 tab 切换 触发
func _update_focus_neighbors() -> void:
	if not is_inside_tree():
		return
	var play_path := play_btn.get_path()
	# 1) 左区四周按钮 Tab → PlayBtn
	for btn in left_btns:
		btn.focus_next = play_path
	info_btn.focus_next = play_path
	delete_btn.focus_next = play_path
	# 2) MidiList 项 Tab → PlayBtn
	for item in midi_list.list_items:
		if is_instance_valid(item) and item.button:
			item.button.focus_next = play_path
	# 3) 选中项路径（InfoBtn 左邻居 / 右 tab 返回共用）
	var sel_path := midi_list.get_focus_node_path()
	# 4) PlayBtn Tab → 右面板当前选中的可见 tab；该 tab Tab → MidiList 选中项
	var tab := _get_selected_visible_tab_btn()
	if tab:
		play_btn.focus_next = tab.get_path()
		if not sel_path.is_empty():
			tab.focus_next = sel_path
	# 5) InfoBtn 左邻居 → MidiList 选中项
	if not sel_path.is_empty():
		info_btn.focus_neighbor_left = sel_path

## 右面板当前选中的可见 tab 按钮（Rank/Mode/Comment 三选一）
func _get_selected_visible_tab_btn() -> Button:
	for b in tab_btn.get_children():
		if b is Button and b.button_pressed and b.is_visible_in_tree():
			return b
	return null

# MIDI 选择变化：加载列表（收藏夹面板/排行榜由 selection_changed 信号统一刷新）
func _on_midi_selected(_midi_id: String, midi: MidiData) -> void:
	# 记录导航位置：直达路径（排序/搜索/收藏夹浏览/商店等非 Album→Song 入口）进入 MidiView 时，
	# 从 MIDI 反查 album/song 补全记录，下次启动当作从 AlbumView 一路点入恢复
	# （不会恢复到 SortedMidiList/商店等直达页面；Album→Song→Midi 正常路径走 song_selected，不经此处）
	NavigationState.save(midi.album_id, midi.song_id, midi.id)
	midi_list.load_midi([midi])


# 歌曲选择：加载该歌曲的 midi 列表（选中项刷新由 selection_changed 信号处理）
func _on_song_selected(song_id: String) -> void:
	# 导航恢复/预选：若记录中的歌曲就是本歌曲且记录了 midi，进入时选中对应 midi（默认第一项）
	# 正常导航时 SongView 进入已清空 midi_id，preferred 为空 → 默认选中第一项，行为不变
	var preferred_id := NavigationState.get_midi_id() if NavigationState.get_song_id() == song_id else ""
	await midi_list.load_midi(data_manager.get_midis_by_song(song_id), preferred_id)


# UI 状态变化：进入 MIDI_VIEW 时若 FavorPanel 可见，用当前选中 midi 刷新
func _on_state_changed(old_state: int, new_state: int) -> void:
	if new_state == UIStateManager.UIState.MIDI_VIEW and _favor_panel_visible and favor_panel:
		var midi: MidiData = midi_list.get_selection()
		if midi:
			favor_panel.show_with_midi(midi)
	# 离开 MidiView 去 SONG_VIEW/ALBUM_VIEW/SORTED_VIEW 时标记清理
	# （去 TrackView/PlayView/ScoreView/SettingsView 不清理，同一 MIDI 复用解析数据）
	# 实际清理延迟到退出动画完毕后由 restore_panel_state() 执行，避免动画播放过程中列表已被清空
	if old_state == UIStateManager.UIState.MIDI_VIEW and new_state in [
		UIStateManager.UIState.SONG_VIEW,
		UIStateManager.UIState.ALBUM_VIEW,
		UIStateManager.UIState.SORTED_VIEW,
	]:
		_pending_cleanup = true
	# 重新进入 MidiView 时：清除残留 pending 标志 + 刷新排行榜（打歌结束后数据可能已更新）
	elif new_state == UIStateManager.UIState.MIDI_VIEW:
		_pending_cleanup = false
		# 回到本页 = 上一次开局流程已结束，解除"开始"防重标志
		_start_requested = false
		var midi: MidiData = midi_list.get_selection()
		if midi:
			score_list.load_scores(midi)
			comment_area.load_comments(midi)

## 释放视图内部资源（midi 列表项 + 当前 MIDI 运行时缓存），保留节点壳和信号连接
## 重新进入时由 song_selected 信号重新加载
func _cleanup() -> void:
	if midi_list:
		# 先清理当前 MIDI 的运行时缓存（parsed_notes + GameSequence + 播放管理器）
		# 同一 MIDI 在 MidiView/TrackView/PlayView 间切换时已保留缓存，此处是真正离开 MidiView 时释放
		var midi = midi_list.get_selection()
		if midi != null:
			midi_list.cleanup_midi_cache(midi)
		midi_list.clear_items()
	# 清空 MidiListItem 的静态信息缓存（_info_cache），避免浏览多个大 MIDI 后
	# bpm_timeline 等字段累积导致长期内存泄漏（每条 1+ MB）
	_MidiListItem._info_cache.clear()


# midi_list 内部切换检测（prev/next/list 展开/列表项点击均直接改 selected_item，
# 由 BaseScrollList 的 selection_changed 信号统一通知，替代原先 _process 逐帧轮询）
# 选中项变化时刷新焦点循环 + 导航位置 + 收藏夹面板 + 排行榜
func _on_selection_changed(index: int) -> void:
	if index == -1:
		return
	_update_focus_neighbors()
	var midi: MidiData = midi_list.get_selection()
	if midi:
		# 记录导航位置：切换 midi 时记录具体选中项（仅在有 album/song 上下文的导航链内，
		# 收藏夹直达等路径不写，避免残缺记录干扰恢复）
		if NavigationState.get_song_id() != "":
			NavigationState.update({"midi_id": midi.id})
		if _favor_panel_visible and favor_panel:
			favor_panel.show_with_midi(midi)
		# 同步刷新排行榜
		if score_list:
			score_list.load_scores(midi)
		# 同步刷新评论区
		if comment_area:
			comment_area.load_comments(midi)

# 点击开始游戏的事件
func _on_click_start_btn() -> void:
	var midi:MidiData = midi_list.get_selection()
	if not midi:
		return
	GLogger.info("选择歌曲： %s" % midi.name, "MidiView")

	# 重复触发防护：连点开始会连续 emit 两次 start_game_with。
	# 判据用本地标志而不是 current_state —— 本函数是"先 change_state 再 deferred emit"，
	# 连点当帧 current_state 已经是 PLAY_VIEW，用它判会连正常进入都被挡掉。
	# PlayView 侧另有代次守卫兜底；这里只是省掉一轮白跑的序列生成 + 后端 seek。
	if _start_requested:
		return
	_start_requested = true

	# 先 change_state 触发 PlayView 懒加载（_ready 连接 start_game_with 信号），
	# 再用 call_deferred emit，确保信号不丢失（与 _on_click_track_btn 模式一致）
	UiStatMGR.change_state(UIStateManager.UIState.PLAY_VIEW)
	EvtBus.start_game_with.emit.call_deferred(midi)

var _start_requested: bool = false

func _on_click_track_btn():
	var midi:MidiData = midi_list.get_selection()
	if not midi:
		return
	
	UiStatMGR.change_state(UIStateManager.UIState.TRACK_VIEW)
	EvtBus.enter_track_view_with.emit.call_deferred(midi)

# 收藏夹按钮：切换 RightArea 中 OptionPanel 和 FavorPanel 的滑动显示
func _on_click_favor_list_btn() -> void:
	if _is_animating:
		return
	if _favor_panel_visible:
		_hide_favor_panel()
	else:
		var midi: MidiData = midi_list.get_selection()
		if not midi:
			return
		favor_panel.show_with_midi(midi)
		_show_favor_panel()


# 显示收藏夹面板：两阶段动画，避免布局跳变
func _show_favor_panel() -> void:
	_is_animating = true
	_favor_panel_visible = true
	favor_list_btn.icon.region = Rect2(160, 160, 80, 80)
	_prev_tab_idx = tab_container.current_tab
	var current_page := tab_container.get_tab_control(_prev_tab_idx) if _prev_tab_idx >= 0 else null
	# FavorPanel 提前就位（布局占位，视觉偏移到下方）
	favor_panel.visible = true
	favor_panel.modulate.a = 0.0
	favor_panel.offset_transform_position.y = 800
	# 第一阶段：TabBtn 淡出 + 高度收缩，布局空间平滑释放
	var tween1 := AniMGR.create_managed_tween(self).set_parallel(true)
	tween1.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
	tween1.tween_property(tab_btn, "modulate:a", 0.0, 0.2)
	tween1.tween_property(tab_btn, "custom_minimum_size:y", 0, 0.2)
	if current_page:
		tween1.tween_property(current_page, "modulate:a", 0.0, 0.2)
	await tween1.finished
	tab_btn.visible = false
	# 切换到 FavorPanel 标签页，使其成为当前可见标签后，再执行下方滑入 + 淡入
	tab_container.current_tab = 3
	# 第二阶段：FavorPanel 从下方滑入 + 淡入
	var tween2 := AniMGR.create_managed_tween(self).set_parallel(true)
	tween2.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
	tween2.tween_property(favor_panel, "modulate:a", 1.0, 0.3)
	tween2.tween_property(favor_panel, "offset_transform_position:y", 0, 0.4)
	await tween2.finished
	_is_animating = false


# 隐藏收藏夹面板：两阶段反向动画
func _hide_favor_panel(exiting_page: bool = false) -> void:
	_is_animating = true
	_favor_panel_visible = false
	favor_list_btn.icon.region = Rect2(320, 0, 80, 80)
	favor_panel.cancel_create()
	var target_page := tab_container.get_tab_control(_prev_tab_idx) if _prev_tab_idx >= 0 else null
	if not target_page:
		push_error("[MidiView] Invalid target page index: %d" % _prev_tab_idx)
	if not exiting_page:
		# 第一阶段：FavorPanel 滑出到下方 + 淡出
		var tween1 := AniMGR.create_managed_tween(self).set_parallel(true)
		tween1.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
		tween1.tween_property(favor_panel, "modulate:a", 0.0, 0.2)
		tween1.tween_property(favor_panel, "offset_transform_position:y", 800, 0.3)
		await tween1.finished
	else:
		favor_panel.modulate.a = 0.0
		favor_panel.offset_transform_position.y = 800
	tab_container.current_tab = _prev_tab_idx
	# 显式隐藏并复位 FavorPanel：清掉下移偏移与透明度，避免残留 800 偏移 + 可见状态卡在下方
	favor_panel.visible = false
	favor_panel.offset_transform_position.y = 0
	favor_panel.modulate.a = 1.0
	# 第二阶段：TabBtn 高度恢复 + 淡入 + 目标标签页淡入
	tab_btn.visible = true
	tab_btn.modulate.a = 1.0 if exiting_page else 0.0
	tab_btn.custom_minimum_size.y = 120 if exiting_page else 0
	
	target_page.visible = true
	target_page.modulate.a = 1.0 if exiting_page else 0.0
	if not exiting_page:
		var tween2 := AniMGR.create_managed_tween(self).set_parallel(true)
		tween2.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
		tween2.tween_property(tab_btn, "modulate:a", 1.0, 0.25)
		tween2.tween_property(tab_btn, "custom_minimum_size:y", 120, 0.25)
		tween2.tween_property(target_page, "modulate:a", 1.0, 0.25)
		await tween2.finished
	_is_animating = false

	if exiting_page:
		get_node("OptionPanel/VBoxC/TabBtn/Rank").button_pressed=true

# 显示简介什么的
func _on_info_btn_pressed():
	if midi_list.selected_item == -1:
		return
	_set_info_visible(not showing_info)

## 设置展开简介面板的可见性（true=展开简介隐藏列表，false=显示列表收起简介）
## _on_info_btn_pressed 和 restore_panel_state 共用此函数
func _set_info_visible(v: bool) -> void:
	showing_info = v
	# 窗口部分
	description.visible = v
	midi_list.visible = not v
	# 禁用按钮，防止点击
	for btn in left_btns:
		btn.disabled = v
	delete_btn.disabled = v
	midi_list.get_parent().get_parent().size_flags_vertical = Control.SIZE_EXPAND_FILL if v else SIZE_FILL
	# 数据区
	detail_data_area.visible = not v
	redirect_btns.visible = v
	midi_list.need_snap = true

func _on_del_btn_pressed():
	var window = PopupWindow.instance
	var midi_to_del: MidiData = midi_list.get_selection()

	if not midi_to_del:
		window.show_message("请先选择歌曲")
		return

	# 填充三档删除选项
	if not await window.show_message("请选择要删除的内容", true, ["删除曲包", "删除设定", "删除人声音频"]):
		return

	# 统一使用规范键（folder_name）发起删除/写回，避免 id / file_hash 别名混用（TMX-020）
	var chart_id: String = midi_to_del.chart_key if not midi_to_del.chart_key.is_empty() \
		else (midi_to_del.file_hash if not midi_to_del.file_hash.is_empty() else midi_to_del.id)

	match window.get_selected():
		"删除人声音频": # 删除人声音频文件，并清除人声相关设置
			var vocal_path: String = midi_to_del.vocal_file_path
			if vocal_path.is_empty():
				window.show_message("该谱面没有设置人声音频")
				return
			if not FileSystemManager.instance.delete_file(vocal_path):
				window.show_message("删除人声文件失败")
				return
			# 更新内存
			midi_to_del.vocal_file_path = ""
			midi_to_del.vocal_offset_ms = 0
			midi_to_del.vocal_volume = 0.5
			# 写回 chart_runtime（权威 DB），经 MidiCore 配置权威入口
			MidiCore.UpdateConfig(chart_id, midi_to_del.export_runtime_config())
			GLogger.info("已删除人声音频: %s" % vocal_path, "MidiView")

		"删除设定": # 重置设定：清除音轨/音量/静音/独奏配置，保留人声路径
			# 更新内存
			midi_to_del.selected_track_indices.clear()
			midi_to_del.selected_track_configs.clear()
			midi_to_del.track_channel_mute_state.clear()
			midi_to_del.track_channel_volume_config.clear()
			midi_to_del.track_channel_instrument_overrides.clear()
			midi_to_del.solo_pairs.clear()
			midi_to_del.midi_volume = -1.0  # -1=未配置（跟随全局 default_midi_volume）
			# 重置 _track_config_initialized=false：使下次进入 TrackView 时 PlaybackDisplay.load_midi
			# 重新解析简介并应用推荐轨道（修复 #59：删除设定后不会回落到从简介读取音轨配置的状态）
			midi_to_del.set_track_config_initialized(false)
			# 清空 chart_runtime（文档存在=已配置，删除=从未配置；与旧 JSON 整块移除 _runtime 语义一致）
			MidiCore.ClearConfig(chart_id)
			GLogger.info("已重置谱面设定: %s" % midi_to_del.name, "MidiView")

		"删除曲包": # 删除曲包：删除整个文件夹，并从内存中移除
			if not FileSystemManager.instance.delete_chart(chart_id):
				window.show_message("删除曲包文件夹失败")
				return
			# 删除前先记录 song_id 和 album_id，用于判断是否被级联删除
			var song_id_before: String = midi_to_del.song_id
			var album_id_before: String = midi_to_del.album_id
			var deleted_id: String = midi_to_del.id
			DataMGR.remove_midi(chart_id)
			# 判断 Song 和 Album 是否被级联删除（DB 聚合权威，不依赖内存水合缓存）
			var song_still_exists: bool = not song_id_before.is_empty() and ChartDB and ChartDB.IsOpen() and ChartDB.SongExists(song_id_before)
			var album_still_exists: bool = not album_id_before.is_empty() and ChartDB and ChartDB.IsOpen() and ChartDB.AlbumExists(album_id_before)
			
			if song_still_exists:
				# Song 仍存在，正常返回 SongView
				midi_list.remove_selected_midi()
			elif album_still_exists:
				# Song 被删除但 Album 仍存在，重新加载该 Album 的 SongView（空列表）
				midi_list.current_midis.erase(midi_to_del)
				midi_list._refresh_display()
				EvtBus.album_selected.emit(album_id_before)
				UiStatMGR.go_back()
			else:
				# Song 和 Album 都被删除，直接跳回 AlbumView
				# 确保静态 SelectedAlbum 头部卡片隐藏复位（直接跳转时可能跳过 SongView 的退出流程）
				var sa_node = get_node_or_null(PathRegistry.SELECTED_ALBUM)
				if is_instance_valid(sa_node):
					sa_node.visible = false
					sa_node.modulate.a = 1.0
				UiStatMGR.go_back_to(UIStateManager.UIState.ALBUM_VIEW)
			EvtBus.midi_deleted.emit(deleted_id)
			GLogger.info("已删除曲包: %s" % midi_to_del.name, "MidiView")

# 退出界面时恢复页面状态
# 由 AnimationManager 在 Midi_Info_View 退出动画完毕后调用
func restore_panel_state() -> void:
	if _favor_panel_visible:
		_hide_favor_panel(true)
	get_node("OptionPanel/VBoxC/TabBtn/Rank").button_pressed=true
	# 重置展开简介状态（若已展开则收起）
	if showing_info:
		_set_info_visible(false)
	# 退出动画完毕，执行延迟的列表清理
	if _pending_cleanup:
		_pending_cleanup = false
		_cleanup()
