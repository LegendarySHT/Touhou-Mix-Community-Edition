## 编辑器插件壳：注册 Android 媒体会话导出插件
## 与 android_runtime_inject 同构（注入清单而非引擎内置插件）
@tool
extends EditorPlugin

const EXPORT_PLUGIN_SCRIPT := preload("android_export_plugin.gd")

var _export_plugin: EditorExportPlugin

func _enter_tree() -> void:
	_export_plugin = EXPORT_PLUGIN_SCRIPT.new()
	add_export_plugin(_export_plugin)
	print("[MediaSessionAndroid] export plugin registered")

func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
