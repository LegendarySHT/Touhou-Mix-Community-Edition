class_name CoverUrl
extends RefCounted

## 谱面封面 URL 的唯一构造入口（2026-11-08 内容寻址去重，2026-11-09 移除版本串）。
##
## 服务端把 Chart.CoverPath 写成 `/covers/{封面字节 SHA-256 前 32 位}.{ext}`，
## 响应 DTO 透出相对路径 `coverUrl` 与 `coverHash`。同图必然同 URL、换图必换 URL，
## 浏览器 / Cloudflare / 客户端磁盘缓存三层自动只存一份，缓存失效天然完成。
##
## 兼容：老服务端或尚未回填的谱面没有 `coverUrl`，这里退回裸旧端点
## `/api/charts/{hash}/cover`（不带 `?v=`，只保证图能显示）。
## 所有拼封面地址的地方都必须走这里——漏一处就会在某个页面悄悄退回旧 URL，
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

## 构造裸旧端点 URL，仅作兼容回退。
static func build(server_url: String, hash: String) -> String:
	if server_url.is_empty() or hash.is_empty():
		return ""
	return "%s/api/charts/%s/cover" % [server_url, hash.uri_encode()]

## 从任意 DTO（ChartResponse / UserScoreRecordResponse / 列表项 hint）取封面地址。
## 优先 `coverUrl`（内容寻址），缺失时回退裸旧端点。
static func from_chart(server_url: String, hash: String, data: Dictionary) -> String:
	var raw_url = data.get("coverUrl", "")
	if raw_url != null and not str(raw_url).is_empty():
		return from_cover_url(server_url, str(raw_url))
	return build(server_url, hash)
