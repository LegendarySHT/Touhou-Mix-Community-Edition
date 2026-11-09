extends ViewBase

class_name MidiView

# 下面的三个主要按钮
@onready var track_view_btn: Button =%TrackViewBtn
@onready var play_btn: Button = %PlayBtn
@onready var favor_list_btn: Button = %FavorListBtn

# 被MidiListItem引用
@onready var indicators: VBoxContainer = %MidiListIndicator
@onready var description: RichTextLabel = %MidiDescription
# 数据
@onready var data_duration: Label = %Duration
@onready var data_note_total: Label = %NoteTotal
@onready var data_npm: Label = %NotePerMinute
@onready var data_track_ctn: Label = %TrackCtn
@onready var data_midi_hash: Label = %MidiHash
@onready var data_vocal_state: Label = %VocalState

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
@onready var left_btns: Array[Button] = [%PreviBtn, %FoldBtn, %NextBtn]

var showing_info: bool = false

func _on_view_ready() -> void:
	# 供跨场景读取的谱面列表
	GlobalNodes.midi_list = %MidiList
	# 连接事件
	EvtBus.song_selected.connect(_on_song_selected)
	EvtBus.midi_selected.connect(_on_midi_selected)
	# 简介里的 http/https 链接点击：统一交给简介解析模块校验并打开
	%MidiDescription.meta_clicked.connect(_on_description_meta_clicked)
	# 「显示上传按钮」在简介展开期间变更时即时刷新按钮组
	EvtBus.config_changed.connect(_on_config_changed)
	# 监听 UI 状态变化，进入 MIDI_VIEW 时若 FavorPanel 可见则刷新
	UiStatMGR.state_changed.connect(_on_state_changed)

	_setup_focus_tabs()

## 右侧面板的三个页签按 Tab 切换，页内控件交给方向键
func _setup_focus_tabs() -> void:
	var bar := FocusTabBar.new()
	bar.root = %OptTabBtns
	bar.page_root = self
	bar.buttons_fn = func() -> Array:
		return %OptTabBtns.get_children().filter(func(b): return b is Button and b.is_visible_in_tree())
	bar.current_fn = func() -> int:
		var list := bar.buttons()
		for i in list.size():
			if (list[i] as Button).button_pressed:
				return i
		return 0
	bar.select_fn = func(i: int) -> void:
		var list := bar.buttons()
		if i >= 0 and i < list.size():
			(list[i] as Button).button_pressed = true
	FocusMGR.register_tab_bar(bar)

## 应用主题色（由 ThemeManager 广播调用 + ViewBase._ready 首次自调）
func apply_theme() -> void:
	_style_individual_nodes()

## 本视图里用 theme_override_styles 单独设色的节点。
## 只改节点自带的 StyleBox（ThemeMGR.has_local_stylebox 判定），不碰共享的主题资源。
func _style_individual_nodes() -> void:
	var p: Color = ThemeMGR.get_color("primary")
	var surface: Color = ThemeMGR.get_color("surface")
	var surface_high: Color = ThemeMGR.get_color("surface_high")
	var surface_low: Color = ThemeMGR.get_color("surface_low")

	# InfoWindow 整体底色
	ThemeMGR._style_panel_set_bg_color(%InfoWindow, surface)

	# Fold 面板（与 Right/Center 共享同一 StyleBoxFlat，改一处两处同步）
	ThemeMGR._style_panel_set_bg_color(%FoldPanel, surface_high)

	# Fold/Btn — 只改 pressed（normal 透明，hover 的暗色遮罩保留）
	if ThemeMGR.has_local_stylebox(%FoldBtn, "pressed"):
		var fold_sb := (%FoldBtn as Button).get_theme_stylebox("pressed")
		if fold_sb is StyleBoxFlat:
			fold_sb.bg_color = surface_low

	# 谱面简介背景 — 强调色淡底
	if ThemeMGR.has_local_stylebox((%MidiDescription as RichTextLabel), "normal"):
		var desc_sb := (%MidiDescription as RichTextLabel).get_theme_stylebox("normal")
		if desc_sb is StyleBoxFlat:
			desc_sb.bg_color = Color(p.r, p.g, p.b, 0.14)
			desc_sb.border_color = Color(p.r, p.g, p.b, 0.35)

	# PlayBtn — 主操作，强调色填充
	ThemeMGR._style_button_set_bg_color(play_btn, p.darkened(0.1))

	# DetailData 的两个面板：PC1 亮（基本信息）/ PC2 暗（文件信息）
	ThemeMGR._style_panel_set_bg_color(%ForePanel, surface_high)
	ThemeMGR._style_panel_set_bg_color(%BackPanel, surface_low)

## 出场：整页淡出，播完后收起详情面板
func _play_exit() -> Tween:
	var tw := AniMGR.animate_fade_out(self, 0.3, "%s_out" % name)
	if tw and tw.is_valid():
		tw.finished.connect(func() -> void:
			if is_instance_valid(self):
				restore_panel_state()
		)
	return tw

## 入场：整页淡入 + 从上方滑回
func _play_enter() -> Tween:
	AniMGR.animate_fade_in(self, 0.1, "%s_fade_in" % name)
	offset_transform_position = Vector2(0, -500)
	return AniMGR.animate_offset_back(self, 0.5, "%s_in" % name)

# MIDI 选择变化：加载列表（收藏夹面板/排行榜由 selection_changed 信号统一刷新）
func _on_midi_selected(_midi_id: String, midi: MidiData) -> void:
	# 记录导航位置：直达路径（排序/搜索/收藏夹浏览/商店等非 Album→Song 入口）进入 MidiView 时，
	# 从 MIDI 反查 album/song 补全记录，下次启动当作从 AlbumView 一路点入恢复
	# （不会恢复到 SortedMidiList/商店等直达页面；Album→Song→Midi 正常路径走 song_selected，不经此处）
	NavigationState.save(midi.album_id, midi.song_id, midi.id)
	# 需要 as 成真实类型：`%` 的静态类型是 Node，动态调用时编译器看不到参数签名，
	# `[midi]` 会保持无类型 Array，被 load_midi(Array[MidiData]) 的运行时检查拒绝
	(%MidiList as MidiList).load_midi([midi])


# 歌曲选择：加载该歌曲的 midi 列表（选中项刷新由 selection_changed 信号处理）
func _on_song_selected(song_id: String) -> void:
	# 导航恢复/预选：若记录中的歌曲就是本歌曲且记录了 midi，进入时选中对应 midi（默认第一项）
	# 正常导航时 SongView 进入已清空 midi_id，preferred 为空 → 默认选中第一项，行为不变
	var preferred_id := NavigationState.get_midi_id() if NavigationState.get_song_id() == song_id else ""
	await %MidiList.load_midi(DataMGR.get_midis_by_song(song_id), preferred_id)


# UI 状态变化：进入 MIDI_VIEW 时若 FavorPanel 可见，用当前选中 midi 刷新
func _on_state_changed(old_state: int, new_state: int) -> void:
	if new_state == UIStateManager.UIState.MIDI_VIEW and _favor_panel_visible:
		var midi: MidiData = %MidiList.get_selection()
		if midi:
			%FavorPanel.show_with_midi(midi)
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
		var midi: MidiData = %MidiList.get_selection()
		if midi:
			# 中途退出时成绩上传是 fire-and-forget：回到本页时它很可能还在路上。
			# 此刻不刷新，交给随后到达的 score_uploaded / score_upload_failed 统一刷一次，
			# 否则「回页刷新 + 上传完成刷新」会连刷两次（列表被 clear_items 清空、
			# 滚动位置弹回顶部，并多打一轮排行榜/统计/评论请求）。
			if ScoreManager.instance != null and ScoreManager.instance.is_upload_in_flight(midi.file_hash):
				GLogger.info("Refresh deferred: score upload in flight (midi=%s)" % midi.file_hash, "MidiView")
			else:
				%ScoreList.load_scores(midi)
				%CommentPanel.load_comments(midi)

## 释放视图内部资源（midi 列表项 + 当前 MIDI 运行时缓存），保留节点壳和信号连接
## 重新进入时由 song_selected 信号重新加载
func _cleanup() -> void:
	# 先清理当前 MIDI 的运行时缓存（parsed_notes + GameSequence + 播放管理器）
	# 同一 MIDI 在 MidiView/TrackView/PlayView 间切换时已保留缓存，此处是真正离开 MidiView 时释放
	var midi = %MidiList.get_selection()
	if midi != null:
		%MidiList.cleanup_midi_cache(midi)
	%MidiList.clear_items()
	# 清空 MidiListItem 的静态信息缓存（_info_cache），避免浏览多个大 MIDI 后
	# bpm_timeline 等字段累积导致长期内存泄漏（每条 1+ MB）
	_MidiListItem._info_cache.clear()


# midilist 内部切换检测（prev/next/list 展开/列表项点击均直接改 selected_item，
# 由 BaseScrollList 的 selection_changed 信号统一通知，替代原先 _process 逐帧轮询）
# 选中项变化时刷新导航位置 + 收藏夹面板 + 排行榜
func _on_selection_changed(index: int) -> void:
	if index == -1:
		return
	var midi: MidiData = %MidiList.get_selection()
	if midi:
		# 记录导航位置：切换 midi 时记录具体选中项（仅在有 album/song 上下文的导航链内，
		# 收藏夹直达等路径不写，避免残缺记录干扰恢复）
		if NavigationState.get_song_id() != "":
			NavigationState.update({"midi_id": midi.id})
		if _favor_panel_visible:
			%FavorPanel.show_with_midi(midi)
		# 同步刷新排行榜
		%ScoreList.load_scores(midi)
		# 同步刷新评论区
		%CommentPanel.load_comments(midi)
		# 简介展开时同步刷新简介操作按钮（在网页查看 / 上传歌曲）
		if showing_info:
			_refresh_redirect_buttons(midi)

# 点击开始游戏的事件
func _on_click_start_btn() -> void:
	var midi:MidiData = %MidiList.get_selection()
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
	var midi:MidiData = %MidiList.get_selection()
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
		var midi: MidiData = %MidiList.get_selection()
		if not midi:
			return
		%FavorPanel.show_with_midi(midi)
		_show_favor_panel()


# 显示收藏夹面板：两阶段动画，避免布局跳变
func _show_favor_panel() -> void:
	_is_animating = true
	_favor_panel_visible = true
	favor_list_btn.icon.region = Rect2(160, 160, 80, 80)
	_prev_tab_idx = %OptTabs.current_tab
	var current_page = %OptTabs.get_tab_control(_prev_tab_idx) if _prev_tab_idx >= 0 else null
	# FavorPanel 提前就位（布局占位，视觉偏移到下方）
	%FavorPanel.visible = true
	%FavorPanel.modulate.a = 0.0
	%FavorPanel.offset_transform_position.y = 800
	# 第一阶段：TabBtn 淡出 + 高度收缩，布局空间平滑释放
	var tween1 := AniMGR.create_managed_tween(self).set_parallel(true)
	tween1.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
	tween1.tween_property(%OptTabBtns, "modulate:a", 0.0, 0.2)
	tween1.tween_property(%OptTabBtns, "custom_minimum_size:y", 0, 0.2)
	tween1.tween_property(%OptTabs, "offset_top", 0, 0.2)
	if current_page:
		tween1.tween_property(current_page, "modulate:a", 0.0, 0.2)
	await tween1.finished
	%OptTabBtns.visible = false
	# 切换到 FavorPanel 标签页，使其成为当前可见标签后，再执行下方滑入 + 淡入
	%OptTabs.current_tab = 3
	# 第二阶段：FavorPanel 从下方滑入 + 淡入
	var tween2 := AniMGR.create_managed_tween(self).set_parallel(true)
	tween2.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
	tween2.tween_property(%FavorPanel, "modulate:a", 1.0, 0.3)
	tween2.tween_property(%FavorPanel, "offset_transform_position:y", 0, 0.4)
	await tween2.finished
	_is_animating = false


# 隐藏收藏夹面板：两阶段反向动画
func _hide_favor_panel(exiting_page: bool = false) -> void:
	_is_animating = true
	_favor_panel_visible = false
	favor_list_btn.icon.region = Rect2(320, 0, 80, 80)
	%FavorPanel.cancel_create()
	var target_page: Control = %OptTabs.get_tab_control(_prev_tab_idx)
	if not exiting_page:
		# 第一阶段：FavorPanel 滑出到下方 + 淡出
		var tween1 := AniMGR.create_managed_tween(self).set_parallel(true)
		tween1.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
		tween1.tween_property(%FavorPanel, "modulate:a", 0.0, 0.2)
		tween1.tween_property(%FavorPanel, "offset_transform_position:y", 800, 0.3)
		await tween1.finished
	else:
		%FavorPanel.modulate.a = 0.0
		%FavorPanel.offset_transform_position.y = 800
	%OptTabs.current_tab = _prev_tab_idx
	# 显式隐藏并复位 FavorPanel：清掉下移偏移与透明度，避免残留 800 偏移 + 可见状态卡在下方
	%FavorPanel.visible = false
	%FavorPanel.offset_transform_position.y = 0
	%FavorPanel.modulate.a = 1.0
	# 第二阶段：TabBtn 高度恢复 + 淡入 + 目标标签页淡入
	%OptTabBtns.visible = true
	%OptTabBtns.modulate.a = 1.0 if exiting_page else 0.0
	%OptTabBtns.custom_minimum_size.y = 120 if exiting_page else 0
	%OptTabs.offset_top = 120.0 if exiting_page else 0.0
	
	target_page.visible = true
	target_page.modulate.a = 1.0 if exiting_page else 0.0
	if not exiting_page:
		var tween2 := AniMGR.create_managed_tween(self).set_parallel(true)
		tween2.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
		tween2.tween_property(%OptTabBtns, "modulate:a", 1.0, 0.25)
		tween2.tween_property(%OptTabBtns, "custom_minimum_size:y", 120, 0.25)
		tween2.tween_property(%OptTabs, "offset_top", 120, 0.25)
		tween2.tween_property(target_page, "modulate:a", 1.0, 0.25)
		await tween2.finished
	_is_animating = false

	if exiting_page:
		%RankBtn.button_pressed=true

# 显示简介什么的
func _on_info_btn_pressed():
	if %MidiList.selected_item == -1:
		return
	_set_info_visible(not showing_info)

## 设置展开简介面板的可见性（true=展开简介隐藏列表，false=显示列表收起简介）
## _on_info_btn_pressed 和 restore_panel_state 共用此函数
func _set_info_visible(v: bool) -> void:
	showing_info = v
	# 窗口部分
	%MidiDescription.visible = v
	%MidiList.visible = not v
	# 禁用按钮，防止点击
	for btn in left_btns:
		btn.disabled = v
	%DeleteBtn.disabled = v
	%MidiList.get_parent().get_parent().size_flags_vertical = Control.SIZE_EXPAND_FILL if v else SIZE_FILL
	# 数据区
	%DetailData.visible = not v
	if v:
		_refresh_redirect_buttons(%MidiList.get_selection())
	else:
		%RedirectButtons.visible = false
	%MidiList.need_snap = true

## 刷新简介下方的操作按钮组：
## - 商店下载的谱面（存在服务端详情页）→ 显示「在网页查看」
## - 本地导入的谱面且开启「显示上传按钮」→ 显示「上传歌曲」
## - 两者都没有时整个按钮组不占位（简介直接铺满）
func _refresh_redirect_buttons(midi: MidiData) -> void:
	if midi == null:
		%CheckinWebBtn.visible = false
		%UploadSongBtn.visible = false
		%RedirectButtons.visible = false
		return

	var show_web := midi.is_store_downloaded()
	var show_upload := midi.is_local_import() and _is_upload_button_enabled()
	%CheckinWebBtn.visible = show_web
	%UploadSongBtn.visible = show_upload
	%RedirectButtons.visible = showing_info and (show_web or show_upload)

## 「显示上传按钮」开关（高级选项，默认关闭）
func _is_upload_button_enabled() -> bool:
	if ConfigManager.instance == null:
		return false
	return ConfigManager.instance.get_int("show_upload_button", 0) == 1

## 配置变更：简介展开期间即时响应「显示上传按钮」
func _on_config_changed(key: String, _value: Variant) -> void:
	if key == "show_upload_button" and showing_info:
		_refresh_redirect_buttons(%MidiList.get_selection())

## 简介里的链接点击（BBCode [url] 的 meta 为清洗后的 URL）
func _on_description_meta_clicked(meta: Variant) -> void:
	if not MidiDescriptionParser.open_url(str(meta)):
		EvtBus.notify("链接无效或无法打开")

## 在网页查看：商店下载的谱面跳转对应详情页
func _on_click_checkin_web_btn() -> void:
	var midi: MidiData = %MidiList.get_selection()
	if midi == null or not midi.is_store_downloaded():
		return
	var url := ""
	if NetManager.instance != null:
		url = NetManager.instance.get_chart_web_url(midi.file_hash if not midi.file_hash.is_empty() else midi.id)
	if url.is_empty():
		# 详情页地址接口尚未提供：保留占位，不做跳转
		EvtBus.notify("详情页链接尚未提供")
		return
	if not MidiDescriptionParser.open_url(url):
		EvtBus.notify("无法打开详情页")

## 上传歌曲：仅本地导入谱面可见；MIDI 与人声文件由 NetManager 的上传入口收集
func _on_click_upload_song_btn() -> void:
	var midi: MidiData = %MidiList.get_selection()
	if midi == null or not midi.is_local_import():
		return
	if NetManager.instance == null:
		EvtBus.notify("网络管理器未就绪")
		return
	var result: Dictionary = NetManager.instance.upload_local_chart(midi)
	if bool(result.get("ok", false)):
		EvtBus.notify("上传请求已提交")
		return
	var error := str(result.get("error", ""))
	if error == "not_implemented":
		EvtBus.notify("上传功能尚未开放")
	else:
		EvtBus.notify("上传失败：%s" % error)

func _on_del_btn_pressed():
	var window = PopupWindow.instance
	var midi_to_del: MidiData = %MidiList.get_selection()

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
			# 人声可能正被播放器持有（Windows 上打开中的文件删不掉，err 1），先释放再删
			FileSystemManager.instance.release_vocal_lock(chart_id)
			if not FileSystemManager.instance.delete_file(vocal_path):
				window.show_message("删除人声文件失败")
				return
			# 更新内存
			midi_to_del.vocal_file_path = ""
			midi_to_del.vocal_offset_ms = 0
			midi_to_del.vocal_volume = -1.0  # -1=未配置（跟随全局 default_vocal_volume）
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
			midi_to_del.vocal_volume = -1.0  # -1=未配置（跟随全局 default_vocal_volume）
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
				%MidiList.remove_selected_midi()
			elif album_still_exists:
				# Song 被删除但 Album 仍存在，重新加载该 Album 的 SongView（空列表）
				%MidiList.current_midis.erase(midi_to_del)
				%MidiList._refresh_display()
				EvtBus.album_selected.emit(album_id_before)
				UiStatMGR.go_back()
			else:
				# Song 和 Album 都被删除，直接跳回 AlbumView
				# 确保静态 SelectedAlbum 头部卡片隐藏复位（直接跳转时可能跳过 SongView 的退出流程）
				var sa_node = GlobalNodes.selected_album
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
	%RankBtn.button_pressed=true
	# 重置展开简介状态（若已展开则收起）
	if showing_info:
		_set_info_visible(false)
	# 退出动画完毕，执行延迟的列表清理
	if _pending_cleanup:
		_pending_cleanup = false
		_cleanup()
