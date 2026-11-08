class_name CoverUrl
extends RefCounted

## 谱面封面 URL 的唯一构造入口（2026-11-08，配合服务端封面去重改造）。
##
## 背景：旧端点 `GET /api/charts/{hash}/cover` 里的 hash 是 **MIDI** 内容哈希，
## 与封面图片无关；封面端点又允许 30 天缓存，于是必须用 `?v={coverVersion}` 兜底。
## 更要命的是客户端 WebCache 以 `md5(完整 URL)` 落盘、且无淘汰——同一张专辑封面
## 被几十个谱面共用，却因每个谱面的 hash 与版本串都不同而被存成几十份。
##
## 根治（服务端 2026-11-08）：封面改为内容寻址 `GET /media/covers/{封面内容哈希}.{ext}`，
## 响应 DTO 透出相对路径 `coverUrl` 与 `coverHash`。同图必然同 URL，
## 浏览器 / Cloudflare / 客户端磁盘缓存三层自动只存一份；换封面 hash 必变，
## 连 `?v=` 都不再需要。
##
## 兼容：老服务端或尚未回填的谱面没有 `coverUrl`，这里退回旧端点 + `coverVersion`。
## 所有拼封面地址的地方都必须走这里——漏一处就会在某个页面悄悄退回旧图，
## 而这类漏不会有任何报错。

## 从服务端下发的**相对**内容寻址 URL 拼出绝对 URL；空串返回空串。
## `coverUrl` 形如 `/media/covers/{32 位 hex}.jpg`，路径里的 hex 会让
## HttpImageLoader._is_content_addressed() 判定为不可变、命中本地缓存时零请求。
static func from_cover_url(server_url: String, cover_url: String) -> String:
	if server_url.is_empty() or cover_url.is_empty():
		return ""
	var base := server_url.rstrip("/")
	if cover_url.begins_with("/"):
		return base + cover_url
	return base + "/" + cover_url

## 构造旧端点 URL（无版本串即退化成最初的裸 URL），仅作兼容回退。
static func build(server_url: String, hash: String, version: String = "") -> String:
	if server_url.is_empty() or hash.is_empty():
		return ""
	var url := "%s/api/charts/%s/cover" % [server_url, hash.uri_encode()]
	if version.is_empty():
		return url
	return "%s?v=%s" % [url, version.uri_encode()]

## 从任意 DTO（ChartResponse / UserScoreRecordResponse / 列表项 hint）取封面地址。
## 优先 `coverUrl`（内容寻址），缺失时按 `coverVersion` 走旧端点。
static func from_chart(server_url: String, hash: String, data: Dictionary) -> String:
	if data.is_empty():
		return build(server_url, hash)
	var raw_url = data.get("coverUrl", "")
	if raw_url != null and not str(raw_url).is_empty():
		return from_cover_url(server_url, str(raw_url))
	var raw_version = data.get("coverVersion", "")
	return build(server_url, hash, "" if raw_version == null else str(raw_version))
