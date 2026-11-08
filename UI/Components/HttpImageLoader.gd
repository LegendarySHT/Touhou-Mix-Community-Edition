## 远程图片加载器（内存缓存 + 本地磁盘缓存 + 在途去重 + 连接复用）
## 供列表项（头像/远程封面）复用：同一 URL 只发一次请求，
## 结果缓存并广播给所有等待方，避免每项新建 HTTPRequest 造成的重复下载（TMX-038）。
##
## 本地磁盘缓存：图片字节按「URL 的 md5」命名存于 PathHelper.get_web_cache_dir()。
## 服务端给图片的 URL 一律带内容哈希（{hash}.jpg / {hash}_{userId}.jpg / /api/charts/{hash}/cover），
## 内容变了 URL 必然变，所以本地有缓存就直接用，不发条件请求、也不存 ETag；
## 请求失败时回退本地缓存，本地文件损坏则丢弃缓存，下次重新下载。
class_name HttpImageLoader
extends RefCounted

const MAX_CACHE_SIZE := 128

## 内容哈希前缀长度：与服务端 AvatarImageProcessor.ContentHashLength 约定一致，
## 改动须两端同步，否则内容寻址判定失效、退回条件请求。
const CONTENT_HASH_LENGTH := 32

## 缓存文件可用的图片扩展名（无法从 URL 判断时回退 .img，读取按文件内容解码）
const IMAGE_EXTENSIONS: Array[String] = ["png", "jpg", "jpeg", "webp"]

## 同时在途的图片请求上限。一页卡片会一口气要二十多张封面，而每条连接都要单独握手，
## TLS 握手又在主线程轮询里做——全发出去会把帧时间和同域名的连接槽位占满，
## 期间页面数据请求（/api/charts）也得跟着排队
const MAX_CONCURRENT_REQUESTS := 6

## 单张图片的请求超时（秒）：占着并发槽位的请求必须有终点，否则一条挂死的连接会永久堵住队列
const REQUEST_TIMEOUT := 20.0

## 连接槽：一条 HTTPRequest 长期复用。Godot 的 HTTPRequest 在 keep-alive 下允许
## 对同一节点反复 request()，连接（含 TLS 会话）不会重开——一页 24 张封面只需
## 建立 6 条连接，翻下一页时这 6 条还是热的，握手次数为 0
class Slot:
	var http: HTTPRequest
	var host: String = ""
	var busy: bool = false
	## 刚刚完成请求的槽要等到下一帧才能再用（此时 requesting 还停在 RS_DONE，立刻 request() 会返回 ERR_BUSY）
	var ready_frame: int = 0

static var _texture_cache: Dictionary = {}   # url -> Texture2D
static var _inflight: Dictionary = {}        # url -> Array[Dictionary{target, callback}]
static var _holder: Node = null              # HTTPRequest 挂载节点（场景根，与列表项生命周期解耦）
static var _active_requests: int = 0         # 已在途的请求数
static var _waiting_requests: Array = []     # 超上限时排队：[{url}]
static var _slots: Array = []                # 复用的连接槽（Slot）
static var _pump_scheduled: bool = false     # 已排了一次「下一帧放行」，避免重复建计时器

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
	# 内容寻址的 URL（路径里带内容哈希）：内容不会原地变，本地有缓存直接读，零请求
	if has_cache_file(url) and _is_content_addressed(url):
		_load_from_cache_file(url, true)
		return
	if not _start_request(url):
		_queue_request(url)

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

## 发起一次图片请求。返回 false 表示当前拿不到连接槽（并发已满 / 槽刚完成要等一帧），
## 调用方负责把 URL 留在/放进队列，不要在函数内部自行入队（否则会和放行循环互相喂）
static func _start_request(url: String) -> bool:
	var holder := _get_holder()
	if holder == null:
		_inflight.erase(url)
		return true  # 没有可挂载的根节点：当作处理过了，别让 URL 永远排在队里
	if _active_requests >= MAX_CONCURRENT_REQUESTS:
		return false
	var slot := _acquire_slot(holder, url)
	if slot == null:
		return false
	_active_requests += 1
	slot.busy = true
	var err := slot.http.request(url)
	if err != OK:
		slot.busy = false
		# 这里不能同步调 _finish_request：它会立刻放行下一条，失败连锁时会一路递归下去。
		# 直接还回槽位，交给下一帧的放行计时器继续
		_active_requests = maxi(0, _active_requests - 1)
		_schedule_pump()
		# 请求发不出（离线/URL 非法）：本地有缓存就用缓存
		if has_cache_file(url):
			_load_from_cache_file(url)
		else:
			_finish_pending(url, null)
		return true
	slot.http.request_completed.connect(_on_completed.bind(url, slot), CONNECT_ONE_SHOT)
	return true


## 取一个可用连接槽：优先同 host 的空闲槽（连接与 TLS 会话直接复用），
## 没有就新开一条（上限 MAX_CONCURRENT_REQUESTS）；到达上限后复用空闲槽并换 host 重连
static func _acquire_slot(holder: Node, url: String) -> Slot:
	var host := _host_of(url)
	var now := Engine.get_process_frames()
	# 清掉场景树重建后失效的槽
	for i in range(_slots.size() - 1, -1, -1):
		var s: Slot = _slots[i]
		if s.http == null or not is_instance_valid(s.http):
			_slots.remove_at(i)
	var idle: Slot = null
	for s in _slots:
		if s.busy or s.ready_frame > now:
			continue
		if s.host == host:
			return s
		if idle == null:
			idle = s
	if idle != null:
		_rebind_slot(holder, idle, host)
		return idle
	if _slots.size() >= MAX_CONCURRENT_REQUESTS:
		return null
	var slot := Slot.new()
	slot.http = _make_request_node(holder)
	slot.host = host
	_slots.append(slot)
	return slot


## 换 host：旧连接用不上了，换一条新的（host 变化只发生在服务器地址变更时）
static func _rebind_slot(holder: Node, slot: Slot, host: String) -> void:
	if slot.http != null and is_instance_valid(slot.http):
		slot.http.queue_free()
	slot.http = _make_request_node(holder)
	slot.host = host


static func _make_request_node(holder: Node) -> HTTPRequest:
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT
	http.accept_gzip = true
	holder.add_child(http)
	return http


## 取 URL 的 host（连接复用的键）
static func _host_of(url: String) -> String:
	var idx := url.find("://")
	if idx < 0:
		return url.get_slice("/", 0)
	return url.substr(idx + 3).get_slice("/", 0)


## 释放一个并发槽位并放行排队项
static func _finish_request() -> void:
	_active_requests = maxi(0, _active_requests - 1)
	_pump_waiting()
	if not _waiting_requests.is_empty():
		_schedule_pump()


## 按先进先出放行排队项（同一页内的卡片保持从上到下的顺序）。
## ⚠ 每次循环要么出队要么直接 return：拿不到连接槽时**必须**把条目留在队首退出，
## 否则「刚完成的槽要等下一帧」这种情况下会原地反复入队、死循环卡死整个程序
static func _pump_waiting() -> void:
	while _active_requests < MAX_CONCURRENT_REQUESTS and not _waiting_requests.is_empty():
		var next: Dictionary = _waiting_requests.pop_front()
		var next_url := str(next.get("url", ""))
		if next_url.is_empty() or not _inflight.has(next_url):
			continue  # 等待者已全部撤走，别为它占槽
		if not _start_request(next_url):
			# 暂时拿不到连接槽：放回队首等下一次机会。
			# 先出队再发起，是为了失败路径里 _finish_request 递归回来时不会再取到同一条
			_waiting_requests.push_front(next)
			return


## 排一次「下一帧再放行」：槽刚完成请求时当帧不可用，队列不能就此停住
static func _schedule_pump() -> void:
	if _pump_scheduled:
		return
	var holder := _get_holder()
	if holder == null:
		return
	var tree := holder.get_tree()
	if tree == null:
		return
	_pump_scheduled = true
	tree.create_timer(0.0).timeout.connect(_on_pump_timer, CONNECT_ONE_SHOT)


static func _on_pump_timer() -> void:
	_pump_scheduled = false
	_pump_waiting()


## 入队 + 兜底排一次放行（正常由请求完成时兑现，这里防「所有槽都在冷却」把队列晾住）
static func _queue_request(url: String) -> void:
	_waiting_requests.append({"url": url})
	_schedule_pump()


## 撤掉某个目标对某 URL 的等待（卡片换绑封面的必经路径）。
## 没人等了且请求还在排队时直接从队列摘掉——否则翻页后新一页的封面要排在
## 上一页没下完的二十多张后面；已在途的请求照常跑完（字节顺手进缓存）
static func cancel(url: String, target: Object) -> void:
	if url.is_empty():
		return
	var pending: Array = _inflight.get(url, [])
	if pending.is_empty():
		return
	var kept: Array = []
	for e in pending:
		if e.get("target") != target:
			kept.append(e)
	if not kept.is_empty():
		_inflight[url] = kept
		return
	_inflight.erase(url)
	for i in range(_waiting_requests.size() - 1, -1, -1):
		if str(_waiting_requests[i].get("url", "")) == url:
			_waiting_requests.remove_at(i)

static func _on_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, url: String, slot: Slot) -> void:
	# 槽不释放，留给下一张图复用（连接还在，省掉一次 TCP+TLS 握手）
	slot.busy = false
	slot.ready_frame = Engine.get_process_frames() + 1
	_finish_request()
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200 and body.size() > 0:
		if _write_data(url, body):
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
			if not _start_request(url):
				_queue_request(url)
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

## 判定 URL 是否「内容永远不会原地变」：路径里出现 32 位十六进制段即视为不可变。
## 覆盖现有的全部命名：{hash}.jpg（媒体文件）、{hash}_{userId}.jpg（头像），
## 以及 /api/charts/{chartHash}/cover、/media/charts/{hash}.mid 这类把 hash 放在路径段里的接口。
## 这类 URL 换内容必然换 URL，本地缓存可以无条件信任，既不发条件请求也不需要 ETag
static func _is_content_addressed(url: String) -> bool:
	# 去掉协议和 query，逐段看路径；host 段不参与判定
	var path := url.get_slice("://", 1)
	if path.is_empty():
		path = url
	for seg in path.split("/", false):
		if _starts_with_content_hash(seg):
			return true
	return false

## 该段是否以 32 位十六进制内容哈希开头（{hash}.jpg / {hash}_{id}.jpg / {hash}）
static func _starts_with_content_hash(seg: String) -> bool:
	if seg.length() < CONTENT_HASH_LENGTH:
		return false
	for i in CONTENT_HASH_LENGTH:
		var c := seg.unicode_at(i)
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

## 本地是否存在该 URL 的图片缓存
static func has_cache_file(url: String) -> bool:
	return FileAccess.file_exists(_data_file(url))

## 返回该 URL 的本地缓存文件路径（未缓存 / 空文件返回空串）。
## 供「界面上已经显示过这张图，落盘时别再下一遍」的调用方直接复用字节
static func get_cache_file(url: String) -> String:
	if url.is_empty():
		return ""
	var path := _data_file(url)
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var size := f.get_length()
	f.close()
	return path if size > 0 else ""

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
	var path := _data_file(url)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

## 清空纹理缓存（登出/切换账号时调用，避免旧账号头像残留）
## 仅清内存；磁盘缓存按 URL 命名，登出后仍可复用
static func clear_cache() -> void:
	_texture_cache.clear()
