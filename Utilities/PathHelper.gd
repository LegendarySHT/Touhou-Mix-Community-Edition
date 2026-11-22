## 平台路径助手（纯静态工具类）
## 集中管理跨平台文件路径逻辑，所有组件统一通过此类获取基础路径
## 
## 设计原则：
##   - 纯静态方法，无需实例化，不依赖任何 Manager
##   - 在 Logger / ConfigManager / FileSystemManager 之前即可使用
##   - Android 平台使用外部可见路径 /storage/emulated/0/Android/data/<包名>/files/
##   - 其他平台保持使用 user://
##
## 使用方式：
##   var charts_dir = PathHelper.get_charts_dir()
##   var config_path = PathHelper.get_user_config_path()
##   PathHelper.ensure_dir_exists(charts_dir)

class_name PathHelper

## Android 包名（硬编码，与 export_presets.cfg 中一致）
const PACKAGE_NAME = "com.touhoumix.ce"

## 内置皮肤配置覆盖目录名（位于皮肤目录之下，见 get_builtin_skin_config_dir()）
const BUILTIN_SKIN_CONFIG_DIR_NAME = "builtin_skin_config"

# ============ 平台判断 ============

## 是否运行在 Android 平台
static func is_android() -> bool:
	return OS.has_feature("android")

# ============ 基础路径 ============

## 获取基础目录（平台自适应，每次实时计算，不缓存）
## Android: /storage/emulated/0/Android/data/com.touhoumix.ce/files/
## 其他平台: user://
static func get_base_dir() -> String:
	if is_android():
		return "/storage/emulated/0/Android/data/%s/files/" % PACKAGE_NAME
	else:
		return "user://"

## 获取固定引导目录（永不随玩家自定义存储根迁移）
## Android: /storage/emulated/0/Android/data/com.touhoumix.ce/files/
## 其他平台: user://files/
## 仅存放迁移日志 / 引导指针文件；settings.ini / favorites.json / Logs / Settings 等
## 用户数据一律位于可移动存储根（get_files_dir() / get_storage_root()）下。
static func get_boot_dir() -> String:
	if is_android():
		return get_base_dir()
	else:
		return get_base_dir().path_join("files") + "/"

# ============ 存储根（可移动） ============

## 玩家自定义存储根 override（绝对路径，含尾斜杠；空 = 使用固定引导目录）
## 由 StorageManager 在启动恢复/迁移后通过 set_storage_root() 注入，
## 保持本类"纯静态、不依赖任何 Manager"的设计约束
static var _storage_root_override: String = ""
## 是否已尝试过"从引导指针提前解析"（见 _resolve_override_from_pointer）
static var _pointer_probed: bool = false

## 获取可移动存储根（用户数据根）
## 已配置自定义路径时返回 override，否则回退固定引导目录（默认行为与旧版本一致）
##
## 【为什么读之前先探一次指针】autoload 的 _ready 全部早于 Main._ready，而存储根由
## StorageManager 在 Main._ready 步骤 1.5 才注入 —— 于是"引擎刚起来就按 user:// 路径
## 读文件"的 autoload（主题 ThemeMGR）读到的是**默认引导目录下的另一个文件**：
## 用户切浅色写进 <存储根>/theme.ini，启动却读 Android/data/<pkg>/files/theme.ini，
## 外观模式永远回默认深色（桌面端两个路径恰好相同，故只在 Android 自定义存储位置复现）。
##
## 这里只做**非破坏性**读取（读指针 → 注入 override），不校验、不写、不迁移 ——
## 那些仍归 StorageManager.recover_and_resolve()（稍后照常执行并按需覆盖本值）。
static func get_storage_root() -> String:
	if _storage_root_override.is_empty() and not _pointer_probed:
		_resolve_override_from_pointer()
	if not _storage_root_override.is_empty():
		return _storage_root_override
	return get_boot_dir()

## 惰性解析：读固定引导目录下的 storage_pointer.ini（[General] custom_storage_path）。
## 只为让"早于 StorageManager 的读取方"拿到正确路径；失败/无指针则保持默认。
static func _resolve_override_from_pointer() -> void:
	_pointer_probed = true
	var pointer_path := get_boot_dir() + "storage_pointer.ini"
	if not FileAccess.file_exists(pointer_path):
		return
	var parsed: Dictionary = IniParser.parse(FileAccess.get_file_as_string(pointer_path))
	# section 名与 StorageManager.CFG_SECTION 保持一致（设置分组合并后由 Storage 改为 General）。
	# 老版本写的是 [Storage]，一并认下，避免升级后读不到指针而静默回退默认根。
	var sec: Variant = parsed.get("General", parsed.get("Storage", {}))
	if not (sec is Dictionary):
		return
	var cfg := normalize_storage_path(str((sec as Dictionary).get("custom_storage_path", "")))
	if cfg.is_empty():
		return
	# 指针指向的目录不存在（外置存储未挂载/被删）时**不采纳**：宁可用默认根，也不要
	# 让全应用指向一个不存在的路径。StorageManager 稍后仍会按自己的规则做完整判定。
	if not DirAccess.dir_exists_absolute(cfg):
		return
	_storage_root_override = cfg
	_nomedia_ready_dirs.clear()

## 设置存储根 override（空值/空串清除，回退固定引导目录）
static func set_storage_root(path: String) -> void:
	_storage_root_override = normalize_storage_path(path) if not path.is_empty() else ""
	# 路径变了：旧的"该目录已有 .nomedia"结论对新根不成立，必须重新判定
	_nomedia_ready_dirs.clear()

## 获取用户数据根（settings.ini / favorites.json / Logs / Settings / 各资源目录的父目录）
## 语义为"可移动存储根"，默认与固定引导目录相同（与旧版本行为一致）
static func get_files_dir() -> String:
	return get_storage_root()

## 规范化存储路径：去首尾空白、反斜杠→正斜杠、统一结尾 "/"
## 空输入返回 ""；user:// 协议根（剥尾斜杠后为 "user:"）原样保留
static func normalize_storage_path(path: String) -> String:
	var p := str(path).strip_edges().replace("\\", "/")
	while p.ends_with("/"):
		p = p.substr(0, p.length() - 1)
	if p == "user:":
		# 保护 user:// 协议根不被剥成非法的 user:/
		return "user://"
	return "" if p.is_empty() else p + "/"

# ============ 各资源目录 ============

## 谱面目录
static func get_charts_dir() -> String:
	return get_storage_root() + "Charts/"

## 皮肤目录
static func get_skins_dir() -> String:
	return get_storage_root() + "Skins/"

## 粒子目录（用户粒子包，外部导入放这里）
static func get_particles_dir() -> String:
	return get_storage_root() + "Particles/"

## 人物目录（用户自定义人物，外部导入放这里）
static func get_charas_dir() -> String:
	return get_storage_root() + "Charas/"

## 内置皮肤配置覆盖目录
## res:// 在导出后为只读，内置皮肤的修改持久化到此目录
## 注意：它位于皮肤目录（get_skins_dir()）之下，只存 {皮肤名}.ini，不是皮肤包，
## 扫描皮肤时必须按 BUILTIN_SKIN_CONFIG_DIR_NAME 跳过
static func get_builtin_skin_config_dir() -> String:
	return get_skins_dir() + BUILTIN_SKIN_CONFIG_DIR_NAME + "/"

## 音源目录
static func get_soundfont_dir() -> String:
	return get_storage_root() + "Soundfont/"

## 背景图目录
static func get_background_dir() -> String:
	return get_storage_root() + "BackgroundImage/"

## 网络资源缓存目录（头像/远程封面等按内容标识缓存的图片字节，可随时重建）
## 注意：位于存储根下，与外部文件导入无关
static func get_web_cache_dir() -> String:
	return get_storage_root() + "WebCache/"

## 在线内容缓存目录（排行榜/评论/统计/商店列表/个人资料的 SWR 快照）
## 与 WebCache 同属「可随时重建的网络派生数据」，随存储根一起迁移。
static func get_online_cache_dir() -> String:
	return get_storage_root() + "OnlineCache/"

## 日志目录
static func get_logs_dir() -> String:
	return get_files_dir() + "Logs/"

## 设置目录
static func get_settings_dir() -> String:
	return get_files_dir() + "Settings/"

# ============ 特定文件路径 ============

## 用户配置文件路径
static func get_user_config_path() -> String:
	return get_files_dir() + "settings.ini"

## 认证文件路径（固定引导目录，设备/账号级数据，永不随存储根迁移）
static func get_auth_file() -> String:
	return get_boot_dir() + "auth.json"

## 设备标识文件路径（固定引导目录，设备级数据，永不随存储根迁移）
static func get_device_id_file() -> String:
	return get_boot_dir() + "device_id.txt"

## 上次已知的用户资料缓存（固定引导目录，账号级数据，永不随存储根迁移）
## 只用于启动时先显示上次的昵称/简介/头像，联网拉到新资料后覆盖
static func get_profile_cache_file() -> String:
	return get_boot_dir() + "profile_cache.json"

## 固定文件惰性兼容迁移：确保 file_name（auth.json / device_id.txt）位于引导目录。
## 历史版本曾随存储根存放，读取时若引导目录不存在而旧位置（存储根）存在，则一次性复制过来。
## 返回实际文件路径（恒为引导目录下）。
static func ensure_pinned_file(file_name: String) -> String:
	var target := get_boot_dir() + file_name
	if FileAccess.file_exists(target):
		return target
	var legacy := get_files_dir() + file_name
	if not FileAccess.file_exists(legacy):
		return target
	var f := FileAccess.open(legacy, FileAccess.READ)
	if f == null:
		return target
	var data := f.get_buffer(f.get_length())
	f.close()
	ensure_dir_exists(get_boot_dir())
	var g := FileAccess.open(target, FileAccess.WRITE)
	if g != null:
		g.store_buffer(data)
		g.close()
	return target

# ============ 目录操作工具 ============

## 确保目录存在（不存在则递归创建）
## 支持 user:// 和 Android 绝对路径
## 返回: true 表示目录已存在或创建成功
static func ensure_dir_exists(dir_path: String) -> bool:
	if DirAccess.dir_exists_absolute(dir_path):
		return true
	
	var error = DirAccess.make_dir_recursive_absolute(dir_path)
	if error == OK:
		return true
	else:
		push_error("[PathHelper] Failed to create directory: %s (Error: %d)" % [dir_path, error])
		return false

## 检查文件是否存在（兼容所有路径格式）
static func file_exists(file_path: String) -> bool:
	return FileAccess.file_exists(file_path)

## 检查目录是否存在（兼容所有路径格式）
static func dir_exists(dir_path: String) -> bool:
	return DirAccess.dir_exists_absolute(dir_path)

# ============ Android 媒体库隔离（.nomedia） ============
#
# 【为什么需要】Android 的媒体扫描器（MediaStore）会索引存储卡上所有图片/音频/视频，
# 再经 ContentResolver 暴露给系统相册、音乐播放器、文件管理器缩略图等应用。
# 默认存储根位于 Android/data/<包名>/files/，MediaProvider 对整个 Android/data 恒判为
# 「不可见」，所以旧版本不会出问题；玩家把「资源存储位置」改到公共目录
# （如 /storage/emulated/0/thmixData/）之后，谱面封面 Charts/*/cover.jpg、人声、
# 背景图、皮肤/粒子/人物贴图、网络图片缓存都会直接出现在系统相册里。
#
# 【机制】目录内存在名为 ".nomedia" 的文件（严格小写、无扩展名、内容无关、0 字节即可）
# 时，扫描器跳过该目录**及其所有子目录**：AOSP 对每个待索引文件向上遍历父目录，
# 任一祖先含 .nomedia 即判为隐藏（老版本 MediaScanner.isNoMediaPath 同样向上遍历）。
# 因此只需在每个游戏自有媒体目录下放一个标记，就能覆盖其下全部谱面文件夹。
#
# 【边界】绝不在存储根本身放标记：玩家可以把存储位置选到 /storage/emulated/0/
# 这类与相册共享的目录，根上一个 .nomedia 会把整张卡的媒体一起从相册里隐藏掉。
# 这里只列**游戏自己创建、且确实会落媒体文件**的目录，边界清楚、不会误伤玩家文件。

## 媒体库隔离标记文件名（0 字节，仅文件名生效）
const NOMEDIA_FILE_NAME := ".nomedia"

## 需要媒体库隔离的目录（相对存储根；顺序无意义）
const NOMEDIA_GUARD_DIRS: Array[String] = [
	"Charts", "BackgroundImage", "Skins", "Particles", "Charas", "WebCache",
]

## 当前存储根是否需要媒体库隔离
static func needs_nomedia_guard() -> bool:
	return needs_nomedia_guard_for(get_storage_root())

## 指定存储根（或其中任意子目录）是否需要媒体库隔离。两个条件同时成立才需要：
##   1. Android —— 只有它有 MediaStore（桌面端系统相册不看 user://，写了也没用）
##   2. 该路径不在应用私有目录 Android/data/<包名>/ 之下 —— MediaProvider 对这一整片
##      恒判为不可见，默认路径本来就不会被索引，落标记只是给玩家添一个莫名的隐藏文件
## 【必须按"要判断的那个路径"求值】迁移时目标根与当前根不是同一个：玩家从默认私有目录
## 迁到公共目录的那一次，恰恰是第一次需要标记的场景，按当前根判断会整个漏掉。
static func needs_nomedia_guard_for(root: String) -> bool:
	if not is_android():
		return false
	return is_media_scanner_visible_path(root, get_base_dir())

## 纯判定：path 是否落在应用私有目录之外（= 会被系统媒体库扫到的位置）。
## 抽成不依赖平台/单例的纯函数，便于 headless 覆盖 Android 分支的边界情况。
## private_base 需为 get_base_dir() 的形态（含尾 "/"）；path 任意形态均可。
static func is_media_scanner_visible_path(path: String, private_base: String) -> bool:
	var p := normalize_storage_path(path)
	var base := normalize_storage_path(private_base)
	if p.is_empty() or base.is_empty():
		return false
	# 前缀比较按路径边界生效：两侧都已规范化带尾 "/"，故 files2/ 不会被当成 files/ 的子目录
	return not p.begins_with(base)

## 目录内是否已有隔离标记
static func has_nomedia_marker(dir_path: String) -> bool:
	var d := normalize_storage_path(dir_path)
	if d.is_empty():
		return false
	return FileAccess.file_exists(d + NOMEDIA_FILE_NAME)

## 在指定目录写隔离标记（不判断平台、不创建目录）。已存在则原样保留。
## 返回 true 表示该目录现在已受保护。
## 【为什么不覆盖】已存在时重写会刷新 mtime，而 mtime 是 WebCache 容量淘汰、
## 谱面目录变更检测的判据之一；标记只是纯占位，不该制造"内容变了"的噪音。
static func write_nomedia_marker(dir_path: String) -> bool:
	var d := normalize_storage_path(dir_path)
	if d.is_empty() or not DirAccess.dir_exists_absolute(d):
		return false
	var marker := d + NOMEDIA_FILE_NAME
	if FileAccess.file_exists(marker):
		return true
	var f := FileAccess.open(marker, FileAccess.WRITE)
	if f == null:
		return false
	# 内容无关：扫描器只看文件名，留空文件（0 字节）即可
	f.close()
	return true

## 已确认写好标记的目录集合（避免 WebCache 每次写图都 stat 三遍）
## 换根时由 set_storage_root() 清空：路径变了，旧的"已就绪"结论不再成立
static var _nomedia_ready_dirs: Dictionary = {}

## 为单个目录补标记（目录不存在时先创建）。返回 true 表示目录可用。
## 供「即将往这个目录写媒体文件」的调用方在写入前调用——标记必须先于媒体落盘，
## 否则复制窗口内被媒体库扫到的封面不会因为后补的标记自动从相册消失。
## 不需要隔离的平台/路径只保证目录存在（不落 .nomedia），同样返回 true。
static func ensure_nomedia_guard_dir(dir_path: String) -> bool:
	var d := normalize_storage_path(dir_path)
	if d.is_empty():
		return false
	if not ensure_dir_exists(d):
		return false
	if not needs_nomedia_guard_for(d):
		return true
	if _nomedia_ready_dirs.has(d):
		return true
	if not write_nomedia_marker(d):
		return false
	_nomedia_ready_dirs[d] = true
	return true

## 为 root 下需要隔离的目录补标记，返回新建的标记数。
## create_missing=true 时连目录一起建（启动建目录阶段用：Charts/Skins/Particles/Charas/
## BackgroundImage 都是玩家可直接丢文件的投放目录，先建好并立标记，玩家往里放图才不会被扫）；
## false 时只处理已存在的目录（换根、迁移等场景不该顺手造空目录）。
static func ensure_nomedia_guard(root: String = "", create_missing: bool = false) -> int:
	var base := get_storage_root() if root.is_empty() else normalize_storage_path(root)
	if base.is_empty() or not needs_nomedia_guard_for(base):
		return 0
	var created := 0
	for d in NOMEDIA_GUARD_DIRS:
		var dir_path := base + d + "/"
		if not DirAccess.dir_exists_absolute(dir_path):
			if not create_missing:
				continue
			if not ensure_dir_exists(dir_path):
				continue
		if has_nomedia_marker(dir_path):
			continue
		if write_nomedia_marker(dir_path):
			created += 1
	return created

# ============ 路径转换工具 ============
## 将 user://files/ 前缀的路径转换为当前平台的实际路径
## 用于兼容旧代码中可能残留的 user:// 路径
static func resolve_user_path(path: String) -> String:
	if is_android() and path.begins_with("user://"):
		# 将 user:// 替换为 Android 外部存储基础路径
		return path.replace("user://", get_base_dir())
	return path

## 获取调试信息字符串（用于日志输出）
static func get_debug_info() -> String:
	var info = "[PathHelper] Platform: %s\n" % OS.get_name()
	info += "[PathHelper] Base dir: %s\n" % get_base_dir()
	info += "[PathHelper] Files dir: %s\n" % get_files_dir()
	info += "[PathHelper] Is Android: %s\n" % str(is_android())
	if is_android():
		info += "[PathHelper] User data dir: %s\n" % OS.get_user_data_dir()
		info += "[PathHelper] Package: %s\n" % PACKAGE_NAME
	return info
