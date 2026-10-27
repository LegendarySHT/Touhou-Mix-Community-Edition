## 远程图片加载器（静态缓存 + 在途去重）
## 供列表项（头像/远程封面）复用：同一 URL 只发一次请求，
## 结果缓存并广播给所有等待方，避免每项新建 HTTPRequest 造成的重复下载（TMX-038）。
class_name HttpImageLoader
extends RefCounted

const MAX_CACHE_SIZE := 128

static var _texture_cache: Dictionary = {}   # url -> Texture2D
static var _inflight: Dictionary = {}        # url -> Array[Dictionary{target, callback}]
static var _holder: Node = null              # HTTPRequest 挂载节点（场景根，与列表项生命周期解耦）

static func _get_holder() -> Node:
	if _holder == null or not is_instance_valid(_holder):
		var tree := Engine.get_main_loop() as SceneTree
		if tree:
			_holder = tree.root
	return _holder

## 取缓存（无或已失效返回 null）
static func get_cached(url: String) -> Texture2D:
	var cached = _texture_cache.get(url)
	if cached is Texture2D and is_instance_valid(cached):
		return cached
	_texture_cache.erase(url)
	return null

## 加载远程图片：有缓存立即回调；在途则追加回调等待；否则发起一次请求。
## target: 用于挂载 HTTPRequest 的节点（通常传 self）
## on_loaded: Callable(Texture2D) —— 加载失败/HTTP 非 200 时传 null
static func load(url: String, target: Node, on_loaded: Callable) -> void:
	if url.is_empty() or not on_loaded.is_valid():
		return
	var cached := get_cached(url)
	if cached:
		on_loaded.call(cached)
		return
	var pending: Array = _inflight.get(url, [])
	pending.append({"target": target, "callback": on_loaded})
	_inflight[url] = pending
	if pending.size() > 1:
		return  # 已在途，等待首个请求完成
	_start_request(url)

static func _start_request(url: String) -> void:
	var holder := _get_holder()
	if holder == null:
		_inflight.erase(url)
		return
	var http := HTTPRequest.new()
	holder.add_child(http)
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		_finish_pending(url, null, null)
		return
	http.request_completed.connect(_on_completed.bind(url, http))

static func _on_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, url: String, http: HTTPRequest) -> void:
	var tex: Texture2D = null
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200 and body.size() > 0:
		var image := ImageUtil.decode_image_buffer(body)
		if image:
			tex = ImageUtil.create_display_texture(image)
			if tex:
				if _texture_cache.size() >= MAX_CACHE_SIZE:
					_texture_cache.clear()
				_texture_cache[url] = tex
	_finish_pending(url, tex, http)

static func _finish_pending(url: String, tex: Texture2D, http: HTTPRequest) -> void:
	var pending: Array = _inflight.get(url, [])
	_inflight.erase(url)
	for entry in pending:
		var callback: Callable = entry.get("callback")
		var target: Node = entry.get("target")
		if callback.is_valid() and is_instance_valid(target):
			callback.call(tex)
	if http:
		http.queue_free()

## 清空纹理缓存（登出/切换账号时调用，避免旧账号头像残留）
static func clear_cache() -> void:
	_texture_cache.clear()
