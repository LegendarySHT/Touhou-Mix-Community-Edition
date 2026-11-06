## 懒加载视图基类
## 统一处理三件事：主题应用者注册/注销、转场入口、挂载层级声明。
##
## 硬约定：子类**禁止覆盖** _ready / _exit_tree / play_transition，
## 只覆盖 _on_view_ready / _on_view_exit / _play_enter / _play_exit / apply_theme。
## 原因：GDScript 不强制子类调用 super，覆盖模板方法后漏掉父类逻辑是静默失效
## （不报错、不崩，只是主题不更新或转场不播），比手写样板更难查。
class_name ViewBase
extends Control

## 懒加载挂载层级，取值见 UIStateManager.ViewLayer。
## -1 = 未声明，UIStateManager 回退到旧的 LAZY_VIEW_LAYERS 常量表。
@export var view_layer: int = -1

func _ready() -> void:
	# 子类初始化先于主题应用：apply_theme 依赖子类在 _on_view_ready 里建立的引用
	_on_view_ready()
	# 页面默认焦点落点：优先级高于内层列表，返回 null 时自动落到内层列表或阅读顺序第一项
	if FocusMGR:
		FocusMGR.register_default(self, _focus_default, 10)
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

func _exit_tree() -> void:
	if FocusMGR:
		FocusMGR.unregister_default(self)
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)
	_on_view_exit()

## 页面默认焦点落点。返回 null 表示本页不指定，交给内层列表或阅读顺序第一项
func _focus_default() -> Control:
	return null

## 子类初始化钩子（替代覆盖 _ready）
func _on_view_ready() -> void:
	pass

## 子类清理钩子（替代覆盖 _exit_tree）
func _on_view_exit() -> void:
	pass

## 主题应用，子类按需覆盖
func apply_theme() -> void:
	pass

## 转场统一入口，子类不要覆盖。
## 通用处理（可见性复位、文字滚动挂起）在这里做，保证子类漏写也能正确收尾。
func play_transition(entering: bool) -> Tween:
	if entering:
		visible = true
		modulate.a = 1.0
		TextScrollMGR.resume_page(self)
		return _play_enter()
	var tw: Tween = _play_exit()
	if tw == null or not tw.is_valid():
		suspend_text_scroll()
	else:
		tw.finished.connect(suspend_text_scroll)
	return tw

func suspend_text_scroll() -> void:
	if is_instance_valid(self):
		TextScrollMGR.suspend_page(self)

## 入场动画，默认整页淡入
func _play_enter() -> Tween:
	return AniMGR.animate_fade_in(self, AniMGR.DURATION_NORMAL, "%s_in" % name)

## 出场动画，默认整页淡出
func _play_exit() -> Tween:
	return AniMGR.animate_fade_out(self, AniMGR.DURATION_NORMAL, "%s_out" % name)
