## 存储管理器
## 负责玩家自定义资源存储路径的校验、迁移与崩溃恢复
##
## 概念：
##   - 固定引导目录（PathHelper.get_boot_dir()）：仅存迁移日志 + 引导指针文件
##     —— 永不迁移，否则启动时无法定位数据根
##   - 可移动存储根（PathHelper.get_storage_root() / get_files_dir()）：
##     全部用户数据 —— Charts / Soundfont / Skins / BackgroundImage / Particles /
##     Charas / Logs / Settings / THMIX_Import + settings.ini / favorites.json /
##     auth.json / device_id.txt / charts.ldb / charts-log.ldb —— 玩家可自定义
##
## 引导机制：settings.ini 随存储根迁移后，启动时不能靠读 settings.ini 定位根。
## 因此在引导目录维护 storage_pointer.ini（记录当前存储根），迁移提交时更新，
## 启动恢复时优先读迁移日志，其次读指针文件。
##
## 崩溃安全设计（核心不变量）：
##   1. 迁移期间只复制、绝不删除旧数据 → 旧根始终是新根的备份
##   2. 迁移日志写引导目录（新根即使损坏也可读）
##   3. cleanup（删旧备份）永远发生在"下次启动验证新根通过之后"
##      → 杜绝"新根失效 + 旧根已删"的双重丢失
##
## 生命周期：Main._ready 最先创建本节点并调用 recover_and_resolve()（先于
## ConfigManager.load_and_set_current()，本类不依赖 ConfigManager）。
extends Node

class_name StorageManager

static var instance: StorageManager

## 迁移日志文件名（存于引导目录）
const JOURNAL_FILE := "storage_migration_journal.json"
## 引导指针文件名（存于引导目录，记录当前存储根，settings.ini 随根迁移后用于引导）
const POINTER_FILE := "storage_pointer.ini"
## 随存储根迁移的子目录（顺序即复制顺序）
## 注意：ChartDB 的 zstd 词典缓存 dicts/ 属可自动重建的缓存，不随根迁移
const MIGRATABLE_DIRS: Array[String] = [
	"Charts", "Soundfont", "Skins", "BackgroundImage", "Particles", "Charas",
	"Logs", "Settings", "THMIX_Import",
]
## 随存储根迁移的顶层文件（用户数据 / 数据库）
const MIGRATABLE_FILES: Array[String] = [
	"settings.ini", "favorites.json", "auth.json", "device_id.txt",
	"charts.ldb", "charts-log.ldb", "charts.ldb.lock", "charts-log.ldb.lock",
]
## 可写性测试文件名（验证后立即删除）
const WRITE_TEST_FILE := ".thmix_write_test"
## 配置键
const CFG_SECTION := "Storage"
const CFG_KEY := "custom_storage_path"

func _ready() -> void:
	if instance == null:
		instance = self
	else:
		queue_free()

# ============================================================
# 纯静态工具（无副作用，headless 可测）
# ============================================================

## 规范化存储路径（委托 PathHelper）
static func normalize(path: String) -> String:
	return PathHelper.normalize_storage_path(path)

## 交互式目标路径校验（UI 确认迁移前调用）
## 返回 {ok, code, reason, target_not_empty}
## code: "ok" | "empty" | "not_absolute" | "same_as_current" | "cycle"（新根是旧根祖先或后代）
##       | "cannot_create" | "not_writable"
static func validate_target_path(path: String) -> Dictionary:
	var normalized := normalize(path)
	if normalized.is_empty():
		return _fail("empty", "存储路径不能为空")
	if not _is_absolute(normalized):
		return _fail("not_absolute", "请输入绝对路径（如 D:/Games/THMIX 或点击浏览选择），相对路径不受支持")

	var current := PathHelper.get_storage_root()
	if normalized == current:
		return _fail("same_as_current", "目标路径与当前存储路径相同")

	# 循环根检测：新根是旧根祖先或后代都拒绝（复制源在目标内部会读到写入中的数据）
	# normalized / current 均已规范化带尾 "/"，前缀匹配天然按路径边界生效
	if normalized.begins_with(current):
		return _fail("cycle", "目标路径位于当前存储路径内部，无法迁移到自身或其子目录")
	if current.begins_with(normalized):
		return _fail("cycle", "目标路径是当前存储路径的上级目录，无法迁移")

	# 目录不存在则创建
	if not DirAccess.dir_exists_absolute(normalized):
		var err := DirAccess.make_dir_recursive_absolute(normalized)
		if err != OK:
			return _fail("cannot_create", "无法创建目标目录（可能无权限或路径非法）")

	# 可写性测试：写入临时文件再删除
	var test_file := normalized + WRITE_TEST_FILE
	var f := FileAccess.open(test_file, FileAccess.WRITE)
	if f == null:
		return _fail("not_writable", "目标目录不可写（无写入权限）")
	f.store_string("test")
	f.close()
	var remove_err := DirAccess.remove_absolute(test_file)
	if remove_err != OK:
		return _fail("not_writable", "目标目录不可写（无法删除测试文件）")

	# 非空检测（忽略隐藏条目）
	var target_not_empty := false
	var dir := DirAccess.open(normalized)
	if dir:
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			if not entry.begins_with("."):
				target_not_empty = true
				break
			entry = dir.get_next()
		dir.list_dir_end()

	return {"ok": true, "code": "ok", "reason": "", "target_not_empty": target_not_empty}

## 启动期轻量校验（恢复/读取配置路径时使用，不创建、不写测试文件）
## 目录存在且可打开，或可被创建 → 视为有效
static func check_configured_path(path: String) -> bool:
	var normalized := normalize(path)
	if normalized.is_empty():
		return false
	if DirAccess.dir_exists_absolute(normalized):
		return DirAccess.open(normalized) != null
	return DirAccess.make_dir_recursive_absolute(normalized) == OK

## 迁移日志状态机（纯逻辑，注入 validate 回调供 headless 测试）
## validate_fn(path) -> {ok: bool, reason: String}
## 返回 {action, path, needs_full_rescan, restored, reason}
## action: "none"（无日志）| "rollback" | "commit"
## 注意：cleanup（删旧备份）不在状态机内执行，由 recover 在同步配置后调用，
## 确保"旧根 settings.ini（最新配置）覆盖新根快照"发生在删旧根之前。
static func _journal_state_machine(journal: Dictionary, validate_fn: Callable) -> Dictionary:
	var state := str(journal.get("state", ""))
	var prev := str(journal.get("prev_override", ""))
	var new_root := str(journal.get("new_root", ""))

	match state:
		"in_progress":
			# 复制/提交中途崩溃：回退旧根（新根可能混有玩家文件，不删除），日志作废
			return {
				"action": "rollback",
				"path": prev,
				"needs_full_rescan": false,
				"restored": true,
				"reason": "检测到未完成的迁移，已回退到迁移前路径",
			}
		"committed", "cleanup_pending":
			var v: Dictionary = validate_fn.call(new_root)
			if not bool(v.get("ok", false)):
				# 新根失效（玩家自删/磁盘异常等）：回退旧根，旧根在 cleanup 前始终完整
				return {
					"action": "rollback",
					"path": prev,
					"needs_full_rescan": false,
					"restored": true,
					"reason": "新存储路径不可用（%s），已回退到迁移前路径" % str(v.get("reason", "unknown")),
				}
			# 新根验证通过 → 采用新根（cleanup 由 recover 在配置同步后执行，幂等可续）
			return {
				"action": "commit",
				"path": new_root,
				"needs_full_rescan": true,
				"restored": false,
				"reason": "",
			}
		_:
			return {
				"action": "none",
				"path": "",
				"needs_full_rescan": false,
				"restored": false,
				"reason": "",
			}

static func _fail(code: String, reason: String) -> Dictionary:
	return {"ok": false, "code": code, "reason": reason, "target_not_empty": false}

## 是否为绝对路径（规范化后判断）
## Android：以 / 开头；桌面：以 / 或 user:// 开头，或 Windows 盘符（X:/）
static func _is_absolute(normalized: String) -> bool:
	if normalized.begins_with("/") or normalized.begins_with("user://"):
		return true
	if normalized.length() >= 2 and normalized[1] == ":":
		var c: String = normalized[0]
		return (c >= "A" and c <= "Z") or (c >= "a" and c <= "z")
	return false

# ============================================================
# 启动恢复
# ============================================================

## 启动恢复（同步）：读迁移日志 → 按状态机处理 → 设置 PathHelper 存储根 override
## 必须最先调用（早于 ConfigManager.load_and_set_current，本函数不依赖 ConfigManager）
## 返回 {storage_root, needs_full_rescan, restored, note, needs_config_commit, pending_root}
## needs_config_commit=true 时调用方须在配置加载后把 pending_root 补写进 settings.ini
func recover_and_resolve() -> Dictionary:
	var journal := _read_journal()
	if journal.is_empty():
		return _resolve_without_journal()

	var decision: Dictionary = _journal_state_machine(
		journal, Callable(self, "_validate_for_recovery"))
	match str(decision.get("action", "none")):
		"rollback":
			var prev := str(decision.get("path", ""))
			PathHelper.set_storage_root(prev)
			_write_pointer(prev)
			_delete_journal()
			GLogger.warning("Storage rollback: %s" % str(decision.get("reason", "")), "StorageMGR")
			var r := _result(false, true, "rollback")
			r["note"] = str(decision.get("reason", "rollback"))
			return r
		"commit":
			var new_root := str(decision.get("path", ""))
			var old_root := str(journal.get("old_root", ""))
			PathHelper.set_storage_root(new_root)
			_write_pointer(new_root)
			# 配置同步：旧根 settings.ini 是迁移后本会话的写入目标（最新配置），
			# 覆盖新根上的迁移快照，避免重启后丢失迁移后修改的设置。
			# 必须在 cleanup（删旧根）之前执行。
			var src_cfg := old_root + "settings.ini"
			if not old_root.is_empty() and FileAccess.file_exists(src_cfg) \
					and new_root != old_root:
				_copy_file(src_cfg, new_root + "settings.ini")
			# cleanup 旧根备份（幂等，中断可续）
			if _cleanup_old_root(old_root):
				_delete_journal()
				GLogger.info("Storage migration committed, old root cleaned", "StorageMGR")
			else:
				var j := _read_journal()
				j["state"] = "cleanup_pending"
				j["updated_at"] = Time.get_unix_time_from_system()
				_write_journal(j)
				GLogger.warning("Storage migration committed, old root cleanup pending", "StorageMGR")
			var res := _result(true, false, "commit")
			# 配置补写交给调用方（此时 ConfigManager 尚未加载）：确保 settings.ini 记录新根
			res["needs_config_commit"] = true
			res["pending_root"] = new_root
			return res
		_:
			# 不应发生：有 journal 但 state 未知 → 按无日志处理
			_delete_journal()
			return _resolve_without_journal()

## 无迁移日志时的存储根解析：读引导指针文件（兼容旧版 settings.ini 内配置）
func _resolve_without_journal() -> Dictionary:
	var cfg := _read_pointer_or_legacy_config()
	if cfg.is_empty():
		PathHelper.set_storage_root("")
		return _result(false, false, "default")
	if check_configured_path(cfg):
		PathHelper.set_storage_root(cfg)
		return _result(false, false, "pointer")
	# 指针指向的路径无效（被删除/无权限）：回退默认根，保留指针不写回
	GLogger.warning("Storage pointer path invalid, falling back to default: %s" % cfg, "StorageMGR")
	PathHelper.set_storage_root("")
	return _result(false, true, "pointer_invalid")

func _result(needs_full_rescan: bool, restored: bool, note: String) -> Dictionary:
	return {
		"storage_root": PathHelper.get_storage_root(),
		"needs_full_rescan": needs_full_rescan,
		"restored": restored,
		"note": note,
		"needs_config_commit": false,
		"pending_root": "",
	}

## 恢复期校验回调（不创建、不写测试文件）
## 校验：新根可用 + 已包含迁移数据。
## 注意：不做旧根逐文件大小对账——迁移后到重启间旧根仍可能有正常写入
## （日志追加、DB 重开后的 charts-log.ldb 增长等），size 不一致不代表迁移失败，
## 否则会误判 rollback 导致旧数据永不清理。防误删由 _has_migration_data 兜底
## （新根无任何数据 → 回退旧根，旧备份不清理）。
func _validate_for_recovery(path: String) -> Dictionary:
	if not check_configured_path(path):
		return {"ok": false, "reason": "path unusable"}
	if not _has_migration_data(path):
		return {"ok": false, "reason": "new root missing migrated data"}
	return {"ok": true, "reason": ""}

## 新根是否包含迁移数据（任一可迁移目录非空，或 DB 存在）
static func _has_migration_data(root: String) -> bool:
	var r := normalize(root)
	if r.is_empty():
		return false
	for d in MIGRATABLE_DIRS:
		if _count_files(r + d) > 0:
			return true
	for f in MIGRATABLE_FILES:
		if FileAccess.file_exists(r + f):
			return true
	return false

# ============================================================
# 迁移（运行期，SettingView 触发）
# ============================================================

## 完整迁移：复制 → 校验 → 提交。协程，需要 UI 进度时传入 ui（show_progress_ui 返回值）
## 返回 {ok, reason}；ok=true 表示已提交（重启生效），ok=false 表示失败（数据层可能已关闭，建议重启）
func migrate(old_root: String, new_root: String, ui: Dictionary = {}) -> Dictionary:
	var v := validate_target_path(new_root)
	if not bool(v.get("ok", false)):
		return {"ok": false, "reason": str(v.get("reason", "路径无效"))}

	old_root = normalize(old_root)
	new_root = normalize(new_root)
	if old_root == new_root:
		return {"ok": false, "reason": "目标路径与当前存储路径相同"}

	# 1. 写迁移日志（in_progress）
	var journal := {
		"state": "in_progress",
		"prev_override": PathHelper._storage_root_override,
		"old_root": old_root,
		"new_root": new_root,
		"migration_id": str(Time.get_unix_time_from_system()) + "_" + str(randi()),
		"started_at": Time.get_unix_time_from_system(),
		"updated_at": Time.get_unix_time_from_system(),
	}
	if not _write_journal(journal):
		return {"ok": false, "reason": "无法写入迁移日志"}

	# 2. 停止播放 + 关闭 DB（LiteDB 单文件锁，必须先关再复制 charts.ldb）
	if MidiPlaybackManager.instance != null:
		MidiPlaybackManager.instance.stop()
	var db_closed: bool = false
	if ChartDB != null and ChartDB.IsOpen():
		ChartDB.CloseDb()
		db_closed = true

	# 3. 复制（让出一帧避免进度 UI 与弹窗遮罩动画冲突）
	if get_tree() != null:
		await get_tree().process_frame
	var copied := await _copy_storage(old_root, new_root, ui)

	# 4. 校验：新根已包含迁移数据即可（复制过程已逐文件保证；不做旧根逐文件大小对账，
	#    迁移期间旧根仍在运行（日志/DB 持续写入），size 不一致不代表复制失败）
	var verified := false
	if copied:
		verified = _has_migration_data(new_root)

	# 5. 恢复会话：重开旧根 DB（重启前游戏继续用旧根运行，功能需保持正常）
	if db_closed and ChartDB != null:
		var db_path := ProjectSettings.globalize_path(old_root + "charts.ldb")
		var old_cache := ProjectSettings.globalize_path(PathHelper.get_base_dir()).path_join(".charts_scan_cache.json")
		ChartDB.OpenDb(db_path, old_cache)

	if not verified:
		_delete_journal()
		return {"ok": false, "reason": "迁移复制或校验失败，数据层已恢复，建议重启游戏"}

	# 6. 提交：journal → committed，配置立即落盘，更新引导指针
	journal["state"] = "committed"
	journal["updated_at"] = Time.get_unix_time_from_system()
	if not _write_journal(journal):
		return {"ok": false, "reason": "迁移已完成但无法写入提交日志，请重启游戏"}
	if not _write_pointer(new_root):
		return {"ok": false, "reason": "迁移已完成但无法更新引导指针，请重启游戏"}
	ConfigManager.instance.set_value(CFG_SECTION, CFG_KEY, new_root)
	ConfigManager.instance.save_config(
		ConfigManager.USER_CONFIG_PATH, ConfigManager.instance.get_current_config())

	GLogger.info("Storage migration committed: %s -> %s (restart required)" % [old_root, new_root], "StorageMGR")
	return {"ok": true, "reason": ""}

## 请求重启（桌面导出环境尝试自动重启后退出）
## 返回 true 表示已触发重启（游戏即将退出），false 表示需要强制提示玩家手动重启
## 注意：Android 不支持自动重启；Godot 编辑器环境（F5 运行）下 OS.create_process 拉起的是
## 编辑器进程而非游戏运行实例，且旧运行实例不会退出，会导致双进程冲突（新实例空白），
## 因此编辑器环境一律走强制提示，由玩家手动重新运行
func request_restart() -> bool:
	if PathHelper.is_android() or OS.has_feature("editor"):
		return false
	var executable := OS.get_executable_path()
	var args: PackedStringArray = PackedStringArray()
	if OS.is_debug_build():
		# 调试构建的 executable 是 Godot 可执行文件，需带 --path
		args.append("--path")
		args.append(ProjectSettings.globalize_path("res://"))
	var err := OS.create_process(executable, args)
	if err == OK:
		if get_tree() != null:
			get_tree().quit()
		return true
	GLogger.warning("Auto restart failed (err %d), forcing restart prompt" % err, "StorageMGR")
	return false

# ============================================================
# Android 外部存储权限
# ============================================================

## 将 Android SAF content:// URI 转换为真实文件路径（外部存储提供者）
## 例：content://com.android.externalstorage.documents/tree/primary%3AthmixData
##   → /storage/emulated/0/thmixData/
## 支持 tree/document 两种形式；仅解析主存储卷（primary → /storage/emulated/0/），
## SD 卡等其他卷无法稳定映射真实挂载点，返回空由调用方提示手动输入
static func saf_uri_to_path(uri: String) -> String:
	if not uri.begins_with("content://com.android.externalstorage.documents/"):
		return ""
	var id := ""
	if "/tree/" in uri:
		id = uri.get_slice("/tree/", 1)
	elif "/document/" in uri:
		id = uri.get_slice("/document/", 1)
	else:
		return ""
	# 去掉 document 子路径的后续段（只取 tree/document id）
	if "/" in id:
		id = id.get_slice("/", 0)
	# URL 解码（%3A → :，%2F → /）
	id = id.uri_decode().strip_edges()
	if not id.begins_with("primary:"):
		return ""  # 非主存储卷（SD 卡等），无法安全映射
	var rel := id.substr("primary:".length())
	var path := "/storage/emulated/0/"
	if not rel.is_empty():
		path += rel
	return normalize(path)

## 目标路径是否需要 Android "所有文件访问"权限（API 30+）
## 应用私有目录（Android/data/<包名>/ 下）零权限
static func needs_android_permission(target: String) -> bool:
	if not PathHelper.is_android():
		return false
	var t := normalize(target)
	if t.is_empty():
		return false
	return not t.begins_with("/storage/emulated/0/Android/data/" + PathHelper.PACKAGE_NAME + "/")

## 是否已授予外部存储访问权限（按需调用，不随启动固定请求）
## API 30+：MANAGE_EXTERNAL_STORAGE（所有文件访问，特殊权限，经系统设置页授予）
## API <30：WRITE_EXTERNAL_STORAGE（运行时权限，可弹窗请求）
## 注意：JavaClassWrapper 必须用 Engine.get_singleton 动态获取（Windows 无此模块），
## Java 方法必须用直接方法调用语法，不能用 .call()/has_method()（见 AudioBtDetector 踩坑笔记）
func is_android_storage_permission_granted() -> bool:
	if not PathHelper.is_android():
		return true
	var jcw = Engine.get_singleton("JavaClassWrapper")
	if jcw == null:
		return false
	# API 30+：Environment.isExternalStorageManager()
	var env: Variant = jcw.call("wrap", "android.os.Environment")
	if env != null:
		var granted: bool = bool(env.isExternalStorageManager())
		if granted:
			return true
	# API <30 兜底：PackageManager.checkPermission(WRITE_EXTERNAL_STORAGE)
	var ctx: Variant = _get_android_context()
	if ctx != null:
		var pm: Variant = ctx.getPackageManager()
		var result: int = int(pm.checkPermission("android.permission.WRITE_EXTERNAL_STORAGE", ctx.getPackageName()))
		if result == 0:  # PackageManager.PERMISSION_GRANTED
			return true
	return false

## 按需请求外部存储权限：
## 1) 先尝试 OS.request_permissions（API <30 的 WRITE_EXTERNAL_STORAGE 运行时权限可弹窗授予，
##    API 30+ 的 MANAGE_EXTERNAL_STORAGE 是特殊权限，request_permissions 无效但无害）
## 2) 再打开系统"所有文件访问"设置页（API 30+ 特殊权限必须经设置页手动开启）
##    方式 A：JavaClassWrapper 构造 Intent（MANAGE_APP_ALL_FILES_ACCESS_PERMISSION）
##    方式 B 兜底：OS.shell_open 打开应用详情页，引导玩家手动开启
func open_android_permission_settings() -> void:
	if not PathHelper.is_android():
		return
	# 低版本运行时权限：可弹窗请求（无参 = 请求 manifest 声明的全部运行时权限；
	# API 30+ 的 MANAGE_EXTERNAL_STORAGE 是特殊权限，此调用无效但无害）
	OS.request_permissions()
	var jcw = Engine.get_singleton("JavaClassWrapper")
	var ctx: Variant = _get_android_context()
	if jcw != null and ctx != null:
		var intent_class: Variant = jcw.call("wrap", "android.content.Intent")
		if intent_class != null:
			var intent: Variant = intent_class.new("android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION")
			if intent != null:
				var uri_class: Variant = jcw.call("wrap", "android.net.Uri")
				var uri: Variant = uri_class.parse("package:" + PathHelper.PACKAGE_NAME)
				intent.setData(uri)
				intent.addFlags(0x10000000)  # Intent.FLAG_ACTIVITY_NEW_TASK
				ctx.startActivity(intent)
				GLogger.info("Opened all-files-access permission settings via Intent", "StorageMGR")
				return
	# 兜底：应用详情页（设置 → 特殊应用权限 → 所有文件访问）
	OS.shell_open("package:" + PathHelper.PACKAGE_NAME)
	GLogger.info("Opened app settings page for all-files-access guidance", "StorageMGR")

## 获取 Android Context（复制 AudioBtDetector 模式：AndroidRuntime 插件 → ActivityThread 兜底）
func _get_android_context() -> Variant:
	var runtime = Engine.get_singleton("AndroidRuntime")
	if runtime != null and runtime.has_method("getApplicationContext"):
		var ctx: Variant = runtime.call("getApplicationContext")
		if ctx != null:
			return ctx
	var jcw = Engine.get_singleton("JavaClassWrapper")
	if jcw == null:
		return null
	var at_class: Variant = jcw.call("wrap", "android.app.ActivityThread")
	if at_class == null:
		return null
	var activity_thread: Variant = at_class.currentActivityThread()
	if activity_thread == null:
		return null
	return activity_thread.getApplication()

# ============================================================
# 内部：日志 / 指针读写（引导目录，不依赖 ConfigManager，启动恢复期可用）
# ============================================================

func _journal_path() -> String:
	return PathHelper.get_boot_dir() + JOURNAL_FILE

func _read_journal() -> Dictionary:
	var p := _journal_path()
	if not FileAccess.file_exists(p):
		return {}
	var content := FileAccess.get_file_as_string(p)
	if content.is_empty():
		return {}
	var parsed = JSON.parse_string(content)
	return parsed if parsed is Dictionary else {}

func _write_journal(journal: Dictionary) -> bool:
	PathHelper.ensure_dir_exists(PathHelper.get_boot_dir())
	var f := FileAccess.open(_journal_path(), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(journal))
	f.close()
	return true

func _delete_journal() -> void:
	var p := _journal_path()
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)

func _pointer_path() -> String:
	return PathHelper.get_boot_dir() + POINTER_FILE

## 读引导指针（[Storage] custom_storage_path），不存在返回 ""
func _read_pointer() -> String:
	var p := _pointer_path()
	if not FileAccess.file_exists(p):
		return ""
	var parsed: Dictionary = IniParser.parse(FileAccess.get_file_as_string(p))
	var sec: Variant = parsed.get(CFG_SECTION, {})
	if sec is Dictionary:
		return str(sec.get(CFG_KEY, ""))
	return ""

## 写引导指针（记录当前存储根，settings.ini 随根迁移后用于启动引导）
func _write_pointer(path: String) -> bool:
	PathHelper.ensure_dir_exists(PathHelper.get_boot_dir())
	var f := FileAccess.open(_pointer_path(), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string("[%s]\n%s = \"%s\"\n" % [CFG_SECTION, CFG_KEY, path])
	f.close()
	return true

## 读指针；指针缺失时兼容旧版本（读引导目录 settings.ini 内配置）
func _read_pointer_or_legacy_config() -> String:
	var p := _read_pointer()
	if not p.is_empty():
		return p
	var legacy := PathHelper.get_boot_dir() + "settings.ini"
	if FileAccess.file_exists(legacy):
		var parsed: Dictionary = IniParser.parse(FileAccess.get_file_as_string(legacy))
		var sec: Variant = parsed.get(CFG_SECTION, {})
		if sec is Dictionary:
			return str(sec.get(CFG_KEY, ""))
	return ""

# ============================================================
# 内部：复制 / 校验 / 清理
# ============================================================

## 复制可迁移内容（全部用户数据目录 + 顶层文件），跳过目标已存在文件（覆盖复制幂等）
## ui: FileSystemManager.show_progress_ui 返回值 {overlay, tip, bar}，可为空
func _copy_storage(old_root: String, new_root: String, ui: Dictionary) -> bool:
	# 统计总文件数用于进度条
	var total := 0
	for d in MIGRATABLE_DIRS:
		if DirAccess.dir_exists_absolute(old_root + d):
			total += _count_files(old_root + d)
	for f in MIGRATABLE_FILES:
		if not f.ends_with(".lock") and FileAccess.file_exists(old_root + f):
			total += 1
	var bar: ProgressBar = ui.get("bar", null)
	if bar and total > 0:
		bar.max_value = maxf(total, 1)
		bar.value = 0
		bar.show_percentage = true
	var counter := {"n": 0, "done": 0}
	var progress_cb := func() -> void:
		counter["done"] = int(counter["done"]) + 1
		if bar:
			bar.value = minf(counter["done"], bar.max_value)

	for d in MIGRATABLE_DIRS:
		var src := old_root + d
		if not DirAccess.dir_exists_absolute(src):
			continue
		if not await _copy_dir_async(src, new_root + d, progress_cb, counter):
			return false

	# 复制顶层文件（用户数据 + 数据库；.lock 属会话锁文件，不复制）
	for f in MIGRATABLE_FILES:
		if f.ends_with(".lock"):
			continue
		var src := old_root + f
		if FileAccess.file_exists(src):
			if not _copy_file(src, new_root + f):
				return false
			progress_cb.call()
	return true

## 递归复制目录（跳过已存在文件；每 8 个文件让出一帧保持界面响应）
func _copy_dir_async(src_dir: String, dst_dir: String, progress_cb: Callable, counter: Dictionary) -> bool:
	if not PathHelper.ensure_dir_exists(dst_dir):
		return false
	var dir := DirAccess.open(src_dir)
	if dir == null:
		return false
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var src := src_dir.path_join(entry)
			var dst := dst_dir.path_join(entry)
			if dir.current_is_dir():
				if not await _copy_dir_async(src, dst, progress_cb, counter):
					return false
			else:
				if not FileAccess.file_exists(dst):
					if not _copy_file(src, dst):
						return false
				progress_cb.call()
				counter["n"] = int(counter["n"]) + 1
				if int(counter["n"]) % 8 == 0 and get_tree() != null:
					await get_tree().process_frame
		entry = dir.get_next()
	dir.list_dir_end()
	return true

## 复制单个文件（整块读取写入）
static func _copy_file(src: String, dst: String) -> bool:
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null:
		return false
	var data := f.get_buffer(f.get_length())
	f.close()
	var g := FileAccess.open(dst, FileAccess.WRITE)
	if g == null:
		return false
	g.store_buffer(data)
	g.close()
	return true

## 统计目录下文件总数（递归，忽略隐藏条目）
static func _count_files(dir_path: String) -> int:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return 0
	var count := 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			if dir.current_is_dir():
				count += _count_files(dir_path.path_join(entry))
			else:
				count += 1
		entry = dir.get_next()
	dir.list_dir_end()
	return count

## 清理旧根备份（幂等）：删全部可迁移目录 + 顶层文件（含 charts-log.ldb / lock），绝不删根自身
## 注意：引导目录（get_boot_dir()）中的迁移日志 / 引导指针不在此列，永不被清理
## 启动期调用时 FileSystemManager 尚未创建，使用独立递归删除
func _cleanup_old_root(old_root: String) -> bool:
	var root := normalize(old_root)
	if root.is_empty():
		return true
	var ok := true
	for d in MIGRATABLE_DIRS:
		var p := root + d
		if DirAccess.dir_exists_absolute(p):
			if not _delete_dir_simple(p):
				ok = false
	for f in MIGRATABLE_FILES:
		var p := root + f
		if FileAccess.file_exists(p):
			var err := DirAccess.remove_absolute(p)
			if err != OK:
				ok = false
	if ok:
		GLogger.info("Old storage root cleaned: %s" % root, "StorageMGR")
	return ok

## 独立递归删除目录（不依赖 FileSystemManager，启动恢复期可用）
func _delete_dir_simple(absolute_path: String) -> bool:
	var dir := DirAccess.open(absolute_path)
	if dir == null:
		return not DirAccess.dir_exists_absolute(absolute_path)
	var ok := true
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full := absolute_path.path_join(entry)
			if dir.current_is_dir():
				if not _delete_dir_simple(full):
					ok = false
			else:
				var err := DirAccess.remove_absolute(full)
				if err != OK:
					ok = false
		entry = dir.get_next()
	dir.list_dir_end()
	var err2 := DirAccess.remove_absolute(absolute_path)
	if err2 != OK:
		ok = false
	return ok
