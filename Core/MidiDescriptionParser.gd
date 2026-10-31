## MIDI 简介解析模块
## 职责一：从谱面简介文本中提取推荐启用音轨、音频偏移等配置（作为默认音轨配置）
## 职责二：把简介渲染成 RichTextLabel 可用的 BBCode，仅对 http/https 链接生成可点击的 [url]
## 支持全角/半角标点，支持多种写法格式；渲染前统一转义简介自带的 BBCode，避免注入
class_name MidiDescriptionParser
extends RefCounted

## 链接最大长度：过长的“链接”多为非预期文本，宁可不渲染也不把整段塞进 meta
const MAX_URL_LENGTH := 2048
## 链接中允许出现的字符（不含引号、尖括号、方括号、反斜杠、反引号等可破坏 BBCode 的字符）
const URL_PATTERN := "https?://[A-Za-z0-9\\-._~:/?#@!$&()*+,;=%]+"


## 解析描述文本，返回配置字典
## 返回格式:
##   {
##     "recommended_tracks": Array[int],  # 推荐启用的轨道索引（已选取第一个难度或直接推荐）
##     "audio_offset_ms": int,            # 音频偏移（毫秒），-1 表示简介中未提及
##     "difficulties": Array              # 所有识别到的难度配置（预留），元素: {"name": String, "tracks": Array[int]}
##   }
static func parse(description: String) -> Dictionary:
	var result: Dictionary = {
		"recommended_tracks": [],
		"audio_offset_ms": -1,
		"difficulties": [],
	}

	if description == null or description.is_empty():
		return result

	# 解析音频偏移
	result["audio_offset_ms"] = _parse_audio_offset(description)

	# 解析音轨推荐：优先直接推荐，其次难度推荐
	var direct_tracks := _parse_direct_recommendation(description)
	if not direct_tracks.is_empty():
		result["recommended_tracks"] = direct_tracks
	else:
		var difficulties := _parse_difficulty_recommendations(description)
		result["difficulties"] = difficulties
		if not difficulties.is_empty():
			# 多个难度时只选用第一个，其余预留
			result["recommended_tracks"] = difficulties[0]["tracks"]

	return result


## ============ 简介富文本渲染 ============

## 把简介转换为 RichTextLabel BBCode：
## - 简介原文里的 [ / ] 全部转义，简介自带的 BBCode（[url]、[img]、[color] 等）不会生效
## - 仅把 http/https 链接包成 [url=...]...[/url]，供 meta_clicked 接收点击
static func to_bbcode(description: String) -> String:
	if description.is_empty():
		return ""

	var text := description.replace("\r\n", "\n").replace("\r", "\n")
	var regex := RegEx.new()
	regex.compile(URL_PATTERN)
	var parts := PackedStringArray()
	var cursor := 0
	for match in regex.search_all(text):
		var start := match.get_start()
		if start < cursor:
			continue
		var raw := match.get_string()
		var url := sanitize_url(raw)
		if url.is_empty():
			# 非法链接按普通文本处理，交给后续片段统一转义
			continue
		parts.append(_escape_bbcode(text.substr(cursor, start - cursor)))
		# 只使用清洗后的 URL 作为 meta，展示文本同样不拼接任意 BBCode
		parts.append("[url=%s]%s[/url]" % [url, _escape_bbcode(url)])
		cursor = start + url.length()
	parts.append(_escape_bbcode(text.substr(cursor)))
	return "".join(parts)


## 清洗并校验链接：只接受 http/https，拒绝可破坏 BBCode/协议处理的字符
## 返回空串表示不可作为链接使用
static func sanitize_url(raw: String) -> String:
	var url := raw.strip_edges()
	url = _trim_trailing_punctuation(url)
	if url.is_empty() or url.length() > MAX_URL_LENGTH:
		return ""

	var lower := url.to_lower()
	if not (lower.begins_with("http://") or lower.begins_with("https://")):
		return ""

	# 协议后必须有主机名（排除 "https://" / "https:///path" 这类残缺链接）
	var host_start := url.find("://") + 3
	if host_start <= 0 or host_start >= url.length():
		return ""
	var rest := url.substr(host_start)
	var host := rest
	for sep in ["/", "?", "#"]:
		var idx := host.find(sep)
		if idx >= 0:
			host = host.substr(0, idx)
	if host.is_empty() or host.begins_with(".") or host.ends_with("."):
		return ""

	# 控制字符与 BBCode/HTML 属性分隔符一律拒绝；仅允许可见 ASCII（空格已在正则/校验阶段排除）
	for i in url.length():
		var code := url.unicode_at(i)
		if code <= 32 or code == 127:
			return ""
	for ch in ["\"", "'", "<", ">", "[", "]", "\\", "`"]:
		if url.contains(ch):
			return ""
	return url


## 打开简介中的链接（仅允许 http/https），返回是否成功交给系统浏览器
static func open_url(raw: String) -> bool:
	var url := sanitize_url(raw)
	if url.is_empty():
		push_warning("[MidiDescription] 拒绝打开非法链接：%s" % raw)
		return false
	var err := OS.shell_open(url)
	if err != OK:
		push_warning("[MidiDescription] 打开链接失败(%d)：%s" % [err, url])
		return false
	return true


## 转义 BBCode 的方括号，避免简介原文被当作标签解析
## 单次扫描逐个替换，避免先替换 '[' 后其生成的 "[lb]" 又被后续替换破坏
static func _escape_bbcode(text: String) -> String:
	var parts := PackedStringArray()
	for i in text.length():
		var ch := text.substr(i, 1)
		if ch == "[":
			parts.append("[lb]")
		elif ch == "]":
			parts.append("[rb]")
		else:
			parts.append(ch)
	return "".join(parts)


## 去掉链接末尾常见的句读/包裹符号；括号仅在左右不配对时去掉，保留合法 URL 中的括号
static func _trim_trailing_punctuation(url: String) -> String:
	var result := url
	while not result.is_empty():
		var last := result.substr(result.length() - 1, 1)
		if ".,;:!?".contains(last):
			result = result.substr(0, result.length() - 1)
		elif last == ")" and result.count("(") < result.count(")"):
			result = result.substr(0, result.length() - 1)
		else:
			break
	return result


## 解析音频偏移（毫秒），未找到返回 -1
## 支持写法:
##   音频偏移：0        → 0ms
##   音频偏移：0.05     → 50ms
##   参考音频偏移：0秒   → 0ms
##   参考音频偏移：0.05秒（因设备而异） → 50ms
## 简介中的数值按秒处理，转换为毫秒
static func _parse_audio_offset(description: String) -> int:
	var regex := RegEx.new()
	# 匹配 "音频偏移" 或 "参考音频偏移"，后接全角/半角冒号，再接数字（可带小数和负号），可选"秒"
	regex.compile("(?:参考)?音频偏移[：:]\\s*(-?[0-9]+(?:\\.[0-9]+)?)\\s*秒?")
	var match := regex.search(description)
	if match == null:
		return -1
	var value_str := match.get_string(1)
	var value_float := float(value_str)
	# 简介中的偏移值按秒处理，转换为毫秒（四舍五入）
	return int(round(value_float * 1000.0))


## 解析直接推荐（"推荐启用音轨：..."），返回轨道索引数组
## 支持写法:
##   推荐启用音轨：6, 9, 10, 11, 12, 13, 14, 15, 16
##   推荐启用音轨：3，4，5
##   推荐启用音轨：0
static func _parse_direct_recommendation(description: String) -> Array[int]:
	var regex := RegEx.new()
	# 匹配 "推荐启用音轨" 后接全角/半角冒号，捕获本行剩余内容（. 默认不匹配换行）
	regex.compile("推荐启用音轨[：:]\\s*(.+)")
	var match := regex.search(description)
	if match == null:
		return []
	var content := match.get_string(1)
	# 截取到首个换行（防止捕获到后续行的内容）
	var newline_idx := content.find("\n")
	if newline_idx >= 0:
		content = content.substr(0, newline_idx)
	return _extract_track_numbers(content)


## 解析基于难度的推荐（"XX版：...Track..."），返回难度数组
## 支持写法:
##   普通版：开启Track1.
##   困难版：开启Track1,2.
##   标准版：开启Track2，Track10，Track11，Track12。
##   简易版：选用Lunatic 开启Track8，Track10，Track12。
##   简单版：Track3,6,12,16,19,22,27,33,34          (无"开启"关键字，仅 Track 列表)
##   普通版：Track3,6,7,9,12,16,19,20,22,27,33
## 按文本出现顺序返回所有难度，调用方只取第一个
## "开启"为可选关键字：当存在时从其后提取数字，否则从冒号后整段提取
static func _parse_difficulty_recommendations(description: String) -> Array:
	var difficulties: Array = []
	var regex := RegEx.new()
	# 逐行匹配 "XXX版：" 开头，后接任意内容
	regex.compile("^(.+?版)[：:]\\s*(.*)$")

	for line in description.split("\n"):
		var line_stripped := line.strip_edges()
		if line_stripped.is_empty():
			continue
		var match := regex.search(line_stripped)
		if match == null:
			continue
		var name := match.get_string(1).strip_edges()
		var rest := match.get_string(2)
		# "开启" 为可选关键字：存在时仅取其后内容，避免误把前缀词数字当轨道号
		# 不存在时直接从 rest 起始提取（支持 "简单版：Track3,6,12" 这类省略写法）
		var track_content := rest
		var kai_idx := rest.find("开启")
		if kai_idx >= 0:
			track_content = rest.substr(kai_idx + 2)
		var tracks := _extract_track_numbers(track_content)
		if not tracks.is_empty():
			difficulties.append({"name": name, "tracks": tracks})

	return difficulties


## 从文本中提取所有轨道编号（连续数字串）
## 容忍任意分隔符（全角/半角逗号、空格、"Track"前缀、句点等）
## 只匹配"音轨段"中的独立整数：排除小数片段（如音频偏移 0.05 / -0.05），避免同一行其他数字误判为音轨
static func _extract_track_numbers(content: String) -> Array[int]:
	var tracks: Array[int] = []
	var regex := RegEx.new()
	# 两种合法形态：
	# 1) 独立 token：前面是行首/分隔符（全角半角逗号、顿号、分号、空白、冒号、连字符），且后面不是数字或小数片段（0.05 之类）
	# 2) Track/T 前缀（可带空格），如 Track1、T 10
	# 注意：允许 "-" 作前置分隔符以支持 "Track1-16" 这类范围写法（负数偏移如 -0.05 仍会被小数规则排除）
	regex.compile("(?:^|[，,、;；\\s:：\\-])(\\d+)(?!\\d|\\.\\d)|(?:Track|T)\\s*(\\d+)")
	for match in regex.search_all(content):
		var num_str := match.get_string(1) if not match.get_string(1).is_empty() else match.get_string(2)
		var num := int(num_str)
		if num not in tracks:
			tracks.append(num)
	return tracks
