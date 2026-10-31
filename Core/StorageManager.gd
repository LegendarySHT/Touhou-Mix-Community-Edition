## 存储管理器
## 负责玩家自定义资源存储路径的校验、迁移与崩溃恢复
##
## 概念：
##   - 固定引导目录（PathHelper.get_boot_dir()）：仅存迁移日志 + 引导指针文件
##     —— 永不迁移，否则启动时无法定位数据根
##   - 可移动存储根（PathHelper.get_storage_root() / get_files_dir()）：
##     全部用户数据 —— Charts / Soundfont / Skins / BackgroundImage / Particles /
##     Charas / Logs / Settings + settings.ini / favorites.json /
##     theme.ini / charts.ldb / charts-log.ldb —— 玩家可自定义
##   - 固定引导目录文件（PathHelper.get_auth_file() / get_device_id_file()）：
##     auth.json（登录态）/ device_id.txt（设备标识）—— 设备/账号级数据，不随存储根迁移
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
## 合并语义（目标侧优先，单向补缺）：
##   - 资源目录：同名文件保留目标已有版本，目标缺的从当前根补
##   - 顶层文件（settings.ini / theme.ini 等）：目标已存在则保留目标版本
##   - favorites.json：两侧按收藏夹 id 取并集（同 id 保留目标那份）
##   - 数据库（charts.ldb）：目标已有库时把当前库缺失的记录补进去，同一 _id 保留目标记录
##   charts.ldb 与 charts-log.ldb（LiteDB 日志）必须成对处理：把源侧日志混进目标主库会写坏库
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
	"Logs", "Settings",
]
## 随存储根迁移的顶层文件（用户数据 / 数据库）
## 注意：auth.json / device_id.txt 为设备/账号级固定文件（存引导目录），永不随根迁移
const MIGRATABLE_FILES: Array[String] = [
	"settings.ini", "favorites.json", "theme.ini",
	"charts.ldb", "charts-log.ldb", "charts.ldb.lock", "charts-log.ldb.lock",
]
## 主数据库文件名（与 charts-log.ldb 成对：日志是 LiteDB 的 journal，跨库混用会写坏主库）
const DB_FILE := "charts.ldb"
const DB_LOG_FILE := "charts-log.ldb"
## 可写性测试文件名（验证后立即删除）
const WRITE_TEST_FILE := ".thmix_write_test"
## 配置键
const CFG_SECTION := "General"
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

	# 非空检测（忽略隐藏条目）+ 冲突分类（可合并目录 / 不可合并文件）
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

	var collisions := _detect_collisions(normalized)
	return {
		"ok": true,
		"code": "ok",
		"reason": "",
		"target_not_empty": target_not_empty,
		"merge_dirs": collisions["merge_dirs"],
		"conflict_files": collisions["conflict_files"],
	}

## 检测目标目录中已存在的游戏数据（迁移提示用）：
##   merge_dirs    —— 目标已存在且非空的 MIGRATABLE_DIRS（同名保留目标，缺的补齐）
##   conflict_files—— 目标已存在的 MIGRATABLE_FILES（目标优先保留，.lock 跟随其主体不单列）
## 只做浅层枚举（每个目录读一层、发现首个条目即停）：冲突分类只需要"有没有内容"，
## 递归统计文件数在大曲包目录上会让主线程长时间无响应。
static func _detect_collisions(normalized: String) -> Dictionary:
	var merge_dirs: Array[String] = []
	for d in MIGRATABLE_DIRS:
		if _dir_has_entries(normalized + d):
			merge_dirs.append(d)
	var conflict_files: Array[String] = []
	for f in MIGRATABLE_FILES:
		if f.ends_with(".lock"):
			continue  # 锁文件跟随其主体文件（charts.ldb / charts-log.ldb）
		if FileAccess.file_exists(normalized + f):
			conflict_files.append(f)
	return {"merge_dirs": merge_dirs, "conflict_files": conflict_files}

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
			# 全量扫描只在"迁移后尚未重建过索引"时执行一次：cleanup 失败会留下
			# cleanup_pending 日志，若仍按"有日志就重扫"处理，每次启动都会白扫一遍
			return {
				"action": "commit",
				"path": new_root,
				"needs_full_rescan": bool(journal.get("rescan_pending", true)),
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
			# 注意：此处绝不能用旧根 settings.ini 覆盖新根。迁移语义是"目标侧优先"，
			# 新根上的配置就是玩家选定的那份；旧根副本此时已是被放弃的一方。
			# 新根 settings.ini 里过期的 custom_storage_path 由调用方在配置加载后补写。
			# cleanup 旧根备份（幂等，中断可续）
			# 同一会话内连续迁移会留下更早的旧根，记录在 pending_cleanup_roots 里一并清理；
			# 当前根永远不在清理范围（防御：记录里的路径可能与当前根重合）
			var cleanup_ok := _cleanup_old_root(old_root)
			for r in journal.get("pending_cleanup_roots", []):
				var extra := normalize(str(r))
				if extra.is_empty() or extra == new_root:
					continue
				if not _cleanup_old_root(extra):
					cleanup_ok = false
			if cleanup_ok:
				_delete_journal()
				GLogger.info("Storage migration committed, old root cleaned", "StorageMGR")
			else:
				var j := _read_journal()
				j["state"] = "cleanup_pending"
				j["updated_at"] = Time.get_unix_time_from_system()
				_write_journal(j)
				GLogger.warning("Storage migration committed, old root cleanup pending", "StorageMGR")
			var res := _result(bool(decision.get("needs_full_rescan", true)), false, "commit")
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
## 同样只做浅层枚举：判定"有数据"不需要知道具体文件数
static func _has_migration_data(root: String) -> bool:
	var r := normalize(root)
	if r.is_empty():
		return false
	for d in MIGRATABLE_DIRS:
		if _dir_has_entries(r + d):
			return true
	for f in MIGRATABLE_FILES:
		if FileAccess.file_exists(r + f):
			return true
	return false

# ============================================================
# 迁移（运行期，SettingView 触发）
# ============================================================

## 完整迁移：合并 → 复制 → 校验 → 提交。协程，需要 UI 进度时传入 ui（show_progress_ui 返回值）
## 两种取值方式（玩家在 StorageConflictAdjust 里选的）：
##   overwrite_target=false（默认，推荐）：**目标侧优先、单向补缺** —— 目标已有的一律保留，
##     目标缺的从当前根搬过去；数据库与收藏夹额外做内容合并（同一 _id / 同一收藏夹保留目标那份）
##   overwrite_target=true：**用当前版本覆盖目标** —— 顶层文件与数据库整份替换目标侧，
##     不做任何合并（玩家认为当前这份才是对的，比如目标库是空的/旧的）
## 返回 {ok, reason, inherited_config}；ok=true 表示已提交（重启后生效）
## inherited_config=true 表示最终生效的是目标自带的配置（设置/外观是目标那份），
##   当前会话的配置来源已改变，只能重启生效，调用方不得走原地热切换
## prevalidated=true 表示调用方刚用 validate_target_path() 校验过同一路径，
##   跳过重复校验（该校验含目标目录枚举，重复执行会让玩家再多等一次）
## keep_db_closed=true 表示提交后不重开旧根 DB（调用方将原地切到新根并打开新库）
func migrate(old_root: String, new_root: String, ui: Dictionary = {},
		prevalidated: bool = false, overwrite_target: bool = false,
		keep_db_closed: bool = false) -> Dictionary:
	new_root = normalize(new_root)
	if not prevalidated:
		var v := validate_target_path(new_root)
		if not bool(v.get("ok", false)):
			return {"ok": false, "reason": str(v.get("reason", "路径无效"))}
	elif not DirAccess.dir_exists_absolute(new_root):
		return {"ok": false, "reason": "目标目录已不可用，请重新选择"}

	old_root = normalize(old_root)
	if old_root == new_root:
		return {"ok": false, "reason": "目标路径与当前存储路径相同"}
	# 最终生效的配置来自哪一侧：
	#   覆盖目标 → 当前根那份（= 会话内存里的配置，热切换安全）
	#   保留目标且目标有 settings.ini → 目标那份（与会话内配置不同，必须重启）
	var inherited_config := not overwrite_target and FileAccess.file_exists(new_root + "settings.ini")

	# 1. 写迁移日志（in_progress）
	# 热切换后可以在同一会话内再次迁移，此时上一次迁移的旧根还没被清理，而新日志会
	# 覆盖掉它的记录 —— 把这类根记进 pending_cleanup_roots，等下次启动验证新根通过后
	# 一并清理（仍然遵守"先验证、后删除"，只是把记录带过去，避免留下一份无用副本）
	var pending_cleanup: Array = []
	var prev_journal := _read_journal()
	for r in prev_journal.get("pending_cleanup_roots", []):
		var pr := normalize(str(r))
		if not pr.is_empty() and pr != old_root and pr != new_root and pr not in pending_cleanup:
			pending_cleanup.append(pr)
	var prev_state := str(prev_journal.get("state", ""))
	if prev_state == "committed" or prev_state == "cleanup_pending":
		var prev_old := normalize(str(prev_journal.get("old_root", "")))
		if not prev_old.is_empty() and prev_old != old_root and prev_old != new_root \
				and prev_old not in pending_cleanup:
			pending_cleanup.append(prev_old)

	var journal := {
		"state": "in_progress",
		"prev_override": PathHelper._storage_root_override,
		"old_root": old_root,
		"new_root": new_root,
		# 提交后是否需要一次全量扫描（绝对路径已变）；扫描完成后由 mark_rescan_done() 复位
		"rescan_pending": true,
		# 更早的迁移残留的旧根（同一会话内连续迁移时），随本次一起在启动验证后清理
		"pending_cleanup_roots": pending_cleanup,
		"migration_id": str(Time.get_unix_time_from_system()) + "_" + str(randi()),
		"started_at": Time.get_unix_time_from_system(),
		"updated_at": Time.get_unix_time_from_system(),
	}
	if not _write_journal(journal):
		return {"ok": false, "reason": "无法写入迁移日志"}

	# 2. 停止播放 + 关闭 DB（LiteDB 单文件锁，必须先关再复制/合并 charts.ldb）
	#    先等后台缓存校验/扫描退出：它会读写 ChartDB，与关库并发会撞上已释放的库
	var fsm := FileSystemManager.instance
	if fsm != null and fsm.is_busy() and get_tree() != null:
		await fsm.await_busy_done()
	if PlaybackDisplay.instance != null:
		PlaybackDisplay.instance.stop()
	var db_closed: bool = false
	if ChartDB != null and ChartDB.IsOpen():
		ChartDB.CloseDb()
		db_closed = true
	var old_cache := ProjectSettings.globalize_path(PathHelper.get_base_dir()).path_join(".charts_scan_cache.json")

	# 3. 先合并两侧用户数据进目标（数据库记录 / 收藏夹条目），再做文件复制。
	#    放在复制之前：合并失败时目标目录还没被动过，直接中止并重开旧库即可。
	#    覆盖目标时不做合并 —— 玩家选了"当前这份才算数"
	var merge_res := {"ok": true}
	if not overwrite_target:
		merge_res = _merge_side_data(old_root, new_root)
	if not bool(merge_res.get("ok", false)):
		if db_closed and ChartDB != null:
			ChartDB.OpenDb(ProjectSettings.globalize_path(old_root + DB_FILE), old_cache)
		_delete_journal()
		return {"ok": false, "reason": "数据合并失败：%s" % str(merge_res.get("reason", "未知错误"))}

	# 4. 复制（让出一帧避免进度 UI 与弹窗遮罩动画冲突）
	if get_tree() != null:
		await get_tree().process_frame
	var copied := await _copy_storage(old_root, new_root, ui, overwrite_target)

	# 5. 校验：新根已包含迁移数据即可（复制过程已逐文件保证；不做旧根逐文件大小对账，
	#    迁移期间旧根仍在运行（日志/DB 持续写入），size 不一致不代表复制失败）
	var verified := false
	if copied:
		verified = _has_migration_data(new_root)

	# 6. 恢复会话：
	#    - 复制/校验失败：必须把旧根 DB 重开，保证当前会话可用（此前失败会留下 DB 关闭状态）
	#    - 常规路径：重开旧根 DB，重启前游戏继续用旧根运行
	#    - 热切换路径（keep_db_closed=true）：保持关闭，由调用方切根后打开新根库
	if not verified:
		if db_closed and ChartDB != null:
			ChartDB.OpenDb(ProjectSettings.globalize_path(old_root + DB_FILE), old_cache)
		_delete_journal()
		return {"ok": false, "reason": "迁移复制或校验失败，数据层已恢复，建议重启游戏"}
	if db_closed and ChartDB != null and not keep_db_closed:
		ChartDB.OpenDb(ProjectSettings.globalize_path(old_root + DB_FILE), old_cache)

	# 7. 提交：journal → committed，更新引导指针
	#    不在写新根 settings.ini：配置采用目标侧那份，过期键由重启后 needs_config_commit 补写；
	#    此时 PathHelper 仍指向旧根，往旧根写一遍没有意义（旧根验证通过后即被清理）
	journal["state"] = "committed"
	journal["updated_at"] = Time.get_unix_time_from_system()
	if not _write_journal(journal):
		return {"ok": false, "reason": "迁移已完成但无法写入提交日志，请重启游戏"}
	if not _write_pointer(new_root):
		return {"ok": false, "reason": "迁移已完成但无法更新引导指针，请重启游戏"}

	GLogger.info("Storage migration committed: %s -> %s (restart required)" % [old_root, new_root], "StorageMGR")
	return {"ok": true, "reason": "", "inherited_config": inherited_config}

## 迁移后的全量扫描完成：复位日志中的重扫标记。
## 只有真正扫完才复位，扫描中途崩溃时下次启动会继续补扫
func mark_rescan_done() -> void:
	var j := _read_journal()
	if j.is_empty() or not bool(j.get("rescan_pending", false)):
		return
	j["rescan_pending"] = false
	j["updated_at"] = Time.get_unix_time_from_system()
	_write_journal(j)

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

## 复制可迁移内容（全部用户数据目录 + 顶层文件）
## overwrite_target=false：目录与顶层文件都"跳过已存在"（目标优先，缺的补齐），绝不覆盖目标
## overwrite_target=true：顶层文件与数据库整份覆盖目标（目录仍按文件粒度补缺，不删目标多余文件）
## ui: FileSystemManager.show_progress_ui 返回值 {overlay, tip, bar}，可为空
func _copy_storage(old_root: String, new_root: String, ui: Dictionary,
		overwrite_target: bool = false) -> bool:
	var bar: ProgressBar = ui.get("bar", null)
	var tip: Label = ui.get("tip", null)
	# 统计总文件数用于进度条。这一步与复制一样要遍历整棵树，故分帧让出，
	# 否则进度条刚显示就会在主线程上僵住（大曲库可达数秒）。
	# 统计期间进度条必然停在 0，提示文案先说明当前在做什么，避免看起来像卡死。
	var restore_tip := ""
	if tip:
		restore_tip = tip.text
		tip.text = "正在统计待迁移文件，请稍后"
	var count_state := {"visited": 0, "last_yield": 0}
	var total := 0
	for d in MIGRATABLE_DIRS:
		if DirAccess.dir_exists_absolute(old_root + d):
			total += await _count_files_async(old_root + d, count_state)
	for f in MIGRATABLE_FILES:
		if not f.ends_with(".lock") and FileAccess.file_exists(old_root + f):
			total += 1
	if tip:
		tip.text = restore_tip
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

	# 数据库单独先处理：主库与日志必须成对，且"先主库后日志"
	var target_has_db := FileAccess.file_exists(new_root + DB_FILE)
	var src_db := old_root + DB_FILE
	var src_log := old_root + DB_LOG_FILE
	var dst_log := new_root + DB_LOG_FILE
	# 需要写入数据库的两种情况：玩家选了覆盖目标；或目标本来就没有库（只能整份搬过去）。
	# 目标是"保留"且已有主库时两者都留目标侧（缺失记录已由 _merge_side_data 补进去），
	# 绝不能把源侧 charts-log.ldb 混进目标主库 —— 那是另一个库的 journal，回放会写坏库。
	if overwrite_target or not target_has_db:
		if FileAccess.file_exists(src_db):
			if not _copy_file(src_db, new_root + DB_FILE):
				return false
			progress_cb.call()
		if FileAccess.file_exists(src_log):
			if not _copy_file(src_log, dst_log):
				return false
			progress_cb.call()
		elif FileAccess.file_exists(dst_log):
			# 目标侧残留的日志与新主库不配套，留着会被回放到新库上
			# （页面类型不匹配 → LiteDB 判库损坏 → RemoveCorruptDb 删库，等于白搬）
			DirAccess.remove_absolute(dst_log)

	# 复制其余顶层文件（用户数据；.lock 属会话锁文件，不复制）
	# 默认（overwrite_target=false）：目标已存在的一律保留目标版本，只补目标缺的文件
	for f in MIGRATABLE_FILES:
		if f.ends_with(".lock") or f == DB_FILE or f == DB_LOG_FILE:
			continue  # 数据库上面已处理
		var src := old_root + f
		if not FileAccess.file_exists(src):
			continue
		if not overwrite_target and FileAccess.file_exists(new_root + f):
			progress_cb.call()
			continue
		if not _copy_file(src, new_root + f):
			return false
		progress_cb.call()
	return true

## 合并两侧用户数据到目标侧（目标优先，只补缺）：
##   charts.ldb     —— 目标已有库时逐集合补入缺失 _id（委托 ChartDb.MergeStorageDatabases）
##   favorites.json —— 两侧收藏夹按 id 取并集，同 id 保留目标那份
## 仅在"保留目标"模式下调用；"覆盖目标"模式由 _copy_storage 整份替换，不需要合并
## 返回 {ok, reason}；任一环节失败即中止迁移（此时尚未复制任何文件）
func _merge_side_data(old_root: String, new_root: String) -> Dictionary:
	if FileAccess.file_exists(new_root + DB_FILE):
		var src_db := old_root + DB_FILE
		if FileAccess.file_exists(src_db):
			if ChartDB == null:
				return {"ok": false, "reason": "数据层不可用"}
			var r: Dictionary = ChartDB.MergeStorageDatabases(
				ProjectSettings.globalize_path(new_root + DB_FILE),
				ProjectSettings.globalize_path(src_db))
			if not bool(r.get("ok", false)):
				return {"ok": false, "reason": str(r.get("error", "数据库合并失败"))}
			GLogger.info("Storage DB merged (target wins): %s" % str(r.get("added", {})), "StorageMGR")
	var src_fav := old_root + "favorites.json"
	var dst_fav := new_root + "favorites.json"
	if FileAccess.file_exists(src_fav) and FileAccess.file_exists(dst_fav):
		# 收藏夹合并失败不中止迁移：最多是少合并几条旧收藏，没理由让整次搬库失败
		if not _merge_favorites_file(dst_fav, src_fav):
			GLogger.warning("Favorites merge failed (target file not writable)", "StorageMGR")
	return {"ok": true, "reason": ""}

## 收藏夹合并：把源侧独有的收藏夹追加到目标侧（同 id 保留目标那份），只写目标文件
## 解析失败一律按"不动目标"处理 —— 目标侧是玩家要保留的一方，宁可少合并也不破坏它
func _merge_favorites_file(dst_path: String, src_path: String) -> bool:
	var target = JSON.parse_string(FileAccess.get_file_as_string(dst_path))
	var source = JSON.parse_string(FileAccess.get_file_as_string(src_path))
	if target is not Dictionary or source is not Dictionary:
		GLogger.warning("Favorites merge skipped: unparsable json", "StorageMGR")
		return true
	var t_list: Array = target.get("favorites", [])
	var s_list: Array = source.get("favorites", [])
	if not (t_list is Array) or not (s_list is Array):
		return true
	var known := {}
	for e in t_list:
		if e is Dictionary:
			var eid := str(e.get("id", ""))
			if not eid.is_empty():
				known[eid] = true
	var added := 0
	for e in s_list:
		if e is not Dictionary:
			continue
		var sid := str(e.get("id", ""))
		if sid.is_empty() or known.has(sid):
			continue
		t_list.append(e)
		known[sid] = true
		added += 1
	if added == 0:
		return true
	target["favorites"] = t_list
	var f := FileAccess.open(dst_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(target, "\t"))
	f.close()
	GLogger.info("Favorites merged: %d list(s) appended from current root" % added, "StorageMGR")
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
				# 按时间片让出（每帧 8ms），而不是每 8 个文件让出一次：
				# 后者在几万文件时会把迁移拖成"每秒几百个"的龟速
				var now := Time.get_ticks_usec()
				if now - _copy_yield_usec > 8000 and get_tree() != null:
					_copy_yield_usec = now
					await get_tree().process_frame
		entry = dir.get_next()
	dir.list_dir_end()
	return true

## 迁移复制的分帧时间片起点（微秒）
var _copy_yield_usec: int = 0

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

## 目录顶层是否存在非隐藏条目（只读一层，发现首个条目立即返回）
## 用于"目录是否已有内容"的判定；隐藏条目（. 开头）与迁移复制的忽略规则保持一致
static func _dir_has_entries(dir_path: String) -> bool:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return false
	var found := false
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			found = true
			break
		entry = dir.get_next()
	dir.list_dir_end()
	return found

## 统计目录下文件总数（递归，忽略隐藏条目）
## 分帧让出：每遍历约 2000 个文件让出一帧，避免进度条在统计阶段卡死界面
## state: 跨递归共享 {visited, last_yield}，用于判断何时让出
func _count_files_async(dir_path: String, state: Dictionary) -> int:
	var count := 0
	for f in DirAccess.get_files_at(dir_path):
		if not f.begins_with("."):
			count += 1
	state["visited"] = int(state["visited"]) + count
	if int(state["visited"]) - int(state["last_yield"]) >= 2000:
		state["last_yield"] = int(state["visited"])
		if get_tree() != null:
			await get_tree().process_frame
	for d in DirAccess.get_directories_at(dir_path):
		if not d.begins_with("."):
			count += await _count_files_async(dir_path.path_join(d), state)
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
