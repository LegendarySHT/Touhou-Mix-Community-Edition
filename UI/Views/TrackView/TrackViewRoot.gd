## TrackView 场景根（ViewBase）。
##
## 拆分原因：TrackView 的列表逻辑必须继承 BaseScrollList（ScrollContainer 分支），
## 而 GDScript 单继承让同一个脚本无法同时是 ViewBase。所以根 Control 只承载
## 「转场 + 主题转发 + 挂载层级」三件事，列表/播放逻辑仍在 PageContent 的 TrackView.gd。
##
## 转场动画写在根节点上：offset_transform_* 是 Control 原生属性（4.7），
## 作用在根节点上等价于原来的整页滑动，且淡入淡出覆盖整棵子树。
extends ViewBase

class_name TrackViewRoot

@onready var content: TrackView = %PageContent

## 主题转发给列表脚本（TrackView.gd 不再自行注册主题应用者）
func apply_theme() -> void:
	content.apply_theme()

## 入场：从整屏下方滑回 + 淡入（原 AnimationManager 的 Track_List 分支）
func _play_enter() -> Tween:
	content.scroll_vertical = 300
	var tw := AniMGR.animate_fade_in(self, 0.45, "track_in")
	# ratio 1.0 = 自身高度，换分辨率也不会位移不足；先归零保证快速来回切换时起点干净
	offset_transform_enabled = true
	offset_transform_visual_only = false
	offset_transform_position = Vector2.ZERO
	offset_transform_position_ratio = Vector2(0, 1)
	AniMGR.animate_offset_ratio_to(self, Vector2.ZERO, 0.3, "track_pos")
	return tw

## 出场：淡出 + 整屏滑出
func _play_exit() -> Tween:
	offset_transform_enabled = true
	offset_transform_visual_only = false
	offset_transform_position_ratio = Vector2.ZERO
	offset_transform_position = Vector2.ZERO
	var tw := AniMGR.animate_fade_out(self, 0.3, "track_out")
	AniMGR.animate_offset_ratio_to(self, Vector2(0, 1), 0.3, "track_pos")
	return tw
