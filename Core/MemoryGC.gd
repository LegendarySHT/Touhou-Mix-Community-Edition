extends Node

class_name MemoryGC

## 后台内存回收管理器（Android 专用；非 Android 平台整体空转）
##
## 触发来自 addons/android_bridge 的 AndroidBridge 插件：
##   signal trim_memory(level)      —— level 0 = 后台挂留超时，其余为 onTrimMemory 原值
##   方法 consume_pending_trim_level() —— "拉"通道，兜住"信号早于引擎就绪/投递时机不定"
##
## 策略（由需求确定）：**只在后台、且达到中等档位时才清**，前台一律不清。
##   - 前台时系统的 TRIM 只记日志不动作：清掉当前页面周边的内容，返回时会看到封面重载，
##     得不偿失；系统真到关键档位会直接杀后台进程，前台清理帮不上忙。
##   - 后台 30 秒挂留（level 0）与 Android 的中等档位等价处理：挂留超时本身就是
##     "后台且该清了"的可靠信号，而且比 TRIM 事件更稳定（内存宽裕的设备长时间不发 TRIM）。
##
## 为什么可以同步直调、不能用 call_deferred：
##   后台时 Godot 主循环停摆（GLSurfaceView 暂停后不再出帧 → Main::iteration 不被调用），
##   而 MessageQueue::flush() 只在 SceneTree::process/physics_process 里发生，deferred 会一直挂着。
##   Java 插件的 emitSignal 走 runOnRenderThread → GLSurfaceView.queueEvent，而渲染线程循环是
##   "先取事件队列、再判断能否绘制"，所以信号在后台仍能被处理（熄屏后台媒体按钮同理）。
##   因此本类所有回收动作都是同步直调。
##
## 为什么可以安全释放：
##   回调运行在 GL 线程（= Godot 主线程）两次迭代之间的空档，场景树没有被遍历、也没在绘制；
##   GL 侧 GodotGLRenderView 开了 setPreserveEGLContextOnPause(true)，EGL context 保留，
##   释放纹理不需要重建上下文。
##
## 不释放的东西（刻意）：
##   - C# 播放器（MeltySynth/MidiCore）任何结构、SoundFont（30.8MB）、当前播放曲目 → 后台播放不能断
##   - 视图节点本身（只清内容不删壳）：各视图 _ready 只跑一次，删壳会连带丢掉信号连接、
##     ThemeMGR 注册，以及别处单例里存的视图引用
##   - 当前所在页面（UiStatMGR.current_state）

## 后台挂留超时的档位（= AndroidBridge 的 level 0）
const LEVEL_BG_IDLE := 0

## 静态实例引用：本类是手动单例（非 autoload），由 Main 创建为子节点。
## 其他组件（如 BaseScrollList 判断"要不要自愈"）不便于拿到节点路径，
## 故在 _ready/_exit_tree 维护这个引用；可能为 null（启动早期/非 Android）。
static var instance: MemoryGC = null

func _ready() -> void:
	instance = self
	# 非 Android 平台直接空转（桌面端没有 onTrimMemory，也没有保后台播放的诉求）
	if OS.get_name() != "Android":
		set_process(false)
		return
	_connect_pending_plugin.call_deferred()

func _exit_tree() -> void:
	if instance == self:
		instance = null

## 达到此档位才执行清理。10 = TRIM_MEMORY_RUNNING_MODERATE，与需求里"中等档位"一致。
const LEVEL_THRESHOLD := 10

## 已执行过清理（供视图判断"要不要自愈"）
var _trimmed: bool = false
## 内存压力档位（诊断用，回前台后清零）
var _last_level: int = 0
## 上次执行的时刻（毫秒）：配合冷却窗口吸收"同一次内存压力的多次广播"。
## 刻意不用"同档位去重"——缓存会被重新填满，档位相同不代表没有东西可清。
var _last_apply_ms: int = 0
## 冷却窗口：10 秒内重复到达的 trim 视为同一次压力事件的多次广播（只清一次）
const APPLY_COOLDOWN_MS := 10000
## [诊断] 累计吸收的 trim 次数
var _absorb_count: int = 0

## 插件实例的获取时机不可靠：AndroidBridge 在 Godot.initEngine() 早期注册，但
## Engine.get_singleton 在两个平台上都可能在启动阶段返回 null（C# 播放器侧有同款重试先例）。
## 这里按帧重试若干次，拿到就绑信号并消费一次内存档位。
var _plugin_retry_frames: int = 0
const PLUGIN_RETRY_MAX_FRAMES := 300

func _connect_pending_plugin() -> void:
	var plugin := _plugin()
	if plugin == null:
		_plugin_retry_frames += 1
		if _plugin_retry_frames < PLUGIN_RETRY_MAX_FRAMES:
			_connect_pending_plugin.call_deferred()
		else:
			GLogger.warning("MemoryGC: AndroidBridge singleton never became available; trim_memory disabled", "MemoryGC")
		return

	if not plugin.has_signal("trim_memory"):
		GLogger.warning("MemoryGC: AndroidBridge has no trim_memory signal (plugin too old?); disabled", "MemoryGC")
		return
	var err: int = plugin.connect("trim_memory", _on_trim_memory)
	if err != OK:
		GLogger.warning("MemoryGC: failed to connect trim_memory (err=%d)" % err, "MemoryGC")
		return

	GLogger.info("MemoryGC ready (threshold level >= %d, background only)" % LEVEL_THRESHOLD, "MemoryGC")
	# 启动兜底：注册监听可能早于引擎就绪，期间到达的档位存在 Java 侧，这里拉一次
	_drain_pending_level("startup")

func _plugin() -> Object:
	if not Engine.has_singleton("AndroidBridge"):
		return null
	return Engine.get_singleton("AndroidBridge")

# ── 触发入口 ──────────────────────────────────────────

## Java 侧推来的档位
func _on_trim_memory(level: int) -> void:
	_log_pss("before level=%d" % level)
	if not is_background():
		# 前台不清理：清的是当前页面周边内容，返回时会看到封面/列表重载
		GLogger.info("[MEMGC] trim level=%d ignored (foreground)" % level, "MemoryGC")
		return
	if not _meets_threshold(level):
		GLogger.info("[MEMGC] trim level=%d ignored (below threshold %d)" % [level, LEVEL_THRESHOLD], "MemoryGC")
		return
	_apply(level)
	_log_pss("after level=%d" % level)

## 回前台：消费一次内存档位（兜住后台投递时机不定的情况），并让视图自愈
func notify_resumed() -> void:
	_last_level = 0
	# 回前台时相机消费：此刻若还有积压档位，说明后台那几次没送达
	_drain_pending_level("resume")
	if _trimmed:
		_refresh_current_view_after_trim()

## 供视图查询"上次后台清理后是否需要自愈"
func is_trimmed() -> bool:
	return _trimmed

func is_background() -> bool:
	return _background

# ── 后台状态 ──────────────────────────────────────────

## 主循环是否处于暂停（后台）状态。由 Main / TrackView 等既有的
## NOTIFICATION_APPLICATION_PAUSED / RESUMED 通知经 set_background() 维护。
var _background: bool = false

func set_background(bg: bool) -> void:
	_background = bg

# ── 档位判定 ──────────────────────────────────────────

func _meets_threshold(level: int) -> bool:
	# 0 = 后台挂留超时，等价于"后台且该清了"
	if level == LEVEL_BG_IDLE:
		return true
	return level >= LEVEL_THRESHOLD

func _drain_pending_level(reason: String) -> void:
	var plugin := _plugin()
	if plugin == null or not plugin.has_method("consume_pending_trim_level"):
		return
	var level: int = int(plugin.call("consume_pending_trim_level"))
	if level == 0:
		return
	GLogger.info("[MEMGC] drained pending trim level=%d (%s)" % [level, reason], "MemoryGC")
	if not is_background():
		GLogger.info("[MEMGC] pending level=%d ignored (foreground)" % level, "MemoryGC")
		return
	if _meets_threshold(level):
		_apply(level)

# ── 执行 ──────────────────────────────────────────────

func _apply(level: int) -> void:
	# 去重判据是【时间冷却】而不是"同档位"：
	# 缓存是会被重新填满的（用户翻几页曲库、看几套皮肤），下一次进后台时它又占了内存 ——
	# 用档位去重会把这次合法的清理挡掉（真机日志里出现过：level=0 清过一次后，
	# 40 秒后再进后台被 "already applied, skip" 跳过，而中间用户翻过曲库）。
	# 冷却窗口只用来吸收"同一次内存压力的多次广播"。
	var now_ms := Time.get_ticks_msec()
	if _trimmed and now_ms - _last_apply_ms < APPLY_COOLDOWN_MS:
		GLogger.debug("[MEMGC] level=%d within cooldown (%dms), skip" %
			[level, now_ms - _last_apply_ms], "MemoryGC")
		return
	_last_apply_ms = now_ms
	_trimmed = true
	_absorb_count += 1
	_last_level = level
	var t0 := Time.get_ticks_usec()
	GLogger.info("[MEMGC] apply level=%d (background, #%d)" % [level, _absorb_count], "MemoryGC")

	# 顺序有讲究：先丢"最纯的缓存"（几乎不可能出错、收益确定），再动视图内容
	_drop_texture_caches()
	_drop_misc_caches()
	_trim_inactive_views()
	_trim_hydration_cache()
	# 最后才要一次托管堆回收：上面前四步刚把一批引用放掉，此刻回收才收得掉那些对象。
	# （C# 侧 CoreCLR 不主动把已提交页还给 OS，空闲进程会长期占着 —— 见
	#   MeltySynthPlayer.collect_managed_garbage 的说明。）
	_collect_managed_garbage()

	GLogger.info("[MEMGC] apply done in %.1f ms" % ((Time.get_ticks_usec() - t0) / 1000.0), "MemoryGC")

## 纹理类缓存：全部有现成的公开清空 API，且都有按需重载路径
func _drop_texture_caches() -> void:
	var fs_mgr := FileSystemManager.instance
	if fs_mgr != null:
		# 封面强引用 LRU（COVER_TEXTURE_CACHE_MAX = 24 条）
		fs_mgr.clear_cover_cache()
		GLogger.info("[MEMGC]   cover cache cleared", "MemoryGC")

	if SkinMGR != null:
		# 音符皮肤贴图（只留最近两套，清了下次用时重扫）
		SkinMGR.clear_skin_cache()
		GLogger.info("[MEMGC]   skin texture cache cleared", "MemoryGC")

	if ParticleMGR != null:
		# 粒子精灵图（基础 + 散射两类）
		ParticleMGR.clear_texture_cache()
		GLogger.info("[MEMGC]   particle texture cache cleared", "MemoryGC")

	if CharaMGR != null:
		# 立绘合成缓存（每份是一整张合成图，单笔不小）
		CharaMGR.clear_composite_cache()
		GLogger.info("[MEMGC]   chara composite cache cleared", "MemoryGC")

## 杂项缓存（纯内存字典，无 GPU 资源）
func _drop_misc_caches() -> void:
	if SortEngine != null:
		SortEngine.clear_cache()
	# 谱面详情列表的静态信息缓存（MidiListItem._info_cache）：MidiView 自己也有清的先例
	var midi_list_item := load("res://UI/Views/MidiView/MidiListItem.gd")
	if midi_list_item != null and midi_list_item.has_method("clear_info_cache"):
		midi_list_item.call("clear_info_cache")
		GLogger.info("[MEMGC]   midi info cache cleared", "MemoryGC")

## 非当前页面的懒加载视图：清内容、留节点壳
##
## 顺序刻意是"先放纹理、再清状态、最后才销毁节点"：
## clear_items() 走 queue_free，而 queue_free 只入队、帧末才真释放；后台帧停摆，
## 真正立刻见效的是"把 Texture 引用放掉"。所以必须先把封面/纹理清掉再销毁节点。
func _trim_inactive_views() -> void:
	if UiStatMGR == null:
		return
	var current: int = UiStatMGR.current_state
	var trimmed := 0
	for state in UiStatMGR.LAZY_VIEW_PATHS.keys():
		if state == current:
			continue
		var view: Node = UiStatMGR.get_loaded_view(state)
		if view == null or not is_instance_valid(view):
			continue
		_trim_view_recursive(view, 0)
		trimmed += 1
	GLogger.info("[MEMGC]   inactive views trimmed: %d (current state=%d kept)" % [trimmed, current], "MemoryGC")

## 递归两层：视图本身 + 其子容器（MusicPlayerView 的曲库/播放列表面板都不是
## BaseScrollList，封面与行池在它们内部）
func _trim_view_recursive(node: Node, depth: int) -> void:
	if node == null or not is_instance_valid(node) or depth > 1:
		return
	# 1) 先放纹理引用（立刻见效）
	if node.has_method("release_covers"):
		node.call("release_covers")
	if node.has_method("release_cover_state"):
		node.call("release_cover_state")
	# 2) 复位"已加载"标记，让下次进入重算视窗并重新入队（否则缓存清了封面会永久空着）
	if node.has_method("invalidate_cover_state"):
		node.call("invalidate_cover_state")
	# 3) 最后销毁列表项/卡片（queue_free 入队，回前台帧末回收）
	if depth > 0 and node.has_method("clear_items"):
		node.call("clear_items")
	for child in node.get_children():
		if is_instance_valid(child):
			_trim_view_recursive(child, depth + 1)

## 水合缓存（DataMGR.midis）：丢弃"当前播放曲"之外的所有条目。
## _ensure_midi 会按需经 ChartDb 重新水合，丢的是内存不是数据。
##
## 保留判据用【对象身份】而不是键名：midis 是"按解析到的规范键/别名"为键的缓存，
## 同一个 MidiData 可能挂在 id / chart_key / 别名等多个键下，按键名保留会漏。
## 身份比较保证"正在播放的那一份"一定活着——C# 后台换曲时 GDScript 侧仍要读它。
func _trim_hydration_cache() -> void:
	if DataMGR == null:
		return
	var midis: Dictionary = DataMGR.midis
	var before := midis.size()
	if before <= 1:
		return

	var pd := _playback_display()
	var current_midi = pd.current_midi_data if pd != null else null

	var dropped := 0
	for key in midis.keys():
		if current_midi != null and midis[key] == current_midi:
			continue
		midis.erase(key)
		dropped += 1
	GLogger.info("[MEMGC]   hydration cache trimmed: %d -> %d (dropped %d)" %
		[before, midis.size(), dropped], "MemoryGC")

func _playback_display() -> Node:
	var pd := get_node_or_null("/root/PlaybackDisplay")
	return pd

## 主动要一次 C# 托管堆回收（把刚放掉的引用真正还给系统）。
## 放在清理流程最末：上面的引用释放要先发生，否则收不到那批对象。
## 停顿几十毫秒，仅在后台内存压力时执行，不在对局/切曲关键路径上。
func _collect_managed_garbage() -> void:
	var pd := _playback_display()
	if pd == null or not pd.has_method("collect_managed_garbage"):
		return
	var t0 := Time.get_ticks_usec()
	pd.call("collect_managed_garbage")
	GLogger.info("[MEMGC]   managed GC requested (%.1f ms)" %
		((Time.get_ticks_usec() - t0) / 1000.0), "MemoryGC")

## 回前台后刷新当前视图的封面（缓存被清了、标记也要复位）
func _refresh_current_view_after_trim() -> void:
	if UiStatMGR == null:
		return
	var view: Node = UiStatMGR.get_loaded_view(UiStatMGR.current_state)
	if view == null or not is_instance_valid(view):
		return
	if view.has_method("invalidate_cover_state"):
		view.call("invalidate_cover_state")

# ── 诊断 ──────────────────────────────────────────────

## 触发一次真实 PSS 打点（Java 侧 Debug.getMemoryInfo），用于量出清理前后的内存差。
## 只看 Godot 托管堆会漏掉原生/纹理部分，PSS 更接近真实占用。
func _log_pss(tag: String) -> void:
	var plugin := _plugin()
	if plugin == null or not plugin.has_method("log_pss"):
		return
	plugin.call("log_pss", tag)

## [诊断] 系统当前把本进程当成什么（前台服务保护是否生效 / 是否已被当缓存进程）
func debug_memory_state() -> String:
	var plugin := _plugin()
	if plugin == null or not plugin.has_method("get_my_memory_state"):
		return "unavailable"
	return str(plugin.call("get_my_memory_state"))
