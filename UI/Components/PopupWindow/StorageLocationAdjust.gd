## 存储位置设置弹窗子页（PopupWindow Tab 第 7 页）
## 展示当前路径 + 路径输入框 + 浏览按钮 + 取消/确定
## Android 端隐藏浏览按钮（导出后 FileDialog 无法可靠浏览共享存储根目录），只做文本输入
##
## 交互设计：
##   - 点击"浏览..."：原生目录选择器是独立窗口，打开时 PopupWindow 会因失去焦点被自动
##     关闭（Godot Popup 行为），导致选择结果无处回填。因此浏览按钮改为：
##     _result.action="browsing" 并关闭弹窗 → 由调用方（SettingList 协程）打开 FileDialog，
##     选择完成后自动重开本弹窗并填入所选目录，流程由协程贯穿，不依赖弹窗记忆。
##   - 取消/确定按钮设置结果并 emit finish_requested，由 PopupWindow 统一 hide()。
extends VBoxContainer

class_name StorageLocationAdjust

## 请求关闭整个弹窗（由 PopupWindow 连接 hide）
signal finish_requested

var _current_label: Label
var _path_line_edit: LineEdit
var _browse_btn: Button
var _cancel_btn: Button
var _confirm_btn: Button
## 弹窗结果：{action: "confirmed"|"cancelled"|"browsing", path: String}
var _result: Dictionary = {"action": "cancelled", "path": ""}

func _ready() -> void:
	_current_label = $CurrentLabel
	_path_line_edit = $PathHBox/LineEdit
	_browse_btn = $PathHBox/BrowseBtn
	_cancel_btn = $Btns/Cancel
	_confirm_btn = $Btns/Confirm

	_browse_btn.pressed.connect(_on_browse_pressed)
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	_confirm_btn.pressed.connect(_on_confirm_pressed)

## 打开弹窗前初始化（每次调用重置结果，避免残留上一次的结果）
func init_adjust(current_path: String) -> void:
	_result = {"action": "cancelled", "path": ""}
	var display := current_path
	if display.is_empty():
		display = PathHelper.get_storage_root()
	_path_line_edit.text = display
	if _current_label:
		_current_label.text = "当前存储位置：%s" % display
	_path_line_edit.call_deferred("grab_focus")

func get_result() -> Dictionary:
	return _result

## 浏览按钮：关闭弹窗并把当前输入值带回给调用方（SettingList 打开系统原生目录选择器）
## 桌面与 Android 均可用（Android 走 SAF 系统文件选择器，SettingList 侧负责权限前置）
func _on_browse_pressed() -> void:
	_result = {"action": "browsing", "path": _path_line_edit.text.strip_edges()}
	finish_requested.emit()

func _on_cancel_pressed() -> void:
	_result = {"action": "cancelled", "path": ""}
	finish_requested.emit()

func _on_confirm_pressed() -> void:
	_result = {"action": "confirmed", "path": _path_line_edit.text.strip_edges()}
	finish_requested.emit()
