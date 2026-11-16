## 导出插件：向 Android 导出清单的 <application> 注入 AndroidRuntime 插件的注册 meta-data。
##
## 机制（与官方 AndroidRuntime 内置插件的勾选效果等价）：
## - AndroidRuntimePlugin 类由 Godot 引擎 aar (godot-lib) 自带，gradle 构建必然携带
## - GodotPluginRegistry 启动时扫描 AndroidManifest 中所有
##   "org.godotengine.plugin.v2.<PluginName>" 前缀的 meta-data，
##   反射实例化 value 指向的 GodotPlugin 子类并以 <PluginName> 注册为 Engine singleton
## - 注入后 GDScript 侧 Engine.get_singleton("AndroidRuntime") 即可用
##   （ServiceHub.audioBt._detect_android 依赖它获取 Activity/Context 做蓝牙检测）
##
## 仅作用于 Android 平台且使用 gradle 构建的导出（manifest 定制只对 gradle 构建生效）。
@tool
extends EditorExportPlugin

## AndroidRuntimePlugin 的 GodotPlugin.getPluginName() 返回值（从 4.7.1 godot-lib 二进制确认）
const ANDROID_RUNTIME_PLUGIN_NAME := "AndroidRuntime"
## 引擎 aar 内的完整类名（org.godotengine.godot.plugin.AndroidRuntimePlugin）
const ANDROID_RUNTIME_PLUGIN_CLASS := "org.godotengine.godot.plugin.AndroidRuntimePlugin"

func _get_name() -> String:
	return "AndroidRuntimeInject"

func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid

func _get_android_manifest_application_element_contents(
		_platform: EditorExportPlatform, _debug: bool) -> String:
	var snippet := """
		<meta-data
			android:name="org.godotengine.plugin.v2.%s"
			android:value="%s" />""" % [
		ANDROID_RUNTIME_PLUGIN_NAME,
		ANDROID_RUNTIME_PLUGIN_CLASS,
	]
	print("[AndroidRuntimeInject] injecting AndroidRuntime plugin meta-data into AndroidManifest")
	return snippet
