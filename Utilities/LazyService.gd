## 懒加载服务的挂载点
##
## 用途：把「只在某个页面/功能才用得上」的服务从 autoload 摘下来，改成首次访问
## `Xxx.instance` 时才创建，并且**挂进场景树**。
##
## 为什么必须挂树（和 ConfigManager 的懒单例不同）：
##   ConfigManager 是纯数据类，`new()` 出来不挂树也能用。
##   但本文件服务的对象都要 `_process` / `get_tree()` / 连接信号 —— 脱离场景树的
##   Node 这些全部失效（`get_tree()` 返回 null，`_process` 不跑）。
##
## 用法（写在服务类内部，外部不要手动调 mount）：
##   static var instance: Foo:
##       get:
##           if _instance == null:
##               _instance = Foo.new()
##               LazyService.mount(_instance, "Foo")
##           return _instance
##   static var _instance: Foo = null
##
## 附带收益（比省那点实例化时间更重要）：
##   autoload 的 `_ready` 早于 Main 的存储根解析 / 配置加载 / FileSystemManager 建立，
##   所以服务在 `_ready` 里读配置或文件索引只能拿到默认值/空值，得靠一堆防御注释和
##   "稍后再补一次"的调用点兜。懒加载的创建时机 = 首次访问，那时这些前置都已就绪，
##   服务可以放心在 `_ready` 里读真实配置。
##
## 时序约束：
##   启动首帧（`SceneTree.get_frame() == 0`）内 root 正在建立主场景，处于 blocked 状态，
##   此时对 root `add_child()` 会直接失败并刷 ERROR。这段窗口只能延迟挂载 —— 服务会先
##   挂到游离的挂载点上（游离节点 add_child 不受限），下一帧整棵子树一起入树。
##   因此**极少数在首帧创建的懒服务，其 `_ready` 会晚一帧执行**；余下所有路径都是同步的。
class_name LazyService

## 挂载点节点名（挂在 /root 下，与 autoload 同层；进程退出时随场景树一起释放）
const HOST_NAME := "LazyServices"

static var _host: Node = null
## 首帧延迟挂载已排队（避免多次访问重复 call_deferred → 重复 add_child）
static var _attach_pending := false

## 把服务实例挂到懒加载挂载点。
## 已入树 / 已释放的实例直接返回，重复调用安全。
static func mount(node: Node, display_name: String = "") -> void:
	if node == null or not is_instance_valid(node):
		return
	if node.is_inside_tree():
		return
	var host := get_host()
	if host == null:
		# 主循环未建立或已结束：退化成"不挂树的单例"，能用但没有 _process
		push_warning("LazyService: 场景树不可用，%s 未挂入树" % display_name)
		if not display_name.is_empty() and node.name.is_empty():
			node.name = display_name
		return
	if not display_name.is_empty():
		node.name = display_name
	host.add_child(node)
	_attach_host()

## 懒加载挂载点（不存在则创建）。调试时可在远程树里找 /root/LazyServices。
static func get_host() -> Node:
	if _host != null and is_instance_valid(_host):
		_attach_host()
		return _host
	var root := _root()
	if root == null:
		return null
	var existing := root.get_node_or_null(NodePath(HOST_NAME))
	if existing != null:
		_host = existing
		return _host
	_host = Node.new()
	_host.name = HOST_NAME
	_attach_host()
	return _host

static func _root() -> Window:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var root := tree.root
	if root == null or not is_instance_valid(root):
		return null
	return root

## 把挂载点接到 root 上（已接上则什么都不做）
static func _attach_host() -> void:
	if _host == null or not is_instance_valid(_host):
		return
	if _host.is_inside_tree():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	# 首帧 root 正在建立主场景（blocked），同步 add_child 会失败：交给延迟调用
	if tree.get_frame() == 0:
		if _attach_pending:
			return
		_attach_pending = true
		_flush_attach.call_deferred()
		return
	tree.root.add_child(_host)

## 首帧末尾把挂载点（连同已挂在它下面的服务）整体入树
static func _flush_attach() -> void:
	_attach_pending = false
	if _host == null or not is_instance_valid(_host):
		return
	if _host.is_inside_tree():
		return
	var root := _root()
	if root == null:
		return
	root.add_child(_host)
