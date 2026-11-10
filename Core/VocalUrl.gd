class_name VocalUrl
extends RefCounted

## 谱面人声 URL 的唯一构造入口（2026-11-10 内容寻址 + 真实扩展名）。
##
## 服务端下发 `vocalUrl` 形如 `/media/vocals/{32 位 hash}-{毫秒时间戳}.{ogg|wav|mp3|flac}`：
## ① 路径带真实扩展名 —— Cloudflare 默认按扩展名白名单缓存。旧的无扩展名
##    `/media/charts/{hash}.vocal` 不在白名单，实测（2026-11-09）恒 `cf-cache-status: DYNAMIC`，
##    每次 3MB 人声都跨太平洋回源；这是七天 Percent Cached 只有 13.61% 的主因。
## ② 版本段＝人声落盘文件名里的毫秒戳 —— 换人声即换文件名、即换 URL，所以能放心
##    immutable 长缓存，也不再需要 `?v=` 版本查询串（老客户端手工拼裸路径会把它丢掉）。
##
## 兼容：老服务端 / 尚未升级的响应没有 `vocalUrl`，回退旧端点
## `/media/charts/{hash}.vocal`（不缓存、永远回源，内容永远最新，照样能播，只是慢）。
## 所有拼人声地址的地方都必须走这里——漏一处就会在某个页面悄悄退回旧 URL，
## 而这类漏不会有任何报错。

## 从服务端下发的**相对** URL 拼出绝对 URL；空串返回空串。
static func from_vocal_url(server_url: String, vocal_url: String) -> String:
	if server_url.is_empty() or vocal_url.is_empty():
		return ""
	var base := server_url.rstrip("/")
	if vocal_url.begins_with("/"):
		return base + vocal_url
	return base + "/" + vocal_url

## 构造裸旧端点 URL，仅作兼容回退（老服务端 / 老数据）。
static func build_legacy(server_url: String, chart_hash: String) -> String:
	if server_url.is_empty() or chart_hash.is_empty():
		return ""
	return "%s/media/charts/%s.vocal" % [server_url, chart_hash.uri_encode()]

## 从任意 DTO（ChartResponse / 商店列表项 hint / 本地 info.json）取人声地址。
## 优先 `vocalUrl`（内容寻址 + 扩展名），缺失时回退旧端点。
static func from_chart(server_url: String, chart_hash: String, data: Dictionary) -> String:
	var raw_url = data.get("vocalUrl", "")
	if raw_url != null and not str(raw_url).is_empty():
		return from_vocal_url(server_url, str(raw_url))
	return build_legacy(server_url, chart_hash)
