class_name CoverUrl
extends RefCounted

## 谱面封面 URL 的唯一构造入口（2026-11-08，配合服务端 `01bbf1f`）。
##
## 背景：服务端封面端点 `GET /api/charts/{hash}/cover` 返回
## `Cache-Control: public, max-age=2592000`（30 天），而路径里的 hash 是 **MIDI**
## 文件的内容哈希——作者换了封面，这个 URL 一个字都不变。于是 Cloudflare 边缘
## 继续把旧图发给客户端，客户端本地也没有可覆盖的缓存层，表现为「网页端换封面后，
## 游戏里永远是旧图」。
##
## 修复：服务端在 ChartResponse / 成绩记录里透出 `coverVersion`（替换封面时写入
## 文件名里的毫秒时间戳，首次上传回退 UpdatedAt）。这里拼成 `?v={coverVersion}`：
## 版本变 → 缓存键变 → 边缘必然回源，而 30 天长缓存的容量收益完全不损失。
##
## 所有拼封面地址的地方都必须走这里，别再手写格式化字符串——漏一处就会在某个
## 页面退回旧图，且这种漏不会有任何报错，只有用户发现「图没变」。

## 构造封面绝对 URL。`version` 为空串时退化为无版本串的旧格式
## （兼容尚未下发的旧列表项 / 老服务端，此时行为与修复前一致）。
static func build(server_url: String, hash: String, version: String = "") -> String:
	if server_url.is_empty() or hash.is_empty():
		return ""
	var url := "%s/api/charts/%s/cover" % [server_url, hash.uri_encode()]
	if version.is_empty():
		return url
	return "%s?v=%s" % [url, version.uri_encode()]

## 从任意 DTO（ChartResponse / UserScoreRecordResponse）取版本串并拼 URL。
## 缺字段或值为 null 时自动退化为无版本串，调用方不必判空。
static func from_chart(server_url: String, hash: String, data: Dictionary) -> String:
	if data.is_empty():
		return build(server_url, hash)
	var raw = data.get("coverVersion", "")
	return build(server_url, hash, "" if raw == null else str(raw))
