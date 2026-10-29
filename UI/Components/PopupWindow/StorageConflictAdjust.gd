## 存储迁移冲突处理子页（PopupWindow Tab 第 8 页）
## 目标目录已存在游戏数据时，让玩家决定迁移时听哪一侧的：
##   - "保留目标已有版本（合并补缺）"：目标已有的一律保留，目标缺的从当前根补齐；
##     数据库两侧合并、收藏夹取并集，同一谱面/同一收藏夹保留目标那份
##   - "用当前版本覆盖目标"：顶层文件与数据库整份替换目标侧，不做合并
##     （典型场景：目标库是空的或旧的，当前这份才是玩家想要的）
## 两个选项都不删除目标目录里的资源文件，只是同名文件的取舍。
## 结果用三态而非 bool：玩家点弹窗外/返回键关闭时必须算"取消"，
## 否则会被当成默认选项继续迁移（旧实现就踩过这个坑）。
extends VBoxContainer

class_name StorageConflictAdjust

## 请求关闭整个弹窗（由 PopupWindow 连接 hide）
signal finish_requested

## 弹窗结果
enum Choice { NONE = -1, KEEP_TARGET = 0, OVERWRITE = 1 }

var _title_label: Label
var _files_label: Label
var _overwrite_btn: Button
var _keep_target_btn: Button
## 未做选择即为取消（点外部关闭、返回键等）
var _result: int = Choice.NONE

func _ready() -> void:
	_title_label = $Title
	_files_label = $FilesLabel
	_overwrite_btn = $Btns/Overwrite
	_keep_target_btn = $Btns/KeepTarget

	_overwrite_btn.pressed.connect(_on_overwrite_pressed)
	_keep_target_btn.pressed.connect(_on_keep_target_pressed)

## 打开弹窗前初始化（每次重置结果，避免残留上一次的选择）
func init_adjust(merge_dirs: Array, conflict_files: Array) -> void:
	_result = Choice.NONE
	_title_label.text = "目标目录已有游戏数据"
	var lines: Array[String] = []
	if not merge_dirs.is_empty():
		lines.append("已有资源目录：%s" % "、".join(merge_dirs))
	if not conflict_files.is_empty():
		lines.append("已有文件：%s" % "、".join(conflict_files))
	lines.append("")
	lines.append("保留目标：目标已有的内容不动，缺的从当前位置补齐；")
	lines.append("曲库记录与收藏夹两侧合并，同一条记录以目标为准。")
	lines.append("覆盖目标：用当前位置的设置、收藏、曲库整份替换目标。")
	lines.append("两种方式都不会删除目标目录中多出来的资源文件。")
	lines.append("点击弹窗外部或按返回键可取消迁移。")
	_files_label.text = "\n".join(lines)

## 返回 Choice：NONE=未选择/取消，KEEP_TARGET，OVERWRITE
func get_result() -> int:
	return _result

func _on_overwrite_pressed() -> void:
	_result = Choice.OVERWRITE
	finish_requested.emit()

func _on_keep_target_pressed() -> void:
	_result = Choice.KEEP_TARGET
	finish_requested.emit()
