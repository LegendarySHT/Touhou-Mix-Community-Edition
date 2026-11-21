## ServiceHub —— 类 systemd 的服务注册中心 + 依赖图启动器
##
## 目标：把「Main 手写 new()+add_child() 固定顺序」的启动编排，收敛为
## 「服务声明依赖，ServiceHub 拓扑排序后自动启动」。调整注册顺序或依赖列表
## 都不需要改业务逻辑，启动顺序由依赖图推导，不再靠手动调顺序保证依赖。
##
## 职责（按 systemd 类比）：
##   - register(def)        注册一个服务 unit（声明 script/scene/cs + deps）
##   - start_all()          拓扑启动所有「非 lazy」服务（kernel + early + main）
##   - get(id) / lazy(id)   首次访问才实例化的非启动服务（on-demand）
##   - service_ready(id)    等待某服务「就绪」的协议（就绪不依赖启动顺序）
##
## 依赖声明位置：服务脚本顶部的 const SERVICE_ID / SERVICE_DEPS（如
##   Core/FileSystemManager.gd），register() 读取：SERVICE_DEPS 填入 ServiceDef.deps，
##   SERVICE_ID 仅校验与注册 id 一致。Main 不再手写 deps。若需临时覆盖，注册前
##   给 def.deps 赋值并把 def.deps_declared 置 true 即可阻止脚本常量覆盖。
##
## 就绪语义：
##   - 缺省：节点入树（_ready 跑完）即视为就绪。
##   - 数据就绪门：服务可提供 ready_by Callable(instance)->bool，如
##     FileSystemManager.resources_scanned / DataManager.is_initialized /
##     ChartDB.IsOpen()。ServiceHub 在启动壳内轮询该谓词，await 到其成立。
##   - 依赖它的服务用 await ServiceHub.service_ready("FileSystemManager")。
##   - 超时兜底：service_ready() 支持超时秒数，逾期按「就绪失败/可能未就绪」
##     返回，由调用方按现有"proceeding anyway"语义继续，不阻断启动。
##
## 懒服务（非启动必需）：
##   - VersionManager / ResourceManager / AudioRouteDetector 注册为 lazy=true ，
##     不进启动队列；首次 ServiceHub.get(id) 时 new+add_child（挂到本节点下
##     的 LazyServices 子节点，复用原物理挂载点布局）。
##   - 由于本类是 autoload 第一位（已在树中），add_child 不受首帧 blocked
##     影响，无需 LazyService 那套延迟入树逻辑（LazyService 已删除）。
##
## 启动分层（对齐 Project 的初始化语义）：
##   - early  层：StorageManager → ConfigManager 等存储/配置前置
##   - kernel 层：FileSystemManager / ChartDB / DataManager 数据链
##   - main   层：Net/Auth/Score/Community/MemoryGC 等业务管理器
##   - 每层内部按拓扑序启动，同一时刻所有「已就绪依赖、无剩余依赖」的服务可并行。
##   并行仅限创建/挂载动作本身；真正触碰场景树/渲染的后置工作由各自就绪门把关。
## 服务注册中心 + 依赖图启动器（autoload，全局名 `ServiceHub`）
##
## 注意：本类**不**声明 class_name —— Godot 规定 class_name 不能与 autoload 同名。
## 全局访问就靠 autoload 节点名 `ServiceHub`（任意脚本里 `ServiceHub.register(...)` /
## `ServiceHub.svc(...)` 即指向这个已入树的实例，方法与成员都在实例上）。
extends Node

const LAZY_HOST_NAME := "LazyServices"
## 同层级一次并行启动的上限（保护低配/移动端不因过多并发实例化抖动）
const MAX_PARALLEL := 4

## 已注册的服务定义：id -> ServiceDef
var _defs: Dictionary = {}
## 已实例化并挂载的服务节点：id -> Node
var _instances: Dictionary = {}

## ---- 类型化访问门面 ----
## 服务访问统一走这里：`ServiceHub.xxx`（短名 + 静态类型）。getter 经 service(id) 取实例，
## lazy 服务首次访问自动创建，非 lazy 已启动服务直接返回。成员名一览全部服务。
var config: ConfigManager:
	get:
		if _instances.has("ConfigManager"):
			return _instances["ConfigManager"] as ConfigManager
		# 未启动时回退到工厂 getter：ThemeManager 等 autoload 锚点在 core 段启动前
		# 就要读配置，原 ConfigManager.instance 本就带自创语义，这里保持一致
		return ConfigManager.instance
var storage: StorageManager:
	get: return service("StorageManager") as StorageManager
var skin: SkinManager:
	get: return service("SkinMGR") as SkinManager
var particle: ParticleManager:
	get: return service("ParticleMGR") as ParticleManager
var chara: CharaManager:
	get: return service("CharaMGR") as CharaManager
var sort: SortingEngine:
	get: return service("SortEngine") as SortingEngine
var textScroll: TextScrollMGR:
	get: return service("TextScrollMGR") as TextScrollMGR
var audioBt: AudioBtDetector:
	get: return service("AudioBtDetector") as AudioBtDetector
var fs: FileSystemManager:
	get: return service("FileSystemManager") as FileSystemManager
var importer: ImportManager:
	get: return service("ImportManager") as ImportManager
var favorite: FavoriteManager:
	get: return service("FavoriteManager") as FavoriteManager
var scoreCalc: ScoreCalculator:
	get: return service("ScoreCalculator") as ScoreCalculator
var keys: KeySequenceManager:
	get: return service("KeySequenceManager") as KeySequenceManager
var net: NetManager:
	get: return service("NetManager") as NetManager
var auth: AuthManager:
	get: return service("AuthManager") as AuthManager
var score: ScoreManager:
	get: return service("ScoreManager") as ScoreManager
var community: CommunityManager:
	get: return service("CommunityManager") as CommunityManager
var drafts: DraftManager:
	get: return service("DraftManager") as DraftManager
var memory: MemoryGC:
	get: return service("MemoryGC") as MemoryGC
var version: VersionManager:
	get: return service("VersionManager") as VersionManager
var resource: ResourceManager:
	get: return service("ResourceManager") as ResourceManager
var playback: PlaybackDisplay:
	get: return service("PlaybackDisplay") as PlaybackDisplay

## 启动是否已完成的标志（Main 引导结束后置位）
var started := false
## post 段是否已开始启动：惰性访问不得在 post 段之前抢跑 post 服务（其 on_started 有外部副作用）
var _post_phase_started := false

## 就绪信号（Main 收到后结束 ui_boot 等待）
signal services_ready


## ---------------- 注册 ----------------

func _ready() -> void:
	add_to_group("singleton")

func register(def: ServiceDef) -> void:
	if def == null or def.id.is_empty():
		push_error("ServiceHub: 服务缺少 id")
		return
	# 依赖声明下沉到服务脚本：脚本顶部可用 const SERVICE_ID / SERVICE_DEPS 声明自身 id 与依赖，
	# 注册时自动读取填入 def；Main 里显式赋的值（如 on_started 相关的动态依赖）优先。
	_load_decl_from_script(def)
	if _defs.has(def.id):
		push_warning("ServiceHub: 服务 %s 重复注册，覆盖" % def.id)
	_defs[def.id] = def


## 从服务脚本读取 SERVICE_ID / SERVICE_DEPS 常量：SERVICE_ID 做一致性校验，
## SERVICE_DEPS 在 Main 未显式声明时填入。脚本常量表在不实例化节点的情况下可读；
## 加载失败时静默跳过（由 Main 显式声明兜底）。
func _load_decl_from_script(def: ServiceDef) -> void:
	var path := def.gd_script
	if path.is_empty():
		return
	var script := load(path) as Script
	if script == null:
		return
	var constants: Dictionary = script.get_script_constant_map()
	# id：以注册处传入为准，脚本 SERVICE_ID 仅做一致性校验，防止 id 漂移
	if constants.has(&"SERVICE_ID"):
		var declared_id := str(constants[&"SERVICE_ID"])
		if declared_id != def.id:
			push_warning("ServiceHub: 服务 %s 的 SERVICE_ID(%s) 与注册 id 不一致" % [def.id, declared_id])
	# deps：Main 未显式声明才采用脚本的 SERVICE_DEPS
	if not def.deps_declared and constants.has(&"SERVICE_DEPS"):
		def.deps = PackedStringArray(constants[&"SERVICE_DEPS"])


## 收编一个「由 Godot/其它路径已实例化」的服务（如保留的 autoload 锚点：
## EvtBus / GLogger / ChartDB / MeltySynth / PlaybackDisplay / DataMGR / UiStatMGR /
## ThemeMGR / FocusMGR / AniMGR / CoverLoader）。它在引擎启动时已在场景树中，
## ServiceHub 只登记它、不做依赖图里的启动/重复实例化，但仍可作为其它服务的
## 依赖节点（其它服务可声明 deps 含其 id，service_ready 直接返回真）。
## 返回已收编的节点。
func adopt(id: String, existing: Node) -> Node:
	if existing == null:
		push_error("ServiceHub: adopt %s 传入空节点" % id)
		return null
	if not _defs.has(id):
		var d := ServiceDef.new()
		d.id = id
		d.node_name = id
		_defs[id] = d
	_instances[id] = existing
	return existing


## ---------------- 启动 ----------------

## 启动指定阶段中「尚未启动」的服务。
##   phase : ServiceDef.phase 值（"core"/"pre"/"post"）
## 返回该阶段本次启动了几个服务（已启动的跳过）。
## 依赖图保证：仅当某服务的全部 deps 已就绪时才实例化；同阶段内无剩余依赖的服务
## 按拓扑顺序被本次或后续 start_phase 调用实例化。
func start_phase(phase: String) -> int:
	if phase == "post":
		_post_phase_started = true
	var order := _topo_order()
	if order.is_empty() and not _has_pending():
		push_error("ServiceHub: 依赖图存在环，无法完成拓扑排序")
		return 0
	var started_count := 0
	for id in order:
		var def: ServiceDef = _defs.get(id, null)
		if def == null or def.lazy:
			continue
		if def.phase != phase:
			continue
		if _instances.has(id):
			continue
		# 仅当全部依赖已实例化（含已收编的 autoload 锚点）才启动
		if not _deps_ready(def):
			continue
		_instantiate(id)
		started_count += 1
	if phase == "post":
		# 最后阶段结束：校验所有非 lazy 服务确已启动，避免依赖缺失时静默半初始化
		if _has_pending():
			push_error("ServiceHub: post 阶段结束后仍有未启动的非 lazy 服务")
		else:
			started = true
			services_ready.emit()
	return started_count


## 判断是否还有未启动的非 lazy 服务（用于环检测）
func _has_pending() -> bool:
	for id in _defs:
		if _defs[id].lazy:
			continue
		if not _instances.has(id):
			return true
	return false


## 某服务的全部依赖是否已实例化（就绪）。
func _deps_ready(def: ServiceDef) -> bool:
	for dep in def.deps:
		if not _instances.has(dep):
			return false
	return true


## 兼容入口：一次性按拓扑与齐所有阶段（等价 core+pre+post 依次 start_phase）。
## Main 不再调用，保留给简单/调试场景。
func start_all() -> bool:
	start_phase("core")
	await get_tree().process_frame
	start_phase("pre")
	await get_tree().process_frame
	start_phase("post")
	return true


## ---------------- 按需（lazy）服务 ----------------

## 取某个服务的实例；未启动的已注册非 lazy 服务在访问时按依赖图自动补齐启动。
## 返回 null 的两种情况：未注册，或注册了但依赖尚未就绪而无法在本调用安全启动。
## 注意方法名用 service() 而非 get()，避免与 Node.get() 冲突。
func service(id: String) -> Node:
	if not _defs.has(id):
		return null
	if _instances.has(id):
		return _instances[id]
	if _defs[id].lazy:
		_instantiate(id)
		return _instances.get(id, null)
	_ensure_started(id)
	return _instances.get(id, null)


## 按依赖图把 id 及其依赖的前缀补齐启动（调用时惰性启动）。
## 只保证「依赖已就绪的服务」能启动；若某依赖尚未注册或形成环/缺失而无法前置，
## 则跳过该服务，其余依赖已就绪的服务继续启动。start_phase 之后再次访问会用同样逻辑兜底。
## 阶段边界：post 服务及其依赖只在 post 段开始后才惰性补齐，避免早期访问时把
## Net/Auth 等及其 on_started 抢跑到入场动画之前执行。
func _ensure_started(id: String) -> void:
	var target: ServiceDef = _defs.get(id, null)
	if target == null or target.lazy:
		return
	var order := _topo_order()
	for sid in order:
		if _instances.has(sid):
			continue
		var def: ServiceDef = _defs.get(sid, null)
		if def == null:
			continue
		# post 段之前不抢跑 post 服务（及其依赖）
		if def.phase == "post" and not _post_phase_started:
			continue
		if not _deps_ready(def):
			continue  # 依赖不齐则跳过，不阻断后续无关服务
		_instantiate(sid)
		if sid == id:
			return


## 等待某服务「就绪」。
##   id       : 服务 id
##   timeout  : 超时秒数（<=0 表示无限等待）；缺省 5 秒
## 返回 true=已就绪，false=超时/服务不存在/实例创建失败。
## 若服务尚未实例化，先经 service() 触发 lazy 创建 / 非 lazy 补齐启动，再轮询就绪门。
## 若服务已实例化且 _ready 跑完（无 ready_by），立即返回 true。
func service_ready(id: String, timeout: float = 5.0) -> bool:
	var def: ServiceDef = _defs.get(id, null)
	if def == null:
		push_error("ServiceHub: 服务 %s 未注册" % id)
		return false
	var infinite := timeout <= 0.0
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while true:
		# 未实例化则每帧尝试补齐（lazy 首次访问会创建；非 lazy 等依赖就绪后启动）
		if not _instances.has(id):
			service(id)
		var inst: Node = _instances.get(id, null)
		if inst == null:
			if not infinite and Time.get_ticks_msec() >= deadline:
				return false
			await get_tree().process_frame
			continue
		if _is_ready(def, inst):
			return true
		if not infinite and Time.get_ticks_msec() >= deadline:
			return false
		await get_tree().process_frame
	# 理论不可达（infinite 时循环不退出；有限时必在 Deadline 内返回）；防御性回归
	return false


## ---------------- 内部 ----------------

## 拓扑排序（Kahn）。返回顶序执行顺序 Array[String]。
func _topo_order() -> Array:
	var order: Array = []
	var indeg: Dictionary = {}
	var adj: Dictionary = {}
	for id in _defs:
		var def: ServiceDef = _defs[id]
		if def.lazy:
			continue  # lazy 不进启动队列
		indeg[id] = 0
		adj[id] = []
	# 建邻接 + 入度
	for id in _defs:
		if _defs[id].lazy:
			continue
		for dep in _defs[id].deps:
			if not _defs.has(dep):
				push_warning("ServiceHub: 服务 %s 依赖未注册的 %s，忽略" % [id, dep])
				continue
			if _defs[dep].lazy:
				continue  # lazy 依赖强制在 get 时同步就绪，不进启动图
			if not adj.has(dep):
				adj[dep] = []
			adj[dep].append(id)
			indeg[id] += 1
	# Kahn
	var queue: Array = []
	for id in indeg:
		if indeg[id] == 0:
			queue.append(id)
	while not queue.is_empty():
		# 每轮取一个入度为 0 的
		var cur: String = queue.pop_front()
		order.append(cur)
		for nxt in adj.get(cur, []):
			indeg[nxt] -= 1
			if indeg[nxt] == 0:
				queue.append(nxt)
	return order


## 实例化一个服务并挂挂载。
func _instantiate(id: String) -> void:
	if _instances.has(id):
		return
	var def: ServiceDef = _defs.get(id, null)
	if def == null:
		push_error("ServiceHub: 服务 %s 未注册" % id)
		return
	var node := ScriptedNodeFactory.create(def)
	if node == null:
		push_error("ServiceHub: 服务 %s 创建失败" % id)
		return
	if def.node_name.is_empty():
		node.name = id
	else:
		node.name = def.node_name
	# 先登记再入树：add_child 会同步跑 _ready，期间若某服务回调自己的 ServiceHub getter，
	# 必须先能从 _instances 找到自己，否则会走到 _ensure_started 二次实例化。
	_instances[id] = node
	if not def.factory.is_valid():
		# factory 服务（懒单例 / autoload 锚点）自管理挂载，ServiceHub 不入树它
		var parent := _resolve_parent(def)
		parent.add_child(node)
	if def.on_started.is_valid():
		# 依赖图排序保证此处的命令式交接在依赖方启动之前执行
		def.on_started.call(node)


## 解析服务挂载父节点。
func _resolve_parent(def: ServiceDef) -> Node:
	match def.parent:
		"root":
			return get_tree().root
		"lazy":
			return _lazy_host()
		_:
			return self


## 懒服务挂载点（复用原 /root/LazyServices 布局，但挂在 ServiceHub 下以保证顺序）。
func _lazy_host() -> Node:
	var host := get_node_or_null(LAZY_HOST_NAME)
	if host == null:
		host = Node.new()
		host.name = LAZY_HOST_NAME
		add_child(host)
	return host


## 判断服务是否就绪。
func _is_ready(def: ServiceDef, inst: Node) -> bool:
	if not is_instance_valid(inst):
		return false
	if def.ready_by.is_valid():
		return bool(def.ready_by.call(inst))
	# 缺省：入树且不是「等待 _ready 中」即就绪。（_ready 同步跑完，add_child 后即完成）
	return true


## 调试：打印当前服务注册表
func dump() -> void:
	for id in _defs:
		var d: ServiceDef = _defs[id]
		print("  %-24s lazy=%s deps=%s" % [id, str(d.lazy), str(d.deps)])
