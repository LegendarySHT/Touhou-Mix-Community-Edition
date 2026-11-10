## Chart JSON 规范化静态工具
## 将旧格式的6个字段（song/album/author + sourceSongName/sourceAlbumName/sourceArtistName）
## 合并为3个统一字段，并精简 song/album 对象只保留必要键
##
## 幂等：第二次调用已规范化的 JSON 必定返回 false
class_name ChartNormalizer


## 判断嵌套对象是否有实际数据（非 null 的 _id 或 name）
static func _has_meaningful_data(dict, id_key: String = "_id") -> bool:
	if not dict is Dictionary:
		return false
	var id_val = dict.get(id_key, null)
	var name_val = dict.get("name", null)
	return (id_val is String and not (id_val as String).is_empty()) or (name_val is String and not (name_val as String).is_empty())


## 安全获取非空字符串，空/非 String 时返回 fallback
static func _safe_str(val, fallback: String) -> String:
	if val is String and not (val as String).is_empty():
		return val as String
	return fallback


## 从 Dictionary 中安全提取 String，key 存在但值为 null 时也返回 fallback
static func _get_str(dict: Dictionary, key: String, fallback: String) -> String:
	var val = dict.get(key, null)
	if val is String and not (val as String).is_empty():
		return val as String
	return fallback


## 从 author 字段提取名称字符串（兼容 String / Dictionary / Array 三种格式）
## 语义上是字符串的字段名集合（在任何层级出现时 null → ""，非 String 会保留原值不转）
## 注：GDScript 无 Set，用 Array 存，靠 has() 判断（对小集合足够）
const _STRING_FIELD_KEYS: Array[String] = [
	"_id", "id", "name", "desc", "description", "status",
	"artistName", "artist",
	"uploaderName", "uploaderId", "uploaderAvatarUrl",
	"artistUrl", "coverHash", "coverUrl", "cover", "vocalUrl",
	"uploadedDate", "approvedDate",
	"hash", "file_hash", "folder_hash", "folder_name",
	"sourceSongName", "sourceAlbumName", "sourceArtistName",
	"midi_id", "song_id", "album_id", "album_name",
	"audio_path", "json_path", "path", "cover_path",
	"author", "abbr", "date",
	"type", "format", "comment", "message", "version",
]


## 就地清理字典：
##   - 所有 float 若整数部分等于其值 → 转 int（例 1.0 → 1）
##   - 字段名在 _STRING_FIELD_KEYS 内且值为 null → 转 ""
## 返回是否有任何修改
static func cleanup_types_recursive(obj, _in_key: String = "", _depth: int = 0) -> bool:
	var t := typeof(obj)
	if t == TYPE_DICTIONARY:
		var d := obj as Dictionary
		var changed := false
		var ks := d.keys()
		for k in ks:
			var v = d[k]
			# 先对 leaf 值做直接替换（null→""、float→int）
			var res: Array = _coerce_value(k, v)
			var new_v = res[0]
			if res[1]:
				d[k] = new_v
				changed = true
				v = new_v
			# 再对容器递归
			if cleanup_types_recursive(v, String(k), _depth + 1):
				changed = true
		return changed
	if t == TYPE_ARRAY:
		var arr := obj as Array
		var changed := false
		for i in range(arr.size()):
			var v = arr[i]
			var res: Array = _coerce_value("", v)  # 数组项无 key → 不做 null→""，只转整数 float
			var new_v = res[0]
			if res[1]:
				arr[i] = new_v
				changed = true
				v = new_v
			if cleanup_types_recursive(v, "", _depth + 1):
				changed = true
		return changed
	return false


## 对单个值返回规范化后的值，以及是否变化。供 Dictionary 上层调用方替换用。
## 返回 Array: [新值（Variant）, 是否变化（bool）]
static func _coerce_value(k, v) -> Array:
	# 1. null→""（只对字符串字段）
	if v == null and _STRING_FIELD_KEYS.has(k):
		return ["", true]
	# 2. float → int（当整数）
	if typeof(v) == TYPE_FLOAT:
		var fv: float = float(v)
		if is_finite(fv) and fv == float(int(fv)):
			var iv: int = int(fv)
			return [iv, true]
	# 其他：不做（Dictionary/Array 由上层递归，String/Bool/Int 原样）
	return [v, false]


static func _extract_author_name(author_val) -> String:
	if author_val is String:
		var s := author_val as String
		if not s.is_empty() and s != "Anonymous":
			return s
		return ""

	if author_val is Dictionary:
		var name_val = author_val.get("name", "")
		if name_val is String:
			var ns := name_val as String
			if not ns.is_empty() and ns != "Anonymous":
				return ns
		return ""

	if author_val is Array:
		var result := ""
		for item in (author_val as Array):
			var name_str := ""
			if item is Dictionary:
				var nv = item.get("name", "")
				if nv is String:
					name_str = nv as String
			elif item is String:
				name_str = item as String
			if not name_str.is_empty() and name_str != "Anonymous":
				if not result.is_empty():
					result += ", "
				result += name_str
		return result

	return ""


## 对已解析的 chart JSON 字典执行就地规范化
## 返回 true 表示有修改（调用方可决定是否写回磁盘）
static func normalize_chart_json(data: Dictionary) -> bool:
	var changed := false

	# ── song ──
	var song_from_source := _safe_str(data.get("sourceSongName", ""), "Unknown Song")

	if data.has("song") and _has_meaningful_data(data["song"]):
		# 嵌套 song 有实际数据 → 精简
		var nested_song: Dictionary = data["song"]
		var sid := _get_str(nested_song, "_id", "")
		if sid.is_empty():
			# 兼容旧格式：部分来源用 "id" 而非 "_id"（如旧版下载 JSON）
			sid = _get_str(nested_song, "id", "")
			if not sid.is_empty():
				nested_song["_id"] = sid
				changed = true
		if sid.is_empty():
			var sn := _get_str(nested_song, "name", "Unknown Song")
			nested_song["_id"] = "song_" + sn.sha256_text().substr(0, 16)
			changed = true
		# track：统一为 int，避免 JSON 写入 1.0 导致 C#/GDScript 类型不一致
		if nested_song.has("track"):
			var tv: Variant = nested_song["track"]
			var iv: int = int(tv)
			if typeof(tv) != TYPE_INT or iv != tv:
				nested_song["track"] = iv
				changed = true
		else:
			nested_song["track"] = 0
			changed = true
		for key in nested_song.keys():
			if key not in ["_id", "name", "track", "author"]:
				nested_song.erase(key)
				changed = true
	else:
		# 无实际数据或缺失 → 从 sourceSongName 重建
		data["song"] = {
			"_id": "song_" + song_from_source.sha256_text().substr(0, 16),
			"name": song_from_source,
			"track": 0
		}
		changed = true

	# ── album ──
	var album_from_source := _safe_str(data.get("sourceAlbumName", ""), "Unknown Album")

	if data.has("album") and _has_meaningful_data(data["album"]):
		var album: Dictionary = data["album"]
		var aid := _get_str(album, "_id", "")
		if aid.is_empty():
			# 兼容旧格式：部分来源用 "id" 而非 "_id"（如旧版下载 JSON）
			aid = _get_str(album, "id", "")
			if not aid.is_empty():
				album["_id"] = aid
				changed = true
		if aid.is_empty():
			var an := _get_str(album, "name", "Unknown Album")
			album["_id"] = "album_" + an.sha256_text().substr(0, 16)
			changed = true
		for key in album.keys():
			if key not in ["_id", "name", "abbr", "date"]:
				album.erase(key)
				changed = true
	else:
		data["album"] = {
			"_id": "album_" + album_from_source.sha256_text().substr(0, 16),
			"name": album_from_source,
			"abbr": "",
			"date": ""
		}
		changed = true

	# ── author ──
	# 统一落位到 song.author（白名单键之一），顶层不再保留 author
	# 取值优先级：sourceArtistName(旧) → 顶层 author(旧) → song.author(现) → 空
	var new_author := _safe_str(data.get("sourceArtistName", ""), "")
	if new_author.is_empty() and data.has("author"):
		new_author = _extract_author_name(data["author"])

	var song: Dictionary = data["song"]
	var existing_song_author := _safe_str(song.get("author", ""), "")
	if new_author.is_empty():
		new_author = existing_song_author

	# 旧格式顶层 author 迁移：已并入取值逻辑，此处直接移除顶层
	if data.has("author"):
		data.erase("author")
		changed = true

	if not song.has("author") or not song["author"] is String or song["author"] != new_author:
		song["author"] = new_author
		changed = true

	# ── 删除顶层冗余字段 ──
	var top_fields_to_remove := [
		"sourceArtistName",
		"sourceAlbumName",
		"sourceSongName",
		"authorId",
		"songId",
		"composer",
		"composerId",
		"id",
	]
	for field in top_fields_to_remove:
		if data.has(field):
			data.erase(field)
			changed = true

	# ── 类型清理：整数值的 float → int，字符串字段 null → ""
	if ChartNormalizer.cleanup_types_recursive(data):
		changed = true

	return changed
