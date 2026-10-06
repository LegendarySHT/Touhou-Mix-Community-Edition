## Android Java 代码注入导出插件（模块 addons/android_bridge）
##
## 两件事：
##   1. 把 addons/android_bridge/android/ 下的**全部** Java 源码拷贝进 gradle 构建目录
##      （新增 Android 能力只需往该目录加 .java，无需改本文件）
##   2. 向 Android 导出清单注入插件注册 meta-data、前台服务声明、权限
##
## 为何要拷贝而非直接放在 res://android/build/src/main/java/：
##   那个目录是 Godot 从 android_source.zip 解出的构建模板（可被"安装/重装 Android
##   构建模板"整体覆盖），且位于 .gitignore 的 /android/ 下不纳入版本控制。
##   源码放这里可随仓库分发，导出时同步进模板目录，模板重装也不会丢。
##   引擎时序：ExportNotifier（触发本插件 _export_begin）在 gradle 构建之前，
##   见 platform/android/export/export_plugin.cpp 中 notifier 构造早于 gradle 调用。
##
## 与 addons/android_runtime_inject 同机制：GodotPluginRegistry 会扫描 AndroidManifest 中
## "org.godotengine.plugin.v2.*" 前缀的 meta-data 反射实例化插件，故只需注入声明。
@tool
extends EditorExportPlugin

const PLUGIN_NAME := "AndroidBridge"
const PLUGIN_CLASS := "com.godot.game.AndroidBridge"

const SOURCE_DIR := "res://addons/android_bridge/android"
const JAVA_PACKAGE_DIR := "src/main/java/com/godot/game"
## 上次同步到构建目录的文件清单，用于清理改名/删除后遗留的陈旧 Java
const MANIFEST_NAME := ".android_bridge_sources.txt"

func _get_name() -> String:
	return "AndroidBridgeJava"

func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid

## 导出开始时把 Java 源码同步进 gradle 构建目录（早于 gradle 编译）
func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_copy_java_sources()

## 同步策略：始终覆盖（保证模板重装后自动恢复）；源目录已删除/改名的文件按清单清理
func _copy_java_sources() -> void:
	var preset := get_export_preset()
	if preset == null:
		return
	var build_dir: String = preset.get("gradle_build/gradle_build_directory")
	if build_dir.is_empty():
		build_dir = "res://android"
	var target_dir := ProjectSettings.globalize_path("%s/build/%s" % [build_dir, JAVA_PACKAGE_DIR])

	var source_dir := ProjectSettings.globalize_path(SOURCE_DIR)
	if not DirAccess.dir_exists_absolute(source_dir):
		push_warning("[AndroidBridge] source dir missing: %s" % SOURCE_DIR)
		return
	DirAccess.make_dir_recursive_absolute(target_dir)

	var manifest_path := "%s/%s" % [target_dir, MANIFEST_NAME]
	var previous := _read_manifest(manifest_path)

	var copied := 0
	var names := PackedStringArray()
	for file_name in DirAccess.get_files_at(source_dir):
		if not file_name.ends_with(".java"):
			continue
		names.append(file_name)
		var src := "%s/%s" % [source_dir, file_name]
		var dst := "%s/%s" % [target_dir, file_name]
		if FileAccess.get_file_as_bytes(src) == FileAccess.get_file_as_bytes(dst):
			continue
		var err := DirAccess.copy_absolute(src, dst)
		if err != OK:
			push_error("[AndroidBridge] failed to copy %s (err %d)" % [file_name, err])
		else:
			copied += 1
	if copied > 0:
		print("[AndroidBridge] synced %d Java source(s) to gradle project" % copied)

	# 清理上次同步过、现已不在源目录的文件（不能按"不在源目录就删"清理：
	# 该包目录内还有 Godot 模板自带的 GodotApp.java）
	for old_name in previous:
		if not names.has(old_name):
			DirAccess.remove_absolute("%s/%s" % [target_dir, old_name])
			print("[AndroidBridge] removed stale %s from gradle project" % old_name)
	_write_manifest(manifest_path, names)

func _read_manifest(path: String) -> PackedStringArray:
	if not FileAccess.file_exists(path):
		return PackedStringArray()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedStringArray()
	var text := file.get_as_text()
	file.close()
	return text.split("\n", false)

func _write_manifest(path: String, names: PackedStringArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string("\n".join(names))
	file.close()

## 插件注册 meta-data + 前台服务声明（application 元素内）
func _get_android_manifest_application_element_contents(
		_platform: EditorExportPlatform, _debug: bool) -> String:
	return """
		<meta-data
				android:name="org.godotengine.plugin.v2.%s"
				android:value="%s" />
		<service
				android:name="com.godot.game.MediaSessionService"
				android:exported="false"
				android:foregroundServiceType="mediaPlayback" />""" % [
		PLUGIN_NAME,
		PLUGIN_CLASS,
	]

## 前台服务与通知权限（manifest 顶层，application 之前）
func _get_android_manifest_element_contents(
		_platform: EditorExportPlatform, _debug: bool) -> String:
	return """
	<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
	<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
	<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />"""
