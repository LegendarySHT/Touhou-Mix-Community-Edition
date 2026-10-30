## 远程图片加载器（内存缓存 + 本地磁盘缓存 + 在途去重）
## 供列表项（头像/远程封面）复用：同一 URL 只发一次请求，
## 结果缓存并广播给所有等待方，避免每项新建 HTTPRequest 造成的重复下载（TMX-038）。
##
## 本地磁盘缓存：图片字节按「URL 的 md5」命名存于 PathHelper.get_web_cache_dir()，
## 同键另存服务端返回的 ETag；再次请求时带 If-None-Match 条件请求，
## 服务端标识未变（304）则直接读本地文件，避免重复下载；
## 请求失败时回退本地缓存，本地文件损坏则丢弃缓存，下次重新下载。
## URL 文件名为内容哈希（内容寻址）时本地有缓存即直接用，连条件请求都不发。
class_name HttpImageLoader
extends RefCounted

const MAX_CACHE_SIZE := 128

## 缓存文件可用的图片扩展名（无法从 URL 判断时回退 .img，读取按文件内容解码）
const IMAGE_EXTENSIONS: Array[String] = ["png", "jpg", "jpeg", "webp"]

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
## on_loaded: Callable(Texture2D) —— 加载失败/HTTP 非 200 且无本地缓存时传 null
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
	# 内容寻址的 URL（文件名即内容哈希）：内容不会原地变，本地有缓存直接读，零请求
	if has_cache_file(url) and _is_content_addressed(url):
		_load_from_cache_file(url, true)
		return
	_start_request(url)

## 只读本地缓存：内存命中直接回调，磁盘命中走后台解码，都没有回调 null。
## 全程不发网络请求 —— 供「先用缓存占位、稍后联网刷新」的启动路径使用（如启动时的头像），
## 否则要先等一次网络往返拿到 URL，屏幕上会先闪一遍默认头像。
static func load_cached(url: String, target: Node, on_loaded: Callable) -> void:
	if url.is_empty() or not on_loaded.is_valid():
		return
	var cached := get_cached(url)
	if cached:
		on_loaded.call(cached)
		return
	if not has_cache_file(url):
		on_loaded.call(null)
		return
	CoverLoader.request_load(url, _data_file(url), func(_path: String, tex: Texture2D, _version: int) -> void:
		if not is_instance_valid(target):
			return
		if tex:
			_remember(url, tex)
		else:
			_drop_cache(url)  # 缓存损坏：丢弃，后续联网请求会重新下载
		on_loaded.call(tex)
	)

static func _start_request(url: String) -> void:
	var holder := _get_holder()
	if holder == null:
		_inflight.erase(url)
		return
	var http := HTTPRequest.new()
	holder.add_child(http)
	# 带本地记录的 ETag 发条件请求：内容未变时服务端只回 304（无响应体）
	var headers := PackedStringArray()
	var etag := _read_etag(url)
	if not etag.is_empty():
		headers.append("If-None-Match: %s" % etag)
	var err := http.request(url, headers)
	if err != OK:
		http.queue_free()
		# 请求发不出（离线/URL 非法）：本地有缓存就用缓存
		if has_cache_file(url):
			_load_from_cache_file(url)
		else:
			_finish_pending(url, null)
		return
	http.request_completed.connect(_on_completed.bind(url, http))

static func _on_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, url: String, http: HTTPRequest) -> void:
	http.queue_free()
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200 and body.size() > 0:
		if _write_data(url, body):
			_write_etag(url, _header_etag(headers))
			_load_from_cache_file(url)
			return
		# 写盘失败（只读/空间不足）：直接用响应体解码，避免缓存不可用导致图片空白
		_finish_pending(url, _texture_from_body(body, url))
		return
	# 304（内容未变）或下载失败：本地有缓存就先读缓存，避免头像空白
	if has_cache_file(url):
		_load_from_cache_file(url)
		return
	_finish_pending(url, null)

## 从本地缓存文件解码：交给 CoverLoader 在后台线程读盘解码，主线程只收纹理结果
## fallback_request: 缓存解码失败时是否改走网络（内容寻址路径没有请求兜底，必须补发）
static func _load_from_cache_file(url: String, fallback_request: bool = false) -> void:
	CoverLoader.request_load(url, _data_file(url), func(_path: String, tex: Texture2D, _version: int) -> void:
		if tex:
			_remember(url, tex)
			_finish_pending(url, tex)
			return
		# 缓存文件损坏/格式不支持：丢弃后下次请求重新下载
		_drop_cache(url)
		if fallback_request:
			_start_request(url)
		else:
			_finish_pending(url, null)
	)

## 直接用响应体建纹理（写盘失败的兜底路径）
static func _texture_from_body(body: PackedByteArray, url: String) -> Texture2D:
	var tex := ImageUtil.create_display_texture(ImageUtil.decode_image_buffer(body))
	if tex:
		_remember(url, tex)
	return tex

static func _remember(url: String, tex: Texture2D) -> void:
	if _texture_cache.size() >= MAX_CACHE_SIZE:
		_texture_cache.clear()
	_texture_cache[url] = tex

static func _finish_pending(url: String, tex: Texture2D) -> void:
	var pending: Array = _inflight.get(url, [])
	_inflight.erase(url)
	for entry in pending:
		var callback: Callable = entry.get("callback")
		var target: Node = entry.get("target")
		if callback.is_valid() and is_instance_valid(target):
			callback.call(tex)

# ========== 本地磁盘缓存 ==========

## 缓存键：URL 的 md5（头像 URL 自带内容 hash，URL 变化即内容变化）
static func _cache_key(url: String) -> String:
	return url.md5_text()

## 判定 URL 是否为内容寻址（文件名为 32 位十六进制内容哈希）。
## 这类 URL 换图必然换 URL，本地缓存可无条件信任，连条件请求都不必发。
static func _is_content_addressed(url: String) -> bool:
	var base := url.get_file().split("?")[0].get_basename()
	if base.length() != 32:
		return false
	for i in base.length():
		var c := base.unicode_at(i)
		var is_hex := (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)
		if not is_hex:
			return false
	return true

## 缓存文件基路径（不含扩展名）
static func _cache_base(url: String) -> String:
	return PathHelper.get_web_cache_dir() + _cache_key(url)

## 图片字节缓存文件；扩展名沿用 URL 的，取不到时用 .img（读取按文件内容解码）
static func _data_file(url: String) -> String:
	var name := url.get_file().split("?")[0].to_lower()
	var ext := name.get_extension()
	if ext not in IMAGE_EXTENSIONS:
		ext = "img"
	return "%s.%s" % [_cache_base(url), ext]

## ETag 记录文件（与图片字节同键，用于条件请求校验）
static func _etag_file(url: String) -> String:
	return _cache_base(url) + ".etag"

## 本地是否存在该 URL 的图片缓存
static func has_cache_file(url: String) -> bool:
	return FileAccess.file_exists(_data_file(url))

## 读取已记录的 ETag（无缓存返回空串，此时下次请求为无条件下载）
static func _read_etag(url: String) -> String:
	var path := _etag_file(url)
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text.strip_edges()

## 记录 ETag（服务端未提供时写空串，下次请求重新下载）
static func _write_etag(url: String, etag: String) -> void:
	if not PathHelper.ensure_dir_exists(PathHelper.get_web_cache_dir()):
		return
	var f := FileAccess.open(_etag_file(url), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(etag)
	f.close()

## 写入图片字节缓存
static func _write_data(url: String, body: PackedByteArray) -> bool:
	if not PathHelper.ensure_dir_exists(PathHelper.get_web_cache_dir()):
		return false
	var f := FileAccess.open(_data_file(url), FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(body)
	f.close()
	return true

## 丢弃本地缓存（内容损坏/已失效时回退到重新下载）
static func _drop_cache(url: String) -> void:
	for path in [_data_file(url), _etag_file(url)]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)

## 从响应头取 ETag（大小写不敏感）
static func _header_etag(headers: PackedStringArray) -> String:
	for raw in headers:
		var h := str(raw)
		if h.to_lower().begins_with("etag:"):
			return h.substr(h.find(":") + 1).strip_edges()
	return ""

## 清空纹理缓存（登出/切换账号时调用，避免旧账号头像残留）
## 仅清内存；磁盘缓存按 URL 命名，登出后仍可复用
static func clear_cache() -> void:
	_texture_cache.clear()
