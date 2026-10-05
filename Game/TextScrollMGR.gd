## 文字滚动管理器（autoload：TextScrollMGR）
## 用统一相位驱动所有溢出文本，页面隐藏后从活跃集移除。
extends Node

## 所有文本共用的单程时长、端点停留与缓动曲线
@export var travel_duration := 3.0
@export var endpoint_pause_duration := 1.0
@export var transition: Tween.TransitionType = Tween.TRANS_QUAD

var _registered_items: Dictionary = {}
var _active_items: Dictionary = {}
var _suspended_roots: Dictionary = {}
var _phase_time := 0.0
var _offset_ratio := 0.0


func _process(delta: float) -> void:
	# 无活跃滚动项时不必推进相位（页面隐藏后其项目已从活跃集移除）
	if _active_items.is_empty():
		return
	var travel := maxf(travel_duration, 0.001)
	var pause := maxf(endpoint_pause_duration, 0.0)
	var cycle_duration := 2.0 * (travel + pause)
	_phase_time = fposmod(_phase_time + delta, cycle_duration)

	var linear_ratio := 0.0
	if _phase_time < travel:
		linear_ratio = _phase_time / travel
	elif _phase_time < travel + pause:
		linear_ratio = 1.0
	elif _phase_time < travel * 2.0 + pause:
		linear_ratio = 1.0 - (_phase_time - travel - pause) / travel
	_offset_ratio = float(Tween.interpolate_value(0.0, 1.0, linear_ratio, 1.0, transition, Tween.EASE_IN_OUT))

	var stale_items: Array = []
	for item in _active_items:
		if not is_instance_valid(item):
			stale_items.append(item)
			continue
		item.apply_scroll_offset(-float(_registered_items[item]) * _offset_ratio)
	for item in stale_items:
		_registered_items.erase(item)
		_active_items.erase(item)


func register(item: Node, max_offset: float) -> void:
	if not is_instance_valid(item):
		return
	_prune_suspended_roots()
	_registered_items[item] = max_offset
	if _is_suspended(item):
		_active_items.erase(item)
		return
	_active_items[item] = true
	item.apply_scroll_offset(-max_offset * _offset_ratio)


func unregister(item: Node) -> void:
	_registered_items.erase(item)
	_active_items.erase(item)


func suspend_page(root: Node) -> void:
	if not is_instance_valid(root):
		return
	_prune_suspended_roots()
	_suspended_roots[root] = true
	var stale_items: Array = []
	for item in _registered_items:
		if not is_instance_valid(item):
			stale_items.append(item)
		elif root == item or root.is_ancestor_of(item):
			_active_items.erase(item)
	for item in stale_items:
		_registered_items.erase(item)
		_active_items.erase(item)


func resume_page(root: Node) -> void:
	if not is_instance_valid(root):
		return
	_prune_suspended_roots()
	_suspended_roots.erase(root)
	var stale_items: Array = []
	for item in _registered_items:
		if not is_instance_valid(item):
			stale_items.append(item)
		elif (root == item or root.is_ancestor_of(item)) and not _is_suspended(item):
			_active_items[item] = true
			item.apply_scroll_offset(-float(_registered_items[item]) * _offset_ratio)
	for item in stale_items:
		_registered_items.erase(item)
		_active_items.erase(item)


func _is_suspended(item: Node) -> bool:
	for root in _suspended_roots:
		if is_instance_valid(root) and (root == item or root.is_ancestor_of(item)):
			return true
	return false


func _prune_suspended_roots() -> void:
	var stale_roots: Array = []
	for root in _suspended_roots:
		if not is_instance_valid(root):
			stale_roots.append(root)
	for root in stale_roots:
		_suspended_roots.erase(root)
