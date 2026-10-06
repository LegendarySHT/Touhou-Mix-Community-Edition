## 蓝牙音频输出检测（autoload，平台分发 + 结果缓存）
## - Windows: 调用 C# AudioRouteDetector autoload（COM 读取默认输出端点的总线类型）
## - Android: AndroidRuntime 插件 + JavaClassWrapper 查询 AudioManager 已连接的输出设备
## - 其余平台: 不检测，回退普通延迟预设（不影响现有功能）
##
## 使用方式（与 GLogger/ThemeMGR 等 autoload 单例一致）:
##   AudioBtDetector.is_bluetooth_output()          # 当前输出是否蓝牙（缓存 5s）
##   AudioBtDetector.is_bluetooth_output(true)      # 强制重新检测
##   AudioBtDetector.get_active_delay_key()          # 当前应使用的延迟预设配置 key
##   AudioBtDetector.get_status_text()               # UI 状态文案（延迟校准窗口顶部）
extends Node

## 检测结果缓存有效期（秒）；关键时点（焦点回归/开局/开窗）用 force_refresh 绕过
const CACHE_TTL_SEC: float = 5.0

## 输出设备变化（蓝牙/有线插拔）。平台有事件订阅时（Android: Java AudioDeviceCallback）
## 由事件触发；无事件能力的平台由消费方兜底轮询（见 has_output_listener）
signal output_changed

# ===== 缓存状态 =====
var _cached_is_bt: bool = false
var _cached_source: String = "none"
var _cached_name: String = ""
var _last_check_ms: float = -1000000.0
## 是否已建立平台事件订阅（已建立则消费方无需轮询）
var _event_listener_ready: bool = false

## 当前是否使用蓝牙输出音频
func is_bluetooth_output(force_refresh: bool = false) -> bool:
	_ensure_detection(force_refresh)
	return _cached_is_bt

## 当前应使用的延迟预设配置 key（[Gameplay] 段）
func get_active_delay_key() -> String:
	return "audio_playback_delay_bt" if is_bluetooth_output() else "audio_playback_delay"

## 状态文案（用于延迟校准窗口顶部的检测提示，调用方自行加前缀）
func get_status_text() -> String:
	_ensure_detection(false)
	if _cached_is_bt:
		var dev := _cached_name.strip_edges()
		return "蓝牙（%s）" % dev if not dev.is_empty() else "蓝牙"
	# 未检测到蓝牙时，检测能力不可用的平台给出提示（其余正常显示有线）
	match _cached_source:
		"unsupported_platform", "no_detector", "no_audio_manager", "detect_error":
			return "有线/扬声器（本平台不支持蓝牙检测）"
		_:
			return "有线/扬声器"

# ===== 内部实现 =====

func _ensure_detection(force: bool) -> void:
	if not _event_listener_ready:
		_ensure_event_listener()
	var now := float(Time.get_ticks_msec())
	if not force and (now - _last_check_ms) < CACHE_TTL_SEC * 1000.0:
		return
	_last_check_ms = now
	var result: Variant = _detect()
	# GDScript 无 try/catch：检测函数内部任何调用失败会中断并返回 null，此处兜住
	if result == null or not (result is Dictionary):
		result = {"is_bt": false, "source": "detect_error", "name": ""}
	var prev_is_bt := _cached_is_bt
	var prev_source := _cached_source
	_cached_is_bt = bool(result.get("is_bt", false))
	_cached_source = String(result.get("source", "unknown"))
	_cached_name = String(result.get("name", ""))
	# 诊断日志：print 直达 Android logcat（筛 "AudioBtDetector" 即可定位失败环节）。
	# 只在结果变化时打印：播放中会周期性检测，每次打印会刷屏
	if _cached_is_bt != prev_is_bt or _cached_source != prev_source:
		print("[AudioBtDetector] detect: source=%s is_bt=%s name=%s" % [
			_cached_source, str(_cached_is_bt), _cached_name])

## 尝试建立平台事件订阅，成功后消费方无需轮询。
## 目前仅 Android：addons/android_bridge 模块的 audio_output_changed（Java AudioDeviceCallback）。
## 插件由引擎在渲染线程异步注册，故每次检测前重试一次；插件缺失/旧版本时保持轮询兜底。
func _ensure_event_listener() -> void:
	if _event_listener_ready or OS.get_name() != "Android":
		return
	var plugin = Engine.get_singleton("AndroidBridge")
	# 以信号是否存在判断插件能力：Java 插件对象的 has_method 恒为 false，不能用
	if plugin == null or not plugin.has_signal("audio_output_changed"):
		return
	if not plugin.audio_output_changed.is_connected(_on_output_changed):
		plugin.audio_output_changed.connect(_on_output_changed)
	# Java 方法可直接调用（GodotPlugin 的 @UsedByGodot 方法已绑定）
	plugin.register_audio_device_listener()
	_event_listener_ready = true
	print("[AudioBtDetector] audio device callback subscribed")

## 输出设备变化：作废缓存并广播，消费方据此立刻重算延迟预设
func _on_output_changed() -> void:
	_last_check_ms = -1000000.0
	output_changed.emit()

## 是否已建立平台事件订阅（已建立则消费方不必轮询）
func has_output_listener() -> bool:
	return _event_listener_ready

func _detect() -> Variant:
	var os_name := OS.get_name()
	if os_name == "Windows":
		return _detect_windows()
	elif os_name == "Android":
		return _detect_android()
	# iOS / macOS / Linux 等：不检测，回退普通预设
	return {"is_bt": false, "source": "unsupported_platform", "name": ""}

## Windows: C# AudioRouteDetector autoload（COM 检测，内部自带失败兜底）
func _detect_windows() -> Dictionary:
	# autoload 按全局名访问；防御性检查避免 C# 侧未注册/加载失败时中断
	var detector = get_node_or_null("/root/AudioRouteDetector")
	if detector == null or not detector.has_method("IsBluetoothOutput"):
		return {"is_bt": false, "source": "no_detector", "name": ""}
	# refresh=true：缓存频率由本类 TTL 控制，透传时绕过 C# 侧缓存
	var is_bt: bool = detector.call("IsBluetoothOutput", true)
	var dev_name: String = str(detector.call("GetOutputName", true))
	return {"is_bt": is_bt, "source": "windows_com", "name": dev_name}

## Android: 获取 AudioManager 后检测蓝牙输出。
## 获取 Context 的两条路径（按优先级）：
##   A) AndroidRuntime 插件 singleton（需导出清单 meta-data 注册，
##      由 addons/android_runtime_inject 导出插件在导出时注入）
##   B) ActivityThread hidden API 兜底（无需任何插件；currentActivityThread()
##      属不受限 hidden API，JavaClassWrapper 的 JNI 调用可直接访问）
## 判定（按优先级）：
##   1) AudioManager.getDevices 遍历蓝牙输出设备类型（准确，含 LE Audio）
##   2) isBluetoothA2dpOn / isBluetoothScoOn 标志位（API 31 起标记废弃但功能保留）
##
## 注意：JavaClassWrapper 返回的 Java 对象包装必须用"直接方法调用"语法
## （官方文档示例风格，如 ctx.getSystemService("audio")），
## 不能用 .call()，更不能用 has_method() ——后者查的是 Godot 方法表，对 Java
## 方法恒返回 false，会静默走进失败分支（本文件首版的真实踩坑）。
func _detect_android() -> Variant:
	var am = _get_android_audio_manager()
	if am == null:
		return {"is_bt": false, "source": "no_audio_manager", "name": ""}

	# 优先 getDevices 路径（覆盖 LE Audio）；任何环节失败会中断本函数返回 null
	var via_devices: Variant = _android_bt_via_get_devices(am)
	if via_devices is Dictionary:
		return via_devices

	# 标志位兜底
	var a2dp: bool = bool(am.isBluetoothA2dpOn())
	var sco: bool = bool(am.isBluetoothScoOn())
	return {"is_bt": a2dp or sco, "source": "android_flags", "name": ""}

## 获取 Android AudioManager（Java 对象包装）；失败返回 null
func _get_android_audio_manager() -> Variant:
	var context = _get_android_context()
	if context == null:
		return null
	# Context.AUDIO_SERVICE = "audio"
	return context.getSystemService("audio")

## 获取 Android Context：A) AndroidRuntime 插件 → B) ActivityThread hidden API
func _get_android_context() -> Variant:
	var runtime = Engine.get_singleton("AndroidRuntime")
	if runtime != null and runtime.has_method("getApplicationContext"):
		var ctx: Variant = runtime.call("getApplicationContext")
		if ctx != null:
			return ctx
	# 兜底：ActivityThread.currentActivityThread().getApplication()
	# currentActivityThread() 是 public static 方法，位于不受限 hidden API 列表
	#
	# 注意：JavaClassWrapper 是 Android 平台专属 singleton（Windows 构建的 Godot
	# 没有该模块），GDScript 编译期直接引用其标识符会导致 Windows 上脚本编译失败，
	# 必须用 Engine.get_singleton 动态获取。
	var jcw = Engine.get_singleton("JavaClassWrapper")
	if jcw == null:
		return null
	var at_class: Variant = jcw.call("wrap", "android.app.ActivityThread")
	if at_class == null:
		return null
	var activity_thread: Variant = at_class.currentActivityThread()
	if activity_thread == null:
		return null
	return activity_thread.getApplication()

## 用 AudioManager.getDevices 遍历输出设备找蓝牙类型（含 LE Audio）。
## JavaClassWrapper 对 Java 数组返回值的转换行为不确定，任何环节失败
## 会中断本函数返回 null，由调用方走标志位兜底，因此内部不做防御。
func _android_bt_via_get_devices(am) -> Variant:
	# AudioManager.GET_DEVICES_OUTPUTS = 3
	var devices: Variant = am.getDevices(3)
	if devices == null:
		return null
	# 蓝牙输出设备类型（AudioDeviceInfo 常量）:
	# TYPE_BLUETOOTH_SCO=7, TYPE_BLUETOOTH_A2DP=8, TYPE_BLE_HEADSET=26, TYPE_BLE_SPEAKER=27
	for d in devices:
		if d == null:
			continue
		var t := int(d.getType())
		if t == 7 or t == 8 or t == 26 or t == 27:
			return {"is_bt": true, "source": "android_bt_type_%d" % t, "name": ""}
	return {"is_bt": false, "source": "android_devices", "name": ""}
