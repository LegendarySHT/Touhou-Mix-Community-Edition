## 粒子管理器
## 负责管理粒子包的扫描、配置加载与精灵图获取
## 支持内置粒子（res://Resources/Particles）与用户粒子（user://files/Particles）统一管理
## 结构参考 SkinManager：
##   粒子包目录下含 particle.ini（配置）+ 若干精灵图（序列帧 spritesheet）
##   particle.ini 声明单帧尺寸/总帧数/帧率/是否循环/是否淡出，以及粒子角色：
##     [base] 节：基础粒子精灵图（游戏「基础粒子」下拉选择此包时播放）
##     [emitter] 节：发射器/散射粒子精灵图（游戏「散射粒子」下拉选择此包时播放）
##   一个包可同时声明两种角色；每个角色 file 可声明多张精灵图（逗号分隔），
##   播放时随机选取一张，用于表现「同角色下发射规律随机轮换」的粒子
##   每个角色还可声明 rotation（随机旋转角度，规格见 _parse_rotation）：空/缺省不旋转
extends Node

class_name ParticleManager

## ========== 目录路径定义（通过 PathHelper 动态获取） ==========
static var PARTICLES_DIR: String:
	get: return PathHelper.get_particles_dir()

## 内置粒子源目录
const DEFAULT_PARTICLES_SRC = "res://Resources/Particles/"

## 粒子包配置文件名（放在粒子包目录下）
const PARTICLE_CONFIG_FILE = "particle.ini"

## 内置包显示后缀（与皮肤一致）
const BUILTIN_SUFFIX = " [内置]"

## 粒子角色（对应 particle.ini 的 [base]/[emitter] 节）
const ROLE_BASE: String = "base"
const ROLE_EMITTER: String = "emitter"

## ========== 资源索引 ==========
## 粒子包索引 {pack_key: Dictionary}
## pack_key = 文件夹名（内置加 [内置] 后缀）
## 字段：{name, path, is_builtin, size, frame, fps, loop, fade_out, cols, rows,
##        base_files, emitter_files, base_rotation, emitter_rotation}
##   base_files:    [基础粒子精灵图文件名, ...]（多图时播放随机选取）
##   emitter_files: [发射器/散射粒子精灵图文件名, ...]（多图时播放随机选取）
var particles_index: Dictionary = {}

## 基础粒子精灵图缓存 {pack_key: Array[Texture2D]}（get_base_textures 结果）
var _base_texture_cache: Dictionary = {}

## 发射器粒子精灵图缓存 {pack_key: Array[Texture2D]}（get_emitter_textures 结果）
var _emitter_texture_cache: Dictionary = {}

## 包层模板缓存 {role + "|" + pack_key: Dictionary}（get_layer_template 结果）
## 预烘焙包级静态元数据，spawn 时免重复字段解析；粒子包重扫时随 clear_index 清空
var _layer_template_cache: Dictionary = {}

func _ready() -> void:
	add_to_group("singleton")
	GLogger.info("ParticleManager initialized (deferred scan)", "ParticleMGR")

## 清空粒子索引（由 FileSystemManager._scan_all_resources 统一扫描前调用）
func clear_index() -> void:
	particles_index.clear()
	_base_texture_cache.clear()
	_emitter_texture_cache.clear()
	_layer_template_cache.clear()



## 删除用户粒子包（内置包不可删）。返回目录是否成功删除。
## 索引/缓存即使目录删除失败也一并清理，避免列表残留已坏条目（与 SkinManager.remove_skin 语义一致）。
func remove_particle_pack(pack_key: String) -> bool:
	var data: Dictionary = particles_index.get(pack_key, {})
	if data.is_empty():
		return false
	if bool(data.get("is_builtin", false)):
		return false
	var path := str(data.get("path", ""))
	var deleted := true
	if not path.is_empty() and DirAccess.dir_exists_absolute(path):
		deleted = FileSystemManager.instance.delete_directory_recursive(path)
	particles_index.erase(pack_key)
	_base_texture_cache.erase(pack_key)
	_emitter_texture_cache.erase(pack_key)
	_layer_template_cache.erase(ROLE_BASE + "|" + pack_key)
	_layer_template_cache.erase(ROLE_EMITTER + "|" + pack_key)
	return deleted

## ========== 扫描 ==========

## 扫描粒子包目录（worker 线程执行）
## 先扫内置（res://），再扫用户（user://），结果经 result_wrapper 回传主线程合并
func _build_particles_index_worker(result_wrapper: Dictionary) -> void:
	var local_particles: Dictionary = {}
	var local_logs: Array = []
	_scan_dir_worker(DEFAULT_PARTICLES_SRC, true, local_particles, local_logs)
	_scan_dir_worker(PARTICLES_DIR, false, local_particles, local_logs)
	result_wrapper["particles"] = local_particles
	result_wrapper["logs"] = local_logs

## worker 内部：扫描单个粒子目录
## 只收集含 particle.ini 的文件夹；日志收集到数组（worker 线程不直接调 GLogger）
func _scan_dir_worker(dir_path: String, is_builtin: bool, local_particles: Dictionary, local_logs: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var folder_name := dir.get_next()
	while folder_name != "":
		if not dir.current_is_dir() or folder_name.begins_with("."):
			folder_name = dir.get_next()
			continue
		var pack_path := dir_path.path_join(folder_name)
		var pack_key := folder_name + (BUILTIN_SUFFIX if is_builtin else "")
		var data := _load_pack_worker(pack_path, pack_key, is_builtin, local_logs)
		if not data.is_empty():
			local_particles[pack_key] = data
		folder_name = dir.get_next()
	dir.list_dir_end()

## worker 内部：加载单个粒子包（解析 particle.ini + 校验精灵图存在性）
## 返回空 Dictionary 表示不是有效粒子包（无 particle.ini / 配置损坏 / 无精灵图）
func _load_pack_worker(pack_path: String, pack_key: String, is_builtin: bool, local_logs: Array) -> Dictionary:
	var config_path := pack_path.path_join(PARTICLE_CONFIG_FILE)
	if not PathHelper.file_exists(config_path):
		return {}

	var file := FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		return {}
	var content := file.get_as_text()
	file.close()

	# 复用项目通用 INI 解析逻辑（段→键→字符串值）
	var raw := IniParser.parse(content)
	if raw.is_empty():
		return {}

	var normalized := _normalize_pack_config(raw, local_logs)
	if normalized.is_empty():
		local_logs.append({"msg": "Particle pack config invalid (missing size): %s" % config_path, "is_warning": true})
		return {}

	# 校验至少存在一张精灵图（基础或发射器任一角色），否则视为无效包
	if not _has_any_sprite(pack_path, normalized.get("base_files", []), normalized.get("emitter_files", [])):
		local_logs.append({"msg": "Particle pack has no sprites: %s" % pack_path, "is_warning": true})
		return {}

	return {
		"name": pack_key,
		"path": pack_path,
		"is_builtin": is_builtin,
		"size": normalized.get("size", 0),
		"frame": normalized.get("frame", 0),
		"fps": normalized.get("fps", 30.0),
		"loop": normalized.get("loop", false),
		"fade_out": normalized.get("fade_out", true),
		"cols": normalized.get("cols", 0),
		"rows": normalized.get("rows", 0),
		"base_files": normalized.get("base_files", []),
		"emitter_files": normalized.get("emitter_files", []),
		"base_rotation": normalized.get("base_rotation", null),
		"emitter_rotation": normalized.get("emitter_rotation", null),
	}

## 将 INI 解析结果 {section: {key: str}} 规范化为带类型的结构化 Dictionary
## 缺失键用默认值补全；无有效 size 返回空 Dictionary（调用方视为无效包）
func _normalize_pack_config(raw: Dictionary, local_logs: Array) -> Dictionary:
	var general: Dictionary = raw.get("general", {})
	var size := int(general.get("size", "0"))
	if size <= 0:
		return {}

	var frame := int(general.get("frame", "0"))
	if frame < 0:
		frame = 0
	var fps := float(general.get("fps", "30"))
	if fps <= 0.0:
		fps = 30.0
	var cols := int(general.get("cols", "0"))
	var rows := int(general.get("rows", "0"))

	# 基础粒子与发射器粒子各自声明精灵图（file 逗号分隔，多图时播放随机选取）
	var base_files := _parse_file_list(raw.get(ROLE_BASE, {}).get("file", ""))
	var emitter_files := _parse_file_list(raw.get(ROLE_EMITTER, {}).get("file", ""))

	# 每层可声明随机旋转角度（rotation 键，规格同旧 particle_rotation）：
	#   [a,b,c] 离散集 / a,b 连续范围 / 单值固定；空或非法 → null（不旋转）
	var base_rotation = _parse_rotation(raw.get(ROLE_BASE, {}).get("rotation", ""), local_logs)
	var emitter_rotation = _parse_rotation(raw.get(ROLE_EMITTER, {}).get("rotation", ""), local_logs)

	return {
		"size": size,
		"frame": frame,
		"fps": fps,
		"loop": _parse_bool(general.get("loop", "false")),
		"fade_out": _parse_bool(general.get("fade_out", "true")),
		"cols": cols,
		"rows": rows,
		"base_files": base_files,
		"emitter_files": emitter_files,
		"base_rotation": base_rotation,
		"emitter_rotation": emitter_rotation,
	}

## 解析节内 file 键：支持逗号分隔的多精灵图列表（随机选取用）
## 单文件 / 空值 / 带空格逗号 均兼容
func _parse_file_list(file_value: Variant) -> Array[String]:
	var list: Array[String] = []
	if file_value == null:
		return list
	var text := str(file_value)
	for part in text.split(",", false):
		var file_name := part.strip_edges()
		if not file_name.is_empty():
			list.append(file_name)
	return list

## 解析随机旋转规格，返回 null（不旋转）或 {mode, ...}：
##   [a,b,c] → {mode: "set",   values: [a, b, c]}（每次播放从列出的角度随机取一个）
##   a,b     → {mode: "range", min: a, max: b}（连续范围内随机，min/max 自动交换）
##   45      → {mode: "fixed", value: 45}（固定角度）
##   空值/非法 → null（不旋转）
func _parse_rotation(value: Variant, local_logs: Array) -> Variant:
	if value == null:
		return null
	var text := str(value).strip_edges()
	if text.is_empty():
		return null
	# 方括号包裹 = 离散集 [a,b,c]
	if text.begins_with("[") and text.ends_with("]"):
		var values: Array[float] = []
		for part in text.substr(1, text.length() - 2).split(",", false):
			var v := part.strip_edges()
			if not v.is_empty() and v.is_valid_float():
				values.append(float(v))
		if not values.is_empty():
			return {"mode": "set", "values": values}
		return null
	# 逗号分隔两值 = 连续范围 a,b（超过两个值视为配置笔误，告警并取前两个）
	var parts := text.split(",", false)
	if parts.size() >= 2:
		var a := parts[0].strip_edges()
		var b := parts[1].strip_edges()
		if a.is_valid_float() and b.is_valid_float():
			if parts.size() > 2:
				local_logs.append({
					"msg": "particle rotation=%s 含 %d 个逗号分隔值，按前两个作连续范围，多余忽略" % [text, parts.size()],
					"is_warning": true,
				})
			var lo := minf(float(a), float(b))
			var hi := maxf(float(a), float(b))
			return {"mode": "range", "min": lo, "max": hi}
		return null
	# 单值 = 固定角度
	if text.is_valid_float():
		return {"mode": "fixed", "value": float(text)}
	return null

## 检查粒子包目录下是否至少存在一张配置声明的精灵图（基础或发射器）
## res:// 走 ResourceLoader（导出后源图以 .ctex 存在，FileAccess 不可读），user:// 走文件存在性检查
func _has_any_sprite(pack_path: String, base_files: Array, emitter_files: Array) -> bool:
	for file_name in base_files:
		if _sprite_exists(pack_path, file_name):
			return true
	for file_name in emitter_files:
		if _sprite_exists(pack_path, file_name):
			return true
	return false

## 单张精灵图存在性检查（空名视为不存在）
func _sprite_exists(pack_path: String, file_name: String) -> bool:
	if file_name.is_empty():
		return false
	var file_path := pack_path.path_join(file_name)
	if file_path.begins_with("res://"):
		return ResourceLoader.exists(file_path)
	return PathHelper.file_exists(file_path)

## 将字符串解析为 bool（接受 "true"/"false"/"1"/"0"）
func _parse_bool(value) -> bool:
	if value is bool:
		return value
	var s := str(value).to_lower()
	return s == "true" or s == "1"

## ========== 查询接口 ==========

## 获取全部粒子包键（按名称排序，保证跨平台/跨枚举顺序的 preset 索引稳定）
func get_particle_list() -> Array:
	var keys := particles_index.keys()
	keys.sort_custom(func(a: String, b: String) -> bool:
		return a.to_lower() < b.to_lower()
	)
	return keys

## 获取粒子包数据（未找到返回空 Dictionary）
func get_particle_data(pack_key: String) -> Dictionary:
	return particles_index.get(pack_key, {})

## 按预设索引取粒子包键（索引 0 = None，1 起对应 get_particle_list() 顺序）
## 越界返回空字符串
func get_particle_pack_by_index(index: int) -> String:
	if index <= 0:
		return ""
	var list := get_particle_list()
	if index > list.size():
		return ""
	return list[index - 1]

## 按粒子包名字取包键（config 用包名字而非数字索引，避免新增粒子包导致索引错位）
## 精确匹配包键；找不到（包被删除/改名/值为旧数字格式）返回空 = None（无特效）
func get_particle_pack_by_name(pack_name: String) -> String:
	if pack_name.is_empty():
		return ""
	return pack_name if particles_index.has(pack_name) else ""

## 获取声明了指定角色精灵图的粒子包键列表（按名称排序）
## role: ROLE_BASE / ROLE_EMITTER；供设置弹窗按角色过滤下拉选项
## 一个包声明了 [base]+[emitter] 时会同时出现在两个角色列表里
func get_particle_list_for_role(role: String) -> Array:
	var result: Array = []
	for pack_key in particles_index.keys():
		var files: Array = particles_index[pack_key].get(role + "_files", [])
		if not files.is_empty():
			result.append(pack_key)
	result.sort_custom(func(a: String, b: String) -> bool: return a.to_lower() < b.to_lower())
	return result

## 获取包在指定角色下的预烘焙模板（纹理列表 + 网格/帧率/帧数/淡出/旋转规格等静态元数据）
## role: ROLE_BASE / ROLE_EMITTER。模板缓存复用，spawn 时只做随机选图 + 旋转采样 + 尺寸换算，
## 免每次 spawn 重复字段解析与网格推导。无效包/缺精灵图返回空 Dictionary
func get_layer_template(pack_key: String, role: String) -> Dictionary:
	var cache_key := role + "|" + pack_key
	if _layer_template_cache.has(cache_key):
		return _layer_template_cache[cache_key]
	var tpl := _build_layer_template(pack_key, role)
	_layer_template_cache[cache_key] = tpl
	return tpl

## 构建单个包层模板（网格推导/帧数截断/帧率容错，与播放器 Layer 原初始化逻辑一致）
func _build_layer_template(pack_key: String, role: String) -> Dictionary:
	var data := get_particle_data(pack_key)
	if data.is_empty():
		return {}
	var textures := get_emitter_textures(pack_key) if role == ROLE_EMITTER else get_base_textures(pack_key)
	if textures.is_empty():
		return {}
	var source_size := float(data.get("size", 0))
	if source_size <= 0.0:
		return {}
	# 网格：优先配置显式 cols/rows，否则按贴图尺寸 / 单帧尺寸推导
	var tex: Texture2D = textures[0]
	var tex_w := tex.get_width()
	var tex_h := tex.get_height()
	var cfg_cols := int(data.get("cols", 0))
	var cfg_rows := int(data.get("rows", 0))
	var cols: int
	if cfg_cols > 0:
		cols = cfg_cols
	elif tex_w > 0:
		@warning_ignore("integer_division")
		cols = maxi(1, tex_w / int(source_size))
	else:
		cols = 1
	var rows: int
	if cfg_rows > 0:
		rows = cfg_rows
	elif tex_h > 0:
		@warning_ignore("integer_division")
		rows = maxi(1, tex_h / int(source_size))
	else:
		rows = 1
	# 帧数：配置显式声明优先，否则网格全部帧；超出网格可用帧时截断
	var cfg_frame := int(data.get("frame", 0))
	var available := cols * rows
	var frame_count: int = cfg_frame if cfg_frame > 0 else available
	frame_count = clampi(frame_count, 1, available)
	var fps := float(data.get("fps", 30.0))
	if fps <= 0.0:
		fps = 30.0
	return {
		"textures": textures,
		"size": source_size,
		"fps": fps,
		"loop": bool(data.get("loop", false)),
		"fade_out": bool(data.get("fade_out", true)),
		"cols": cols,
		"rows": rows,
		"frame_count": frame_count,
		"rotation_spec": data.get("emitter_rotation" if role == ROLE_EMITTER else "base_rotation", null),
	}

## 获取粒子包在基础角色下可用的全部精灵图（Texture2D 列表）
## 返回列表可能为空（该包未声明 [base]，播放器会透明跳过基础层）
func get_base_textures(pack_key: String) -> Array:
	return _get_role_textures(pack_key, ROLE_BASE, _base_texture_cache)

## 获取粒子包在发射器角色下可用的全部精灵图（Texture2D 列表）
## 返回列表可能为空（该包未声明 [emitter]，播放器会透明跳过发射器层）
func get_emitter_textures(pack_key: String) -> Array:
	return _get_role_textures(pack_key, ROLE_EMITTER, _emitter_texture_cache)

## 通用角色精灵图查询（带缓存，避免反复读盘）
func _get_role_textures(pack_key: String, role: String, cache: Dictionary) -> Array:
	if cache.has(pack_key):
		return cache[pack_key]
	var result: Array = []
	var data := get_particle_data(pack_key)
	if not data.is_empty():
		var pack_path: String = data.get("path", "")
		var files: Array = data.get(role + "_files", [])
		result = _load_sprite_list(pack_path, files)
	cache[pack_key] = result
	return result

## 加载一组精灵图文件名，返回成功加载的 Texture2D 列表（失败项自动跳过）
func _load_sprite_list(pack_path: String, file_list: Array) -> Array:
	var result: Array = []
	for file_name in file_list:
		if file_name.is_empty():
			continue
		var tex := _try_load_sprite(pack_path, file_name)
		if tex != null:
			result.append(tex)
	return result

## 加载单张精灵图：内置走 ResourceLoader，用户目录走 Image 动态加载
func _try_load_sprite(pack_path: String, file_name: String) -> Texture2D:
	if file_name.is_empty():
		return null
	var file_path := pack_path.path_join(file_name)
	if file_path.begins_with("res://"):
		if ResourceLoader.exists(file_path):
			return load(file_path)
		return null
	if PathHelper.file_exists(file_path):
		var image := ImageUtil.load_image_file(file_path)
		if image:
			return ImageTexture.create_from_image(image)
	return null

## 清空精灵图缓存（粒子包重扫时调用）
func clear_texture_cache() -> void:
	_base_texture_cache.clear()
	_emitter_texture_cache.clear()
