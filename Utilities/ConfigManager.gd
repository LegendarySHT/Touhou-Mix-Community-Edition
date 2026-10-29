## 统一配置管理器（单例）
## 集中管理所有INI/JSON配置文件的读取和写入，内部自动维护当前活跃配置
##
## ============ 按 key 访问（唯一推荐方式）============
## 配置键在整份 config.ini 中**全局唯一**（validate_defaults 每次启动自检）。
## 因此读写只需要 key，不需要 section：section 退化为「ini 文件里的排版分组」，
## 它跟随设置页分类走，重组分类不需要改任何模块代码，也不会因为写错 section 而静默读不到值。
##
##   ConfigManager.instance.load_and_set_current()
##   var lane_count = ConfigManager.instance.get_int("lane_count", 12)
##   ConfigManager.instance.set_value_and_notify("lane_count", 16)
##
## 覆盖外部配置字典时用第三参（读取）：
##   ConfigManager.instance.get_int("lane_count", 12, some_config)
##
## 写入一个**不在默认 config.ini 里**的运行时键时，用 section_hint 指定落点：
##   ConfigManager.instance.set_value("player_midi_linear", 0.8, "System")
##
## ============ 配置变更通知 ============
##   EvtBus.config_changed.connect(_on_config_changed)
##   func _on_config_changed(key: String, value: Variant):
##       print("配置已更改: %s = %s" % [key, str(value)])
## 订阅者只该按 key 判断；key == "*" 表示全量重载。

class_name ConfigManager
extends Node

# ============ 单例实现 ============

static var instance: ConfigManager:
	get:
		if _instance == null:
			_instance = ConfigManager.new()
			_instance.add_to_group("singletons")
		return _instance

static var _instance: ConfigManager = null

func _init() -> void:
	if _instance != null:
		push_error("ConfigManager is a singleton, use ConfigManager.instance instead")
		return

# ============ 配置路径 ============

## 默认配置文件路径（项目内置）
const DEFAULT_CONFIG_PATH = "res://Resources/Config/config.ini"

## 用户配置文件路径（通过 PathHelper 动态获取，兼容 Android 外部存储）
## 使用 getter 确保运行时才求值
static var USER_CONFIG_PATH: String:
	get: return PathHelper.get_user_config_path()

## 音源文件目录（通过 PathHelper 动态获取）
static var SOUNDFONT_DIR: String:
	get: return PathHelper.get_soundfont_dir()

## 配置版本号
## 2.0.0：section 按设置页分类重组（General/Audio/Gameplay/Performance/Appearance/System），
##        默认值统一由 config.ini 提供。旧版本用户配置会按 key 名自动迁移（见 check_and_migrate）。
const CONFIG_VERSION = "2.0.0"

## 当前版本使用的 section 集合。不在这个集合里的 section 视为历史结构，迁移时按键名搬迁。
## 注意：这份列表只服务于「迁移」与「section 合法性自检」，业务代码不该出现字符串 section。
const KNOWN_SECTIONS: Array[String] = [
	"General", "Audio", "Gameplay", "Performance", "Appearance", "System"
]

## 写入未登记的运行时键（不在默认 config.ini 里的键）时的兜底落点。
## 只在调用方没给 section_hint 且该键确实不存在时使用，并会 push_error 提示。
const FALLBACK_SECTION := "System"

# ============ 内部状态 ============

## 配置缓存 - 避免重复解析同一文件
var configs: Dictionary = {}

## 当前活跃的配置（合并了用户配置和默认配置）
var _current_config: Dictionary = {}

## key → section 反查索引。这是「只传 key」这套 API 的地基：
## 读取时用于定位值，写入时用于决定落到哪个 section。
## 由 _rebuild_key_index() 在每次配置结构变化后重建，不以独立副本缓存值（避免两份数据不同步）。
var _key_section: Dictionary = {}

# ============ 核心配置加载方法 ============

## 加载INI配置文件
## 若缓存中存在则直接返回，否则解析文件并缓存
## Android 平台特殊处理：res:// 路径资源在 PCK 包中
func load_config(file_path: String) -> Dictionary:
	# 检查缓存
	if configs.has(file_path):
		return configs[file_path]
	
	var content: String = ""
	
	# Android 平台 res:// 路径需要特殊处理
	if file_path.begins_with("res://"):
		# 检查资源是否存在于 PCK 包中
		if not FileAccess.file_exists(file_path):
			push_error("Config file not found in PCK: %s" % file_path)
			GLogger.error("Config file not found in PCK: %s [Check export settings]" % file_path, "ConfigManager")
			return {}
		
		var file = FileAccess.open(file_path, FileAccess.READ)
		if file == null:
			var error_code = FileAccess.get_open_error()
			push_error("Failed to open config from PCK: %s (Error: %d)" % [file_path, error_code])
			GLogger.error("Failed to open PCK config [%s] with error code %d" % [file_path, error_code], "ConfigManager")
			if file:
				file.close()
			return {}
		
		if file.get_length() == 0:
			GLogger.warning("Config file in PCK is empty: %s" % file_path, "ConfigManager")
			file.close()
			return {}
		
		content = file.get_as_text()
		file.close()
		GLogger.info("Config loaded from PCK: %s (size: %d bytes)" % [file_path, content.length()], "ConfigManager")
	else:
		# user:// 路径的常规加载
		if not FileAccess.file_exists(file_path):
			GLogger.warning("Config file not found in user://: %s" % file_path, "ConfigManager")
			return {}
		
		var file = FileAccess.open(file_path, FileAccess.READ)
		if file == null:
			var error_code = FileAccess.get_open_error()
			push_error("Failed to load config: %s (Error: %d)" % [file_path, error_code])
			GLogger.error("Failed to open user config [%s] with error code %d" % [file_path, error_code], "ConfigManager")
			return {}
		
		content = file.get_as_text()
		file.close()
		GLogger.info("Config loaded from user://: %s" % file_path, "ConfigManager")
	
	if content.is_empty():
		push_error("Config content is empty: %s" % file_path)
		GLogger.error("Config file is empty: %s" % file_path, "ConfigManager")
		return {}
	
	var result = IniParser.parse(content)
	
	if result.is_empty():
		GLogger.warning("Config parsed to empty dictionary: %s" % file_path, "ConfigManager")
	
	# 缓存结果
	configs[file_path] = result
	
	return result

## 加载配置文件并设置为当前活跃配置
## 优先加载用户配置，如果不存在或为空则加载默认配置
## 然后用默认配置补充缺失的部分
func load_and_set_current(_file_path: String = "") -> Dictionary:
	# 清除缓存以确保读取最新的文件内容
	configs.clear()
	
	var user_config = {}
	var default_config = {}
	
	# 优先加载用户配置
	if FileAccess.file_exists(USER_CONFIG_PATH):
		user_config = load_config(USER_CONFIG_PATH)
		if not user_config.is_empty():
			GLogger.info("User configuration loaded from %s" % USER_CONFIG_PATH, "ConfigManager")
		else:
			GLogger.warning("User configuration file is empty, will use default", "ConfigManager")
	else:
		GLogger.info("User configuration file not found at %s, will use default" % USER_CONFIG_PATH, "ConfigManager")
	
	# 加载默认配置用于补充
	default_config = load_config(DEFAULT_CONFIG_PATH)
	if default_config.is_empty():
		push_error("Failed to load default configuration")
		return {}
	
	# 合并配置：用户配置优先，默认配置补充缺失部分
	_current_config = merge_with_defaults(user_config, default_config)
	_prune_misplaced_keys()
	_rebuild_key_index()

	# 调试：打印当前配置的部分内容
	var section_count = _current_config.size()
	GLogger.info("Current configuration initialized with %d sections" % section_count, "ConfigManager")

	return _current_config

# ============ key → section 索引 ============

## 重建 key → section 反查索引。
## key 全局唯一是这套访问方式的前提，出现重复说明配置里有两份同名值：
## 正常路径上 _prune_misplaced_keys 已经清过一遍，这里再报错就是护栏（说明 prune 被绕过）。
func _rebuild_key_index() -> void:
	_key_section.clear()
	for section in _current_config.keys():
		var sec_data = _current_config[section]
		if not (sec_data is Dictionary):
			continue
		for key in sec_data.keys():
			if _key_section.has(key):
				if _key_section[key] != section:
					push_error("[Config] key 重复: %s 同时存在于 [%s] 和 [%s]，按 [%s] 定位" % [
						key, _key_section[key], section, _key_section[key]])
				continue
			_key_section[key] = section

## 清除「不在自己家」的重复键。
## 规则（以默认 config.ini 的归属为唯一权威）：
##   权威 section 里的值仍是默认值（或缺失）→ 用错位处那份（那是用户真正改过的），搬回权威 section；
##   权威 section 里已是非默认值            → 保留它，丢弃错位那份。
## 不在默认配置里的运行时键（如播放器音量）不参与本流程。
func _prune_misplaced_keys(config: Variant = null) -> int:
	if config == null:
		config = _current_config
	if not (config is Dictionary):
		return 0
	var default_config = load_config(DEFAULT_CONFIG_PATH)
	if default_config.is_empty():
		return 0

	# key → 权威 section
	var owner := {}
	for section in default_config.keys():
		var sec_data = default_config[section]
		if sec_data is Dictionary:
			for key in sec_data.keys():
				owner[key] = section

	var removed := 0
	var moved: Array[String] = []
	for section in config.keys():
		if section is not String or not (config[section] is Dictionary):
			continue
		var stray: Array[String] = []
		for key in config[section].keys():
			if owner.has(key) and owner[key] != section:
				stray.append(key)
		for key in stray:
			var home: String = owner[key]
			var value: Variant = config[section][key]
			if not (config.get(home, null) is Dictionary):
				config[home] = {}
			var home_value: Variant = config[home].get(key, null)
			var home_default: Variant = default_config[home].get(key, null)
			if home_value == null or str(home_value) == str(home_default):
				config[home][key] = value
				moved.append("%s → [%s]（取错位值）" % [key, home])
			else:
				moved.append("%s → 丢弃 [%s] 的重复值" % [key, section])
			config[section].erase(key)
			removed += 1

	if removed > 0:
		GLogger.warning("[Config] 清理了 %d 个错位/重复键（以默认 config.ini 归属为准）：%s" % [
			removed, ", ".join(moved)], "ConfigManager")
	return removed

## 查某个 key 在指定配置里的 section。
## 优先走索引；索引未覆盖（传入了外部配置字典、或是刚写入的运行时键）时退化为线性搜索。
func _section_of_key(key: String, config: Dictionary) -> String:
	var section: String = _key_section.get(key, "")
	if not section.is_empty():
		var sec_data = config.get(section, null)
		if sec_data is Dictionary and sec_data.has(key):
			return section
	return _find_section_of_key(key, config)

## 决定一次写入该落到哪个 section。
## 顺序：key 已有归属 → 用它（同一 key 永远只有一处家，不会因为传错 section 再分裂一份）；
##       key 未登记 → 用 section_hint（运行时键）；
##       都没有 → 返回空串，由调用方报错兜底。
func _resolve_write_section(key: String, section_hint: String, config: Dictionary) -> String:
	var section := _section_of_key(key, config)
	if not section.is_empty():
		return section
	if section_hint.is_empty():
		return ""
	_key_section[key] = section_hint
	return section_hint

# ============ 配置读取方法 ============

## 获取配置值
## 用法：get_value("lane_count", 12)
## 指定配置字典：get_value("lane_count", 12, some_config)
func get_value(key: String, default: Variant = "", config: Variant = null) -> Variant:
	if config == null or not (config is Dictionary):
		config = _current_config
	
	var section := _section_of_key(key, config)
	if not section.is_empty():
		return config[section][key]
	
	GLogger.warning("Config key not found: %s, using default value: %s" % [key, str(default)], "ConfigManager")
	return default

## 获取整数值
func get_int(key: String, default: int = 0, config: Variant = null) -> int:
	var value = get_value(key, str(default), config)
	return int(value)

## 获取浮点值
func get_float(key: String, default: float = 0.0, config: Variant = null) -> float:
	var value = get_value(key, str(default), config)
	return float(value)

## 获取布尔值
func get_bool(key: String, default: bool = false, config: Variant = null) -> bool:
	var value = get_value(key, str(default), config)
	return parse_bool(value, default)

## 类型安全的布尔解析：兼容 bool / int / float / 字符串（含 "1"/"true"/"yes"/"on"）
## 配置链中同一 key 可能以字符串（INI 解析）或 typed 值（set_value_and_notify）存在，
## 统一在此转换，避免对非字符串调用字符串方法导致运行时错误。
static func parse_bool(value: Variant, default: bool = false) -> bool:
	if value is bool:
		return value
	if value is int or value is float:
		return value != 0
	var s := str(value).strip_edges().to_lower()
	if s.is_empty():
		return default
	return s in ["1", "true", "yes", "on"]

func get_string(key: String, default: String = "", config: Variant = null) -> String:
	return str(get_value(key, default, config))

## 查询某个 key 当前归属的 section（诊断用；业务逻辑不该依赖它）
func get_section_of(key: String) -> String:
	return _section_of_key(key, _current_config)

# ============ 配置写入方法 ============

## 设置配置值并发送变更通知
## 用法：set_value_and_notify("lane_count", 16)
## 写入未登记键：set_value_and_notify("player_midi_linear", 0.8, "System")
func set_value_and_notify(key: String, value: Variant, section_hint: String = "", config: Variant = null) -> void:
	if config == null:
		config = _current_config
	
	var section := _resolve_write_section(key, section_hint, config)
	if section.is_empty():
		push_error("[Config] 未登记的配置键: %s（默认 config.ini 里没有它，也没给 section_hint）" % key)
		section = FALLBACK_SECTION
	
	if not (config.get(section, null) is Dictionary):
		config[section] = {}
	
	var old_value = config[section].get(key, null)
	config[section][key] = value
	
	# 只有当值确实改变时才发送通知
	# 使用字符串比较避免类型不匹配错误（例如 "0" vs 0）
	var old_value_str = str(old_value) if old_value != null else ""
	var new_value_str = str(value)
	
	if old_value_str != new_value_str:
		if EvtBus != null:
			EvtBus.config_changed.emit(key, value)
		GLogger.info("Config changed: %s = %s (in [%s])" % [key, str(value), section], "ConfigManager")

## 设置单个配置值（不发送通知）
## 用于批量修改配置后再统一保存，避免发送过多信号
func set_value(key: String, value: Variant, section_hint: String = "", config: Variant = null) -> void:
	if config == null:
		config = _current_config
	
	var section := _resolve_write_section(key, section_hint, config)
	if section.is_empty():
		push_error("[Config] 未登记的配置键: %s（默认 config.ini 里没有它，也没给 section_hint）" % key)
		section = FALLBACK_SECTION
	
	if not (config.get(section, null) is Dictionary):
		config[section] = {}
	config[section][key] = value

## 保存配置到INI文件
func save_config(file_path: String, config: Variant = null) -> bool:
	if config == null:
		config = _current_config
	
	var content = _serialize_ini(config)
	
	# 确保目标目录存在（Android 外部存储路径可能首次使用时不存在）
	var dir_path = file_path.get_base_dir()
	PathHelper.ensure_dir_exists(dir_path)
	
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		push_error("Failed to save config: %s (Error: %d)" % [file_path, FileAccess.get_open_error()])
		return false
	
	file.store_string(content)
	file.close()
	
	# 清除该文件的缓存，避免后续加载读到旧缓存
	# 同时更新为最新的配置
	configs[file_path] = config
	if file_path == USER_CONFIG_PATH:
		# 用户配置可能只包含部分 section：先与默认配置合并再作为当前活跃配置，
		# 避免部分写入后默认 section/key 从内存配置中丢失
		var default_config = load_config(DEFAULT_CONFIG_PATH)
		_current_config = merge_with_defaults(config, default_config) if not default_config.is_empty() else config
		_prune_misplaced_keys()
		_rebuild_key_index()
	
	GLogger.info("Config saved to: %s" % file_path, "ConfigManager")
	return true

## 序列化配置字典为INI格式
func _serialize_ini(config: Dictionary) -> String:
	var result = ""
	
	for section in config.keys():
		result += "[%s]\n" % section
		
		var section_data = config[section]
		if section_data is Dictionary:
			for key in section_data.keys():
				var value = section_data[key]
				
				var value_str = str(value)
				# 处理需要引号的值（含空白/空串/引号/分号/等号/换行等，转义后写入）
				if value is String and _needs_ini_quoting(value_str):
					result += "%s = \"%s\"\n" % [key, _escape_ini_value(value_str)]
				else:
					result += "%s = %s\n" % [key, value_str]
		
		result += "\n"
	
	return result

## 判断字符串值是否需要加引号并转义
func _needs_ini_quoting(value: String) -> bool:
	return value.is_empty() \
		or value != value.strip_edges() \
		or "\"" in value \
		or ";" in value \
		or "=" in value \
		or "\n" in value \
		or "\r" in value

## 转义 INI 字符串值（与 IniParser._unescape_value 对称）
func _escape_ini_value(value: String) -> String:
	return value \
		.replace("\\", "\\\\") \
		.replace("\"", "\\\"") \
		.replace("\n", "\\n") \
		.replace("\r", "\\r")

# ============ 配置管理高级方法 ============

## 合并配置与默认值（用于兼容性）
## 将用户配置与默认配置合并，用户设置优先
func merge_with_defaults(user_config: Dictionary, default_config: Dictionary) -> Dictionary:
	var merged = default_config.duplicate(true)
	
	for section in user_config.keys():
		if not merged.has(section):
			merged[section] = {}
		
		var user_section = user_config[section]
		if user_section is Dictionary:
			for key in user_section.keys():
				merged[section][key] = user_section[key]
	
	return merged

## 清空缓存
func clear_cache() -> void:
	configs.clear()
	GLogger.info("Config cache cleared", "ConfigManager")

## 获取当前活跃配置
func get_current_config() -> Dictionary:
	return _current_config

## 重新加载配置（优先用户配置）
## 清空缓存后重新加载用户配置和默认配置，然后合并以确保完整性
func reload_config() -> bool:
	# 清除所有缓存以确保读取最新文件
	clear_cache()
	
	# 优先加载用户配置
	var user_config = {}
	if FileAccess.file_exists(USER_CONFIG_PATH):
		user_config = load_config(USER_CONFIG_PATH)
		if not user_config.is_empty():
			GLogger.info("User configuration reloaded from %s" % USER_CONFIG_PATH, "ConfigManager")
		else:
			GLogger.warning("User configuration file is empty, using default", "ConfigManager")
	else:
		GLogger.warning("User configuration file not found at %s, using default" % USER_CONFIG_PATH, "ConfigManager")
	
	# 加载默认配置来补充缺失部分
	var default_config = load_config(DEFAULT_CONFIG_PATH)
	if default_config.is_empty():
		push_error("Failed to load default configuration")
		return false
	
	# 合并配置：用户配置优先
	_current_config = merge_with_defaults(user_config, default_config)
	_prune_misplaced_keys()
	_rebuild_key_index()
	
	# 发送批量变更通知
	if EvtBus != null:
		EvtBus.config_changed.emit("*", null)  # 通配符表示全量变更
	
	GLogger.info("Configuration reload complete with user priority", "ConfigManager")
	return true

## 检查并迁移配置版本
## 版本不匹配时按 **key 名** 迁移：从旧结构 section 里逐个取出键，到新默认配置里找它
## 现在属于哪个 section，再写过去。key 全局唯一（同一个键不会出现在两个 section），
## 所以即使 section 全部改名，用户的值也不会丢。
## 已是新结构的 section 里的用户值优先保留（那是用户在当前版本写过的）。
func check_and_migrate(config: Variant = null, file_path: String = "") -> Dictionary:
	if config == null:
		config = _current_config

	if not (config is Dictionary):
		return {}

	var version = str(get_value("config_version", "0.0.0", config))
	if version == CONFIG_VERSION:
		GLogger.debug("Configuration version is current", "ConfigManager")
		return config

	# 默认配置作为迁移骨架：新 section、新键、新默认值都从它来
	var default_config = load_config(DEFAULT_CONFIG_PATH)
	if default_config.is_empty():
		push_error("Failed to load default config for migration")
		GLogger.error("Migration aborted: default config missing", "ConfigManager")
		return config

	GLogger.info("Migrating config from %s to %s (by key name)" % [version, CONFIG_VERSION], "ConfigManager")
	var migrated: Dictionary = default_config.duplicate(true)

	# 1) 当前结构的 section：用户写过的值覆盖默认层
	for section in config.keys():
		if not (section in KNOWN_SECTIONS):
			continue
		if not migrated.has(section) or not (migrated[section] is Dictionary):
			continue
		var sec_data = config[section]
		if not (sec_data is Dictionary):
			continue
		for key in sec_data.keys():
			migrated[section][key] = sec_data[key]

	# 2) 历史 section：按 key 名搬到它现在所属的 section
	var moved := 0
	var dropped: Array[String] = []
	for section in config.keys():
		if section in KNOWN_SECTIONS:
			continue
		if not (config[section] is Dictionary):
			continue
		for key in config[section].keys():
			var target := _find_section_of_key(key, migrated)
			if target.is_empty():
				dropped.append("%s/%s" % [section, key])
				continue
			migrated[target][key] = config[section][key]
			moved += 1

	GLogger.info("Migration moved %d keys, dropped %d obsolete" % [moved, dropped.size()], "ConfigManager")
	if not dropped.is_empty():
		GLogger.info("Dropped obsolete keys: %s" % ", ".join(dropped), "ConfigManager")

	if not migrated.has("System"):
		migrated["System"] = {}
	migrated["System"]["config_version"] = CONFIG_VERSION

	var save_path = USER_CONFIG_PATH if file_path.is_empty() else file_path
	if save_config(save_path, migrated):
		GLogger.info("Configuration migrated and saved to %s" % save_path, "ConfigManager")
	else:
		GLogger.warning("Failed to save migrated configuration", "ConfigManager")

	_current_config = migrated
	_prune_misplaced_keys()
	_rebuild_key_index()
	return migrated

## 在配置里查某个 key 现在属于哪个 section。
## key 全局唯一是本函数成立的前提（见 config.ini 头部说明与 validate_defaults 自检）。
func _find_section_of_key(key: String, config: Dictionary) -> String:
	for section in config.keys():
		var sec_data = config[section]
		if sec_data is Dictionary and sec_data.has(key):
			return String(section)
	return ""

## 启动自检：默认值只在 config.ini 一处维护，本函数就是这条约定的护栏。
## 检查三件事：
##   1. SettingsMapper 里声明的每个 key 在默认 config.ini 中确实存在；
##      缺失意味着该项永远拿不到默认值（UI 空、或代码里的兜底值悄悄生效）。
##   2. key 在整份默认配置里全局唯一——「只传 key 读写」与迁移（按 key 名搬 section）
##      两条路径都依赖这一点，重复会让一个键同时存在两份值。
##   3. config.ini 自己的 config_version 与常量一致。
## 返回 false 时说明配置有结构性错误，但不会中断启动（仍用现有默认值运行）。
func validate_defaults() -> bool:
	var default_config = load_config(DEFAULT_CONFIG_PATH)
	if default_config.is_empty():
		push_error("[Config] 默认配置加载失败，无法校验: %s" % DEFAULT_CONFIG_PATH)
		GLogger.error("validate_defaults: default config unavailable", "ConfigManager")
		return false

	# key 唯一性（先建，缺键检查也走它）
	var seen := {}
	var dup: Array[String] = []
	for section in default_config.keys():
		var sec_data = default_config[section]
		if not (sec_data is Dictionary):
			continue
		for key in sec_data.keys():
			if seen.has(key):
				dup.append("%s（[%s] 与 [%s]）" % [key, seen[key], section])
			else:
				seen[key] = section

	var missing: Array[String] = []
	for setting_id in SettingsMapper.mappings.keys():
		var m: Dictionary = SettingsMapper.mappings[setting_id]
		var key: String = m.get("key", "")
		if key.is_empty():
			missing.append("%s -> 映射缺 key" % setting_id)
			continue
		if not seen.has(key):
			missing.append("%s -> %s" % [setting_id, key])

	if missing.is_empty() and dup.is_empty():
		# 默认文件自己的版本号必须与常量一致：不一致时每个新用户首次启动都会白跑一次迁移
		var ini_version := str(default_config.get("System", {}).get("config_version", ""))
		if ini_version != CONFIG_VERSION:
			push_error("[Config] config.ini 的 config_version=%s 与 CONFIG_VERSION=%s 不一致" % [ini_version, CONFIG_VERSION])
			GLogger.error("validate_defaults: version mismatch in default config", "ConfigManager")
			return false
		GLogger.info("validate_defaults OK: %d 项映射全部命中默认配置，%d 个 key 无重复，版本 %s" % [
			SettingsMapper.mappings.size(), seen.size(), CONFIG_VERSION], "ConfigManager")
		return true

	for item in missing:
		push_error("[Config] 默认配置缺少映射项: %s（应补进 config.ini 对应 section）" % item)
	for item in dup:
		push_error("[Config] key 重复: %s（按 key 读写与迁移都要求全局唯一）" % item)
	GLogger.error("validate_defaults 失败：缺 %d 项，重复 %d 项" % [missing.size(), dup.size()], "ConfigManager")
	return false

# ============ JSON 文件操作方法 ============

## 加载JSON文件
func load_json_file(file_path: String) -> Dictionary:
	if not FileAccess.file_exists(file_path):
		return {}
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		GLogger.warning("Failed to open JSON file: %s" % file_path, "ConfigManager")
		return {}
	
	var content = file.get_as_text()
	var json = JSON.parse_string(content)
	
	if json == null:
		GLogger.warning("Failed to parse JSON file: %s" % file_path, "ConfigManager")
		return {}
	
	return json if json is Dictionary else {}

## 保存JSON文件（合并模式：保留原有字段，补充新字段）
## 参数merge_existing决定是否合并现有文件内容
func save_json_file(file_path: String, data: Dictionary, merge_existing: bool = true) -> bool:
	var final_data = data
	
	# 如果启用合并模式且文件存在，先读取现有内容
	if merge_existing and FileAccess.file_exists(file_path):
		var existing = load_json_file(file_path)
		if not existing.is_empty():
			# 深度合并：保留所有原有字段，覆盖或添加新字段
			for key in data.keys():
				existing[key] = data[key]
			final_data = existing
	
	# 序列化为JSON字符串
	var json_str = JSON.stringify(final_data)
	
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		push_error("Failed to save JSON file: %s (Error: %d)" % [file_path, FileAccess.get_open_error()])
		return false
	
	file.store_string(json_str)
	file.close()
	
	GLogger.info("JSON file saved to: %s" % file_path, "ConfigManager")
	return true
