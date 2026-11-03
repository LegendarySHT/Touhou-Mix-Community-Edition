extends TextureButton

## 点击呼出角色详情时触发（携角色 key）
signal chara_activated(chara_key: String)

## 按住放大倍率
const PRESS_SCALE := Vector2.ONE * 1.01

@onready var name_label: Label = $Name
@onready var info_label: Label = $Name/Info

var _chara_key: String = ""
var _press_tween: Tween = null

## 由 CharaView 构建列表时调用：填充角色图、姓名与解锁方式
func setup_chara(chara_key: String, data: Dictionary) -> void:
	_chara_key = chara_key
	name_label.text = str(data.get("name", chara_key.replace(CharaMGR.BUILTIN_SUFFIX, "")))
	# 解锁方式：内置角色为固定文字，用户角色显示解锁条件
	if data.get("is_builtin", false):
		info_label.text = "内置角色"
	else:
		info_label.text = str(data.get("unlock_condition", str(data.get("author", ""))))
	var tex := CharaMGR.get_portrait(chara_key, 0)
	if tex:
		texture_normal = tex


func _on_button_down() -> void:
	_press_scale(true)


func _on_button_up() -> void:
	_press_scale(false)


func _on_pressed() -> void:
	if _chara_key.is_empty():
		return
	chara_activated.emit(_chara_key)


## 按住放大/松手恢复缩放动画
func _press_scale(is_pressed_: bool) -> void:
	if _press_tween and _press_tween.is_valid():
		_press_tween.kill()
	offset_transform_enabled = true
	_press_tween = create_tween()
	_press_tween.set_trans(Tween.TRANS_CUBIC)
	_press_tween.set_ease(Tween.EASE_OUT)
	_press_tween.tween_property(self, "offset_transform_scale", PRESS_SCALE if is_pressed_ else Vector2.ONE, 0.15)
