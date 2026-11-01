## UI状态管理器
## 使用状态机管理应用的UI状态
extends Node

class_name UIStateManager

## UI状态枚举
enum UIState {
	NONE = -1,           # 无状态
	ALBUM_VIEW = 0,      # 专辑列表页面
	SONG_VIEW = 1,       # 歌曲选择页面
	MIDI_VIEW = 2,       # MIDI详细页面
	TRACK_VIEW = 21, 	 # 音轨界面
	SORTED_VIEW = 3,     # 排序后的MIDI列表页面
	STORE_VIEW = 4,      # Store页面
	SETTINGS_VIEW = 5,   # 设置页面
	PLAY_VIEW = 6,		 # 打歌界面
	SCORE_VIEW = 61,	 # 结算界面
	CHARA_VIEW = 7,		 # 选角色界面
	PROFILE_VIEW = 8,	 # 个人资料界面
	MUSIC_PLAYER_VIEW = 9, # 音乐播放器界面
}

## 懒加载视图的固定挂载位置。遮挡关系只由树序表达，不再设置 z_index。
enum ViewLayer {
	SKEW_C,          ## skew/C 末尾：跟随倾斜区域的列表/详情视图
	MAIN_AFTER_RB,   ## RB_Btn 之后：压在左上/右下按钮之上（进入该视图时按钮通常已隐藏）
	MAIN_BEFORE_RB,  ## RB_Btn 之前：只挡左上角 LT_Btn，RB_Btn 仍在最上层
	MAIN_BEFORE_LT,  ## LT_Btn 之前：LT_Btn / RB_Btn 都保持可见、可点
}

## 当前UI状态（启动时为 NONE，数据就绪后通过 change_state 进入真实视图）
var current_state: UIState = UIState.NONE

## 上一个UI状态（用于返回）
var previous_state: UIState = UIState.NONE

## 状态历史栈
var state_history: Array[UIState] = []

## 状态改变信号
signal state_changed(old_state: UIState, new_state: UIState)
## 懒加载视图首次实例化完成（常驻组件需要在视图就绪后回填数据时订阅）
signal view_loaded(state: UIState, node: Node)
# signal state_entering(state: UIState)
# signal state_exiting(state: UIState)

## 最大历史记录深度
const MAX_HISTORY_DEPTH: int = 10

## 可懒加载的视图路径（UIState → PackedScene 路径）
const LAZY_VIEW_PATHS := {
	UIState.MIDI_VIEW: "res://UI/Views/MidiView/MidiView.tscn",
	UIState.STORE_VIEW: "res://UI/Views/StoreView/MidiStore.tscn",
	UIState.TRACK_VIEW: "res://UI/Views/TrackView/TrackView.tscn",
	UIState.SETTINGS_VIEW: "res://UI/Views/SettingView/SettingView.tscn",
	UIState.PLAY_VIEW: "res://UI/Views/PlayView/PlayView.tscn",
	UIState.SCORE_VIEW: "res://UI/Views/ScoreView/ScoreView.tscn",
	UIState.CHARA_VIEW: "res://UI/Views/CharaView/CharaView.tscn",
	UIState.PROFILE_VIEW: "res://UI/Views/ProfileView/ProfileView.tscn",
	UIState.MUSIC_PLAYER_VIEW: "res://UI/Views/MusicPlayerView/MusicPlayerView.tscn",
}

## 懒加载视图的挂载层级（UIState → ViewLayer）
const LAZY_VIEW_LAYERS := {
	UIState.MIDI_VIEW: ViewLayer.SKEW_C,
	UIState.STORE_VIEW: ViewLayer.MAIN_BEFORE_RB,
	UIState.TRACK_VIEW: ViewLayer.SKEW_C,
	UIState.SETTINGS_VIEW: ViewLayer.SKEW_C,
	UIState.PLAY_VIEW: ViewLayer.MAIN_AFTER_RB,
	UIState.SCORE_VIEW: ViewLayer.MAIN_BEFORE_LT,
	UIState.CHARA_VIEW: ViewLayer.MAIN_BEFORE_RB,
	UIState.PROFILE_VIEW: ViewLayer.MAIN_BEFORE_RB,
	UIState.MUSIC_PLAYER_VIEW: ViewLayer.MAIN_AFTER_RB,
}

## 已加载的懒加载视图实例 {UIState: Node}
var _loaded_lazy_views: Dictionary = {}

var signal_conn:bool = false

var transition_version: int = 0

var _data_ready: bool = false  ## 数据是否已加载完成（替代 is_loading 轮询）

func _ready() -> void:
	add_to_group("singleton")
	# 监听 DataManager 加载完成信号
	DataMGR.data_loaded.connect(_on_data_loaded)
	# 防止 data_loaded 在 _ready 之前已发射：一次性检查
	if not DataMGR.is_loading:
		_data_ready = true
		_restore_saved_navigation()
	# 导航记录清除钩子：退回 AlbumView 时清空记录
	# （启动时 current 已是 ALBUM_VIEW 无 transition，不会误清；go_back/go_back_to 均会 emit state_changed）
	state_changed.connect(func(old_state: UIState, new_state: UIState):
		if new_state == UIState.ALBUM_VIEW and old_state != UIState.ALBUM_VIEW:
			NavigationState.clear()
	)

func _on_data_loaded() -> void:
	_data_ready = true
	_restore_saved_navigation()

## 启动时恢复上次导航位置（一次性，仅两种深度：仅 album → SongView；有 song → MidiView）
var _nav_restore_started: bool = false

func _restore_saved_navigation() -> void:
	if _nav_restore_started:
		return
	if ChartDB == null or not ChartDB.IsOpen():
		return  # DB 未就绪：不消费标志，等 data_loaded 触发时重试
	_nav_restore_started = true
	_restore_saved_navigation_impl()

func _restore_saved_navigation_impl() -> void:
	# 等一帧：让 data_loaded 信号分发完成后 AlbumView 至少开始构建列表（Phase A 同步建节点），
	# 再走正常导航/入场路径，避免在空壳上播动画
	await get_tree().process_frame
	var album_id := NavigationState.get_album_id()
	if album_id.is_empty():
		# 无待恢复导航：触发当前状态（ALBUM_VIEW）入场，使默认隐藏的组件入场动画播出
		_enter_initial_view(UIState.ALBUM_VIEW)
		return
	# 校验专辑仍存在（DB 权威；已删则清记录，并回落到 AlbumView 入场）
	if ChartDB == null or not ChartDB.IsOpen() or ChartDB.GetAlbum(album_id).is_empty():
		NavigationState.clear()
		_enter_initial_view(UIState.ALBUM_VIEW)
		return

	var song_id := NavigationState.get_song_id()
	if not song_id.is_empty() and not ChartDB.SongExists(song_id):
		# 歌曲已删：清空完整记录，只恢复到专辑层级（与旧行为一致）
		NavigationState.clear()
		navigate_to_album_song(album_id, "", "", false)
		return

	var midi_id := NavigationState.get_midi_id() if not song_id.is_empty() else ""
	navigate_to_album_song(album_id, song_id, midi_id)

## 公共导航：从任意页面进入指定专辑/歌曲
## song_id 为空时只到 SongView；非空时进入 MidiView 并由 NavigationState 的 midi_id 预选。
## 返回链固定为 MIDI_VIEW → SONG_VIEW → ALBUM_VIEW（或 SONG_VIEW → ALBUM_VIEW）。
## 启动导航恢复与外部导入跳转共用，避免两处各写一套历史栈处理。
## save_navigation=false 时不写 NavigationState（启动恢复失败回退时用）。
func navigate_to_album_song(album_id: String, song_id: String = "", midi_id: String = "",
		save_navigation: bool = true) -> void:
	if not _data_ready:
		return
	if ChartDB == null or not ChartDB.IsOpen():
		return
	if album_id.is_empty() or ChartDB.GetAlbum(album_id).is_empty():
		return
	if not song_id.is_empty() and not ChartDB.SongExists(song_id):
		song_id = ""
		midi_id = ""
	if save_navigation:
		NavigationState.save(album_id, song_id, midi_id)

	# 已在 MidiView：只切到目标歌曲并重置返回链，不再走页面转场
	if current_state == UIState.MIDI_VIEW and not song_id.is_empty():
		state_history.clear()
		state_history.append(UIState.ALBUM_VIEW)
		state_history.append(UIState.SONG_VIEW)
		previous_state = UIState.SONG_VIEW
		EvtBus.album_selected.emit(album_id)
		EvtBus.emit_song_selected(song_id)
		return

	# 已在 SongView：目标只到歌曲则刷新列表；有 midi 则直接进 MidiView
	if current_state == UIState.SONG_VIEW:
		state_history.clear()
		state_history.append(UIState.ALBUM_VIEW)
		EvtBus.album_selected.emit(album_id)
		if song_id.is_empty():
			previous_state = UIState.ALBUM_VIEW
			return
		change_state(UIState.MIDI_VIEW, true)
		EvtBus.emit_song_selected(song_id)
		return

	# 其它页面（设置/商店/音轨/打歌等）：直达目标页，手动构造返回链，避免多级转场叠加
	if current_state != UIState.ALBUM_VIEW and current_state != UIState.NONE:
		state_history.clear()
		state_history.append(UIState.ALBUM_VIEW)
		EvtBus.album_selected.emit(album_id)
		if song_id.is_empty():
			change_state(UIState.SONG_VIEW, false)
			return
		state_history.append(UIState.SONG_VIEW)
		change_state(UIState.MIDI_VIEW, false)
		EvtBus.emit_song_selected(song_id)
		return

	# 启动/专辑页：复刻启动导航恢复的标准链
	# 历史栈基座 = ALBUM_VIEW：启动态为 NONE，不能作为返回目标。若直接 change_state(SONG_VIEW, true)
	# 会把 NONE 压栈，导致从恢复的 MidiView 按返回键链式退回时最终落到 NONE（非真实视图）。
	state_history.clear()
	state_history.append(UIState.ALBUM_VIEW)
	EvtBus.album_selected.emit(album_id)
	change_state(UIState.SONG_VIEW, false)
	if song_id.is_empty():
		return
	change_state(UIState.MIDI_VIEW, true)
	EvtBus.emit_song_selected(song_id)

## 无待恢复导航（或恢复目标已失效）时，触发初始视图入场（stash=false 保持历史栈为空）
func _enter_initial_view(state: UIState) -> void:
	if current_state == state:
		return
	change_state(state, false)

## 统一的新建入口：加载场景 → 实例化 → 按 layer 插入 → 置为隐藏。
## 视图的绘制/点击优先级全部由插入位置（树序）表达，不设置 z_index。
func create_view(scene_path: String, layer: ViewLayer) -> Node:
	var packed: PackedScene = load(scene_path)
	if packed == null:
		push_error("Failed to load view: %s" % scene_path)
		return null
	var instance: Node = packed.instantiate()
	instance.visible = false
	if not _place_view(instance, layer):
		instance.free()
		return null
	return instance

## 把新视图插到 Main / skew.C 的固定位置
func _place_view(instance: Node, layer: ViewLayer) -> bool:
	if layer == ViewLayer.SKEW_C:
		var skew_c := get_node_or_null(PathRegistry.SKEW_C)
		if skew_c == null:
			push_error("skew/C not found for lazy view")
			return false
		skew_c.add_child(instance)
		return true
	var main := get_node_or_null(PathRegistry.MAIN)
	if main == null:
		push_error("Main not found for lazy view")
		return false
	# 仅 MAIN_BEFORE_LT 以 LT_Btn 为锚点，其余以 RB_Btn 为准：
	# RB_Btn 之前只挡 LT；RB_Btn 之后覆盖两个角按钮
	var anchor_path := PathRegistry.LT_BTN if layer == ViewLayer.MAIN_BEFORE_LT else PathRegistry.RB_BTN
	var anchor := get_node_or_null(anchor_path)
	if anchor == null or anchor.get_parent() != main:
		push_error("Corner button not found under Main for lazy view")
		return false
	main.add_child(instance)
	var anchor_index := anchor.get_index()
	main.move_child(instance, anchor_index + (1 if layer == ViewLayer.MAIN_AFTER_RB else 0))
	return true

## 确保懒加载视图已实例化（首次进入对应 state 时调用）
## 返回实例化的节点，失败返回 null
func ensure_view_loaded(state: UIState) -> Node:
	if _loaded_lazy_views.has(state):
		var existing = _loaded_lazy_views[state]
		if is_instance_valid(existing):
			return existing
		_loaded_lazy_views.erase(state)
	if not LAZY_VIEW_PATHS.has(state):
		return null
	var instance: Node = create_view(LAZY_VIEW_PATHS[state], LAZY_VIEW_LAYERS[state])
	if instance == null:
		return null
	_loaded_lazy_views[state] = instance
	view_loaded.emit(state, instance)
	# 主题色由视图自身 _ready 注册到 ThemeMGR._theme_appliers 并自调 apply_theme() 完成，
	# 不再需要在此手动补应用（见 ThemeManager.register_theme_applier）
	return instance

## 获取已加载的懒加载视图实例（未加载返回 null）
func get_loaded_view(state: UIState) -> Node:
	return _loaded_lazy_views.get(state)

## 转换状态
func change_state(new_state: UIState, stash_state: bool = true) -> void:
	if new_state == current_state:
		GLogger.warning("can not change state", "UiStatMGR")
		return

	if not _data_ready:
		return

	# 确保目标视图已加载（懒加载）
	if LAZY_VIEW_PATHS.has(new_state):
		ensure_view_loaded(new_state)

	var old_state = current_state

	# 发出状态退出信号)
	# state_exiting.emit(old_state)
	# 记录历史
	if stash_state:
		if state_history.size() >= MAX_HISTORY_DEPTH:
			state_history.pop_front()
		state_history.append(old_state)

	# 更新状态
	previous_state = old_state
	current_state = new_state
	transition_version += 1

	state_changed.emit(old_state, new_state)

# 收到动画结束信号再发射新状态信号 (感觉可能可以改成通知ui释放组件的)
# func _scene_transition_exit() -> void:
# 	# 发出状态进入和改变信号
# 	print("Change state to %s" % get_state_name(current_state))
# 	state_entering.emit(current_state)

## 返回上一个状态
func go_back() -> bool:
	if state_history.is_empty():
		return false
	if not _data_ready:
		return false
	var back_state = state_history.pop_back()
	# 检查历史栈是否还有元素，有则更新previous_state
	var old_state = current_state
	if not state_history.is_empty():
		previous_state = state_history.back()
	transition_version += 1
	current_state = back_state
	state_changed.emit(old_state, back_state)
	return true

## 直接返回到目标状态，跳过中间层级，只发一次 state_changed 信号
## 用于级联删除等需要跳过多级 UI 的场景
func go_back_to(target_state: UIState) -> bool:
	if current_state == target_state:
		return false
	if not _data_ready:
		return false
	# 弹出历史栈直到找到目标状态，或清空为止
	while not state_history.is_empty() and state_history.back() != target_state:
		state_history.pop_back()
	if not state_history.is_empty():
		state_history.pop_back()  # 弹出 target_state 本身
	if not state_history.is_empty():
		previous_state = state_history.back()
	var old_state = current_state
	current_state = target_state
	transition_version += 1
	state_changed.emit(old_state, target_state)
	return true

## 获取当前状态
func get_current_state() -> UIState:
	return current_state

## 检查是否在特定状态
func is_in_state(state: UIState) -> bool:
	return current_state == state

## 获取状态名称（调试用）
func get_state_name(state: UIState) -> String:
	match state:
		UIState.ALBUM_VIEW:
			return "ALBUM_VIEW"
		UIState.SONG_VIEW:
			return "SONG_VIEW"
		UIState.MIDI_VIEW:
			return "MIDI_VIEW"
		UIState.SORTED_VIEW:
			return "SORTED_VIEW"
		UIState.STORE_VIEW:
			return "STORE_VIEW"
		UIState.SETTINGS_VIEW:
			return "SETTINGS_VIEW"
		UIState.TRACK_VIEW:
			return "TRACK_VIEW"
		UIState.PLAY_VIEW:
			return "PLAY_VIEW"
		UIState.SCORE_VIEW:
			return "SCORE_VIEW"
		UIState.CHARA_VIEW:
			return "CHARA_VIEW"
		UIState.PROFILE_VIEW:
			return "PROFILE_VIEW"
		UIState.MUSIC_PLAYER_VIEW:
			return "MUSIC_PLAYER_VIEW"
		_:
			return "UNKNOWN_STATE"

## 打印当前状态（调试）
func print_state_info() -> void:
	GLogger.info("Current State: %s (%d)" % [get_state_name(current_state), current_state], "UiStatMGR")
	GLogger.info("Previous State: %s (%d)" % [get_state_name(previous_state), previous_state], "UiStatMGR")
	GLogger.info("History Depth: %d" % state_history.size(), "UiStatMGR")
