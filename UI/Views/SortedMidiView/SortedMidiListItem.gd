## 排序MIDI列表项组件
## 继承自 CoverListItemBase，显示排序视图中的MIDI谱面信息
extends CoverListItemBase

class_name SortedMidiListItem

## 引用节点
@onready var status_label: Label = $MidiName/status
@onready var midi_name_label: Label = $MidiName
@onready var author_label: Label = $MidiName/Author
# cover_texture 继承自 CoverListItemBase，在 _ready() 中赋值

@onready var state_manager:UIStateManager = UiStatMGR

## 轻量投影数据（ChartDB.GetSortedMidiListItems / GetMidiListItemsByKeys 返回的字典）
## 替代完整 MidiData，避免列表全量水合；点击时由 SortedMidiView 惰性水合完整对象
var item_dict: Dictionary = {}

## 选择动画补间
var select_tween: Tween

## 刷新入场动画补间（复用时从左侧滑入）
var _refresh_ani_tween: Tween

## 入场动画抑制开关：滚动复用/虚拟化补位时不播滑入动画，仅普通刷新（切筛选进顶）播放
var _suppress_refresh_animation: bool = false

signal _init_fin

var _has_ready: bool = false

func _ready() -> void:
	cover_texture = $cover
	await _init_fin
	# 先置位 _has_ready 再刷新：_refresh_display 里据此走"复用"分支（含播放入场动画），
	# 否则首次构建恒跳过动画（必须在 _play_refresh_slide_in / switch_cover_data 判断之前置位）
	_has_ready = true
	_refresh_display()

## 刷新显示数据并重新加载封面（新建与复用共用）
## 复用时先 switch_cover_data 重置加载状态（保留旧 texture 显示），再 start_cover_load 加载新封面；
## 新建节点 _cover_loaded=false 无需 switch_cover_data（避免冗余操作）
## 注:新建项若 path 暂不可用,start_cover_load 直接 return,由列表 trigger_cover_chain 统一重试
func _refresh_display() -> void:
	# 显示MIDI信息：下载/游玩/赞/踩，数字右对齐留六位
	get_node("Data").text = "下载 %6d | 游玩 %6d | 赞 %6d | 踩 %6d" % [
		item_dict.get("download_count", 0),
		item_dict.get("trial_count", 0),
		item_dict.get("up_count", 0),
		item_dict.get("down_count", 0)]
	status_label.text = String(item_dict.get("status", ""))
	midi_name_label.text = String(item_dict.get("name", "")).strip_edges()
	var artist := String(item_dict.get("artist_name", ""))
	author_label.text = artist if not artist.is_empty() else "Unknown"

	if _has_ready:
		switch_cover_data()
		_play_refresh_slide_in()

## 复用刷新时的滑入动画：offset_transform_position_ratio.x 从 -2 回到 0
## 仅当项自然位置（ratio=0）与父级可见区域重合时播放；不可见则直接归零
func _play_refresh_slide_in() -> void:
	if _refresh_ani_tween:
		_refresh_ani_tween.kill()
		_refresh_ani_tween = null

	# 滚动复用/虚拟化补位：直接归零，不播放滑入动画
	if _suppress_refresh_animation:
		offset_transform_position_ratio.x = 0.0
		return

	# 切换筛选已跳回顶部，固定为可见项播放入场动画：
	# 观感上整列表重新入场，掩盖"跳回顶部"的瞬时切位；不可见项不建动画省资源

	# 临时重置 x ratio 到 0，检测自然位置是否可见
	offset_transform_position_ratio.x = 0.0
	var in_view := _is_in_viewport()

	if in_view:
		# 可见：从左侧 -2 滑入到 0
		offset_transform_position_ratio.x = -2.0
		_refresh_ani_tween = AniMGR.create_managed_tween(self)
		_refresh_ani_tween.tween_property(
			self, "offset_transform_position_ratio:x", 0.0, 0.4
		).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	else:
		# 不可见：保持 0，无动画
		offset_transform_position_ratio.x = 0.0

## 检测自身是否与父级（ScrollContainer）当前可视视窗相交。
## 项位置写在 offset_transform_position 里（内容坐标，还没被滚动容器平移），
## 故用 global_position 换算回「相对滚动容器的屏幕局部 y」再比较。
## 项目启用了"鼠标模拟触摸"，Godot ScrollContainer 自带惯性滚动，无需手动处理
func _is_in_viewport() -> bool:
	if not parent_node or not is_instance_valid(parent_node):
		return false
	var sc := parent_node as ScrollContainer
	if not sc or sc.size.y <= 0.0:
		return false
	var y := global_position.y - sc.global_position.y
	return (y + size.y > 0.0) and (y < sc.size.y)

## 重写基类虚函数：返回 MIDI 封面 Texture2D
func _get_cover_texture() -> Texture2D:
	if item_dict.is_empty():
		return null
	var fs_mgr := FileSystemManager.instance
	if not fs_mgr:
		return null
	return fs_mgr.get_cover_by_ids(String(item_dict.get("file_hash", "")), String(item_dict.get("id", "")))

## 重写基类虚函数：返回封面文件路径（主线程调用，供异步加载器使用）
func _resolve_cover_path() -> String:
	if item_dict.is_empty():
		return ""
	var fs_mgr := FileSystemManager.instance
	if not fs_mgr:
		return ""
	var real := fs_mgr.get_cover_path_by_ids(String(item_dict.get("file_hash", "")), String(item_dict.get("id", "")))
	# 同一 coverHash 的封面内容一致，复用首个解析路径作为缓存键，
	# 同 hash 谱面（不同文件夹各存一份拷贝）共享一份 Texture，避免按路径重复上传
	return fs_mgr.canonicalize_cover_key(real, String(item_dict.get("coverHash", "")))

## 从轻量投影字典初始化显示（DB 返回，无完整 MidiData）
## 新建节点（_has_ready=false）：emit _init_fin 触发 _ready 中的 await 继续
## 复用节点（_has_ready=true）：直接调 _refresh_display 刷新数据
func setup_with_dict(d: Dictionary, index: int, bg:ButtonGroup) -> void:
	item_dict = d
	item_id = String(d.get("id", ""))
	item_type = "sorted_midi"
	item_index = index

	# 初始化按钮（MidiNode 本身即 Button，复用时已初始化，跳过重复初始化）
	if not button:
		button = self
		enable_selected_animation(button, get_node(PathRegistry.SORTED_MIDIS_LIST))
	button.button_group = bg

	if _has_ready:
		# 复用：清理残留 tween + 重置选中状态 + 刷新显示
		# pulse_tween 为 infinite loop，必须 kill 避免持续占用 CPU
		if pulse_tween:
			pulse_tween.kill()
			pulse_tween = null
		if press_tween:
			press_tween.kill()
		offset_transform_scale = Vector2.ONE
		if button:
			button.set_pressed_no_signal(false)
		is_selected = false
		_refresh_display()
	else:
		# 新建：触发 _ready 中的 await 继续
		_init_fin.emit()
