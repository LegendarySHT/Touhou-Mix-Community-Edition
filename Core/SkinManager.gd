## 皮肤管理器
## 负责管理皮肤资源的扫描、配置加载与贴图获取
## 支持内置皮肤（res://）与用户皮肤（user://）的统一管理
extends Node

class_name SkinManager

## ========== 目录路径定义（通过 PathHelper 动态获取） ==========
static var SKINS_DIR: String:
	get: return PathHelper.get_skins_dir()

static var BUILTIN_CONFIG_DIR: String:
	get: return PathHelper.get_builtin_skin_config_dir()

## 默认资源源目录
const DEFAULT_SKINS_SRC = "res://Resources/Skins/"

## 皮肤配置文件名（放置在皮肤包目录下）
const SKIN_CONFIG_FILE = "skin.ini"

## 默认音符皮肤预设（Appearance/block_skin_preset 的兜底值，与 Resources/Config/config.ini 一致）
const DEFAULT_SKIN_PRESET = "Squre45 [内置]"

## 长条连接模式常量
const LONG_CONNECT_MODE_EDGE = "edge"
const LONG_CONNECT_MODE_CENTER = "center"
const LONG_F_MODE_REPEAT = "repeat"
const LONG_F_MODE_STRETCH = "stretch"

## ========== 资源索引 ==========
## 皮肤索引 {skin_name: SkinMetadata}
var skins_index: Dictionary = {}
## 皮肤贴图缓存 {skin_name: Dictionary{texture_key: Texture2D}}
var _skin_textures_cache: Dictionary = {}

func _ready() -> void:
	add_to_group("singleton")
	# 不在 _ready 中主动扫描。扫描由 FileSystemManager._scan_all_resources()
	# 在目录结构初始化完成后统一触发，确保默认皮肤已复制到位。
	GLogger.info("SkinManager initialized (deferred scan)", "SkinMGR")

## 清空皮肤索引（由 FileSystemManager._scan_all_resources 在统一扫描前调用）
## 避免外部直接写 skins_index.clear()
func clear_index() -> void:
	skins_index.clear()

## 扫描皮肤目录（公共 API，worker 线程扫描）
## 同时扫描内置皮肤（res://）和用户皮肤（user://）
## 在 worker 中扫描两个目录，主线程合并到 skins_index 并构建 SkinMetadata 对象
func scan_skins() -> void:
	skins_index.clear()
	var t_start := Time.get_ticks_usec()
	var rw: Dictionary = {}
	var task_id := WorkerThreadPool.add_task(
		func(): _build_skins_index_worker(rw),
		false, "ScanSkins"
	)
	while not WorkerThreadPool.is_task_completed(task_id):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)

	# 合并结果到 skins_index（主线程构建 SkinMetadata 对象）
	var skins_data: Dictionary = rw.get("skins", {})
	for skin_key in skins_data:
		skins_index[skin_key] = SkinMetadata.from_dict(skins_data[skin_key])

	# 打印收集的 logs（主线程安全调用 GLogger）
	for log_entry in rw.get("logs", []):
		if log_entry.get("is_warning", true):
			GLogger.warning(log_entry.msg, "SkinMGR")
		else:
			GLogger.info(log_entry.msg, "SkinMGR")

	var t_end := Time.get_ticks_usec()
	GLogger.info("Scanned %d skins in %.0fms" % [
		skins_index.size(), (t_end - t_start) / 1000.0
	], "SkinMGR")

## 在 worker 线程中扫描皮肤目录（内置 + 用户）
## 纯文件 I/O + Dictionary 操作，结果通过 result_wrapper 回传
## 不创建 SkinMetadata（主线程合并时构建），不调用 GLogger（logs 收集到数组）
## _load_skin_metadata 内部调用 _load_or_generate_skin_config 可能写文件（用户皮肤生成 skin.ini），并发写不同文件安全
func _build_skins_index_worker(result_wrapper: Dictionary) -> void:
	var local_skins: Dictionary = {}
	var local_logs: Array = []

	# 先扫描内置皮肤，再扫描用户皮肤
	_scan_skins_from_dir_worker(DEFAULT_SKINS_SRC, true, local_skins, local_logs)
	_scan_skins_from_dir_worker(SKINS_DIR, false, local_skins, local_logs)

	result_wrapper["skins"] = local_skins
	result_wrapper["logs"] = local_logs

## worker 内部使用的目录扫描辅助函数
## 写入 local_skins 字典（skin_key → metadata Dictionary），不创建 SkinMetadata，不让步
func _scan_skins_from_dir_worker(dir_path: String, is_builtin: bool, local_skins: Dictionary, local_logs: Array) -> void:
	var dir = DirAccess.open(dir_path)
	if dir == null:
		if is_builtin:
			local_logs.append({"msg": "Failed to open built-in skins directory: %s" % dir_path, "is_warning": true})
		return

	dir.list_dir_begin()
	var folder_name = dir.get_next()
	while folder_name != "":
		if not dir.current_is_dir() or folder_name.begins_with("."):
			folder_name = dir.get_next()
			continue

		# 跳过内置皮肤配置覆盖目录：它位于用户皮肤目录之下，只存 {皮肤名}.ini 覆盖文件，
		# 不是皮肤包。否则会被当成一个名为 builtin_skin_config 的用户皮肤，
		# 并且因为"用户皮肤配置缺失即生成并写盘"而往里写入一份多余的 skin.ini
		if folder_name == PathHelper.BUILTIN_SKIN_CONFIG_DIR_NAME:
			folder_name = dir.get_next()
			continue

		var skin_path = dir_path.path_join(folder_name)
		var skin_key = folder_name

		# 如果是内置皮肤，添加 [内置] 标记
		if is_builtin:
			skin_key = "%s [内置]" % folder_name

		var metadata = _load_skin_metadata(skin_path, skin_key, is_builtin, local_logs)

		if metadata != null and not metadata.is_empty():
			local_skins[skin_key] = metadata  # 保留 Dictionary 形式，主线程合并时构建 SkinMetadata

		folder_name = dir.get_next()
	dir.list_dir_end()

## 加载皮肤元数据
## logs 参数：传入 Array 则收集日志（worker 模式，避免在 worker 线程调用 GLogger）；传 null 则直接调用 GLogger（主线程模式）
func _load_skin_metadata(skin_path: String, skin_name: String, is_builtin: bool = false, logs: Variant = null) -> Dictionary:
	# 不再检查必需文件，允许部分贴图缺失
	var metadata = {
		"name": skin_name,
		"path": skin_path,
		"is_builtin": is_builtin,
		"is_complete": true,
		"missing_files": [],
		# 皮肤级配置（光晕颜色/大小、long-f 贴图应用方式等）
		"config": _load_or_generate_skin_config(skin_path, is_builtin, logs)
	}

	return metadata

## 加载或自动生成皮肤配置
## - 用户皮肤（user://）：加载 skin.ini，缺失则生成并写入磁盘
## - 内置皮肤（res://）：加载 res:// 中的 skin.ini（缺失则生成默认值，不写盘），
##   然后检查内置皮肤覆盖目录中的 {name}.ini 是否存在，存在则用其覆盖
## logs 参数：传入 Array 则收集日志到数组（worker 模式）；传 null 则直接调用 GLogger（主线程模式）
func _load_or_generate_skin_config(skin_path: String, is_builtin: bool, logs: Variant = null) -> Dictionary:
	var config_path = skin_path.path_join(SKIN_CONFIG_FILE)

	# 内部辅助：日志输出，根据 logs 是否为 Array 决定走收集还是直接调用 GLogger
	var _log = func(msg: String, is_warning: bool = true):
		if logs is Array:
			(logs as Array).append({"msg": msg, "is_warning": is_warning})
		else:
			if is_warning:
				GLogger.warning(msg, "SkinMGR")
			else:
				GLogger.info(msg, "SkinMGR")

	# 1. 尝试加载已存在的 skin.ini
	var config: Dictionary = {}
	if PathHelper.file_exists(config_path):
		config = _load_skin_config_from_file(config_path)
		if config.is_empty():
			# 加载失败（文件损坏等）：回退到自动生成，并打印警告
			_log.call("Skin config corrupted, regenerating: %s" % config_path, true)
			config = _generate_default_skin_config(skin_path)
	else:
		# 2. 自动生成默认配置
		config = _generate_default_skin_config(skin_path)
		# 用户皮肤写入磁盘；内置皮肤跳过（res:// 在导出后为只读）
		if not is_builtin:
			_save_skin_config_to_file(config_path, config, logs)
			_log.call("Generated skin config: %s" % config_path, false)

	# 3. 内置皮肤：检查覆盖配置，存在则用其替代
	if is_builtin:
		var pure_name = skin_path.get_file()
		var override_path = _get_builtin_config_path(pure_name)
		if PathHelper.file_exists(override_path):
			var override = _load_skin_config_from_file(override_path)
			if not override.is_empty():
				_log.call("Loaded builtin skin override config: %s" % override_path, false)
				return override
			_log.call("Builtin skin override config corrupted, using default: %s" % override_path, true)

	return config

## 获取内置皮肤覆盖配置文件路径
## pure_name 为不含 [内置] 后缀的皮肤文件夹名
func _get_builtin_config_path(pure_name: String) -> String:
	return BUILTIN_CONFIG_DIR.path_join(pure_name + ".ini")

## 从文件加载皮肤配置并解析为结构化 Dictionary
## 返回空 Dictionary 表示加载/解析失败
func _load_skin_config_from_file(config_path: String) -> Dictionary:
	var file = FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		return {}
	var content = file.get_as_text()
	file.close()

	# 复用项目通用的 INI 解析逻辑（段→键→字符串值）
	var raw = IniParser.parse(content)
	if raw.is_empty():
		return {}

	return _normalize_skin_config(raw)

## 生成默认皮肤配置
## 新结构：[general] 全局开关 + [short/instant/long] 各类型颜色/随机 + [long] 长条连接模式
func _generate_default_skin_config(_skin_path: String) -> Dictionary:
	return {
		"general": {
			"enable_glow": false,
			"custom_color": false
		},
		"short": _default_note_section(),
		"instant": _default_note_section(),
		"long": _default_note_section(true)
	}

## 单个音符类型的默认配置节
func _default_note_section(is_long: bool = false) -> Dictionary:
	var sec: Dictionary = {
		"enable_color": false,
		"color": Color.WHITE,
		"random_color": false
	}
	if is_long:
		sec["long_connect_mode"] = LONG_CONNECT_MODE_EDGE
		sec["long_f_mode"] = LONG_F_MODE_REPEAT
	return sec

## 将解析得到的 {section: {key: str}} 规范化为带类型的结构化 Dictionary
## 缺失的键使用默认值补全，确保下游可以安全读取
func _normalize_skin_config(raw: Dictionary) -> Dictionary:
	return {
		"general": _normalize_general_section(raw.get("general", {})),
		"short": _normalize_note_section(raw.get("short", {}), false),
		"instant": _normalize_note_section(raw.get("instant", {}), false),
		"long": _normalize_note_section(raw.get("long", {}), true)
	}

## 规范化 [general] 节
func _normalize_general_section(section_raw: Dictionary) -> Dictionary:
	return {
		"enable_glow": _parse_bool(section_raw.get("enable_glow", "false")),
		"custom_color": _parse_bool(section_raw.get("custom_color", "false"))
	}

## 规范化单个键型的配置节
func _normalize_note_section(section_raw: Dictionary, is_long: bool) -> Dictionary:
	var result: Dictionary = {
		"enable_color": _parse_bool(section_raw.get("enable_color", "false")),
		"color": _parse_color(section_raw.get("color", "#ffffff")),
		"random_color": _parse_bool(section_raw.get("random_color", "false"))
	}
	if is_long:
		var connect_mode = section_raw.get("long_connect_mode", LONG_CONNECT_MODE_EDGE)
		result["long_connect_mode"] = LONG_CONNECT_MODE_CENTER if connect_mode == LONG_CONNECT_MODE_CENTER else LONG_CONNECT_MODE_EDGE
		var f_mode = section_raw.get("long_f_mode", LONG_F_MODE_REPEAT)
		result["long_f_mode"] = LONG_F_MODE_STRETCH if f_mode == LONG_F_MODE_STRETCH else LONG_F_MODE_REPEAT
	return result

## 将字符串解析为 bool（接受 "true"/"false"/"1"/"0"）
func _parse_bool(value) -> bool:
	if value is bool:
		return value
	var s = str(value).to_lower()
	return s == "true" or s == "1"

## 将字符串解析为 Color（接受 "#RRGGBB" / "#RRGGBBAA" / 颜色名）
func _parse_color(value) -> Color:
	if value is Color:
		return value
	var s = str(value).strip_edges()
	if s.is_empty():
		return Color.WHITE
	# Color.html 安全解析 hex；失败时返回 Color.MAGENTA 作为可见错误标记，这里回退到 WHITE
	var col = Color.from_string(s, Color.WHITE)
	return col

## 将结构化配置 Dictionary 写入 skin.ini 文件
## logs 参数：传入 Array 则收集日志到数组（worker 模式，避免在 worker 线程调用 GLogger）；传 null 则直接调用 GLogger（主线程模式）
func _save_skin_config_to_file(config_path: String, config: Dictionary, logs: Variant = null) -> bool:
	var content = _serialize_skin_config(config)
	var file = FileAccess.open(config_path, FileAccess.WRITE)
	if file == null:
		var msg = "Failed to write skin config: %s" % config_path
		if logs is Array:
			(logs as Array).append({"msg": msg, "is_warning": true})
		else:
			GLogger.warning(msg, "SkinMGR")
		return false
	file.store_string(content)
	file.close()
	return true

## 将配置 Dictionary 序列化为 INI 文本
func _serialize_skin_config(config: Dictionary) -> String:
	var lines: Array = ["# 自动生成的皮肤配置文件 - 可手动编辑", ""]
	# [general] 节
	if config.has("general"):
		lines.append("[general]")
		var gen = config["general"]
		lines.append("enable_glow=%s" % str(gen.get("enable_glow", false)).to_lower())
		lines.append("custom_color=%s" % str(gen.get("custom_color", false)).to_lower())
		lines.append("")
	# 各音符类型节
	for section in ["short", "instant", "long"]:
		if not config.has(section):
			continue
		lines.append("[%s]" % section)
		var sec = config[section]
		lines.append("enable_color=%s" % str(sec.get("enable_color", false)).to_lower())
		lines.append("color=%s" % _color_to_hex(sec.get("color", Color.WHITE)))
		lines.append("random_color=%s" % str(sec.get("random_color", false)).to_lower())
		if section == "long":
			lines.append("long_connect_mode=%s" % str(sec.get("long_connect_mode", LONG_CONNECT_MODE_EDGE)))
			lines.append("long_f_mode=%s" % str(sec.get("long_f_mode", LONG_F_MODE_REPEAT)))
		lines.append("")
	return "\n".join(lines)

## 将 Color 转换为 #RRGGBB 字符串
func _color_to_hex(col: Color) -> String:
	return "#%02x%02x%02x" % [int(round(col.r * 255)), int(round(col.g * 255)), int(round(col.b * 255))]

## 获取指定皮肤的配置 Dictionary
## 返回结构：{general:{...}, short:{...}, instant:{...}, long:{...}}；查找不到时返回空 Dictionary
func get_skin_config(skin_name: String) -> Dictionary:
	var skin_data: SkinMetadata = skins_index.get(skin_name, null)
	if skin_data == null:
		# 尝试移除 [内置] 标记查找
		if skin_name.ends_with(" [内置]"):
			var pure_name = skin_name.substr(0, skin_name.length() - 8)
			skin_data = skins_index.get(pure_name, null)
		if skin_data == null:
			GLogger.warning("Skin config not found: %s" % skin_name, "SkinMGR")
			return {}
	return skin_data.config

## 获取长条连接模式（"edge" 边缘连接 / "center" 中心连接）
func get_long_connect_mode(skin_name: String) -> String:
	var config = get_skin_config(skin_name)
	if config.is_empty():
		return LONG_CONNECT_MODE_EDGE
	var long_sec: Dictionary = config.get("long", {})
	var mode = long_sec.get("long_connect_mode", LONG_CONNECT_MODE_EDGE)
	return LONG_CONNECT_MODE_CENTER if mode == LONG_CONNECT_MODE_CENTER else LONG_CONNECT_MODE_EDGE

## 获取长条中部贴图延伸模式（"repeat" 垂直重复 / "stretch" 竖直拉伸）
func get_long_f_mode(skin_name: String) -> String:
	var config = get_skin_config(skin_name)
	if config.is_empty():
		return LONG_F_MODE_REPEAT
	var long_sec: Dictionary = config.get("long", {})
	var mode = long_sec.get("long_f_mode", LONG_F_MODE_REPEAT)
	return LONG_F_MODE_STRETCH if mode == LONG_F_MODE_STRETCH else LONG_F_MODE_REPEAT

## 判断皮肤是否启用光效（[general] enable_glow）
func is_glow_enabled(skin_name: String) -> bool:
	var config = get_skin_config(skin_name)
	if config.is_empty():
		return false
	var gen: Dictionary = config.get("general", {})
	return bool(gen.get("enable_glow", false))

## 判断皮肤是否启用自定义颜色主开关（[general] custom_color）
func is_custom_color_enabled(skin_name: String) -> bool:
	var config = get_skin_config(skin_name)
	if config.is_empty():
		return false
	var gen: Dictionary = config.get("general", {})
	return bool(gen.get("custom_color", false))

## 获取指定音符类型的颜色配置
## note_type_key ∈ {"short", "instant", "long"}
## 返回 {enable_color: bool, color: Color, random_color: bool}
func get_note_color_config(skin_name: String, note_type_key: String) -> Dictionary:
	var config = get_skin_config(skin_name)
	if config.is_empty():
		return {"enable_color": false, "color": Color.WHITE, "random_color": false}
	var sec: Dictionary = config.get(note_type_key, {})
	return {
		"enable_color": bool(sec.get("enable_color", false)),
		"color": sec.get("color", Color.WHITE),
		"random_color": bool(sec.get("random_color", false))
	}

## 将工作副本配置保存到磁盘并更新内存配置
## - 用户皮肤（user://）：写入皮肤包目录下的 skin.ini
## - 内置皮肤（res://）：写入 user://skin/builtin_skin_config/{name}.ini 覆盖文件
##   （res:// 在导出后为只读，故用 user:// 下的覆盖文件持久化修改）
## 返回是否成功写入磁盘
func save_skin_config(skin_name: String, config: Dictionary) -> bool:
	var skin_data: SkinMetadata = skins_index.get(skin_name, null)
	if skin_data == null:
		if skin_name.ends_with(" [内置]"):
			var pure_name = skin_name.substr(0, skin_name.length() - 8)
			skin_data = skins_index.get(pure_name, null)
		if skin_data == null:
			GLogger.warning("save_skin_config: skin not found: %s" % skin_name, "SkinMGR")
			return false

	# 规范化一次，确保字段完整
	var normalized = _normalize_skin_config({
		"general": config.get("general", {}),
		"short": config.get("short", {}),
		"instant": config.get("instant", {}),
		"long": config.get("long", {})
	})

	# 始终更新内存配置（保证本次会话内生效）
	skin_data.config = normalized

	# 内置皮肤写入覆盖文件（res:// 在导出后为只读）
	if skin_data.is_builtin:
		var pure_name = skin_data.path.get_file()
		var override_path = _get_builtin_config_path(pure_name)
		# 确保覆盖目录存在
		if not PathHelper.ensure_dir_exists(BUILTIN_CONFIG_DIR):
			GLogger.error("Failed to create builtin config dir: %s" % BUILTIN_CONFIG_DIR, "SkinMGR")
			return false
		if not _save_skin_config_to_file(override_path, normalized):
			return false
		GLogger.info("Saved builtin skin override config: %s" % override_path, "SkinMGR")
		return true

	# 用户皮肤写入皮肤包目录
	var config_path = skin_data.path.path_join(SKIN_CONFIG_FILE)
	if not _save_skin_config_to_file(config_path, normalized):
		return false
	GLogger.info("Saved skin config: %s" % config_path, "SkinMGR")
	return true

## 获取所有可用皮肤列表
func get_available_skins() -> Array:
	var result: Array = []

	for skin_name in skins_index.keys():
		result.append(skin_name)

	return result

## 获取皮肤贴图文件映射
const SKIN_TEXTURES = {
	"short": "short.png",
	"short_core": "short-core.png",
	"instant": "instant.png",
	"instant_core": "instant-core.png",
	"long_t": "long-t.png",
	"long_t_core": "long-t-core.png",
	"long_f": "long-f.png",
	"long_f_core": "long-f-core.png",
	"long_b": "long-b.png",
	"long_b_core": "long-b-core.png"
}

## 获取指定皮肤的贴图字典
func get_skin_textures(skin_name: String) -> Dictionary:
	# 缓存命中检查
	if _skin_textures_cache.has(skin_name):
		return _skin_textures_cache[skin_name]

	var result: Dictionary = {}

	# 获取皮肤数据
	var skin_data: SkinMetadata = skins_index.get(skin_name, null)
	if skin_data == null:
		# 尝试移除 [内置] 标记查找（用于内置皮肤）
		if skin_name.ends_with(" [内置]"):
			var pure_name = skin_name.substr(0, skin_name.length() - 8)
			skin_data = skins_index.get(pure_name, null)

		if skin_data == null:
			GLogger.warning("Skin not found: %s" % skin_name, "SkinMGR")
			return result

	var skin_path = skin_data.path
	if skin_path.is_empty():
		return result

	# 加载所有贴图
	for texture_key in SKIN_TEXTURES:
		var file_name = SKIN_TEXTURES[texture_key]
		var file_path = skin_path.path_join(file_name)

		if file_path.begins_with("res://"):
			# 内置资源直接加载
			if ResourceLoader.exists(file_path):
				result[texture_key] = load(file_path)
		else:
			# 用户目录资源动态加载 - 先检查文件是否存在
			if PathHelper.file_exists(file_path):
				var image = ImageUtil.load_image_file(file_path)
				if image:
					var texture = ImageTexture.create_from_image(image)
					result[texture_key] = texture

	# 缓存结果（非空时）
	if not result.is_empty():
		_skin_textures_cache[skin_name] = result

	return result

## 清空皮肤贴图缓存（皮肤切换/删除/重扫时调用）
func clear_skin_cache(skin_name: String = "") -> void:
	if skin_name.is_empty():
		_skin_textures_cache.clear()
	else:
		_skin_textures_cache.erase(skin_name)

## ========== 音符显示颜色解析（运行时与皮肤预览共用的唯一规则来源） ==========
## 规则（按优先级）：
##   皮肤 custom_color ON → 皮肤规则（enable_color + random_color，取 skin_random_colors 或 color）
##   custom_color OFF + 非键盘模式 + 全局随机 ON  → global_random_colors[key]
##   custom_color OFF + 非键盘模式 + 全局随机 OFF → 全局手动色（Appearance/{key}_block_color）
##   custom_color OFF + 键盘模式                  → Color.WHITE
static func resolve_note_colors(skin_config: Dictionary, keyboard_mode: bool,
		skin_random_colors: Dictionary = {}, global_random_colors: Dictionary = {}) -> Dictionary:
	var custom_color_on: bool = bool(skin_config.get("general", {}).get("custom_color", false))
	var global_random_on: bool = ConfigManager.instance.get_int("Appearance", "randomize_block_color", 0) == 1
	var out: Dictionary = {}
	for key in ["short", "instant", "long"]:
		var color := Color.WHITE
		if custom_color_on and skin_config.has(key):
			var sec: Dictionary = skin_config[key]
			if bool(sec.get("enable_color", false)):
				if bool(sec.get("random_color", false)) and skin_random_colors.has(key):
					color = skin_random_colors[key]
				else:
					color = sec.get("color", Color.WHITE)
		elif not keyboard_mode:
			if global_random_on and global_random_colors.has(key):
				color = global_random_colors[key]
			else:
				color = get_global_note_color(key)
		out[key] = color
	return out

## 读取全局手动音符颜色（默认值与 Resources/Config/config.ini [Appearance] 一致）
static func get_global_note_color(key: String) -> Color:
	var default_hex := "#4ECDC4"  # short=点块
	if key == "instant":
		default_hex = "#FF6B6B"   # instant=滑块
	elif key == "long":
		default_hex = "#45B7D1"   # long=长条
	var raw: String = ConfigManager.instance.get_string("Appearance", "%s_block_color" % key, default_hex)
	return Color.from_string(raw, Color.WHITE)

## 获取默认皮肤的贴图
func get_default_skin_textures() -> Dictionary:
	var default_name: String = ConfigManager.instance.get_string("Appearance", "block_skin_preset", DEFAULT_SKIN_PRESET)
	return get_skin_textures(default_name)

## 获取皮肤路径
func get_skin_path(skin_name: String) -> String:
	if not skins_index.has(skin_name):
		return ""

	var metadata: SkinMetadata = skins_index[skin_name]
	return metadata.path

## 获取皮肤索引
func get_skins_index() -> Dictionary:
	return skins_index

## 删除皮肤及其目录，并从 skins_index 移除
func remove_skin(skin_name: String) -> bool:
	if not skins_index.has(skin_name):
		GLogger.warning("remove_skin: skin not found: %s" % skin_name, "SkinMGR")
		return false

	var meta: SkinMetadata = skins_index[skin_name]
	if meta.is_builtin:
		GLogger.warning("remove_skin: cannot delete builtin skin: %s" % skin_name, "SkinMGR")
		return false

	var deleted := false
	# 删除皮肤目录
	if PathHelper.dir_exists(meta.path):
		deleted = FileSystemManager.instance.delete_directory_recursive(meta.path)
		if not deleted:
			GLogger.warning("remove_skin: failed to delete dir: %s" % meta.path, "SkinMGR")
	else:
		deleted = true  # 目录已不存在，算成功

	# 索引总是清理，避免残留条目
	skins_index.erase(skin_name)
	GLogger.info("Removed skin from index: %s (files deleted: %s)" % [skin_name, deleted], "SkinMGR")
	return deleted
