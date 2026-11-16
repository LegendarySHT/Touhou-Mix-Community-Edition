## 统一「节点创建 + 脚本/C# 脚本设置」的工具
##
## 项目里散落着多种"建一个带脚本的节点"的写法：
##   - Main.gd：new()+add_child 手动创建管理器（脚本由 class_name 常量 new 出来）
##   - AudioBtDetector：Node.new()+set_script("...cs")+add_child（C# 懒子节点）
##   - ParticleAdjust：Node.new()+set_script(preload)+add_child
## 本类把它们收敛为一条路径，ServiceHub 与业务代码都经它创建节点，
## 消除「手动 set_script / 手动 add_child」的重复与顺序隐患。
## 实例一律由脚本或场景派生，调用方不再需要自己 new()+set_script()。
class_name ScriptedNodeFactory
extends RefCounted


## 依据 ServiceDef 创建一个（尚未挂载的）节点实例。
##   gd_script: 新建 Node 并 set_script(.gd)
##   cs_script: 新建 Node 并 set_script(.cs)
##   scene    : load(.tscn).instantiate()
## 返回 Node；三种都未配时报 push_error + 返回 null。
static func create(def: ServiceDef) -> Node:
	if def == null:
		return null
	if def.factory.is_valid():
		return def.factory.call()
	if not def.scene.is_empty():
		var packed := load(def.scene) as PackedScene
		if packed == null:
			push_error("ScriptedNodeFactory: 无法加载场景 %s" % def.scene)
			return null
		return packed.instantiate()
	if not def.gd_script.is_empty():
		var n := Node.new()
		n.set_script(load(def.gd_script))
		return n
	if not def.cs_script.is_empty():
		var n := Node.new()
		n.set_script(load(def.cs_script))
		return n
	push_error("ScriptedNodeFactory: 服务 %s 未配置 script/scene/cs" % def.id)
	return null


## 由脚本路径创建一个节点并挂到 parent 下（收敛手写 Node.new()+set_script()+add_child）。
##   script_path : res:// .gd 或 .cs
##   node_name   : 挂载后的节点名（缺省取文件基名）
##   返回已入树的节点。
static func spawn_script(script_path: String, parent: Node,
		node_name: String = "") -> Node:
	if parent == null:
		push_error("ScriptedNodeFactory: parent 为空，无法挂载 %s" % script_path)
		return null
	var n := Node.new()
	n.set_script(load(script_path))
	if node_name.is_empty():
		node_name = script_path.get_file().get_basename()
	n.name = node_name
	parent.add_child(n)
	return n


## 由场景路径实例化并挂到 parent 下。
##   返回已入树的节点。
static func instantiate_scene(scene_path: String, parent: Node,
		node_name: String = "") -> Node:
	if parent == null:
		push_error("ScriptedNodeFactory: parent 为空，无法实例化 %s" % scene_path)
		return null
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_error("ScriptedNodeFactory: 无法加载场景 %s" % scene_path)
		return null
	var n := packed.instantiate()
	if not node_name.is_empty():
		n.name = node_name
	parent.add_child(n)
	return n