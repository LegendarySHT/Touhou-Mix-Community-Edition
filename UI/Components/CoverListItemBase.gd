## 含封面视差效果的列表项基类
## 继承自 ListItemBase,为含 cover_texture 的子类提供统一的视差移动与封面加载/释放
## 封面加载采用异步线程池:主线程入队 CoverLoader,后台线程纯 I/O 读 Image,主线程回调创建 ImageTexture
## 取消机制:用 _loading_path 一致性校验替代版本号,避免实例级版本号与 CoverLoader 全局版本号不同步
extends ListItemBase
class_name CoverListItemBase

## 默认封面路径(兜底用，res:// 中的默认封面资源)
const DEFAULT_COVER_PATH := FileSystemManager.DEFAULT_COVER_PATH

## 封面纹理节点(子类在 _ready 中赋值,因节点路径各不相同)
var cover_texture: TextureRect = null

## 上次计算的封面偏移(避免重复赋值)
var _last_cover_offset: float = 0.0

## 是否启用视差(子类可禁用,如 StoreMidiListItem)
var _parallax_enabled: bool = true

## 封面是否已加载(控制 cover_texture.texture 是否有效)
var _cover_loaded: bool = false

## 当前正在异步加载的封面路径(空表示无在途任务)
## 用于回调校验:若回调的 path 与此不一致,说明期间已 release 或切到其他封面,丢弃结果
var _loading_path: String = ""

## 子类重写:返回封面文件路径(主线程调用,用于后台线程读盘)
## 默认返回空,子类必须实现
func _resolve_cover_path() -> String:
	return ""

## 子类重写:返回封面 Texture2D(旧同步接口,保留兼容,新流程不再调用)
## 默认返回 null
func _get_cover_texture() -> Texture2D:
	return null

## 启动封面加载(异步)
## 1. 主线程查 WeakRef 缓存(命中零开销同步应用)
## 2. 未命中 → 路径查询(主线程) → 入 CoverLoader 队列 → 后台线程读 Image → 主线程回调创建 Texture
## 已加载(_cover_loaded=true)时直接 return,避免重复加载
## 路径暂不可用时 return,由列表 trigger_cover_chain 统一重试
func start_cover_load() -> void:
	if _cover_loaded:
		return  # 已加载:不重复加载
	if cover_texture == null:
		return  # 无 cover 节点

	# 主线程预算路径(子类虚函数,访问 DataMGR/FileSystemManager 等单例)
	var path := _resolve_cover_path()
	if path.is_empty():
		# 路径暂不可用(数据未就绪等):return,由列表 trigger_cover_chain 统一重试
		return

	# 主线程查 WeakRef 缓存(命中零开销)
	var fs_mgr := FileSystemManager.instance
	if fs_mgr:
		var cached_tex := fs_mgr.get_cached_cover_texture(path)
		if cached_tex:
			_loading_path = ""  # 无在途异步任务
			_apply_cover_texture(cached_tex)
			return

	# res:// 路径在主线程同步加载(PCK 缓存命中零开销,且 load() 子线程不安全)
	if path.begins_with("res://"):
		_loading_path = ""
		var tex := load(path)
		if tex is Texture2D:
			if fs_mgr:
				fs_mgr._cache_cover_texture(path, tex)
			_apply_cover_texture(tex)
		else:
			# res:// 加载失败(资源缺失/导入错误):回退默认封面,避免永久空白
			_fallback_to_default_cover(path)
		return

	# user:// 未命中 → 异步加载
	# 去重:同 path 已有在途任务,不重复入队(避免版本号递增导致旧任务失效)
	if path == _loading_path:
		return  # 同 path 在途任务,等其完成即可
	_loading_path = path
	CoverLoader.request_load(item_id, path, _on_cover_loaded_async)

## 异步加载回调(主线程,CoverLoader._process 中调用)
## 回调接收的是 CoverLoader 按路径共享的纹理（同一封面全局一份），此处直接应用，不再各自创建
func _on_cover_loaded_async(path: String, texture: Texture2D, _version: int) -> void:
	if not is_instance_valid(self):
		return  # 节点已销毁
	if _cover_loaded:
		_loading_path = ""
		return  # 已通过其他途径加载(如缓存)
	# path 一致性校验:期间若 release_cover 或切换封面,_loading_path 会变
	if path != _loading_path:
		return  # 旧任务结果,丢弃
	_loading_path = ""  # 消费在途标记

	if texture == null:
		# 读盘失败(文件损坏等):回退到默认封面,与 load_cover_with_cache 行为一致
		# 避免封面保持空白;默认封面是 res:// 路径,主线程同步加载
		_fallback_to_default_cover(path)
		return

	_apply_cover_texture(texture)

## 回退到默认封面(主线程同步加载)
## 当异步读盘失败(文件损坏)或 user:// 文件不存在时调用,与旧同步路径的回退行为一致
## path 参数用于避免无限递归:若 path 已是默认封面路径则不再重试
func _fallback_to_default_cover(failed_path: String) -> void:
	if failed_path == DEFAULT_COVER_PATH:
		# 默认封面也加载失败(极端情况):标记 _cover_loaded=true 避免 trigger_cover_chain 反复重试
		_cover_loaded = true
		return
	var fs_mgr := FileSystemManager.instance
	if fs_mgr:
		# 先查缓存(可能其他项已加载过默认封面)
		var cached := fs_mgr.get_cached_cover_texture(DEFAULT_COVER_PATH)
		if cached:
			_apply_cover_texture(cached)
			return
	var tex := load(DEFAULT_COVER_PATH)
	if tex is Texture2D:
		if fs_mgr:
			fs_mgr._cache_cover_texture(DEFAULT_COVER_PATH, tex)
		_apply_cover_texture(tex)
	else:
		# 默认封面 load 失败(资源缺失/导入错误):标记 _cover_loaded=true 避免反复重试浪费 CPU/IO
		_cover_loaded = true

## 应用封面 Texture:设置 texture、调子类钩子、计算视差偏移
## 缓存命中(同步)和异步回调(延迟)共用此路径
func _apply_cover_texture(tex: Texture2D) -> void:
	if tex == null or cover_texture == null:
		return
	cover_texture.texture = tex
	# 封面节点可能默认隐藏（如 StoreView 的 cover visible=false），应用纹理时显式显示
	cover_texture.visible = true
	_cover_loaded = true
	# 子类钩子:封面 texture 设置完成后做额外处理(如静态偏移)
	_on_cover_texture_set()
	# 视差项立即计算一次初始偏移:非滚动状态下 _process 不会触发重算,
	# 若不主动设置初始 offset,相邻项封面会停在 offset 0 显示同一区域
	if _parallax_enabled:
		_apply_parallax_offset()
		_last_cover_offset = NAN  # 强制下帧再算一次(避免布局未稳定时初始值偏差)

## 子类重写:封面 texture 设置完成后调用,可做额外处理(如 SongListItem 的 item_index 静态错位)
func _on_cover_texture_set() -> void:
	pass

## 计算并应用当前视差偏移(仅当 parent_node 已就绪时)
## 在 start_cover_load / _process 中复用,确保非滚动状态下封面也有正确的初始偏移
func _apply_parallax_offset() -> void:
	var parent_ctrl := parent_node as Control
	if not parent_ctrl or parent_ctrl.size.y <= 0.0:
		return
	var new_offset: float = -(global_position.y / parent_ctrl.size.y) * max(cover_texture.size.y - size.y, 0.0)
	if not is_equal_approx(new_offset, _last_cover_offset):
		cover_texture.offset_transform_position.y = new_offset
		_last_cover_offset = new_offset

## 释放封面(状态切换/清空列表时调用)
## 将 cover_texture.texture 置空,允许下次 start_cover_load 重新加载
## 同时清空 _loading_path 使在途异步任务回调自然失效(path 校验不匹配)
func release_cover() -> void:
	_loading_path = ""  # 使在途任务回调失效
	if cover_texture:
		cover_texture.texture = null
	_cover_loaded = false

## 后台内存回收后复位封面状态(见 Core/MemoryGC.gd)
## 与 release_cover 的区别：本方法用于"外部把全局封面缓存清空了"的场景，
## 所以要在同一个同步调用里把节点的 texture 一起放掉——否则节点仍强引用着 Texture，
## 缓存清了内存也降不下来。
func reset_cover_state() -> void:
	release_cover()

## 切换封面数据(复用项刷新时调用)
## 与 release_cover 区别:不清空 texture,保留旧封面显示直到新封面加载完成
## 避免异步加载期间显示空白;新封面加载完成后 _apply_cover_texture 会自动覆盖
## WeakRef 缓存的 GC 会被延迟到新 texture 覆盖后(旧 texture 引用计数归零),属可接受开销
func switch_cover_data() -> void:
	_loading_path = ""  # 使在途任务回调失效
	_cover_loaded = false  # 允许 start_cover_load 重新加载
