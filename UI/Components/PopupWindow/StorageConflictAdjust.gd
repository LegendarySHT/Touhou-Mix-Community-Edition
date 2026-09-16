## 存储迁移冲突询问子页（PopupWindow Tab 第 8 页）
## 目标目录已存在不可合并文件（settings.ini / favorites.json / charts.ldb / charts-log.ldb）时，
## 统一询问玩家保留哪一侧：
##   - "保留当前版本（覆盖目标）" → 迁移时用当前（旧根）版本覆盖目标
##   - "保留目标已有版本（跳过）" → 迁移时跳过目标已存在的顶层文件
## 交互：两个按钮设置结果并 emit finish_requested，由 PopupWindow 统一 hide()。
extends VBoxContainer

class_name StorageConflictAdjust

## 请求关闭整个弹窗（由 PopupWindow 连接 hide）
signal finish_requested

var _files_label: Label
var _overwrite_btn: Button
var _keep_target_btn: Button
## 弹窗结果：true=保留目标已有版本（跳过）；false=保留当前版本（覆盖目标）
var _result: bool = false

func _ready() -> void:
	_files_label = $FilesLabel
	_overwrite_btn = $Btns/Overwrite
	_keep_target_btn = $Btns/KeepTarget

	_overwrite_btn.pressed.connect(_on_overwrite_pressed)
	_keep_target_btn.pressed.connect(_on_keep_target_pressed)

## 打开弹窗前初始化（每次重置结果，避免残留上一次的选择）
func init_adjust(files: Array) -> void:
	_result = false
	_files_label.text = "目标目录已存在以下文件：\n%s\n请选择保留哪一侧：" % "、".join(files)

func get_result() -> bool:
	return _result

func _on_overwrite_pressed() -> void:
	_result = false
	finish_requested.emit()

func _on_keep_target_pressed() -> void:
	_result = true
	finish_requested.emit()
