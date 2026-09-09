## 人物管理器
## 负责管理交互人物资源的扫描、配置加载与立绘合成
## 支持内置人物（res://Resources/Charas）与用户人物（user://files/Charas）统一管理
## 结构参考 ParticleManager / SkinManager：
##   人物目录下含 chara.json（配置）+ 人物图 + 表情图
##   合成立绘 = 人物图 + 在指定位置盖上表情图网格中的某格
extends Node

class_name CharaManager

## ========== 目录路径定义 ==========
static var CHARAS_DIR: String:
	get: return PathHelper.get_charas_dir()

## 内置人物源目录
const DEFAULT_CHARAS_SRC = "res://Resources/Charas/"

## 人物配置文件名（放在人物目录下）
const CHARA_CONFIG_FILE = "chara.json"

## 内置人物显示后缀（与皮肤/粒子一致）
const BUILTIN_SUFFIX = " [内置]"

## ========== 资源索引 ==========
## 人物索引 {chara_key: Dictionary}
## chara_key = 文件夹名（内置加 [内置] 后缀）
## 字段：{id, name, author, unlock_condition, description, path, is_builtin,
##        emotion_cols, emotion_rows, emotion_offset(Vector2i),
##        character_image, emotion_image, rating, dialog}
##   rating: {评级字符串: 表情号}；dialog: {表情号字符串: [对话, ...]}
var charas_index: Dictionary = {}

## 合成立绘缓存 {chara_key + "|" + emotion: Texture2D}
var _composite_cache: Dictionary = {}
var _texture_cache: Dictionary = {}

func _ready() -> void:
	add_to_group("singleton")
	GLogger.info("CharaManager initialized (deferred scan)", "CharaMGR")

## 清空人物索引与合成缓存（由 FileSystemManager._scan_all_resources 统一扫描前调用）
func clear_index() -> void:
	charas_index.clear()
	clear_composite_cache()

## ========== 扫描 ==========

## 公共扫描接口（worker 线程扫描，主线程合并）
## 供需要动态重扫人物列表的地方调用；启动时由 _scan_all_resources 的 worker 路径驱动
func scan_charas() -> void:
	clear_index()
	var rw: Dictionary = {}
	var task_id := WorkerThreadPool.add_task(
		func(): _build_charas_index_worker(rw),
		false, "ScanCharas"
	)
	while not WorkerThreadPool.is_task_completed(task_id):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)
	_merge_index_worker_result(rw)
	GLogger.info("Scanned %d charas" % charas_index.size(), "CharaMGR")

## worker 线程扫描人物目录（内置 + 用户），结果经 result_wrapper 回传主线程合并
func _build_charas_index_worker(result_wrapper: Dictionary) -> void:
	var local_charas: Dictionary = {}
	var local_logs: Array = []
	_scan_dir_worker(DEFAULT_CHARAS_SRC, true, local_charas, local_logs)
	_scan_dir_worker(CHARAS_DIR, false, local_charas, local_logs)
	result_wrapper["charas"] = local_charas
	result_wrapper["logs"] = local_logs

## worker 内部：扫描单个人物目录
## 只收集含 chara.json 的文件夹；日志收集到数组（worker 线程不直接调 GLogger）
func _scan_dir_worker(dir_path: String, is_builtin: bool, local_charas: Dictionary, local_logs: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var folder_name := dir.get_next()
	while folder_name != "":
		if not dir.current_is_dir() or folder_name.begins_with("."):
			folder_name = dir.get_next()
			continue
		var chara_path := dir_path.path_join(folder_name)
		var chara_key := folder_name + (BUILTIN_SUFFIX if is_builtin else "")
		var data := _load_chara_worker(chara_path, chara_key, is_builtin, local_logs)
		if not data.is_empty():
			local_charas[chara_key] = data
		folder_name = dir.get_next()
	dir.list_dir_end()

## worker 内部：加载单个人物（解析 chara.json + 校验图片存在性）
## 返回空 Dictionary 表示不是有效人物（无配置 / 配置损坏 / 缺人物图）
func _load_chara_worker(chara_path: String, chara_key: String, is_builtin: bool, local_logs: Array) -> Dictionary:
	var config_path := chara_path.path_join(CHARA_CONFIG_FILE)
	if not PathHelper.file_exists(config_path):
		return {}

	var file := FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		return {}
	var content := file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(content)
	if not (parsed is Dictionary):
		local_logs.append({"msg": "Chara config invalid JSON: %s" % config_path, "is_warning": true})
		return {}

	var general := _config_dictionary(parsed.get("general"))
	var info := _config_dictionary(parsed.get("info"))

	var character_image: String = str(general.get("character_image", "")).strip_edges()
	if character_image.is_empty() or not _image_exists(chara_path, character_image):
		local_logs.append({"msg": "Chara missing character image: %s" % config_path, "is_warning": true})
		return {}

	return {
		"id": chara_key,
		"name": str(info.get("name", chara_key.replace(BUILTIN_SUFFIX, ""))),
		"author": str(info.get("author", "")),
		"unlock_condition": str(info.get("unlock_condition", "")),
		"description": str(info.get("description", "")),
		"path": chara_path,
		"is_builtin": is_builtin,
		"emotion_cols": maxi(1, int(general.get("emotion_cols", 1))),
		"emotion_rows": maxi(1, int(general.get("emotion_rows", 1))),
		"emotion_offset": _parse_offset(general.get("emotion_offset", [0, 0])),
		"character_image": character_image,
		"emotion_image": str(general.get("emotion_image", "")).strip_edges(),
		"background_image": str(general.get("background_image", "")).strip_edges(),
		"rating": _config_dictionary(parsed.get("rating")),
		"dialog": _config_dictionary(parsed.get("dialog")),
		"motion": _normalize_motion(parsed.get("motion"), chara_path),
		"score_reactions": _normalize_score_reactions(parsed.get("score_reactions")),
	}

func _config_dictionary(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}

func _config_number(config: Dictionary, key: String, fallback: float, minimum: float, maximum: float) -> float:
	var value: Variant = config.get(key, fallback)
	if not (value is int or value is float) or not is_finite(float(value)):
		return fallback
	return clampf(float(value), minimum, maximum)

func _relative_image_name(value: Variant) -> String:
	if not value is String:
		return ""
	var image_name: String = value.strip_edges().replace("\\", "/")
	if image_name.is_empty() or image_name.is_absolute_path() or image_name.contains(":") or ".." in image_name.split("/"):
		return ""
	return image_name

func _normalize_motion(value: Variant, chara_path: String) -> Dictionary:
	var config := _config_dictionary(value)
	if _config_number(config, "version", 0.0, 0.0, 100.0) != 1.0:
		return {}
	var weight_image := _relative_image_name(config.get("weight_image"))
	if weight_image.is_empty() or not _image_exists(chara_path, weight_image):
		return {}
	var motion := {
		"version": 1,
		"weight_image": weight_image,
		"breath": _config_number(config, "breath", 2.0, 0.0, 12.0),
		"sway": _config_number(config, "sway", 2.0, 0.0, 15.0),
		"wing": _config_number(config, "wing", 10.0, 0.0, 30.0),
		"wing_rotation": _config_number(config, "wing_rotation", 4.0, 0.0, 12.0),
		"hair": _config_number(config, "hair", 4.0, 0.0, 20.0),
		"skirt": _config_number(config, "skirt", 4.0, 0.0, 20.0),
		"speed": _config_number(config, "speed", 1.0, 0.2, 3.0),
		"float": _config_number(config, "float", 5.0, 0.0, 20.0),
		"head_pivot": Vector2(0.28, 0.4),
		"blink": {},
	}
	var pivot: Variant = config.get("head_pivot")
	if pivot is Array and pivot.size() == 2:
		var coordinates := {"x": pivot[0], "y": pivot[1]}
		motion.head_pivot = Vector2(_config_number(coordinates, "x", 0.28, 0.0, 1.0), _config_number(coordinates, "y", 0.4, 0.05, 0.95))
	var wing_pivots: Variant = config.get("wing_pivots")
	if wing_pivots is Array and wing_pivots.size() == 2:
		var normalized_wing_pivots: Array[Vector2] = []
		for wing_pivot in wing_pivots:
			if not wing_pivot is Array or wing_pivot.size() != 2:
				continue
			var wing_coordinates := {"x": wing_pivot[0], "y": wing_pivot[1]}
			normalized_wing_pivots.append(Vector2(
				_config_number(wing_coordinates, "x", 0.5, 0.0, 1.0),
				_config_number(wing_coordinates, "y", 0.25, 0.0, 1.0)))
		if normalized_wing_pivots.size() == 2:
			motion.wing_pivots = normalized_wing_pivots
	var blink := _config_dictionary(config.get("blink"))
	var blink_image := _relative_image_name(blink.get("image"))
	if not blink_image.is_empty() and _image_exists(chara_path, blink_image):
		var emotions: Array[int] = []
		var configured_emotions: Variant = blink.get("emotions", [])
		if configured_emotions is Array:
			for emotion in configured_emotions:
				if (emotion is int or emotion is float) and is_finite(float(emotion)) and float(emotion) >= 0.0 and float(emotion) <= 255.0:
					emotions.append(int(emotion))
		var interval := Vector2(3.0, 6.0)
		var configured_interval: Variant = blink.get("interval")
		if configured_interval is Array and configured_interval.size() == 2:
			var bounds := {"min": configured_interval[0], "max": configured_interval[1]}
			interval.x = _config_number(bounds, "min", 3.0, 1.0, 30.0)
			interval.y = maxf(interval.x, _config_number(bounds, "max", 6.0, 1.0, 30.0))
		motion.blink = {
			"image": blink_image,
			"emotions": emotions,
			"interval": interval,
			"duration": _config_number(blink, "duration", 0.18, 0.08, 0.6),
		}
	return motion

func _normalize_score_reactions(value: Variant) -> Dictionary:
	var config := _config_dictionary(value)
	var presets := _config_dictionary(config.get("presets"))
	var normalized: Dictionary = {}
	for preset_name in presets:
		if not preset_name is String or not presets[preset_name] is Dictionary:
			continue
		var preset: Dictionary = presets[preset_name]
		var effect := str(preset.get("effect", "none"))
		if effect not in ["petals", "sparkles", "none"]:
			effect = "none"
		normalized[preset_name] = {
			"motion_scale": _config_number(preset, "motion_scale", 1.0, 0.0, 2.0),
			"bounce": _config_number(preset, "bounce", 0.0, 0.0, 40.0),
			"tilt": _config_number(preset, "tilt", 0.0, -8.0, 8.0),
			"effect": effect,
			"count": int(_config_number(preset, "count", 0.0, 0.0, 32.0)),
			"message": str(preset.get("message", "")).left(160),
		}
	if normalized.is_empty():
		return {}
	var ratings := _config_dictionary(config.get("ratings"))
	var valid_ratings: Dictionary = {}
	for rank in ratings:
		if rank is String and ratings[rank] is String and normalized.has(ratings[rank]):
			valid_ratings[rank] = ratings[rank]
	return {"default": str(config.get("default", "")), "ratings": valid_ratings, "presets": normalized}

## 解析表情放置坐标 [x, y]（左上角原点）
func _parse_offset(value: Variant) -> Vector2i:
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO

## 图片存在性检查（内置走 ResourceLoader，用户走文件系统）
func _image_exists(chara_path: String, file_name: String) -> bool:
	if file_name.is_empty():
		return false
	var file_path := chara_path.path_join(file_name)
	if file_path.begins_with("res://"):
		return ResourceLoader.exists(file_path)
	return PathHelper.file_exists(file_path)

## 主线程合并 worker 扫描结果
func _merge_index_worker_result(result_wrapper: Dictionary) -> void:
	var charas_data: Dictionary = result_wrapper.get("charas", {})
	charas_index = charas_data
	for log_entry in result_wrapper.get("logs", []):
		if log_entry.get("is_warning", true):
			GLogger.warning(log_entry.msg, "CharaMGR")
		else:
			GLogger.info(log_entry.msg, "CharaMGR")

## ========== 查询接口 ==========

## 获取全部人物键（按名称排序，保证跨平台/跨枚举顺序稳定）
func get_chara_list() -> Array:
	var keys := charas_index.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return a.to_lower() < b.to_lower())
	return keys

## 获取人物数据（未找到返回空 Dictionary）
func get_chara_data(chara_key: String) -> Dictionary:
	return charas_index.get(chara_key, {})

## 人物键的存在性检查（配置值可能是内置键，校验时容忍多/缺 [内置] 后缀）
func has_chara(chara_key: String) -> bool:
	if charas_index.has(chara_key):
		return true
	if chara_key.ends_with(BUILTIN_SUFFIX):
		return charas_index.has(chara_key.trim_suffix(BUILTIN_SUFFIX))
	return charas_index.has(chara_key + BUILTIN_SUFFIX)

## 取实际的人物索引键（容忍多/缺 [内置] 后缀的输入）
func resolve_chara_key(chara_key: String) -> String:
	if charas_index.has(chara_key):
		return chara_key
	if chara_key.ends_with(BUILTIN_SUFFIX):
		var pure := chara_key.trim_suffix(BUILTIN_SUFFIX)
		if charas_index.has(pure):
			return pure
		return ""
	return chara_key + BUILTIN_SUFFIX if charas_index.has(chara_key + BUILTIN_SUFFIX) else ""

## 获取当前选中的内置/用户人物键（由 ScoreView 等消费）
## 读取 [Chara] chara_id 配置；配置无值/被删时回退到第一个内置人物
func get_current_chara_key() -> String:
	var conf_key: String = ""
	if ConfigManager.instance != null:
		conf_key = ConfigManager.instance.get_string("Chara", "chara_id", "")
	conf_key = conf_key.strip_edges()
	if not conf_key.is_empty() and has_chara(conf_key):
		return resolve_chara_key(conf_key)
	# 回退：第一个内置人物
	for key in charas_index.keys():
		if charas_index[key].get("is_builtin", false):
			return key
	# 兜底：任意第一个人物
	if not charas_index.is_empty():
		return charas_index.keys()[0]
	return ""

## ========== 立绘合成 ==========

## 按评级字符串获取当前人物的立绘贴图（返回 null 表示人物无效/合成失败）
## rank: ScoreCalculator 返回的评级，如 "S" / "A+" / "Ω" / "F" 等
func get_current_portrait_by_rank(rank: String) -> Texture2D:
	var chara_key := get_current_chara_key()
	if chara_key.is_empty():
		return null
	return get_portrait(chara_key, get_rating_emotion(chara_key, rank))

## 按表情号获取人物的合成立绘贴图
## emotion 0 表示「不使用表情图片」（人物图自带表情），1..N 对应表情图第 N 格
## 返回 null 表示人物无效/图片加载失败
func get_portrait(chara_key: String, emotion: int) -> Texture2D:
	chara_key = resolve_chara_key(chara_key)
	if chara_key.is_empty():
		return null
	var meta: Dictionary = charas_index[chara_key]
	if emotion < 0 or emotion > int(meta.get("emotion_cols", 1)) * int(meta.get("emotion_rows", 1)):
		emotion = 0
	var cache_key := "%s|%d" % [chara_key, emotion]
	if _composite_cache.has(cache_key):
		return _composite_cache[cache_key]

	var chara_img := _load_image(meta.get("path", "").path_join(meta.get("character_image", "")))
	if chara_img == null:
		GLogger.warning("Failed to load chara image: %s" % meta.get("path", ""), "CharaMGR")
		return null

	# 合成基座（emotion 0 只留人物图自身）
	var result_img: Image = chara_img

	if emotion > 0:
		var emos_name: String = meta.get("emotion_image", "")
		var emos_img: Image = null
		if not emos_name.is_empty():
			emos_img = _load_image(meta.get("path", "").path_join(emos_name))
		if emos_img != null:
			var cols := int(meta.get("emotion_cols", 1))
			var rows := int(meta.get("emotion_rows", 1))
			var ew := maxi(1, emos_img.get_width())
			var eh := maxi(1, emos_img.get_height())
			var cell_w := ew / cols
			var cell_h := eh / rows
			# emotion N（1 起）对应网格第 N-1 格
			var idx := emotion - 1
			var col := idx % cols
			var row := idx / cols
			var cell_rect := Rect2i(col * cell_w, row * cell_h, cell_w, cell_h)
			var region := emos_img.get_region(cell_rect)
			# blend_rect 要求源与目标格式一致，先统一格式再覆盖
			region.convert(result_img.get_format())
			var offset: Vector2i = meta.get("emotion_offset", Vector2i.ZERO)
			# 直接在人物图上叠加（人物图已带 alpha，blend_rect 按源 alpha 覆盖）
			result_img.blend_rect(region, Rect2i(0, 0, cell_w, cell_h), offset)
			emos_img = null
		else:
			GLogger.warning("Emotion image missing: %s (%d)" % [emos_name, emotion], "CharaMGR")

	var texture := ImageTexture.create_from_image(result_img)
	if texture != null:
		_composite_cache[cache_key] = texture
	return texture

## 获取人物背景贴图（background_image），返回 null 表示未配置/加载失败
func get_background(chara_key: String) -> Texture2D:
	chara_key = resolve_chara_key(chara_key)
	if chara_key.is_empty():
		return null
	var meta: Dictionary = charas_index[chara_key]
	var bg_name := str(meta.get("background_image", "")).strip_edges()
	if bg_name.is_empty():
		return null
	var file_path: String = str(meta.get("path", "")).path_join(bg_name)
	if file_path.begins_with("res://"):
		if ResourceLoader.exists(file_path):
			return load(file_path) as Texture2D
		return null
	# 用户目录：解码为 ImageTexture
	var img := ImageUtil.load_image_file(file_path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)

## 加载图片为 Image（内置走 ResourceLoader → get_image，用户走 ImageUtil）
func _load_image(file_path: String) -> Image:
	if file_path.begins_with("res://"):
		if ResourceLoader.exists(file_path):
			var tex := load(file_path) as Texture2D
			if tex != null:
				return tex.get_image()
		return null
	return ImageUtil.load_image_file(file_path)

## ========== 评级映射 ==========

## 依据评级字符串解析应使用的表情号
## 回退规则：SSS/SS 未定义时回退到 S；A+/A- 未定义时回退到 A；再缺失用表情 0
func get_rating_emotion(chara_key: String, rank: String) -> int:
	chara_key = resolve_chara_key(chara_key)
	if chara_key.is_empty():
		return 0
	var rating: Dictionary = charas_index[chara_key].get("rating", {})
	var lookup := rank
	if not rating.has(lookup):
		if rank == "SSS" or rank == "SS":
			lookup = "S"
		elif rank == "A+" or rank == "A-":
			lookup = "A"
	return int(rating.get(lookup, 0))

## ========== 对话接口 ==========

## 获取人物的一句随机对话
## 返回 {emotion: int, text: String}；未配置对话或人物无效时返回 {emotion: 0, text: ""}
## emotion 指定时只从该表情的对话里随机；-1 表示先随机表情再随机对话
func get_dialog(chara_key: String, emotion: int = -1) -> Dictionary:
	chara_key = resolve_chara_key(chara_key)
	if chara_key.is_empty():
		return {"emotion": 0, "text": ""}
	var dialog: Dictionary = charas_index[chara_key].get("dialog", {})

	# 未指定表情时，从所有配置了对话的表情里随机选一个
	var emotion_key := str(emotion)
	if emotion < 0 or not dialog.has(emotion_key):
		var emo_keys := dialog.keys()
		if emo_keys.is_empty():
			return {"emotion": 0, "text": ""}
		emotion_key = str(emo_keys[randi() % emo_keys.size()])

	var lines: Array = dialog.get(emotion_key, [])
	if lines.is_empty():
		return {"emotion": 0, "text": ""}
	return {"emotion": int(emotion_key), "text": str(lines[randi() % lines.size()])}

## 清空合成缓存（人物重扫时调用）
func clear_composite_cache() -> void:
	_composite_cache.clear()
	_texture_cache.clear()

func get_motion_config(chara_key: String) -> Dictionary:
	chara_key = resolve_chara_key(chara_key)
	return get_chara_data(chara_key).get("motion", {}).duplicate(true)

func get_score_reaction(chara_key: String, rank: String) -> Dictionary:
	chara_key = resolve_chara_key(chara_key)
	var config: Dictionary = get_chara_data(chara_key).get("score_reactions", {})
	var preset_name: String = config.get("ratings", {}).get(rank, config.get("default", ""))
	return config.get("presets", {}).get(preset_name, {}).duplicate(true)

func get_chara_texture(chara_key: String, image_name: String) -> Texture2D:
	chara_key = resolve_chara_key(chara_key)
	image_name = _relative_image_name(image_name)
	if chara_key.is_empty() or image_name.is_empty():
		return null
	var file_path: String = str(charas_index[chara_key].get("path", "")).path_join(image_name)
	if _texture_cache.has(file_path):
		return _texture_cache[file_path]
	var texture: Texture2D = null
	if file_path.begins_with("res://"):
		if ResourceLoader.exists(file_path):
			texture = load(file_path) as Texture2D
	else:
		var image := ImageUtil.load_image_file(file_path)
		if image != null:
			texture = ImageTexture.create_from_image(image)
	if texture != null:
		_texture_cache[file_path] = texture
	return texture
