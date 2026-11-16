## 服务描述：依赖图中的单个服务节点
##
## 由 ServiceHub 读取，描述一个服务如何实例化、挂载、就绪，
## 以及它依赖哪些其它服务（作为拓扑排序与并行启动的依据）。
##
## 用途（与 systemd unit 的 [Unit]/[Install] 段类比）：
##   - script / scene / cs  指定如何创建实例（三者至多一个）
##   - deps                 声明 Prerequisite，ServiceHub 据此拓扑排序
##   - ready                可选的「就绪」判定，缺省 = 入树后 _ready 完即就绪
class_name ServiceDef
extends RefCounted

## 服务唯一 id（依赖图节点 key，如 "FileSystemManager"）
var id: String = ""

## 创建设置 —— 三者至多一个：
##   factory   : Callable() -> Node  返回已存在的实例（懒单例 ServiceHub.config、
##              autoload 锚点等自管理节点）。设了它则忽略 gd_script/scene/cs_script。
##   gd_script: res:// 一个 .gd 脚本路径  -> 新建 Node 并 set_script
##   scene    : res:// 一个 .tscn 场景路径 -> load().instantiate()
##   cs_script: res:// 一个 .cs 脚本路径  -> 新建 Node 并 set_script（C# 脚本）
## 注意：不叫 script，避免与 RefCounted 自带成员冲突。
## 注意：用 factory 的服务 ServiceHub 不会 add_child（该节点自管理挂载），只登记就绪。
var factory: Callable = Callable()
var gd_script: String = ""
var scene: String = ""
var cs_script: String = ""

## 挂载后的节点名（缺省用 id）
var node_name: String = ""

## 挂载到的父节点 id；缺省挂在 ServiceHub 自身（autoload，已在树中）。
## 传 "root" 会挂到场景树根 /root；传 "lazy" 会挂到 ServiceHub 的懒服务挂载点下
## （仅语义，ServiceHub 会根据本值选择实际父节点）。
var parent: String = "hub"

## 依赖服务 id 列表（必须先于本服务就绪）
var deps: PackedStringArray = []

## 是否属于「非启动必需」服务：不在 start_all() 的拓扑启动队列里，
## 而是首次 ServiceHub.get(id) 时才实例化（如 VersionManager / ResourceManager）。
var lazy: bool = false

## 是否只启动一次并立即释放（不常驻；如一次性初始化任务）
## 当前未启用，保留字段以对齐 systemd oneshot 语义。
var oneshot: bool = false

## 就绪回调 Callable(instance) -> bool。缺省 null = 入树后（_ready 完）即就绪。
## 用于数据就绪门（如 FileSystemManager.resources_scanned、
##   DataManager.is_initialized、ChartDB 的 IsOpen()）。
var ready_by: Callable = Callable()

## 启动阶段（仅影响启动节奏/入场动画的切分，不影响依赖顺序）：
##   "core"：存储/配置/DB/文件系统/导入 等早期前置
##   "pre" ：入场前的轻量管理器（收藏夹、分数计算器）
##   "post"：入场后依赖较广的业务管理器（Net/Auth/Score/Community/MemoryGC）
## 依赖顺序完全由 deps 推导；phase 只决定启动器在哪个阶段时间点实例化。
var phase: String = "core"

## 实例化后同步调用的回调 Callable(instance) -> void。
## 用于承载「依赖图表达不了的命令式值交接」：
##   - StorageManager 创建后立刻 recover_and_resolve()，把 storage_resolve 捕获取给 Main，
##     供随后 FileSystemManager.force_full_rescan / 配置提交使用。
##   - FileSystemManager 创建后按 storage_resolve 设置 force_full_rescan 并连 mark_rescan_done。
##   - NetManager 创建后 set_online_mode(配置)。
var on_started: Callable = Callable()


## 构造一个 .gd 脚本服务
static func gd(p_id: String, p_script: String) -> ServiceDef:
	var d := ServiceDef.new()
	d.id = p_id
	d.gd_script = p_script
	d.node_name = p_id
	return d


## 构造一个 .tscn 场景服务
static func scene_of(p_id: String, p_scene: String) -> ServiceDef:
	var d := ServiceDef.new()
	d.id = p_id
	d.scene = p_scene
	d.node_name = p_id
	return d


## 构造一个 C# 脚本服务
static func cs_of(p_id: String, p_cs: String) -> ServiceDef:
	var d := ServiceDef.new()
	d.id = p_id
	d.cs_script = p_cs
	d.node_name = p_id
	return d