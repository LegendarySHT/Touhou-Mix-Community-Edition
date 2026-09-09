## 动画管理器
## 统一管理项目中的动画和Tween，避免重复创建和内存泄漏
extends Node

class_name AnimationManager

## 预定义的动画时长
const DURATION_QUICK = 0.2
const DURATION_NORMAL = 0.3
const DURATION_SLOW = 0.5

## 预定义的缓动方式
const EASING_STANDARD = Tween.EASE_OUT
const EASING_SMOOTH = Tween.EASE_IN_OUT
const EASING_SHARP = Tween.EASE_IN

## 所有活跃Tween的集合（用于统一管理）
var active_tweens: Dictionary[String, Tween] = {}

## Tween计数器（为每个Tween生成唯一ID）
var tween_counter: int = 0

# 场景退出信号
signal scene_transition_fin

var _current_transition_version: int = -1

func _ready() -> void:
	add_to_group("singleton")

	# 连接场景退出信号
	var UI: UIStateManager = UiStatMGR
	if UI:
		UI.state_changed.connect(_scene_transition_exit)
		#UI.state_entering.connect(_scene_transition_enter)

## 创建位置动画
func animate_position(target: Node, to_pos: Vector2, duration: float = DURATION_NORMAL, 
					  tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(target, "position", to_pos, duration)
	return tween

## 列表项水平滑动动画
var out_item_idx: int = -1
func animate_list_item_horizontal(target: BaseScrollList, center_index: int, horizon_delta: int, tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)

	var screen_rect = get_viewport().get_visible_rect()
	var container: Container = target.container

	var range_left = maxi(center_index - 3, 0)
	var range_right = mini(center_index + 10, container.get_child_count())

	for i in range(range_left, range_right):
		var tag = container.get_child(i)
		if not tag.get_global_rect().intersects(screen_rect):
			pass
		tween.tween_property(tag,"offset_transform_position:x",horizon_delta,0.05)
	return tween

## 创建透明度动画
func animate_modulate(target: Node, to_color: Color, duration: float = DURATION_NORMAL,
					  tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(target, "modulate", to_color, duration)
	return tween

## 创建缩放动画
func animate_scale(target: Node, to_scale: Vector2, duration: float = DURATION_NORMAL,
				   tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(target, "scale", to_scale, duration)
	return tween

## 创建旋转动画
func animate_rotation(target: Node, to_rotation: float, duration: float = DURATION_NORMAL,
					  tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(target, "rotation", to_rotation, duration)
	return tween

## 创建大小动画（仅Control节点）
func animate_size(target: Control, to_size: Vector2, duration: float = DURATION_NORMAL,
				  tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(target, "size", to_size, duration)
	return tween

## 创建淡入效果
func animate_fade_in(target: Node, duration: float = DURATION_NORMAL,
					 tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	if not target.visible:
		target.visible = true

	target.modulate.a = 0.0
	tween.tween_property(target, "modulate:a", 1.0, duration)
	return tween

## 创建淡出效果
func animate_fade_out(target: Node, duration: float = DURATION_NORMAL,
					  tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(target, "modulate:a", 0.0, duration)
	tween.finished.connect(func() -> void:
		if target and target.visible:
			target.visible = false
	)
	return tween

## 创建菜单展开动画
func animate_menu_expand(target: Control, target_height: float, 
						duration: float = DURATION_NORMAL,
						tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_SMOOTH)
	tween.set_trans(Tween.TRANS_BACK)
	tween.tween_property(target, "custom_minimum_size:y", target_height, duration)
	return tween

## 创建菜单收起动画
func animate_menu_collapse(target: Control, duration: float = DURATION_NORMAL,
						   tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_SMOOTH)
	tween.set_trans(Tween.TRANS_BACK)
	tween.tween_property(target, "custom_minimum_size:y", 0, duration)
	return tween

## 创建弹跳动画
func animate_bounce(target: Node, from_pos: Vector2, to_pos: Vector2,
					duration: float = DURATION_NORMAL,
					tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_BOUNCE)
	target.position = from_pos
	tween.tween_property(target, "position", to_pos, duration)
	return tween

## 创建脉冲效果
func animate_pulse(target: Node, min_scale: float = 0.9, max_scale: float = 1.0,
				   duration: float = DURATION_QUICK,
				   tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(target, "scale", Vector2(max_scale, max_scale), duration / 2.0)
	tween.tween_property(target, "scale", Vector2(min_scale, min_scale), duration / 2.0)
	return tween

func animate_offset_to(target: Node, to_offset: Vector2, duration: float = DURATION_NORMAL,
					   tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	target.offset_transform_enabled = true
	target.offset_transform_visual_only = false
	tween.tween_property(target, "offset_transform_position", to_offset, duration)
	return tween

func animate_offset_back(target: Node, duration: float = DURATION_NORMAL,
						 tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	target.offset_transform_enabled = true
	tween.tween_property(target, "offset_transform_position", Vector2.ZERO, duration)
	return tween

## 创建 offset_transform_scale 缩放动画（用于 Control 节点的非破坏性缩放，不影响布局）
func animate_offset_scale(target: Node, to_scale: Vector2, duration: float = DURATION_NORMAL,
						  tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	target.offset_transform_enabled = true
	tween.tween_property(target, "offset_transform_scale", to_scale, duration)
	return tween

## 创建 offset_transform_rotation 旋转动画（用于 Control 节点的非破坏性旋转，不影响布局）
func animate_offset_rotation(target: Node, to_rotation: float, duration: float = DURATION_NORMAL,
							 tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	target.offset_transform_enabled = true
	tween.tween_property(target, "offset_transform_rotation", to_rotation, duration)
	return tween

######################################## 组合动画（后续通用复用） ########################################

## 原地淡入 + 缩放（from_scale → 1），适合弹窗/面板入场
func animate_fade_scale_in(target: Control, from_scale: Vector2 = Vector2(1.1, 1.1),
							duration: float = DURATION_NORMAL, tween_id: String = "") -> Tween:
	var tween := _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	if not target.visible:
		target.visible = true
	target.modulate.a = 0.0
	target.offset_transform_enabled = true
	target.offset_transform_scale = from_scale
	tween.tween_property(target, "modulate:a", 1.0, duration)
	tween.parallel().tween_property(target, "offset_transform_scale", Vector2.ONE, duration)
	return tween

## 原地淡出 + 缩放（轻微缩小/放大），作为 fade_scale_in 的反向动画
func animate_fade_scale_out(target: Control, to_scale: Vector2 = Vector2(0.96, 0.96),
							 duration: float = DURATION_NORMAL, tween_id: String = "") -> Tween:
	var tween := _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(target, "modulate:a", 0.0, duration)
	tween.parallel().tween_property(target, "offset_transform_scale", to_scale, duration)
	tween.finished.connect(func() -> void:
		if target and target.visible:
			target.visible = false
	)
	return tween

## 淡入 + 位移滑入（from_offset → 原位）
func animate_fade_slide_in(target: Control, from_offset: Vector2,
							duration: float = DURATION_NORMAL, tween_id: String = "") -> Tween:
	var tween := _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	if not target.visible:
		target.visible = true
	target.modulate.a = 0.0
	target.offset_transform_enabled = true
	target.offset_transform_position = from_offset
	tween.tween_property(target, "modulate:a", 1.0, duration)
	tween.parallel().tween_property(target, "offset_transform_position", Vector2.ZERO, duration)
	return tween

## 淡出 + 位移滑出（to_offset），作为 fade_slide_in 的反向动画
func animate_fade_slide_out(target: Control, to_offset: Vector2,
							 duration: float = DURATION_NORMAL, tween_id: String = "") -> Tween:
	var tween := _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(target, "modulate:a", 0.0, duration)
	tween.parallel().tween_property(target, "offset_transform_position", to_offset, duration)
	tween.finished.connect(func() -> void:
		if target and target.visible:
			target.visible = false
	)
	return tween

## 淡入 + 位移滑入 + 缩放（from_offset + from_scale → 原位 1:1），适合大图入场
func animate_fade_slide_scale_in(target: Control, from_offset: Vector2, from_scale: Vector2 = Vector2.ONE,
								   duration: float = DURATION_NORMAL, tween_id: String = "") -> Tween:
	var tween := _create_tween(tween_id)
	tween.set_ease(EASING_STANDARD)
	tween.set_trans(Tween.TRANS_CUBIC)
	if not target.visible:
		target.visible = true
	target.modulate.a = 0.0
	target.offset_transform_enabled = true
	target.offset_transform_position = from_offset
	target.offset_transform_scale = from_scale
	tween.tween_property(target, "modulate:a", 1.0, duration)
	tween.parallel().tween_property(target, "offset_transform_position", Vector2.ZERO, duration)
	tween.parallel().tween_property(target, "offset_transform_scale", Vector2.ONE, duration)
	return tween

## 上下浮动无限循环动画（offset 相对基准 0 上下浮动 amplitude；用 stop_tween 结束）
func animate_floating(target: Control, amplitude: float, duration: float = 1.5,
						tween_id: String = "") -> Tween:
	var tween := _create_tween(tween_id)
	tween.set_loops()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(target, "offset_transform_position:y", amplitude, duration)
	tween.tween_property(target, "offset_transform_position:y", 0.0, duration)
	return tween

## 延迟执行回调
func delay_call(callback: Callable, delay: float, tween_id: String = "") -> Tween:
	var tween = _create_tween(tween_id)
	tween.tween_callback(callback).set_delay(delay)
	return tween

## 创建序列动画（多个动画依次执行）
func create_sequence(tween_id: String = "") -> Tween:
	return _create_tween(tween_id)

## 通用 Tween 工厂：绑定到指定节点并纳入统一管理（替代各处的裸 create_tween()）
## tween_id 可选：提供后可用 stop_tween/pause_tween/resume_tween 管理；重名会先杀掉旧 Tween。
## 注意：绑定到 target 节点（与调用方裸 create_tween() 的暂停/生命周期语义一致），
## 仅创建与清理路径经过 AnimationManager 统一管理。
func create_managed_tween(target: Node, tween_id: String = "") -> Tween:
	if not is_instance_valid(target):
		push_warning("AnimationManager.create_managed_tween: invalid target")
		return null
	if not tween_id.is_empty() and active_tweens.has(tween_id):
		active_tweens[tween_id].kill()
	if tween_id.is_empty():
		tween_id = "managed_%d" % tween_counter
		tween_counter += 1
	_prune_active_tweens()
	var tween := target.create_tween()
	active_tweens[tween_id] = tween
	tween.finished.connect(func() -> void:
		if active_tweens.get(tween_id) == tween:
			active_tweens.erase(tween_id)
	)
	return tween

## 清理已失效的 Tween 条目（防止循环动画等长期存活条目无限堆积）
func _prune_active_tweens() -> void:
	if active_tweens.size() < 256:
		return
	var stale: Array[String] = []
	for tid in active_tweens:
		var tw: Tween = active_tweens[tid]
		if tw == null or not tw.is_valid():
			stale.append(tid)
	for tid in stale:
		active_tweens.erase(tid)

## 获取或创建Tween（使用tween_id来保存和重用）
func _create_tween(tween_id: String = "") -> Tween:
	# 如果提供了ID且已存在，则杀死旧Tween
	if not tween_id.is_empty() and active_tweens.has(tween_id):
		active_tweens[tween_id].kill()
	
	# 生成唯一ID（如果未提供）
	if tween_id.is_empty():
		tween_id = "tween_%d" % tween_counter
		tween_counter += 1
	
	# 创建新Tween
	var tween = create_tween()
	active_tweens[tween_id] = tween
	
	# 连接Tween完成信号以清理
	tween.finished.connect(func() -> void:
		active_tweens.erase(tween_id)
	)
	
	return tween

## 停止特定ID的Tween
func stop_tween(tween_id: String) -> void:
	if active_tweens.has(tween_id):
		active_tweens[tween_id].kill()
		active_tweens.erase(tween_id)

## 停止所有Tween
func stop_all_tweens() -> void:
	for tween in active_tweens.values():
		if tween and tween.is_valid():
			tween.kill()
	active_tweens.clear()

## 暂停特定ID的Tween
func pause_tween(tween_id: String) -> void:
	if active_tweens.has(tween_id):
		active_tweens[tween_id].pause()

## 恢复特定ID的Tween
func resume_tween(tween_id: String) -> void:
	if active_tweens.has(tween_id):
		active_tweens[tween_id].play()

## 获取活跃Tween数量
func get_active_tween_count() -> int:
	return active_tweens.size()

## 销毁时清理所有Tween
func _exit_tree() -> void:
	stop_all_tweens()

############################## 页面切换动画 #######################################

## 记录所有组件的状态
var ui_exist = {
	"Album_List" : false,
	"Player_Info": false,
	"Character": false,
	"Shortcut_Menu" : false,
	"Song_List" : false,
	"Sorted_List" : false,
	"Midi_Info_View" : false,
	"Store_View": false,
	"Track_List": false,
	"Play_View": false,
	"Setting_View": false,
	"Score_View": false,
	"Chara_View": false,
	"Profile_Page": false,
}

## 记录每个页面存在哪些组件
var ui_part = {
	UIStateManager.UIState.NONE: [],  # 启动初始态：无组件，避免 _scene_transition_exit 对 NONE 键取空
	UIStateManager.UIState.ALBUM_VIEW: ["Album_List", "Player_Info", "Shortcut_Menu", "Character"],
	UIStateManager.UIState.SONG_VIEW: ["Song_List", "Player_Info", "Shortcut_Menu", "Character"],
	UIStateManager.UIState.SORTED_VIEW: ["Sorted_List", "Player_Info", "Shortcut_Menu", "Character"],
	UIStateManager.UIState.MIDI_VIEW: ["Midi_Info_View"],
	UIStateManager.UIState.STORE_VIEW: ["Store_View"],
	UIStateManager.UIState.TRACK_VIEW: ["Track_List"],
	UIStateManager.UIState.SETTINGS_VIEW: ["Setting_View"],
	UIStateManager.UIState.PLAY_VIEW: ["Play_View"],
	UIStateManager.UIState.SCORE_VIEW: ["Score_View"],
	UIStateManager.UIState.CHARA_VIEW: ["Chara_View"],
	UIStateManager.UIState.PROFILE_VIEW: ["Profile_Page", "Player_Info"]
}

var ui_path_map = {
	"Album_List" : PathRegistry.ALBUM_LIST,
	"Song_List" : PathRegistry.SONG_LIST,
	"Player_Info": PathRegistry.PLAYER_INFO,
	"Character": PathRegistry.CHARACTER,
	"Sorted_List" : PathRegistry.SORTED_MIDIS_LIST,
	"Shortcut_Menu" : PathRegistry.SHORTCUT_MENU,
	"Midi_Info_View" : PathRegistry.MIDI_VIEW,
	"Store_View": PathRegistry.STORE_VIEW,
	"Track_List": PathRegistry.TRACK_VIEW,
	"Play_View": PathRegistry.PLAY_VIEW,
	"Setting_View": PathRegistry.SETTING_VIEW,
	"Score_View": PathRegistry.SCORE_VIEW,
	"Chara_View": PathRegistry.CHARA_VIEW,
	"Profile_Page": PathRegistry.PROFILE_PAGE,
}

func get_comp(ui_part_name: String) -> Node:
	if not ui_path_map[ui_part_name]:
		return
	var node = get_node_or_null(ui_path_map[ui_part_name])
	if node:
		return node
	else:
		# 懒加载视图未实例化时返回 null 是合法状态（调用方均用 is_instance_valid 检查）
		# 用 debug 而非 push_error，避免每次切换视图时对未加载视图产生噪音
		GLogger.debug("[AniMGR] COMP %s Not Found" % ui_part_name, "AniMGR")
		return null

var tan15 = tan(deg_to_rad(15))

## 当前要展示在 SelectedAlbum 头部卡片上的专辑数据（选中项优先；恢复/直达路径回退到 SongView 当前专辑）
func _get_selected_album_data() -> Dictionary:
	var album_list: AlbumView = get_comp("Album_List")
	if album_list == null or album_list.current_albums.is_empty():
		return {}
	var idx := album_list.selected_item
	if idx < 0 or idx >= album_list.current_albums.size():
		idx = out_item_idx
	if idx >= 0 and idx < album_list.current_albums.size():
		return album_list.current_albums[idx]
	# 回退：按 SongView 当前专辑 id 在专辑投影中查找（导航恢复等直达路径 selected_item 为 -1）
	var song_list_ref: SongView = get_comp("Song_List")
	var target_id := song_list_ref.current_album_id if song_list_ref else ""
	if target_id != "":
		for d in album_list.current_albums:
			if str(d.get("id", "")) == target_id:
				return d
	return {}

## 页面组件退出动画
func _scene_transition_exit(old_state: UIStateManager.UIState, new_state: UIStateManager.UIState) -> void:
	_current_transition_version = UiStatMGR.transition_version

	# 收集所有退出动画的有效 tween，等待其中任一完成后再进入新场景
	var valid_out_tween: Tween = null
	for key in ui_exist.keys():
		if ui_exist[key] and (key in ui_part[old_state]) and (key not in ui_part[new_state]):
			var tween := animate_ui_out(key, old_state, new_state)
			ui_exist[key] = false
			if tween and tween.is_valid() and not valid_out_tween:
				valid_out_tween = tween

	# 等待其中一个有效的 tween 完成，再触发入场动画
	if valid_out_tween:
		var captured_version := _current_transition_version
		valid_out_tween.finished.connect(func() -> void:
			if UiStatMGR.transition_version != captured_version:
				return
			_scene_transition_enter(old_state, new_state)
		)
	else:
		_scene_transition_enter(old_state, new_state)

func _scene_transition_enter(old_state: UIStateManager.UIState, new_state: UIStateManager.UIState) -> void:
	if UiStatMGR.transition_version != _current_transition_version:
		return
	# 新组件：播放入场动画，收集所有有效 tween
	var valid_in_tween: Tween = null
	for key in ui_exist.keys():
		if not ui_exist[key] and key in ui_part.get(new_state, []):
			var tween := animate_ui_in(key, old_state)
			ui_exist[key] = true
			if tween and tween.is_valid() and not valid_in_tween:
				valid_in_tween = tween

	# 等待其中一个有效的 tween 完成，再发射结束信号
	if valid_in_tween:
		var captured_version := _current_transition_version
		valid_in_tween.finished.connect(func() -> void:
			if UiStatMGR.transition_version != captured_version:
				return
			scene_transition_fin.emit()
		)
	else:
		scene_transition_fin.emit()

func animate_ui_out(ui_name: String, _old_state: UIStateManager.UIState, new_state: UIStateManager.UIState) -> Tween:
	GLogger.info("组件退出动画: %s" % ui_name, "AnimationManager")
	var tween_id = "%s_out" % ui_name
	var tween : Tween
	
	# 播放动画的组件
	var album_list:AlbumView = get_comp("Album_List")
	var song_list:SongView = get_comp("Song_List")
	var ani_comp = get_comp(ui_name)

	match ui_name:
		"Album_List":
			var sIndex = album_list.selected_item

			# 静态 SelectedAlbum 头部卡片：退出时只设置展示内容（可见与右移入场在 Song_List 入场时处理，
			# 避免恢复/直达路径下直接 visible 导致的突兀出现）
			if new_state == UIStateManager.UIState.SONG_VIEW:
				var album_data := _get_selected_album_data()
				if not album_data.is_empty():
					var sa := get_node_or_null(PathRegistry.SELECTED_ALBUM)
					if sa:
						sa.set_display_album(album_data)

			# 列表项左移退出
			animate_list_item_horizontal(album_list, sIndex, -1200, tween_id)

			out_item_idx = sIndex
			tween = animate_fade_out(album_list, 0.5, "AlbumListFadeOut")
			animate_fade_out(get_node(PathRegistry.RANDOM_SELECT_BTN), 0.7, "RandomSelectFadeOut")
		"Song_List":
			# 静态 SelectedAlbum：离开 SongView 时左移退出，结束后隐藏并复位（去向一致）
			var sa := get_node_or_null(PathRegistry.SELECTED_ALBUM)
			if sa:
				sa.offset_transform_enabled = true
				var sa_tween := animate_offset_to(sa, Vector2(-1200, 0), 0.25, "SSPosition")
				sa.modulate.a = 1.0
				sa_tween.finished.connect(func() -> void:
					if is_instance_valid(sa):
						sa.visible = false
						sa.offset_transform_position = Vector2.ZERO
				)

			# 歌曲列表收起
			animate_fade_out(song_list, 0.25, "SongListFadeOut")
			tween = animate_offset_to(song_list, Vector2(0, song_list.size.y), 0.25, tween_id)

		"Sorted_List":
			# 覆盖层与滚动容器同步滑出，保证下次入场时两者初始偏移对齐（各视图退出后置于 -1500）
			var overlay := get_node_or_null(PathRegistry.SKEW_C + "/SortedMidiContainer")
			if overlay:
				var otween := animate_offset_to(overlay, Vector2(-1500, 0), 0.25, "SortedOverlayOut")
				otween.finished.connect(func() -> void:
					if is_instance_valid(overlay):
						overlay.visible = false
				)
			tween = animate_offset_to(ani_comp, Vector2(-1500, 0), 0.25, tween_id)
			tween.finished.connect(func() -> void:
				ani_comp.visible=false
			)
		"Midi_Info_View":
			tween = animate_fade_out(ani_comp, 0.3, tween_id)
			
			tween.finished.connect(func() -> void:
				ani_comp.restore_panel_state()
			)
		"Player_Info":
			animate_offset_to(ani_comp, Vector2(ani_comp.size.x * 1.3, ani_comp.offset_transform_position.y), 0.55, "PlayerInfoPosition")
		"Character":
			animate_offset_to(ani_comp, Vector2(0, ani_comp.size.y), 0.35, "CharacterPosition")
		"Shortcut_Menu":
			ani_comp.play_transition_animation(true)
		"Store_View":
			tween = animate_fade_out(ani_comp, 0.35, tween_id)
		"Track_List":
			tween = animate_fade_out(ani_comp, 0.35, tween_id)
			animate_offset_to(ani_comp, Vector2(0, 1080), 0.25, "track_pos")
		"Play_View":
			tween = animate_fade_out(ani_comp, 0.45, tween_id)
		"Setting_View":
			if ani_comp.has_method("has_pending_changes") and ani_comp.has_pending_changes():
				_save_settings_on_exit(ani_comp)
			
			var btns = ani_comp.get_node("HBoxC/ShortCut")
			var setting_list = ani_comp.get_node("HBoxC/SettingList")
			tween = animate_offset_to(btns, Vector2(-500, 0), 0.35, "sv_btns")
			animate_offset_to(setting_list, Vector2(-1500, 0), 0.25, "sv_info")

			tween = animate_fade_out(ani_comp, 0.35, tween_id)
			if ani_comp.has_method("switch_page_instant"):
				ani_comp.switch_page_instant()
			else:
				ani_comp.switch_page()
		"Score_View":
			tween = ani_comp.animate(false)
		"Chara_View":
			if ani_comp == null or not is_instance_valid(ani_comp):
				return null
			if ani_comp.has_method("play_exit"):
				ani_comp.play_exit()
		"Profile_Page":
			var navi := ani_comp.get_node_or_null("Navi")
			if navi:
				animate_offset_to(navi, Vector2(0, navi.size.y), 0.3, "ProfileNaviOut")
			var content := ani_comp.get_node_or_null("PC/PageContent")
			if content:
				tween = animate_fade_out(content, 0.3, tween_id)

	return tween

## 保存设置配置（在 SettingView 退出时调用）
func _save_settings_on_exit(setting_view: Control) -> void:
	if not setting_view or not setting_view.has_method("save_config_to_file"):
		return
	
	# 调用 SettingView 的保存方法
	var success = setting_view.save_config_to_file()
	
	if success:
		GLogger.info("Settings saved successfully", "AnimationManager")
		
		# 发出通配符信号，通知所有监听者配置已变化
		if EvtBus:
			EvtBus.settings_changed.emit("*", null)
	else:
		push_warning("[AnimationManager] Failed to save settings")

func animate_ui_in(ui_name: String, _old_state: UIStateManager.UIState) -> Tween:
	GLogger.info("组件进入动画: %s" % ui_name, "AnimationManager")
	var tween_id = "%s_in" % ui_name
	var tween : Tween

	# 播放动画的组件
	var album_list:AlbumView = get_comp("Album_List")
	var song_list:SongView = get_comp("Song_List")
	var ani_comp = get_comp(ui_name)
	if is_instance_valid(ani_comp) and ani_comp is CanvasItem:
		ani_comp.visible = true
		ani_comp.modulate.a = 1.0

	match ui_name:
		"Album_List":
			animate_fade_in(album_list, 0.35, "AlbumListFadeIn")
			song_list.visible=false
			
			# 静态 SelectedAlbum 常驻：回到 AlbumView 时确保隐藏复位（原 SS 为临时节点此处 queue_free）
			var sa := get_node_or_null(PathRegistry.SELECTED_ALBUM)
			if sa:
				sa.visible = false
				sa.modulate.a = 1.0
				sa.offset_transform_position = Vector2.ZERO
			
			var sIndex = out_item_idx
			var vbox := album_list.container
			# 选中项退出时左移过，返回时先复位其 modulate（索引无效时跳过，不阻断滑回）
			if sIndex >= 0 and sIndex < vbox.get_child_count():
				vbox.get_child(sIndex).modulate = Color(1, 1, 1, 1)
			
			tween = animate_list_item_horizontal(album_list, sIndex, 0, tween_id)
			
			song_list.clear_items.call_deferred()
			tween = animate_fade_in(get_node(PathRegistry.RANDOM_SELECT_BTN), 0.35, "RandomSelectFadeIn")
		"Song_List":
			var sa := get_node_or_null(PathRegistry.SELECTED_ALBUM)
			# 进入 SongView：头部卡片从左侧起步、右移滑入到位（内容在退出时已设置，此处兜底覆盖恢复/直达路径）
			if sa:
				var album_data := _get_selected_album_data()
				if not album_data.is_empty():
					sa.set_display_album(album_data)
				sa.visible = true
				sa.modulate.a = 1.0
				sa.offset_transform_enabled = true
				sa.offset_transform_position = Vector2(-1200, 0)
				animate_offset_back(sa, 0.35, "SSPosition")

			song_list.visible=true
			song_list.offset_transform_position = Vector2(0, -1150)
			animate_offset_back(song_list, 0.15, tween_id)
			tween = animate_fade_in(song_list, 0.4, "SongListFadeIn")
		"Sorted_List":
			ani_comp.visible = true

			# 覆盖层（虚拟化项渲染容器，与滚动容器同级）与滚动容器同步入场：
			# 先强制对其初始偏移（退出/首次 tscn 停车位一致），再并行滑回 0，两动画同时结束
			var overlay := get_node_or_null(PathRegistry.SKEW_C + "/SortedMidiContainer")
			if overlay:
				overlay.visible = true
				if overlay.offset_transform_position != ani_comp.offset_transform_position:
					overlay.offset_transform_position = ani_comp.offset_transform_position
				animate_offset_back(overlay, 0.25, "SortedOverlayIn")

			tween = animate_offset_back(ani_comp, 0.25, tween_id)
		"Midi_Info_View":
			animate_fade_in(ani_comp, 0.1, "MidiViewFadeIn")

			ani_comp.offset_transform_position = Vector2(0, -500)
			tween = animate_offset_back(ani_comp, 0.5, tween_id)
		"Player_Info":
			# 离线模式下不显示玩家面板（仅检查 online_mode 配置，与 RB_Btn 商店图标一致）
			if not NetManager.is_online_mode():
				ani_comp.visible = false
				return null
			ani_comp.offset_transform_position = Vector2(900, 200)
			animate_offset_back(ani_comp, 0.35, "PlayerInfoPosition")
		"Character":
			ani_comp.offset_transform_position = Vector2(0, ani_comp.size.y)
			animate_offset_back(ani_comp, 0.35, "CharacterPosition")
		"Shortcut_Menu":
			tween = ani_comp.play_transition_animation(false)
		"Store_View":
			var top_bar = ani_comp.get_node("TopBar")
			top_bar.offset_transform_position = Vector2(0, -500)
			animate_offset_back(top_bar, 0.25, "top_bar_in")

			var bottom = ani_comp.get_node("Bottom")
			bottom.offset_transform_position = Vector2(0, 500)
			animate_offset_back(bottom, 0.25, "bottom_in")

			tween = animate_fade_in(ani_comp, 0.45, tween_id)
		"Track_List":
			ani_comp.scroll_vertical = 300
			tween = animate_fade_in(ani_comp, 0.45, tween_id)
			animate_offset_back(ani_comp, 0.25, "track_pos")
		"Play_View":
			tween = animate_fade_in(ani_comp, 0.45, tween_id)
		"Setting_View":
			var btns = ani_comp.get_node("HBoxC/ShortCut")
			var setting_list = ani_comp.get_node("HBoxC/SettingList")
			btns.offset_transform_position = Vector2(-500, 0)
			setting_list.offset_transform_position = Vector2(-1500, 0)
			tween = animate_offset_back(btns, 0.25, "sv_btns")
			animate_offset_back(setting_list, 0.35, "sv_info")
		"Score_View":
			if ani_comp == null or not is_instance_valid(ani_comp):
				return null
			ani_comp.visible = true
			ani_comp.call("animate")
		"Chara_View":
			if ani_comp == null or not is_instance_valid(ani_comp):
				return null
			if ani_comp.has_method("play_enter"):
				ani_comp.play_enter()
		"Profile_Page":
			# 底栏向上滑入 + 内容区淡入
			var navi := ani_comp.get_node_or_null("Navi")
			if navi:
				navi.offset_transform_position = Vector2(0, navi.size.y)
				animate_offset_back(navi, 0.3, "ProfileNaviIn")
			var content := ani_comp.get_node_or_null("PC/PageContent")
			if content:
				content.modulate.a = 0.0
				tween = animate_fade_in(content, 0.35, tween_id)

	return tween
