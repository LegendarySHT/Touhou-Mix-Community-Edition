## 文件系统管理器
## 负责管理游戏资源目录（谱面、皮肤、音源、日志等）
## 支持自动初始化默认内容和玩家自定义内容的热加载
## Android 平台使用外部可见路径，其他平台使用 user://
extends Node

class_name FileSystemManager

## 单例实例
static var instance: FileSystemManager

## ========== 目录路径定义（通过 PathHelper 动态获取） ==========
## 使用 getter 确保运行时才求值，避免类加载期间 OS.has_feature() 未就绪的问题
static var BASE_DIR: String:
	get: return PathHelper.get_base_dir()
static var CHARTS_DIR: String:
	get: return PathHelper.get_charts_dir()
static var SKINS_DIR: String:
	get: return PathHelper.get_skins_dir()
static var PARTICLES_DIR: String:
	get: return PathHelper.get_particles_dir()
static var SOUNDFONT_DIR: String:
	get: return PathHelper.get_soundfont_dir()
static var BACKGROUND_DIR: String:
	get: return PathHelper.get_background_dir()
static var LOGS_DIR: String:
	get: return PathHelper.get_logs_dir()
static var SETTINGS_DIR: String:
	get: return PathHelper.get_settings_dir()

## 默认资源源目录
const DEFAULT_CHARTS_SRC = "res://Resources/Charts/"
const DEFAULT_SOUNDFONT_SRC = "res://Resources/Soundfont/"
const DEFAULT_BACKGROUND_SRC = "res://Resources/BackgroundImage/"
## 中央封面目录：封面以 {coverHash}.{ext} 命名，由谱面 JSON 的 coverHash 引用
const DEFAULT_COVERS_SRC = "res://Resources/Covers/"
## 查找中央封面时尝试的扩展名（coverHash 纯哈希不带扩展名）
const COVER_HASH_EXTS = ["jpg", "jpeg", "png", "webp"]
## 默认封面路径（兜底用，res:// 中的默认封面资源）
const DEFAULT_COVER_PATH := "res://Resources/Covers/423be8d161a8a972c9014454921864a9.jpg"

## 通用加载/导入提示文案（ProcessTip，与 Main.tscn 默认文案一致）
const LOADING_TIP_TEXT := "加载中，请稍后"
const COPY_TIP_TEXT := "正在初始化资源，请稍后"
const IMPORT_TIP_TEXT := "正在导入数据，请稍后"
const SCAN_TIP_TEXT := "正在扫描谱面，请稍后"

## 图片文件扩展名列表（Godot 导出时会被转换为 .ctex，无法通过 FileAccess 直接读取）
const IMAGE_EXTENSIONS = ["jpg", "jpeg", "png", "webp"]

## .import 文件后缀（Godot 导出后，res:// 中的图片以 xxx.jpg.import 形式存在）
const IMPORT_SUFFIX = ".import"

## charts 扫描分片大小：每片包含的目录数
## 2000 谱面 → ~32 片，由 WorkerThreadPool 按核心数调度，足够并行粒度
const CHART_SCAN_CHUNK_SIZE := 64

## ========== 资源索引 ==========
## 谱面索引 {chart_id: ChartMetadata}
var charts_index: Dictionary = {}

## 音源索引 {soundfont_name: {path, size_mb, is_builtin}}
var soundfonts_index: Dictionary = {}

## 背景图索引 {background_name: String(path)}
var backgrounds_index: Dictionary = {}

## 封面纹理弱引用缓存 {cover_path: WeakRef}
## 用 WeakRef 而非强引用：列表项释放 cover_texture.texture=null 后，
## Texture 引用计数归零自动 GC，缓存中的 WeakRef 随之失效，下次重新加载
## 多列表项共享同一 Texture 时，只要任一项仍引用，WeakRef 即有效（命中缓存零开销）
## WeakRef 失效时 load_cover_with_cache 会自动 erase 条目，Dictionary 不会无限增长
var _cover_texture_cache: Dictionary = {}

## coverHash → 稳定封面缓存键路径
## 同一 coverHash 的封面内容必然一致，复用首个解析到的真实路径作为缓存键，
## 使不同歌曲（不同 cover_path）指向同一份 Texture，实现封面去重
## clear_cover_cache 时一并清空，防止谱面删除后键指向已不存在的路径
var _cover_hash_to_path: Dictionary = {}

## ========== 反向索引 ==========
## {chart_id: folder_name}
var _chart_id_to_folder: Dictionary = {}
## {file_hash: folder_name}
var _hash_to_folder: Dictionary = {}
## ========== 音频文件索引 ==========
## [{file_name, path, format, chart_id, song_name}]
var audio_files_index: Array[Dictionary] = []

## ========== 状态标志 ==========
var is_initialized: bool = false
var is_scanning: bool = false
var resources_scanned: bool = false  ## 标记资源扫描是否已完成
## 存储根迁移后强制全量扫描（跳过 DB 缓存恢复，重建投影中的绝对路径）
## 由 StorageManager.recover_and_resolve() 在检测到刚迁移时置位，扫描结束后复位
var force_full_rescan: bool = false
## 后台缓存校验进行中标志（fire-and-forget 协程 _await_cache_validation 运行期间为 true）
## 此期间 charts_index 可能被协程 clear + 重建，外部若要安全读取/删除需 await await_busy_done()
var _is_validating: bool = false

## 结构变更检测：扫描前拍下的 (folder_name -> "album_id|song_id") 快照
## 扫描/校验完成后对比，不一致则 emit charts_structure_changed 让 AlbumView/SongView 统一刷新
var _pre_scan_structure: Dictionary = {}

## ========== 信号 ==========
signal resources_ready

## 是否正忙于扫描或后台校验（外部判断 charts_index 是否稳定）
func is_busy() -> bool:
	return is_scanning or _is_validating

## 等待扫描 + 后台校验全部完成（charts_index 稳定可读）
## DelView 构建页 / rescan 前调用，防止与后台校验协程并发 clobber charts_index
func await_busy_done() -> void:
	while is_scanning or _is_validating:
		await get_tree().process_frame

## 记录当前 DB 内的结构快照（扫描/校验前调用）
func _snapshot_structure_pre() -> void:
	if ChartDB and ChartDB.IsOpen():
		_pre_scan_structure = ChartDB.GetStructureSnapshot()
	else:
		_pre_scan_structure.clear()

## 对比快照 + DB 最新结构；不一致则 emit charts_structure_changed 让 UI 统一刷新
## 仅扫描/校验全部完成后调用一次，避免中间刷新卡顿
func _snapshot_structure_check_and_emit() -> void:
	if not (ChartDB and ChartDB.IsOpen() and EvtBus):
		return
	var after: Dictionary = ChartDB.GetStructureSnapshot()
	if after == _pre_scan_structure:
		return
	var before_size: int = _pre_scan_structure.size()
	var after_size: int = after.size()
	_pre_scan_structure = after
	EvtBus.charts_structure_changed.emit()
	GLogger.info("Structure changed (charts=%d -> %d), emitted charts_structure_changed" % [
		before_size, after_size
	], "FileSystemMGR")

func _ready() -> void:
	if instance == null:
		instance = self
	else:
		queue_free()
	
	add_to_group("singleton")
	
	# 输出平台信息以便调试
	var platform = OS.get_name()
	var user_data_dir = OS.get_user_data_dir()
	GLogger.info("Platform: %s" % platform, "FileSystemMGR")
	GLogger.info("User data directory: %s" % user_data_dir, "FileSystemMGR")
	GLogger.info("Base directory: %s" % BASE_DIR, "FileSystemMGR")
	GLogger.info("Charts directory: %s" % CHARTS_DIR, "FileSystemMGR")
	if PathHelper.is_android():
		GLogger.info("Android external storage enabled", "FileSystemMGR")
		GLogger.info(PathHelper.get_debug_info(), "FileSystemMGR")
	GLogger.info("FileSystemManager initialized", "FileSystemMGR")

## 检查关键 res:// 资源是否在导出包中存在（Android 调试用）
func check_critical_resources() -> void:
	GLogger.info("=== Checking critical resources in PCK ===", "FileSystemMGR")
	
	var critical_resources = {
		"Config": "res://Resources/Config/config.ini",
		"Charts Directory": DEFAULT_CHARTS_SRC,
		"Soundfont Directory": DEFAULT_SOUNDFONT_SRC,
		"Background Directory": DEFAULT_BACKGROUND_SRC,
		"Skins Directory": SkinManager.DEFAULT_SKINS_SRC,
		"Particles Directory": ParticleMGR.DEFAULT_PARTICLES_SRC,
		"Charas Directory": CharaMGR.DEFAULT_CHARAS_SRC
	}
	
	for resource_name in critical_resources.keys():
		var resource_path = critical_resources[resource_name]
		var exists = false
		
		# 检查文件或目录是否存在
		if resource_path.ends_with("/"):
			exists = DirAccess.dir_exists_absolute(resource_path)
		else:
			exists = FileAccess.file_exists(resource_path)
		
		var status = "✓ FOUND" if exists else "✗ MISSING"
		GLogger.info("%s: %s [%s]" % [resource_name, status, resource_path], "FileSystemMGR")
		
		if not exists:
			GLogger.error("Critical resource missing: %s - Check export settings!" % resource_name, "FileSystemMGR")
	
	GLogger.info("=== Resource check complete ===", "FileSystemMGR")

## 初始化目录结构（修改为异步等待资源复制完成）
func initialize_directory_structure() -> void:
	if is_initialized:
		GLogger.warning("FileSystemManager already initialized", "FileSystemMGR")
		return
	
	GLogger.info("Initializing directory structure...", "FileSystemMGR")
	
	# Android 平台：首先检查关键资源是否被正确导出
	check_critical_resources()
	
	# 创建所有必需目录
	var directories = [
		CHARTS_DIR,
		SKINS_DIR,
		PARTICLES_DIR,
		SOUNDFONT_DIR,
		BACKGROUND_DIR,
		LOGS_DIR,
		SETTINGS_DIR
	]
	
	for dir_path in directories:
		_ensure_directory_exists(dir_path)
	
	# 启动文件处理串行管线：先复制默认资源 → 再导入外部游戏数据 → 最后扫描并更新数据库缓存
	await _copy_default_resources_async()
	await _import_external_charts_async()
	_scan_all_resources()

## 确保目录存在，不存在则创建
## 使用 make_dir_recursive_absolute 以兼容 Android 绝对路径
func _ensure_directory_exists(dir_path: String) -> bool:
	if DirAccess.dir_exists_absolute(dir_path):
		return true
	
	var error = DirAccess.make_dir_recursive_absolute(dir_path)
	if error == OK:
		GLogger.info("Created directory: %s" % dir_path, "FileSystemMGR")
		return true
	else:
		GLogger.error("Failed to create directory: %s (Error: %d)" % [dir_path, error], "FileSystemMGR")
		return false

## 异步复制默认资源（目录为空才复制；带统一进度条 UI）
## 仅负责文件复制，导入与数据库扫描由 initialize_directory_structure 串行编排
func _copy_default_resources_async() -> void:
	# 统计本次需要执行的操作总数（复制谱面按谱面目录数计，皮肤/背景各计 1 步）
	var total_steps := _count_default_chart_folders()
	if _is_directory_empty(SKINS_DIR):
		total_steps += 1
	if _is_directory_empty(BACKGROUND_DIR):
		total_steps += 1

	var bar: ProgressBar = null
	if total_steps > 0:
		bar = show_progress_ui(COPY_TIP_TEXT, total_steps)["bar"]

	var done := 0
	# 复制谱面（若目录为空）
	if _is_directory_empty(CHARTS_DIR):
		GLogger.info("Charts directory is empty, copying default charts...", "FileSystemMGR")
		done = await _copy_default_charts_async(bar)
		if bar:
			bar.value = minf(done, bar.max_value)

	# 复制皮肤（若目录为空）
	if _is_directory_empty(SKINS_DIR):
		GLogger.info("Skins directory is empty, copying default skins...", "FileSystemMGR")
		await _copy_directory_recursive_async(SkinManager.DEFAULT_SKINS_SRC, SKINS_DIR)
		done += 1
		if bar:
			bar.value = minf(done, bar.max_value)

	# 音源目录：仅创建目录，不复制默认资源
	_ensure_directory_exists(SOUNDFONT_DIR)
	GLogger.info("Soundfont directory ready (no default resources copied)", "FileSystemMGR")

	# 复制背景图（若目录为空）
	if _is_directory_empty(BACKGROUND_DIR):
		GLogger.info("Background directory is empty, copying default backgrounds...", "FileSystemMGR")
		await _copy_directory_contents_async(DEFAULT_BACKGROUND_SRC, BACKGROUND_DIR, "jpg,jpeg,png,webp")
		done += 1
		if bar:
			bar.value = minf(done, bar.max_value)

	if total_steps > 0:
		hide_progress_ui()

## 异步导入外部游戏（THMIX）数据
## 主线程先快速检查导入任务（check_import_task，含诊断日志），决定是否显示导入 UI 并启动后台 worker
## 转换在 WorkerThreadPool 后台执行（纯文件 I/O），进度经 progress_cb 以 call_deferred 送回主线程，
## state 只在任务完成后读取（任务完成有 happens-before），全程无跨线程并发读写，不阻塞界面
func _import_external_charts_async() -> void:
	# 检查导入任务：has_work 决定是否启动后台 worker；ui_pending 决定是否显示进度 UI
	var task_info: Dictionary = ExternalGameConverter.check_import_task()
	if not task_info.get("has_work", false):
		return
	var pending: int = int(task_info.get("ui_pending", 0))
	var show_ui: bool = pending > 0

	# 显示统一进度 UI（遮罩 + 提示 + 进度条），仅当有待导入任务时
	var ui := {}
	var bar: ProgressBar = null
	if show_ui:
		ui = show_progress_ui(IMPORT_TIP_TEXT, pending)
		bar = ui["bar"]

	# 进度回调：worker 内 call_deferred 调用 → 主线程执行，更新进度条（与 Logger 的 worker 转主线程同模式）
	var progress_cb := func(cur: int, total: int) -> void:
		if bar:
			if total > 0:
				bar.max_value = maxf(total, 1)
			bar.value = minf(cur, total)

	var state: Dictionary = {}
	var task_id := WorkerThreadPool.add_task(
		func(): ExternalGameConverter.check_and_convert(state, progress_cb),
		false, "ImportTHMIX"
	)
	if task_id < 0:
		GLogger.error("启动 THMIX 导入 worker 失败（task_id=%d）" % task_id, "FileSystemMGR")
		if show_ui:
			hide_progress_ui()
		return

	while not WorkerThreadPool.is_task_completed(task_id):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)

	# 输出 worker 收集的诊断日志（任务完成后读取，主线程统一写 GLogger）
	for w in state.get("warnings", []):
		GLogger.warning(w, "ExternalConverter")
	for i in state.get("info", []):
		GLogger.info(i, "ExternalConverter")

	var converted: int = int(state.get("converted", 0))
	GLogger.info("外部数据导入结束：转换 %d 个谱面" % converted, "FileSystemMGR")

	# 立即把新导入的谱面扫描进 DB 缓存，让 _scan_all_resources 阶段 A 从缓存即可看到，无需等后台校验补扫
	var imported_folders: Array = state.get("imported_folders", [])
	if not imported_folders.is_empty() and ChartDB != null and ChartDB.IsOpen():
		await _sync_imported_charts_to_db(imported_folders)

	if show_ui:
		hide_progress_ui()

## 显示统一进度 UI（遮罩 + 提示 + 进度条），供启动期复制/导入/扫描复用
## 返回值：{overlay, tip, bar} 字典，调用方在循环中推进 "bar".value 即可
func show_progress_ui(text: String, max_value: int) -> Dictionary:
	var ui := {
		"overlay": get_node_or_null(PathRegistry.POPUP_WINDOW_SHADER) as Control,
		"tip": get_node_or_null(PathRegistry.PROCESS_TIP) as Label,
		"bar": get_node_or_null(PathRegistry.PROCESS_PROGRESS) as ProgressBar,
	}
	var overlay: Control = ui["overlay"]
	var tip: Label = ui["tip"]
	var bar: ProgressBar = ui["bar"]
	if overlay:
		overlay.modulate.a = 1.0  # 复位透明度（与 PopupWindow 的 fade 共享此节点，防御残留 0）
		overlay.visible = true
	if tip:
		tip.visible = true
		tip.text = text
	if bar:
		bar.visible = true
		bar.min_value = 0
		bar.max_value = maxf(max_value, 1)
		bar.value = 0
		bar.show_percentage = true
	return ui

## 隐藏统一进度 UI 并复位提示文案
func hide_progress_ui() -> void:
	var overlay: Control = get_node_or_null(PathRegistry.POPUP_WINDOW_SHADER)
	var tip: Label = get_node_or_null(PathRegistry.PROCESS_TIP)
	var bar: ProgressBar = get_node_or_null(PathRegistry.PROCESS_PROGRESS)
	if bar:
		bar.visible = false
	if tip:
		tip.text = LOADING_TIP_TEXT
	if overlay:
		overlay.visible = false

## 把新导入的谱面文件夹扫描并写入 DB 缓存（复用分片扫描 worker）
## 使随后的 _scan_all_resources 阶段 A 从缓存即可构建 charts_index，谱面立即可见
func _sync_imported_charts_to_db(imported_folders: Array) -> void:
	var chart_tasks := _start_charts_scan_tasks(imported_folders)
	while not _all_chart_tasks_completed(chart_tasks):
		await get_tree().process_frame
	for t in chart_tasks:
		WorkerThreadPool.wait_for_task_completion(t.id)

	var new_data: Dictionary = {}
	for t in chart_tasks:
		var task_rw: Dictionary = t.result
		var charts_data: Dictionary = task_rw.get("charts", {})
		for folder_name in charts_data.keys():
			new_data[folder_name] = charts_data[folder_name]
	if new_data.is_empty():
		return
	_save_charts_cache(new_data)
	GLogger.info("导入完成，已将 %d 个新谱面同步到 DB 缓存（无需等后台校验）" % new_data.size(), "FileSystemMGR")

## 统计默认谱面源目录下的子目录数（供复制进度条 max 使用）
func _count_default_chart_folders() -> int:
	var source_dir := DirAccess.open(DEFAULT_CHARTS_SRC)
	if source_dir == null:
		return 0
	var count := 0
	source_dir.list_dir_begin()
	var entry_name := source_dir.get_next()
	while entry_name != "":
		if source_dir.current_is_dir() and not entry_name.begins_with("."):
			count += 1
		entry_name = source_dir.get_next()
	source_dir.list_dir_end()
	return count

## 异步复制所有默认谱面（在每个文件夹复制后让步）
## progress_bar: 非空则每复制完一个谱面目录推进一次进度；返回实际复制的目录数
func _copy_default_charts_async(progress_bar: ProgressBar = null) -> int:
	var source_base = DEFAULT_CHARTS_SRC
	var dest_base = CHARTS_DIR
	
	if not DirAccess.dir_exists_absolute(source_base):
		GLogger.warning("Charts source directory not found in PCK", "FileSystemMGR")
		return 0
	
	GLogger.info("Starting to copy default charts from PCK...", "FileSystemMGR")
	
	var source_dir = DirAccess.open(source_base)
	if not source_dir:
		GLogger.error("Failed to open source charts directory", "FileSystemMGR")
		return 0
	
	source_dir.list_dir_begin()
	var chart_folder = source_dir.get_next()
	var copied_count = 0
	
	while chart_folder != "":
		if source_dir.current_is_dir() and not chart_folder.begins_with("."):
			var source_chart_path = source_base + chart_folder
			var dest_chart_path = dest_base + chart_folder
			
			if not DirAccess.dir_exists_absolute(dest_chart_path):
				DirAccess.make_dir_absolute(dest_chart_path)
			
			# 复制该文件夹内的所有文件（内部已改为可让步的版本）
			if await _copy_chart_files_from_pck_async(source_chart_path, dest_chart_path):
				copied_count += 1

			# 依据 JSON coverHash 从中央封面目录复制封面（封面已移出曲包）
			_copy_default_cover(dest_chart_path)

			if progress_bar:
				progress_bar.value = minf(copied_count, progress_bar.max_value)
			
			# 每处理完一个 chart 文件夹，让出一帧，保持界面响应
			await get_tree().process_frame
		
		chart_folder = source_dir.get_next()
	
	source_dir.list_dir_end()
	GLogger.info("Copied %d chart folders from PCK" % copied_count, "FileSystemMGR")
	return 1

## 异步复制单个 chart 文件夹的所有文件（内部处理图片时使用资源加载器）
func _copy_chart_files_from_pck_async(source_path: String, dest_path: String) -> bool:
	var source_dir = DirAccess.open(source_path)
	if not source_dir:
		GLogger.warning("Failed to open chart folder: %s" % source_path, "FileSystemMGR")
		return false
	
	var success = false
	source_dir.list_dir_begin()
	var file_name = source_dir.get_next()
	
	while file_name != "":
		if not source_dir.current_is_dir():
			if _is_image_import_file(file_name):
				var original_name = _strip_import_suffix(file_name)
				var source_resource = source_path + "/" + original_name
				var dest_file = dest_path + "/" + original_name
				if _copy_image_via_resource_loader(source_resource, dest_file):
					success = true
			else:
				var source_file = source_path + "/" + file_name
				var dest_file = dest_path + "/" + file_name
				if _copy_file_from_pck(source_file, dest_file):
					success = true
			
			# 每复制一个文件后让出（可选，可减少卡顿感）
			await get_tree().process_frame
		
		file_name = source_dir.get_next()
	
	source_dir.list_dir_end()
	return success


## 检查文件是否为图片文件（基于扩展名）
static func _is_image_file(file_path: String) -> bool:
	var ext = file_path.get_extension().to_lower()
	return ext in IMAGE_EXTENSIONS

## 检查文件是否为图片的 .import 文件（Godot 导出后的形式）
## 例如: cover.jpg.import, instant.png.import
static func _is_image_import_file(file_name: String) -> bool:
	if not file_name.ends_with(IMPORT_SUFFIX):
		return false
	# 去掉 .import 后缀后检查原始扩展名
	var original_name = file_name.substr(0, file_name.length() - IMPORT_SUFFIX.length())
	return _is_image_file(original_name)

## 从 .import 文件名获取原始图片文件名
## cover.jpg.import → cover.jpg
static func _strip_import_suffix(file_name: String) -> String:
	if file_name.ends_with(IMPORT_SUFFIX):
		return file_name.substr(0, file_name.length() - IMPORT_SUFFIX.length())
	return file_name

## 通过 Godot 资源加载器复制图片文件（Android/导出兼容）
## Godot 导出时图片被导入系统转换为 .ctex（压缩纹理），原始 JPG/PNG 不在 PCK/APK 中
## 因此需要通过 ResourceLoader 加载纹理资源，再从 Image 对象重新保存为原始格式
func _copy_image_via_resource_loader(src_path: String, dest_path: String) -> bool:
	if not ResourceLoader.exists(src_path):
		GLogger.warning(
			"Image resource not found in PCK: %s" % src_path, "FileSystemMGR"
		)
		return false
	
	var texture = ResourceLoader.load(src_path, "Texture2D")
	if texture == null or not (texture is Texture2D):
		GLogger.warning(
			"Failed to load image as Texture2D: %s" % src_path, "FileSystemMGR"
		)
		return false
	
	var image: Image = (texture as Texture2D).get_image()
	if image == null:
		GLogger.warning(
			"Failed to get Image from texture: %s" % src_path, "FileSystemMGR"
		)
		return false
	
	# 根据目标文件扩展名选择保存格式
	var ext = dest_path.get_extension().to_lower()
	var error: Error
	
	match ext:
		"jpg", "jpeg":
			error = image.save_jpg(dest_path, 0.95)
		"png":
			error = image.save_png(dest_path)
		"webp":
			error = image.save_webp(dest_path)
		_:
			# 未知格式默认保存为 PNG（无损）
			error = image.save_png(dest_path)
	
	if error != OK:
		GLogger.error(
			"Failed to save image: %s (Error: %d)" % [dest_path, error], "FileSystemMGR"
		)
		return false
	
	#GLogger.info(
		#"Copied image via resource loader: %s" % dest_path.get_file(), "FileSystemMGR"
	#)
	return true

## 依据谱面 JSON 的 coverHash，从中央封面目录复制封面到谱面文件夹（cover.jpg）
## 封面已移出曲包，统一按 {coverHash}.{ext} 存于 res://Resources/Covers/
## 与 _copy_image_via_resource_loader 一致，导出后经 ResourceLoader 解码回原始格式
func _copy_default_cover(dest_chart_path: String) -> bool:
	# 在目标（user://）谱面文件夹中定位元数据 JSON
	var chart_id := dest_chart_path.get_file().split("_")[0]
	var json_path := ""
	var dir := DirAccess.open(dest_chart_path)
	if dir == null:
		return false
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "" and json_path.is_empty():
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			if lower == "info.json" or lower == (chart_id + ".json").to_lower():
				json_path = dest_chart_path.path_join(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	if json_path.is_empty():
		return false

	var metadata := _load_chart_from_json(json_path, chart_id)
	var cover_hash := str(metadata.get("coverHash", ""))
	if cover_hash.is_empty():
		return false

	# 按扩展名候选从中央目录查找并复制为 cover.jpg
	for ext in COVER_HASH_EXTS:
		var src := "%s%s.%s" % [DEFAULT_COVERS_SRC, cover_hash, ext]
		if ResourceLoader.exists(src):
			return _copy_image_via_resource_loader(src, dest_chart_path.path_join("cover.jpg"))
	GLogger.warning(
		"Default cover not found for hash %s (%s)" % [cover_hash, dest_chart_path],
		"FileSystemMGR"
	)
	return false

## 从 PCK 复制单个文件（关键方法）
## 注意：.import 图片文件应在目录遍历层处理，此方法作为防御性回退
func _copy_file_from_pck(source_path: String, dest_path: String) -> bool:
	# 跳过非图片的 .import 文件（无用的元数据）
	if source_path.ends_with(IMPORT_SUFFIX):
		if _is_image_import_file(source_path.get_file()):
			# .import 图片文件：转换为原始资源路径后通过 ResourceLoader 复制
			var original_source = _strip_import_suffix(source_path)
			var original_dest = _strip_import_suffix(dest_path)
			return _copy_image_via_resource_loader(original_source, original_dest)
		# 其他 .import 文件直接跳过
		return false
	
	# Android/导出兼容：res:// 下的图片文件需要通过资源加载器复制
	# 因为 Godot 导出时图片被转换为 .ctex，FileAccess 无法直接读取原始数据
	if source_path.begins_with("res://") and _is_image_file(source_path):
		return _copy_image_via_resource_loader(source_path, dest_path)
	
	# 非图片文件：使用 FileAccess 直接复制
	if not FileAccess.file_exists(source_path):
		GLogger.warning("Source file not found in PCK: %s" % source_path, "FileSystemMGR")
		return false
	
	var source_file = FileAccess.open(source_path, FileAccess.READ)
	if not source_file:
		var error = FileAccess.get_open_error()
		GLogger.warning(
			"Failed to read from PCK [%s], error code: %d" % [source_path, error],
			"FileSystemMGR"
		)
		return false
	
	var dest_file = FileAccess.open(dest_path, FileAccess.WRITE)
	if not dest_file:
		var error = FileAccess.get_open_error()
		GLogger.error(
			"Failed to write to user:// [%s], error code: %d" % [dest_path, error],
			"FileSystemMGR"
		)
		source_file.close()
		return false
	
	# 复制数据
	var file_size = source_file.get_length()
	if file_size > 0:
		var buffer = source_file.get_buffer(file_size)
		dest_file.store_buffer(buffer)
	
	source_file.close()
	dest_file.close()
	return true

## 检查目录是否为空
func _is_directory_empty(dir_path: String) -> bool:
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return true
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if not file_name.begins_with("."):
			dir.list_dir_end()
			return false
		file_name = dir.get_next()
	
	dir.list_dir_end()
	return true

## 异步复制目录内容（仅顶层文件）
func _copy_directory_contents_async(src_dir: String, dest_dir: String, extensions: String) -> void:
	if src_dir.begins_with("res://"):
		if not DirAccess.dir_exists_absolute(src_dir):
			GLogger.warning("Source directory not found in PCK: %s" % src_dir, "FileSystemMGR")
			return
	
	var dir = DirAccess.open(src_dir)
	if dir == null:
		GLogger.warning("Failed to open source directory: %s" % src_dir, "FileSystemMGR")
		return
	
	var ext_list = extensions.split(",")
	dir.list_dir_begin()
	var file_name = dir.get_next()
	var copied_count = 0
	
	while file_name != "":
		if not dir.current_is_dir() and not file_name.begins_with("."):
			if _is_image_import_file(file_name):
				var original_name = _strip_import_suffix(file_name)
				var original_ext = original_name.get_extension().to_lower()
				if ext_list.has(original_ext):
					var src_resource = src_dir.path_join(original_name)
					var dest_path = dest_dir.path_join(original_name)
					if _copy_image_via_resource_loader(src_resource, dest_path):
						copied_count += 1
			else:
				var file_ext = file_name.get_extension().to_lower()
				if ext_list.has(file_ext):
					var src_path = src_dir.path_join(file_name)
					var dest_path = dest_dir.path_join(file_name)
					if _copy_file_from_pck(src_path, dest_path):
						copied_count += 1
			
			# 每复制一个文件后让步
			await get_tree().process_frame
		
		file_name = dir.get_next()
	
	dir.list_dir_end()
	GLogger.info("Copied %d files from %s to %s" % [copied_count, src_dir, dest_dir], "FileSystemMGR")

## 异步递归复制整个目录（在文件循环中让步）
func _copy_directory_recursive_async(src_dir: String, dest_dir: String) -> void:
	if src_dir.begins_with("res://"):
		if not DirAccess.dir_exists_absolute(src_dir):
			GLogger.warning("Source directory not found in PCK: %s" % src_dir, "FileSystemMGR")
			return
	
	var dir = DirAccess.open(src_dir)
	if dir == null:
		GLogger.warning("Failed to open source directory: %s" % src_dir, "FileSystemMGR")
		return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	var copied_count = 0
	
	while file_name != "":
		if not file_name.begins_with("."):
			if dir.current_is_dir():
				var src_path = src_dir.path_join(file_name)
				var dest_path = dest_dir.path_join(file_name)
				_ensure_directory_exists(dest_path)
				await _copy_directory_recursive_async(src_path, dest_path)
			elif _is_image_import_file(file_name):
				var original_name = _strip_import_suffix(file_name)
				var src_resource = src_dir.path_join(original_name)
				var dest_path = dest_dir.path_join(original_name)
				if _copy_image_via_resource_loader(src_resource, dest_path):
					copied_count += 1
			else:
				var src_path = src_dir.path_join(file_name)
				var dest_path = dest_dir.path_join(file_name)
				if _copy_file_from_pck(src_path, dest_path):
					copied_count += 1
			
			# 每处理一个文件后让步
			await get_tree().process_frame
		
		file_name = dir.get_next()
	
	dir.list_dir_end()
	GLogger.info("Recursively copied %d files from %s" % [copied_count, src_dir], "FileSystemMGR")


## 扫描所有资源（两阶段：快速缓存恢复 + 后台校验）
## 阶段 A（主线程，<1秒）：读缓存 → 构建 charts_index → 启动 skins/sf/bg 并行扫描 → emit resources_ready
## 阶段 B（后台 worker）：校验 charts 缓存有效性 → 发现差异时 emit charts_cache_validated
## 用户在阶段 A 后即可操作，阶段 B 异步刷新 UI
func _scan_all_resources() -> void:
	if is_scanning:
		return
	# 若后台缓存校验仍在进行，先等其完成再开始 rescan，避免与校验协程并发 clobber charts_index
	while _is_validating:
		await get_tree().process_frame

	is_scanning = true
	var t_start := Time.get_ticks_usec()
	GLogger.info("Scanning all resources (cache + parallel)...", "FileSystemMGR")

	# 结构变更检测：扫描前拍下 DB 快照，完成后对比；仅结构变了才让 UI 大刷新
	_snapshot_structure_pre()

	# 清空所有索引（主线程，避免 worker 并发写）
	charts_index.clear()
	_chart_id_to_folder.clear()
	_hash_to_folder.clear()
	audio_files_index.clear()
	SkinMGR.clear_index()
	ParticleMGR.clear_index()
	CharaMGR.clear_index()
	soundfonts_index.clear()
	backgrounds_index.clear()

	# === 阶段 A.1：主线程列出所有 charts 目录 + 加载缓存 ===
	var all_chart_folders := _list_chart_folder_names()
	var cached_charts := _load_charts_cache()

	# 阶段 A.2：从缓存恢复 charts_index（缓存命中的文件夹直接用缓存数据）
	# 新增文件夹（缓存中没有的）暂时跳过，由后台校验 worker 扫描
	var all_charts_data: Dictionary = {}
	for folder_name in all_chart_folders:
		if cached_charts.has(folder_name):
			all_charts_data[folder_name] = cached_charts[folder_name]
	var cache_hit_count := all_charts_data.size()

	# 缓存策略决策：
	# - 缓存命中率 > 0（有缓存数据）：走快速路径，后台校验增量
	# - 缓存命中率为 0（首次启动或缓存失效）：走全量扫描路径，前台等待完成
	# - force_full_rescan（存储根刚迁移）：即使缓存命中也走全量扫描，
	#   因为缓存投影中的 path/json_path/cover_path/audio_path 等绝对路径仍指向旧根
	# 避免首次启动时用户看到空列表等 18 秒
	var use_fast_path := cache_hit_count > 0 and not force_full_rescan
	if use_fast_path:
		GLogger.info("Charts cache: %d/%d hit, %d new (will scan in background)" % [
			cache_hit_count, all_chart_folders.size(),
			all_chart_folders.size() - cache_hit_count
		], "FileSystemMGR")
	else:
		GLogger.info("Charts cache empty or miss, full scan mode", "FileSystemMGR")

	# 阶段 A.3：构建 charts_index + 反向索引 + audio_files_index（主线程，纯 CPU）
	# 快速路径：用缓存数据构建，让 resources_ready 时 charts_index 已有数据
	# 全量路径：跳过（_scan_charts_full_sync 会从 worker 结果构建）
	if use_fast_path:
		_build_charts_index_from_data(all_charts_data, [])

	# === 阶段 A.4：启动 skins/particles/sf/bg 并行扫描 ===
	var skins_rw: Dictionary = {}
	var skins_task := WorkerThreadPool.add_task(
		func(): SkinMGR._build_skins_index_worker(skins_rw),
		false, "ScanSkins"
	)
	var particles_rw: Dictionary = {}
	var particles_task := WorkerThreadPool.add_task(
		func(): ParticleMGR._build_particles_index_worker(particles_rw),
		false, "ScanParticles"
	)
	var charas_rw: Dictionary = {}
	var charas_task := WorkerThreadPool.add_task(
		func(): CharaMGR._build_charas_index_worker(charas_rw),
		false, "ScanCharas"
	)
	var sf_rw: Dictionary = {}
	var sf_task := WorkerThreadPool.add_task(
		func(): _scan_soundfonts_worker(sf_rw),
		false, "ScanSoundfonts"
	)
	var bg_rw: Dictionary = {}
	var bg_task := WorkerThreadPool.add_task(
		func(): _scan_backgrounds_worker(bg_rw),
		false, "ScanBackgrounds"
	)

	# === 阶段 A.5：charts 扫描 ===
	# 快速路径：启动后台校验 worker（不阻塞 emit resources_ready）
	# 全量路径：调用 _scan_charts_full_sync 同步扫描 + 构建索引 + 保存缓存
	if use_fast_path:
		_start_charts_cache_validation(all_chart_folders, cached_charts)
	else:
		# 首次全量扫描复用统一进度 UI（遮罩 + 提示 + 进度条），扫完隐藏
		var total_folders: int = all_chart_folders.size()
		var ui := {}
		var bar: ProgressBar = null
		if total_folders > 0:
			ui = show_progress_ui(SCAN_TIP_TEXT, total_folders)
			bar = ui["bar"]
		var scan_progress := func(done: int, total: int) -> void:
			if bar:
				bar.max_value = maxf(total, 1)
				bar.value = minf(done, total)
		await _scan_charts_full_sync(scan_progress)
		if total_folders > 0:
			hide_progress_ui()

	# === 阶段 A.6：等待 skins/sf/bg 完成 ===
	# 快速路径：只等 skins/sf/bg（charts 已从缓存恢复）
	# 全量路径：_scan_charts_full_sync 已完成，只等 skins/sf/bg
	var simple_tasks := [skins_task, particles_task, charas_task, sf_task, bg_task]
	while not _all_simple_tasks_completed(simple_tasks):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(skins_task)
	WorkerThreadPool.wait_for_task_completion(particles_task)
	WorkerThreadPool.wait_for_task_completion(charas_task)
	WorkerThreadPool.wait_for_task_completion(sf_task)
	WorkerThreadPool.wait_for_task_completion(bg_task)

	# 合并 skins/particles/sf/bg 结果
	var skins_data: Dictionary = skins_rw.get("skins", {})
	for skin_key in skins_data:
		SkinMGR.skins_index[skin_key] = SkinMetadata.from_dict(skins_data[skin_key])
	for log_entry in skins_rw.get("logs", []):
		if log_entry.get("is_warning", true):
			GLogger.warning(log_entry.msg, "SkinMGR")
		else:
			GLogger.info(log_entry.msg, "SkinMGR")
	ParticleMGR.particles_index = particles_rw.get("particles", {})
	for log_entry in particles_rw.get("logs", []):
		if log_entry.get("is_warning", true):
			GLogger.warning(log_entry.msg, "ParticleMGR")
		else:
			GLogger.info(log_entry.msg, "ParticleMGR")
	CharaMGR.charas_index = charas_rw.get("charas", {})
	for log_entry in charas_rw.get("logs", []):
		if log_entry.get("is_warning", true):
			GLogger.warning(log_entry.msg, "CharaMGR")
		else:
			GLogger.info(log_entry.msg, "CharaMGR")
	soundfonts_index = sf_rw.get("soundfonts", {})
	for w in sf_rw.get("warnings", []):
		GLogger.warning(w, "FileSystemMGR")
	backgrounds_index = bg_rw.get("backgrounds", {})
	for w in bg_rw.get("warnings", []):
		GLogger.warning(w, "FileSystemMGR")

	# === 阶段 A.7：emit resources_ready，用户可立即操作 ===
	# 快速路径：charts_index 已从缓存恢复，后台校验仍在进行，完成后会 emit charts_cache_validated
	# 全量路径：charts_index 已从 worker 结果构建完成
	# 全量路径：扫描完成且 DB upsert + 聚合重算已全部结束，此时对比结构变更；
	# 快速路径：_await_cache_validation 末尾自行对比
	if not use_fast_path:
		_snapshot_structure_check_and_emit()
	is_scanning = false
	resources_scanned = true
	resources_ready.emit()
	is_initialized = true
	# 存储根迁移后的强制全量扫描已完成，复位标志（下次启动走常规缓存路径）
	if force_full_rescan:
		force_full_rescan = false
		GLogger.info("Full rescan completed after storage migration", "FileSystemMGR")

	var t_end := Time.get_ticks_usec()
	if use_fast_path:
		GLogger.info("Resources ready in %.0fms (charts=%d from cache, skins=%d, particles=%d, charas=%d, sf=%d, bg=%d)" % [
			(t_end - t_start) / 1000.0,
			charts_index.size(), SkinMGR.skins_index.size(),
			ParticleMGR.particles_index.size(), CharaMGR.charas_index.size(),
			soundfonts_index.size(), backgrounds_index.size()
		], "FileSystemMGR")
	else:
		GLogger.info("Directory structure initialized in %.0fms (charts=%d, skins=%d, particles=%d, charas=%d, sf=%d, bg=%d)" % [
			(t_end - t_start) / 1000.0,
			charts_index.size(), SkinMGR.skins_index.size(),
			ParticleMGR.particles_index.size(), CharaMGR.charas_index.size(),
			soundfonts_index.size(), backgrounds_index.size()
		], "FileSystemMGR")

## 启动 charts 缓存后台校验（worker 线程）
## 校验缓存条目有效性 + 扫描新增文件夹 → 主线程合并差异 → emit charts_cache_validated
## 不阻塞启动流程，用户在 resources_ready 后即可操作
func _start_charts_cache_validation(all_chart_folders: Array, cached_charts: Dictionary) -> void:
	var rw: Dictionary = {}
	var task_id := WorkerThreadPool.add_task(
		func(): _validate_charts_cache_worker(cached_charts, all_chart_folders, rw),
		false, "ValidateChartsCache"
	)
	# 后台轮询，不阻塞启动主流程
	_await_cache_validation(task_id, rw, cached_charts)

## 后台 await 缓存校验完成，处理差异后 emit 信号
## 通过 _is_validating 标志保护：期间 DelView / rescan 等可通过 await_busy_done() 等待
func _await_cache_validation(task_id: int, rw: Dictionary, cached_charts: Dictionary) -> void:
	_is_validating = true
	while not WorkerThreadPool.is_task_completed(task_id):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)

	var changed_folders: Array = rw.get("changed_folders", [])
	var removed_folders: Array = rw.get("removed_folders", [])
	var new_folders: Array = rw.get("new_folders", [])
	var is_clean: bool = rw.get("is_clean", true)

	GLogger.info("Charts cache validation: %d changed, %d removed, %d new (clean=%s)" % [
		changed_folders.size(), removed_folders.size(), new_folders.size(), is_clean
	], "FileSystemMGR")

	# 无任何变化 → 不刷新 UI
	if is_clean:
		# 仍 emit 一次（changed=false），让监听方知道校验已完成
		_is_validating = false
		if EvtBus:
			EvtBus.charts_cache_validated.emit(false)
		return

	# 有变化：扫描新增 + 变化的文件夹，更新 charts_index，emit 信号刷新 UI
	var folders_to_scan: Array = []
	for f in new_folders:
		folders_to_scan.append(f)
	for f in changed_folders:
		folders_to_scan.append(f)

	# 启动 worker 扫描新增 + 变化的文件夹
	var chart_tasks := _start_charts_scan_tasks(folders_to_scan)
	while not _all_chart_tasks_completed(chart_tasks):
		await get_tree().process_frame
	for t in chart_tasks:
		WorkerThreadPool.wait_for_task_completion(t.id)

	# 合并结果：移除已删除文件夹 + 更新变化的 + 添加新增的
	# 1. 移除已删除的
	for folder_name in removed_folders:
		cached_charts.erase(folder_name)
	# 2. 更新变化的（先移除旧的，下面会被新的覆盖）
	for folder_name in changed_folders:
		cached_charts.erase(folder_name)
	# 3. 添加新增/重扫的
	for t in chart_tasks:
		var task_rw: Dictionary = t.result
		var charts_data: Dictionary = task_rw.get("charts", {})
		for folder_name in charts_data.keys():
			cached_charts[folder_name] = charts_data[folder_name]

	# 重建 charts_index（主线程）
	charts_index.clear()
	_chart_id_to_folder.clear()
	_hash_to_folder.clear()
	# audio_files_index 全部来自 charts，直接 clear 重建
	audio_files_index.clear()
	_build_charts_index_from_data(cached_charts, chart_tasks)

	# 保存更新后的缓存（SaveChartsCache 只写带 _is_full 标记的新增/变化条目，轻量投影条目自动跳过不覆盖）
	_save_charts_cache(cached_charts)
	# 已删除文件夹同步移除 DB 中的 chart（含 chart_runtime + 聚合重算）
	if ChartDB and ChartDB.IsOpen() and not removed_folders.is_empty():
		ChartDB.RemoveCharts(removed_folders)

	# 结构变更检测：SaveChartsCache + RemoveCharts 均已触发 RebuildAlbumsSongs，
	# 此时与扫描前快照对比，不一致才通知 UI 刷新 AlbumView + SongView（避免无意义卡顿）
	_snapshot_structure_check_and_emit()

	_is_validating = false
	# emit 信号通知 UI 刷新
	if EvtBus:
		EvtBus.charts_cache_validated.emit(true)
	GLogger.info("Charts cache validation done: charts=%d (refreshed)" % charts_index.size(), "FileSystemMGR")

## 检查所有 simple task（单个 task_id 数组）是否全部完成
func _all_simple_tasks_completed(task_ids: Array) -> bool:
	for tid in task_ids:
		if not WorkerThreadPool.is_task_completed(tid):
			return false
	return true

## 扫描谱面目录（公共 API，并行分片）
## 仅扫描新的谱面文件夹格式（每个文件夹一个谱面）
## 通过 WorkerThreadPool 分片并行扫描，主线程 await 全部完成
## 注意：此方法不走缓存（用于 DelView 删除资源后的强制重扫），启动时走 _scan_all_resources 的缓存路径
func scan_charts() -> void:
	_snapshot_structure_pre()
	await _scan_charts_full_sync()
	_snapshot_structure_check_and_emit()

## 全量扫描 charts 并构建索引 + 保存缓存（公共逻辑）
## 内部：list folders → start chunk tasks → await → collect → clear+build index → save cache
## 由 scan_charts() 公共 API 和 _scan_all_resources() 全量路径复用
## progress_cb（可选）：主线程逐帧回调(已扫描数, 总数)，供全量路径显示进度条
## 返回：扫描耗时（毫秒），用于调用方日志
func _scan_charts_full_sync(progress_cb: Callable = Callable()) -> float:
	var t_start := Time.get_ticks_usec()

	var all_chart_folders := _list_chart_folder_names()
	if all_chart_folders.is_empty():
		GLogger.info("No charts to scan", "FileSystemMGR")
		charts_index.clear()
		_chart_id_to_folder.clear()
		_hash_to_folder.clear()
		audio_files_index.clear()
		return 0.0

	var chart_tasks := _start_charts_scan_tasks(all_chart_folders)
	var total_folders: int = all_chart_folders.size()

	# 主线程轮询 await，保持 UI 响应；每帧累计已完成片数用于进度
	while not _all_chart_tasks_completed(chart_tasks):
		if progress_cb.is_valid():
			var done: int = 0
			for t in chart_tasks:
				if WorkerThreadPool.is_task_completed(t.id):
					done += int(t.get("count", 0))
			progress_cb.call(done, total_folders)
		await get_tree().process_frame
	if progress_cb.is_valid():
		progress_cb.call(total_folders, total_folders)

	# wait_for_task_completion 仅做线程 join（瞬时）
	for t in chart_tasks:
		WorkerThreadPool.wait_for_task_completion(t.id)

	# 从 worker 结果收集所有 charts data（不走缓存，完整扫描）
	var all_charts_data: Dictionary = {}
	for t in chart_tasks:
		var rw: Dictionary = t.result
		var charts_data: Dictionary = rw.get("charts", {})
		for folder_name in charts_data.keys():
			all_charts_data[folder_name] = charts_data[folder_name]

	# 重建 charts_index（全量扫描结果）
	charts_index.clear()
	_chart_id_to_folder.clear()
	_hash_to_folder.clear()
	audio_files_index.clear()
	_build_charts_index_from_data(all_charts_data, chart_tasks)

	# 保存缓存（DelView 重扫后也更新缓存，保持一致）
	_save_charts_cache(all_charts_data)

	# 清理 DB 中已不在磁盘上的谱面（全量重扫不跑缓存校验，需手动 diff，防止删除残留）
	if ChartDB and ChartDB.IsOpen():
		var db_keys: Array = ChartDB.GetAllChartKeys()
		var folder_set: Dictionary = {}
		for fn in all_chart_folders:
			folder_set[fn] = true
		var removed_from_db: Array = []
		for k: String in db_keys:
			if not folder_set.has(k):
				removed_from_db.append(k)
		if not removed_from_db.is_empty():
			ChartDB.RemoveCharts(removed_from_db)
			GLogger.info("Rescan: pruned %d stale charts from DB" % removed_from_db.size(), "FileSystemMGR")

	var elapsed_ms := (Time.get_ticks_usec() - t_start) / 1000.0
	GLogger.info("Scanned %d charts in %.0fms" % [
		charts_index.size(), elapsed_ms
	], "FileSystemMGR")
	return elapsed_ms

## 主线程一次性列出所有 chart 文件夹名（避免 worker 并发 DirAccess 同一目录）
func _list_chart_folder_names() -> Array:
	var folder_names: Array = []
	var dir = DirAccess.open(CHARTS_DIR)
	if dir == null:
		GLogger.warning("Failed to open charts directory: %s" % CHARTS_DIR, "FileSystemMGR")
		return folder_names
	dir.list_dir_begin()
	var folder_name = dir.get_next()
	while folder_name != "":
		if dir.current_is_dir() and not folder_name.begins_with("."):
			folder_names.append(folder_name)
		folder_name = dir.get_next()
	dir.list_dir_end()
	return folder_names

## ========== charts 扫描缓存 ==========
## 缓存存于 LiteDB（ChartDb），替代原 .charts_scan_cache.json
## 缓存策略：对比当前文件夹列表，只扫描新增/变化文件夹，未变的从 DB 恢复（轻量投影，不物化 JSON）

## 加载 charts 扫描缓存
## 返回 {folder_name: metadata_dict}，加载失败返回空 Dictionary
## metadata_dict 是 ChartDb 轻量投影（含路径/mtime/扁平化 id 字段，不含 data 大块）
func _load_charts_cache() -> Dictionary:
	# 从 LiteDB 读取缓存（替代原 .charts_scan_cache.json 文本解析）
	# schema 版本校验已在 ChartDB.OpenDb 中处理（版本不符 → 重建导入）
	if ChartDB == null or not ChartDB.IsOpen():
		return {}
	var t_start := Time.get_ticks_usec()
	var charts: Dictionary = ChartDB.LoadChartsCache()
	var t_end := Time.get_ticks_usec()
	GLogger.info("Loaded charts cache from DB: %d entries in %.0fms" % [
		charts.size(), (t_end - t_start) / 1000.0
	], "FileSystemMGR")
	return charts

## 保存 charts 扫描缓存
## charts_data: {folder_name: metadata_dict}
func _save_charts_cache(charts_data: Dictionary) -> void:
	# 写入 LiteDB（替代原 .charts_scan_cache.json 文本序列化）
	if ChartDB == null or not ChartDB.IsOpen():
		return
	ChartDB.SaveChartsCache(charts_data)
	GLogger.info("Saved charts cache to DB: %d entries" % charts_data.size(), "FileSystemMGR")

## 后台校验缓存 worker：检查每个缓存条目的文件夹是否仍然存在 + json/mid mTime 是否变化
## 纯文件 I/O，不调 GLogger / 不写全局字段，结果通过 result_wrapper 回传
## result_wrapper 返回字段：
##   - changed_folders: Array[String] — 缓存失效的文件夹名（mTime 变化或 json/mid 缺失），需重扫
##   - removed_folders: Array[String] — 文件夹已被删除的，需从缓存移除
##   - new_folders: Array[String] — 当前存在但缓存中没有的新文件夹，需扫描
##   - is_clean: bool — true 表示无任何变化（完全干净，无需刷新 UI）
func _validate_charts_cache_worker(cached_charts: Dictionary, current_folders: Array, result_wrapper: Dictionary) -> void:
	var changed: Array = []
	var removed: Array = []
	var new_set: Dictionary = {}  # current_folders 转 set 加速查询
	for f in current_folders:
		new_set[f] = true

	# 1. 检查缓存中的文件夹：是否存在 + mTime 是否变化
	for folder_name in cached_charts.keys():
		if not new_set.has(folder_name):
			removed.append(folder_name)
			continue
		var meta: Dictionary = cached_charts[folder_name]
		var chart_path = CHARTS_DIR.path_join(folder_name)
		var chart_id = folder_name.split("_")[0]
		# 标准命名优先，旧命名回退（json/mid 判存在，供增删/变更检测）
		var json_path := chart_path.path_join("info.json")
		if not FileAccess.file_exists(json_path):
			json_path = chart_path.path_join(chart_id + ".json")
		var mid_path := chart_path.path_join("song.mid")
		if not FileAccess.file_exists(mid_path):
			mid_path = chart_path.path_join(chart_id + ".mid")
		# 检查 json/mid 是否存在
		if not FileAccess.file_exists(json_path) or not FileAccess.file_exists(mid_path):
			changed.append(folder_name)
			new_set.erase(folder_name)
			continue
		# 对比 mTime（两级，先快后全）：
		# 1. 文件夹 mTime（一次性 stat）变化 → 必有增/删/改文件，直接标记重扫
		# 2. 文件夹 mTime 未变 → 仍可能"文件内容就地修改"（Linux/Android 文件夹 mTime 不感知），回退文件级对比
		var cached_folder_mtime: int = int(meta.get("_folder_mtime", 0))
		var cur_folder_mtime := FileAccess.get_modified_time(chart_path)
		if cached_folder_mtime != 0 and cur_folder_mtime != cached_folder_mtime:
			changed.append(folder_name)
			new_set.erase(folder_name)
			continue
		# 对比 json/mid 文件 mTime（内容变化 → 标记需重扫）
		var cached_json_mtime: int = int(meta.get("_json_mtime", 0))
		var cached_mid_mtime: int = int(meta.get("_mid_mtime", 0))
		var cur_json_mtime := FileAccess.get_modified_time(json_path)
		var cur_mid_mtime := FileAccess.get_modified_time(mid_path)
		if cur_json_mtime != cached_json_mtime or cur_mid_mtime != cached_mid_mtime:
			changed.append(folder_name)
		new_set.erase(folder_name)  # 从 new_set 移除，剩余的就是新增文件夹

	# 2. new_set 中剩余的是新增文件夹（缓存中没有的）
	var new_folders: Array = new_set.keys()

	result_wrapper["changed_folders"] = changed
	result_wrapper["removed_folders"] = removed
	result_wrapper["new_folders"] = new_folders
	result_wrapper["is_clean"] = changed.is_empty() and removed.is_empty() and new_folders.is_empty()

## 快速变更检测：基于文件夹 mTime 一次性找出 新增/删除/修改 的谱面文件夹
## 只做轻量 stat（每文件夹 1 次），绝不读 JSON —— 供运行时自动检测歌曲变更复用
## cached_charts: {folder_name: metadata_dict}（须含 _folder_mtime，来自 _load_charts_cache）
## 返回 {new_folders, removed_folders, changed_folders, is_clean}
##
## 局限：Linux/Android 上文件夹 mTime 只随"增/删/改名"变化，不感知"文件内容就地修改"
##   —— 需要捕捉就地编辑（如直接改 chart JSON）时，用 _validate_charts_cache_worker 的
##      文件级 _json_mtime/_mid_mtime 校验兜底。本函数适合运行时轮询的快速第一道闸。
func detect_chart_folder_changes_fast(cached_charts: Dictionary) -> Dictionary:
	var current_folders := _list_chart_folder_names()
	var folder_set: Dictionary = {}
	for f in current_folders:
		folder_set[f] = true

	var new_folders: Array = []
	var removed_folders: Array = []
	var changed_folders: Array = []

	# 缓存中有的：先查是否被删除，再对比文件夹 mTime
	for folder_name in cached_charts.keys():
		if not folder_set.has(folder_name):
			removed_folders.append(folder_name)
			continue
		var meta: Dictionary = cached_charts[folder_name]
		var cached_folder_mtime: int = int(meta.get("_folder_mtime", 0))
		if cached_folder_mtime == 0:
			# 缓存无 mTime（旧数据），保守视为变化，交调用方重扫
			changed_folders.append(folder_name)
			continue
		var cur_folder_mtime := FileAccess.get_modified_time(CHARTS_DIR.path_join(folder_name))
		if cur_folder_mtime != cached_folder_mtime:
			changed_folders.append(folder_name)

	# 磁盘上存在但缓存中没有 = 新增
	for f in current_folders:
		if not cached_charts.has(f):
			new_folders.append(f)

	return {
		"new_folders": new_folders,
		"removed_folders": removed_folders,
		"changed_folders": changed_folders,
		"is_clean": new_folders.is_empty() and removed_folders.is_empty() and changed_folders.is_empty(),
	}

## 启动 charts 分片扫描的多个 worker task
## 返回 [{id: task_id, result: result_wrapper}, ...]
## 主线程在启动后 await 全部完成，再调用 _build_charts_index_from_data 合并
func _start_charts_scan_tasks(all_chart_folders: Array) -> Array:
	var chart_tasks: Array = []
	if all_chart_folders.is_empty():
		return chart_tasks
	for i in range(0, all_chart_folders.size(), CHART_SCAN_CHUNK_SIZE):
		var chunk: Array = all_chart_folders.slice(i, i + CHART_SCAN_CHUNK_SIZE)
		var rw: Dictionary = {}
		var tid := WorkerThreadPool.add_task(
			func(): _scan_charts_chunk_worker(chunk, rw),
			false, "ScanChartsChunk"
		)
		chart_tasks.append({"id": tid, "result": rw, "count": chunk.size()})
	return chart_tasks

## 检查所有 charts task 是否全部完成
func _all_chart_tasks_completed(chart_tasks: Array) -> bool:
	for t in chart_tasks:
		if not WorkerThreadPool.is_task_completed(t.id):
			return false
	return true

## 在 worker 线程中扫描一组 chart 文件夹
## 全部为纯文件 I/O + Dictionary 操作，无引擎 API 调用（不调 GLogger / 不写全局字段）
## 结果通过 result_wrapper 回传，由主线程 _build_charts_index_from_data 合并
## 反向索引 / audio_entries 由主线程统一从 metadata dict 提取，worker 不再单独构建
func _scan_charts_chunk_worker(folder_names: Array, result_wrapper: Dictionary) -> void:
	var local_charts: Dictionary = {}          # folder_name → metadata Dictionary
	var local_warnings: Array = []
	var t_start := Time.get_ticks_usec()

	for folder_name in folder_names:
		var chart_path = CHARTS_DIR.path_join(folder_name)
		var metadata = _load_chart_metadata(chart_path, folder_name)

		# _load_chart_metadata 出错时返回 {"_warnings": [...]}，没有 "id" 字段
		# 只收集有效 metadata（有 id 字段）
		if not metadata.has("id"):
			var ws = metadata.get("_warnings", [])
			for w in ws:
				local_warnings.append(w)
			continue

		local_charts[folder_name] = metadata

		# 收集 warnings（有效 metadata 也可能有 warnings，如 .mid 缺失但 metadata 仍返回）
		# 收集后立即 erase：避免 _warnings 字段被写入缓存文件膨胀体积
		var ws2 = metadata.get("_warnings", [])
		for w in ws2:
			local_warnings.append(w)
		if not ws2.is_empty():
			metadata.erase("_warnings")

	# 性能诊断：单分片耗时 + 平均每文件夹耗时（写入 result_wrapper，主线程统一打印）
	var elapsed_ms := (Time.get_ticks_usec() - t_start) / 1000.0
	result_wrapper["chunk_elapsed_ms"] = elapsed_ms
	result_wrapper["chunk_folder_count"] = folder_names.size()

	result_wrapper["charts"] = local_charts
	result_wrapper["warnings"] = local_warnings

## 从 charts metadata dict 构建 charts_index + 反向索引 + audio_files_index
## 主线程调用：统一处理缓存恢复和 worker 新扫描的结果
## all_charts_data: {folder_name: metadata_dict}（缓存恢复 + worker 新扫描合并后的完整集合）
## chart_tasks: worker 结果（用于打印性能诊断 + warnings）
func _build_charts_index_from_data(all_charts_data: Dictionary, chart_tasks: Array) -> void:
	# 性能诊断：打印新增文件夹的扫描耗时（缓存命中的不计时）
	var total_chunk_ms := 0.0
	var max_chunk_ms := 0.0
	var total_new_folders := 0
	for t in chart_tasks:
		var rw: Dictionary = t.result
		var chunk_ms: float = rw.get("chunk_elapsed_ms", 0.0)
		var folder_count: int = rw.get("chunk_folder_count", 0)
		total_chunk_ms += chunk_ms
		if chunk_ms > max_chunk_ms:
			max_chunk_ms = chunk_ms
		total_new_folders += folder_count
	if total_new_folders > 0:
		GLogger.info("Charts scan: %d new folders in %d chunks, sum=%.0fms max=%.0fms avg/folder=%.2fms" % [
			total_new_folders, chart_tasks.size(), total_chunk_ms, max_chunk_ms,
			total_chunk_ms / total_new_folders
		], "FileSystemMGR")

	# 构建 charts_index + 反向索引 + audio_files_index
	# 统一从 metadata dict 收集 audio_entries（缓存和 worker 结果处理方式一致）
	for folder_name in all_charts_data.keys():
		var meta_dict: Dictionary = all_charts_data[folder_name]
		# 跳过无效 metadata（_load_chart_metadata 出错时返回 {"_warnings": [...]}）
		if not meta_dict.has("id"):
			continue

		# v3：统一补全扁平化字段（缓存恢复投影已带；扫描结果需从 data 提取一次，避免物化整块 JSON）
		if not meta_dict.has("midi_id") and meta_dict.has("data"):
			var jd: Variant = meta_dict.get("data", {})
			if jd is Dictionary:
				meta_dict["midi_id"] = jd.get("_id", "")
				meta_dict["file_hash"] = jd.get("file_hash", "")
				meta_dict["hash"] = jd.get("hash", "")
		charts_index[folder_name] = ChartMetadata.from_dict(meta_dict)

		# 构建反向索引（扁平化字段，不再读 data 大块）
		var chart_meta: ChartMetadata = charts_index[folder_name]
		var meta_id: String = chart_meta.id
		if not meta_id.is_empty():
			_chart_id_to_folder[meta_id] = folder_name
		var fh: String = chart_meta.file_hash
		if not fh.is_empty():
			_hash_to_folder[fh] = folder_name
		var ah: String = chart_meta.hash
		if not ah.is_empty() and ah != fh:
			_hash_to_folder[ah] = folder_name

		# 收集 audio 条目（统一从 metadata dict 提取，不再依赖 worker 的单独 audio 数组）
		var entries = meta_dict.get("audio_entries", [])
		for e in entries:
			audio_files_index.append(e)

	# 打印 worker 收集的 warnings（主线程安全调用 GLogger）
	for t in chart_tasks:
		var rw: Dictionary = t.result
		for w in rw.get("warnings", []):
			GLogger.warning(w, "FileSystemMGR")

## 加载谱面元数据（从谱面文件夹）
## 文件夹命名格式：{hash}_{song_name}_{difficulty}/
## 文件标准命名：info.json / song.mid / cover.jpg / vocal.<ext>
## 旧命名（{hash}.json / {hash}.mid / {hash}-cover.jpg / {hash}.<ext>）作为回退兼容扫描
## 纯函数：无全局副作用，错误信息通过返回字典的 _warnings 数组返回，audio 条目通过 audio_entries 字段返回
## 由调用方决定如何处理（写入 audio_files_index / 打印日志），便于在 worker 线程安全调用
##
## 性能优化：单次 DirAccess 遍历一次性收集 json/mid/audio/cover，避免多次独立 stat
## 在 Android emmc/ufs 存储上，readdir 走系统目录缓存，比单独 stat 快一个数量级
func _load_chart_metadata(chart_path: String, folder_name: String) -> Dictionary:
	var warnings: Array = []
	# 从文件夹名称提取 chart_id（哈希值）
	var chart_id = folder_name.split("_")[0]
	# 旧命名回退候选（标准命名 info.json / song.mid 存在时优先使用）
	var json_name = chart_id + ".json"
	var mid_name = chart_id + ".mid"

	# 从文件夹名提取 song_name（用于 audio 条目）
	var _song_name = folder_name
	var _hash_idx = _song_name.find("_")
	if _hash_idx >= 0:
		_song_name = _song_name.substr(_hash_idx + 1)

	# === 单次 DirAccess 遍历，一次性收集所有需要的文件 ===
	var json_path: String = ""
	var mid_path: String = ""
	var cover_path: String = ""
	var has_audio = false
	# 音频按格式分组收集：标准命名 vocal.<ext> 优先，旧命名 {hash}.<ext> 回退
	var std_audio: Dictionary = {}       # ext -> {file_name, path}
	var fallback_audio: Dictionary = {}  # ext -> {file_name, path}

	var dir = DirAccess.open(chart_path)
	if dir == null:
		warnings.append("Failed to open chart folder: %s" % chart_path)
		return {"_warnings": warnings}

	# 旧命名音频格式映射（小写匹配，避免大小写问题）
	var fallback_ext_map = {
		(chart_id + ".ogg").to_lower(): "ogg",
		(chart_id + ".mp3").to_lower(): "mp3",
		(chart_id + ".wav").to_lower(): "wav",
		(chart_id + ".flac").to_lower(): "flac",
	}

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var lower_name = file_name.to_lower()
			# JSON：标准 info.json 优先，旧 {hash}.json 回退
			if lower_name == "info.json":
				json_path = chart_path.path_join(file_name)
			elif lower_name == "song.mid":
				mid_path = chart_path.path_join(file_name)
			elif json_path.is_empty() and lower_name == json_name.to_lower():
				json_path = chart_path.path_join(file_name)
			elif mid_path.is_empty() and lower_name == mid_name.to_lower():
				mid_path = chart_path.path_join(file_name)
			elif cover_path.is_empty() and \
				 (lower_name.contains("cover") or lower_name.contains("thumbnail")) and \
				 (lower_name.ends_with(".jpg") or lower_name.ends_with(".jpeg") or \
				  lower_name.ends_with(".png") or lower_name.ends_with(".webp")):
				# 封面（标准 cover.jpg 与旧命名均含 cover/thumbnail 关键词）
				cover_path = chart_path.path_join(file_name)
			elif lower_name.begins_with("vocal."):
				# 音频标准命名：vocal.<ext>
				var vext := lower_name.substr("vocal.".length())
				if ["ogg", "mp3", "wav", "flac"].has(vext):
					std_audio[vext] = {"file_name": file_name, "path": chart_path.path_join(file_name)}
			elif fallback_ext_map.has(lower_name):
				# 音频旧命名：{hash}.<ext>
				var fext: String = fallback_ext_map[lower_name]
				if not fallback_audio.has(fext):
					fallback_audio[fext] = {"file_name": file_name, "path": chart_path.path_join(file_name)}
		file_name = dir.get_next()
	dir.list_dir_end()

	# 合并音频条目：标准命名优先，同格式旧命名忽略
	var audio_entries: Array = []
	for ext in std_audio.keys():
		var e: Dictionary = std_audio[ext]
		audio_entries.append({
			"file_name": e["file_name"], "path": e["path"], "format": ext,
			"chart_id": chart_id, "song_name": _song_name,
		})
	for ext in fallback_audio.keys():
		if std_audio.has(ext):
			continue
		var e: Dictionary = fallback_audio[ext]
		audio_entries.append({
			"file_name": e["file_name"], "path": e["path"], "format": ext,
			"chart_id": chart_id, "song_name": _song_name,
		})
	if not audio_entries.is_empty():
		has_audio = true

	# === 检查必需文件 ===
	if json_path.is_empty():
		warnings.append("Chart folder %s missing JSON file: %s" % [folder_name, chart_path.path_join(json_name)])
		return {"_warnings": warnings}

	# === 读取 JSON 元数据 ===
	var metadata = _load_chart_from_json(json_path, chart_id, warnings)
	if metadata.is_empty():
		return {"_warnings": warnings}

	# === MIDI 文件检查 ===
	if mid_path.is_empty():
		warnings.append("Chart %s missing MIDI file: %s" % [chart_id, chart_path.path_join(mid_name)])
		metadata["is_complete"] = false
		metadata["_warnings"] = warnings
		return metadata

	# === 设置可选字段 ===
	if not cover_path.is_empty():
		metadata["cover_path"] = cover_path
	if has_audio:
		# audio_entries 已按遍历顺序填充，第一个作为 audio_path
		metadata["audio_path"] = audio_entries[0]["path"]

	metadata["is_complete"] = has_audio  # 仅当有音频文件时才算完整
	metadata["path"] = chart_path
	metadata["folder_name"] = folder_name
	metadata["audio_entries"] = audio_entries
	# 记录 json + mid 文件的 mTime（Unix 时间戳），用于后台缓存校验
	# 校验时对比 mTime，变化则重扫该文件夹
	metadata["_json_mtime"] = FileAccess.get_modified_time(json_path)
	metadata["_mid_mtime"] = FileAccess.get_modified_time(mid_path)
	# 记录文件夹自身 mTime，供 detect_chart_folder_changes_fast 做快速变更检测（一次性 stat 比 2 次文件 stat 便宜）
	# 注意：Linux/Android 上文件夹 mTime 只随 增/删/改名 变化，不感知"文件内容就地修改"
	metadata["_folder_mtime"] = FileAccess.get_modified_time(chart_path)
	if not warnings.is_empty():
		metadata["_warnings"] = warnings
	return metadata

## 从 JSON 文件加载谱面数据
## 纯函数：错误信息追加到 warnings 数组由调用方处理，避免在 worker 线程调用 GLogger
func _load_chart_from_json(json_path: String, chart_id: String, warnings: Array = []) -> Dictionary:
	var file = FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		warnings.append("Failed to open chart JSON: %s" % json_path)
		return {}
	
	var content = file.get_as_text()
	var json = JSON.parse_string(content)
	file.close()
	
	if json == null:
		warnings.append("Failed to parse chart JSON: %s" % json_path)
		return {}
	
	# Normalize JSON format (merge song/album/author + source* into 3 fields)
	# 仅在值有修改时写回磁盘（on-disk 仍存完整规范化 JSON，白名单只作用于提取路径）
	if ChartNormalizer.normalize_chart_json(json):
		var wf = FileAccess.open(json_path, FileAccess.WRITE)
		if wf:
			wf.store_string(JSON.stringify(json, "\t", false))
			wf.close()
	
	var flat := _extract_chart_fields(json)
	flat["id"] = chart_id
	flat["json_path"] = json_path
	flat["is_complete"] = false
	# 标记该 dict 为「需 upsert 进 DB」的全量扫描结果（替代原 data 整块判据）
	flat["_is_full"] = true
	return flat

## 从已规范化 chart JSON 提取白名单字段（扁平化到顶层，供内存 / DB 直接消费）。
## 非白名单键一律忽略（loveCount/avgAccuracy/passCount/failCount/评级分布等实际 JSON 无源）。
static func _extract_chart_fields(json: Dictionary) -> Dictionary:
	var flat: Dictionary = {}
	# midi_id 为谱面唯一标识：规范化/导入 JSON 只保留 hash（无 _id），故回落为 hash，
	# 保证水合出的 MidiData.id 非空（否则 DataManager._ensure_midi 判空返回 null，midi 列表为空）
	var midi_id_val := str(json.get("_id", ""))
	flat["midi_id"] = midi_id_val if not midi_id_val.is_empty() else str(json.get("hash", ""))
	flat["name"] = str(json.get("name", ""))
	flat["description"] = str(json.get("desc", ""))
	flat["status"] = str(json.get("status", "PENDING"))
	flat["artist_name"] = str(json.get("artistName", ""))
	flat["uploader_name"] = str(json.get("uploaderName", ""))
	flat["uploader_id"] = str(json.get("uploaderId", ""))
	flat["uploader_avatar_url"] = str(json.get("uploaderAvatarUrl", ""))
	flat["artist_url"] = str(json.get("artistUrl", ""))
	flat["coverHash"] = str(json.get("coverHash", ""))
	flat["uploaded_date"] = str(json.get("uploadedDate", ""))
	flat["approved_date"] = str(json.get("approvedDate", ""))
	flat["trial_count"] = int(json.get("trialCount", 0))
	flat["download_count"] = int(json.get("downloadCount", 0))
	flat["up_count"] = int(json.get("upCount", 0))
	flat["down_count"] = int(json.get("downCount", 0))
	flat["hash"] = str(json.get("hash", ""))
	var fh: String = str(json.get("file_hash", ""))
	flat["file_hash"] = fh if not fh.is_empty() else str(json.get("hash", ""))
	# author 优先 song.author（新白名单落位），回退顶层 author（兼容旧格式/过渡期目录）
	var author_val: Variant = ""
	if json.has("song") and json["song"] is Dictionary:
		author_val = (json["song"] as Dictionary).get("author", "")
	if author_val == "" and json.has("author"):
		author_val = json.get("author", "")
	flat["author_name"] = author_val if author_val is String else ""
	# song / album 子文档原样保留（RebuildAlbumsSongs / GetChartJson 复用）
	if json.has("song") and json["song"] is Dictionary:
		var song_dict: Dictionary = json["song"].duplicate(true)
		ChartNormalizer.cleanup_types_recursive(song_dict)
		flat["song"] = song_dict
	if json.has("album") and json["album"] is Dictionary:
		var album_dict: Dictionary = json["album"].duplicate(true)
		ChartNormalizer.cleanup_types_recursive(album_dict)
		flat["album"] = album_dict
	# 磁盘 JSON 内嵌的旧运行时配置（仅供 SaveChartsCache 播种 chart_runtime，非持久化字段）
	if json.has("_runtime") and json["_runtime"] is Dictionary:
		flat["_seed_runtime"] = json["_runtime"]
	return flat

## 扫描音源目录（公共 API，worker 线程扫描）
## 在 worker 中扫描用户目录和内置目录，主线程合并到 soundfonts_index
func scan_soundfonts() -> void:
	soundfonts_index.clear()
	var t_start := Time.get_ticks_usec()
	var rw: Dictionary = {}
	var task_id := WorkerThreadPool.add_task(
		func(): _scan_soundfonts_worker(rw),
		false, "ScanSoundfonts"
	)
	while not WorkerThreadPool.is_task_completed(task_id):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)
	soundfonts_index = rw.get("soundfonts", {})
	for w in rw.get("warnings", []):
		GLogger.warning(w, "FileSystemMGR")
	var t_end := Time.get_ticks_usec()
	GLogger.info("Scanned %d soundfonts in %.0fms" % [
		soundfonts_index.size(), (t_end - t_start) / 1000.0
	], "FileSystemMGR")

## 在 worker 线程中扫描音源目录
## 扫描 SOUNDFONT_DIR（用户）和 res://Resources/Soundfont/（内置）
## 用户目录优先级高于内置目录（同名不覆盖）
## 纯文件 I/O，结果通过 result_wrapper 回传，主线程合并
func _scan_soundfonts_worker(result_wrapper: Dictionary) -> void:
	var local_soundfonts: Dictionary = {}
	var local_warnings: Array = []

	# 辅助函数：扫描单个目录
	var _scan_dir = func(dir_path: String, is_builtin: bool):
		var dir = DirAccess.open(dir_path)
		if dir == null:
			return
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(".sf2"):
				var sf_path = dir_path.path_join(file_name)
				var sf_name = file_name.get_basename()

				# 如果用户目录有同名文件，内置版本不覆盖
				if is_builtin and local_soundfonts.has(sf_name):
					file_name = dir.get_next()
					continue

				var size_mb = 0.0
				var f = FileAccess.open(sf_path, FileAccess.READ)
				if f:
					size_mb = snapped(f.get_length() / 1048576.0, 0.1)
					f.close()

				local_soundfonts[sf_name] = {
					"path": sf_path,
					"size_mb": size_mb,
					"is_builtin": is_builtin,
				}
			file_name = dir.get_next()
		dir.list_dir_end()

	# 先扫描用户目录，再扫描内置目录
	_scan_dir.call(SOUNDFONT_DIR, false)
	_scan_dir.call("res://Resources/Soundfont/", true)

	result_wrapper["soundfonts"] = local_soundfonts
	result_wrapper["warnings"] = local_warnings

## 扫描背景图目录（公共 API，worker 线程扫描）
func scan_backgrounds() -> void:
	backgrounds_index.clear()
	var t_start := Time.get_ticks_usec()
	var rw: Dictionary = {}
	var task_id := WorkerThreadPool.add_task(
		func(): _scan_backgrounds_worker(rw),
		false, "ScanBackgrounds"
	)
	while not WorkerThreadPool.is_task_completed(task_id):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)
	backgrounds_index = rw.get("backgrounds", {})
	for w in rw.get("warnings", []):
		GLogger.warning(w, "FileSystemMGR")
	var t_end := Time.get_ticks_usec()
	GLogger.info("Scanned %d backgrounds in %.0fms" % [
		backgrounds_index.size(), (t_end - t_start) / 1000.0
	], "FileSystemMGR")

## 在 worker 线程中扫描背景图目录
## 纯文件 I/O，结果通过 result_wrapper 回传，主线程合并
func _scan_backgrounds_worker(result_wrapper: Dictionary) -> void:
	var local_backgrounds: Dictionary = {}
	var local_warnings: Array = []

	var dir = DirAccess.open(BACKGROUND_DIR)
	if dir == null:
		local_warnings.append("Failed to open background directory: %s" % BACKGROUND_DIR)
		result_wrapper["backgrounds"] = local_backgrounds
		result_wrapper["warnings"] = local_warnings
		return

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var ext = file_name.get_extension().to_lower()
			if ext in ["jpg", "jpeg", "png", "webp"]:
				var bg_path = BACKGROUND_DIR.path_join(file_name)
				local_backgrounds[file_name.get_basename()] = bg_path
		file_name = dir.get_next()
	dir.list_dir_end()

	result_wrapper["backgrounds"] = local_backgrounds
	result_wrapper["warnings"] = local_warnings

## ========== 公共查询接口 ==========

## 获取谱面索引
func get_charts_index() -> Dictionary:
	return charts_index

## 获取音源索引
## 获取音源索引（完整信息）
func get_soundfonts_index() -> Dictionary:
	return soundfonts_index

## 获取指定音源的文件路径
func get_soundfont_path(sf2_name: String) -> String:
	var entry = soundfonts_index.get(sf2_name, {})
	return entry.get("path", "") if entry is Dictionary else ""

## 获取背景图索引
func get_backgrounds_index() -> Dictionary:
	return backgrounds_index

## 获取音频文件索引
## 返回: Array[Dictionary] 含 file_name/path/format/chart_id/song_name
func get_audio_files_index() -> Array[Dictionary]:
	return audio_files_index

## 获取谱面目录路径
func get_charts_directory() -> String:
	return CHARTS_DIR

## 获取日志目录路径
func get_logs_directory() -> String:
	return LOGS_DIR

## 获取设置目录路径
func get_settings_directory() -> String:
	return SETTINGS_DIR

## 通过 chart_id/hash 查找 charts_index 条目（O(1)反向索引，未命中时回退到线性扫描）
## 磁盘侧规范解析器：chart 文档规范键 = folder_name；DB 打开时优先经 ChartDB.LookupChartKey 统一解析
func lookup_chart(chart_id: String) -> Dictionary:
	# folder_name 直达（chart 文档 _id，与 C# LookupChartKey 别名漏斗第一项一致；
	# DelView 懒加载以 folder_name 作 key 收集/删除，需支持）
	if charts_index.has(chart_id):
		return {"folder_name": chart_id, "metadata": charts_index[chart_id]}
	if not _chart_id_to_folder.is_empty():
		if _chart_id_to_folder.has(chart_id):
			var fn: String = _chart_id_to_folder[chart_id]
			if charts_index.has(fn):
				return {"folder_name": fn, "metadata": charts_index[fn]}
		if _hash_to_folder.has(chart_id):
			var fn: String = _hash_to_folder[chart_id]
			if charts_index.has(fn):
				return {"folder_name": fn, "metadata": charts_index[fn]}
	# 回退到线性扫描（扁平化字段，不读 data 大块）
	for folder_name in charts_index.keys():
		var meta: ChartMetadata = charts_index[folder_name]
		if meta.id == chart_id:
			return {"folder_name": folder_name, "metadata": meta}
		if meta.midi_id == chart_id or meta.file_hash == chart_id or meta.hash == chart_id:
			return {"folder_name": folder_name, "metadata": meta}
	return {}

## 判断谱面是否存在于磁盘扫描结果中（按 id/file_hash/midi_id/hash 任一别名）
## 供收藏夹校验等不依赖 DB 的存在性判断使用：DB 不可用时（如 charts.ldb 被占用），
## 磁盘扫描的 charts_index 是唯一可靠的数据源，避免误删收藏引用
func chart_exists_on_disk(chart_id: String) -> bool:
	if chart_id.is_empty():
		return false
	return not lookup_chart(chart_id).is_empty()

## 从 chart_id 反向查询对应的曲包文件夹路径
## 参数: chart_id - MidiData 中的 id 字段或 file_hash 字段
## 返回: user://files/Charts/[folder_name]/ 或空字符串（未找到）
func get_chart_folder_path(chart_id: String) -> String:
	# 事先检查 charts_index 是否已初始化
	if charts_index.is_empty():
		GLogger.warning("charts_index is empty, cannot locate chart folder", "FileSystemMGR")
		return ""
	
	var result = lookup_chart(chart_id)
	if not result.is_empty():
		var path: String = result["metadata"].path
		if not path.is_empty():
			return path
	GLogger.warning("Chart folder path not found for ID: %s" % chart_id, "FileSystemMGR")
	return ""

## 验证文件是否为有效的音频文件
## 参数: file_path - 文件路径
## 返回: bool - 是否是有效的音频文件
func is_valid_audio_file(file_path: String) -> bool:
	# 检查文件是否存在
	if not FileAccess.file_exists(file_path):
		return false
	
	# 检查文件是否不是空文件
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		GLogger.warning("Cannot access audio file: %s" % file_path, "FileSystemMGR")
		return false
	
	var file_size = file.get_length()
	file.close()
	
	# 检查文件大小（小于1KB的文件不是有效的音频）
	if file_size < 1024:
		return false
	
	# 检查文件扩展名
	var valid_extensions = ["ogg", "mp3", "wav", "flac"]
	var file_ext = file_path.get_extension().to_lower()
	return valid_extensions.has(file_ext)

## 重新扫描资源（热重载）
## 协程：内部 await _scan_all_resources()，调用方需 await 此函数
func rescan_resources() -> void:
	GLogger.info("Rescanning resources...", "FileSystemMGR")
	clear_cover_cache()
	await _scan_all_resources()

## 重置内置资源：强制重新复制默认谱面、皮肤、背景图到 user:// 目录
## 与 _copy_default_resources_async 不同，此方法不检查目录是否为空，强制覆盖
func reload_default_resources() -> void:
	GLogger.info("Reloading built-in resources...", "FileSystemMGR")

	# 复制默认谱面（强制，不检查空目录）
	GLogger.info("Copying default charts...", "FileSystemMGR")
	await _copy_default_charts_async()

	# 复制默认皮肤（强制）
	GLogger.info("Copying default skins...", "FileSystemMGR")
	await _copy_directory_recursive_async(SkinManager.DEFAULT_SKINS_SRC, SKINS_DIR)

	# 复制默认背景图（强制）
	GLogger.info("Copying default backgrounds...", "FileSystemMGR")
	await _copy_directory_contents_async(DEFAULT_BACKGROUND_SRC, BACKGROUND_DIR, "jpg,jpeg,png,webp")

	# 重新扫描所有资源
	await _scan_all_resources()

	GLogger.info("Built-in resources reloaded", "FileSystemMGR")

## 验证谱面完整性
func validate_chart(chart_id: String) -> bool:
	if not charts_index.has(chart_id):
		return false
	
	var metadata: ChartMetadata = charts_index[chart_id]
	return metadata.is_complete

## 获取谱面路径
func get_chart_path(chart_id: String) -> String:
	if not charts_index.has(chart_id):
		return ""
	
	var metadata: ChartMetadata = charts_index[chart_id]
	return metadata.path

## 封面路径兜底：为空或 user:// 文件不存在 → 返回默认封面路径（与 load_cover_with_cache 回退一致）
## Album/Song 列表项（DB 直查 cover_path）与 _cover_path_from_chart 共用
func default_cover_if_missing(path: String) -> String:
	if path.is_empty():
		return DEFAULT_COVER_PATH
	if not path.begins_with("res://") and not FileAccess.file_exists(path):
		return DEFAULT_COVER_PATH
	return path

## 封面查询公共实现：按 file_hash / midi_id 反查 charts_index，返回封面路径
## 未命中或为空返回默认封面路径；user:// 路径校验文件存在性
func _cover_path_from_chart(file_hash: String, midi_id: String) -> String:
	# 优先用 file_hash 反向索引查找
	var result = lookup_chart(file_hash)
	if result.is_empty():
		result = lookup_chart(midi_id)
	if not result.is_empty():
		return default_cover_if_missing(result["metadata"].cover_path)
	return default_cover_if_missing("")

## 按 file_hash / midi_id 查询封面文件路径（不读盘，主线程调用，供异步加载器使用）
## 与 get_cover_path_by_midiData 行为一致，供轻量投影列表项（无 MidiData 对象）使用
func get_cover_path_by_ids(file_hash: String, midi_id: String) -> String:
	return _cover_path_from_chart(file_hash, midi_id)

## 按 file_hash / midi_id 加载封面 Texture2D（同步，走 load_cover_with_cache）
func get_cover_by_ids(file_hash: String, midi_id: String) -> Texture2D:
	return load_cover_with_cache(_cover_path_from_chart(file_hash, midi_id))

func get_cover_by_midiData(midi: MidiData) -> Texture2D:
	if not midi:
		return load_cover_with_cache(DEFAULT_COVER_PATH)
	return get_cover_by_ids(midi.file_hash, midi.id)

## 查询封面文件路径（不读盘，主线程调用，供异步加载器使用）
## 返回 path 字符串：命中返回 metadata.cover_path，未命中或为空返回默认封面路径
## 与 load_cover_with_cache 的回退行为一致：user:// 文件不存在时回退到默认封面
## 避免异步加载器读到 null 后无回退逻辑导致封面空白
func get_cover_path_by_midiData(midi: MidiData) -> String:
	if not midi:
		return DEFAULT_COVER_PATH
	return get_cover_path_by_ids(midi.file_hash, midi.id)

## 主线程查 WeakRef 缓存，命中返回 Texture，未命中返回 null
## 供 CoverListItemBase 在入队异步加载前先查缓存
func get_cached_cover_texture(path: String) -> Texture2D:
	if _cover_texture_cache.has(path):
		var weak := _cover_texture_cache[path] as WeakRef
		if weak:
			var cached = weak.get_ref()
			if cached and is_instance_valid(cached):
				return cached
		# WeakRef 失效：清理缓存条目
		_cover_texture_cache.erase(path)
	return null

## 主线程写入 WeakRef 缓存（供 CoverLoader 回调调用）
## 不持有强引用，Texture 随列表项引用计数归零自动 GC
func _cache_cover_texture(path: String, tex: Texture2D) -> void:
	if tex:
		_cover_texture_cache[path] = weakref(tex)

## 带弱引用缓存的封面纹理加载
## 同 path 多次调用：若上次加载的 Texture 仍被列表项引用（WeakRef 有效），直接返回，零读盘开销
## 若 Texture 已被 GC（所有列表项都释放了），WeakRef 失效，重新从磁盘加载并清理失效条目
func load_cover_with_cache(path: String) -> Texture2D:
	# 命中缓存：通过 WeakRef 取回 Texture
	if _cover_texture_cache.has(path):
		var weak := _cover_texture_cache[path] as WeakRef
		if weak:
			var cached = weak.get_ref()
			if cached and is_instance_valid(cached):
				# WeakRef 仍有效（有列表项引用此 Texture）：直接返回
				return cached
		# WeakRef 失效（Texture 已被 GC）：清理缓存条目
		_cover_texture_cache.erase(path)

	var texture: Texture2D = null
	# 区分 res:// 和 user:// 路径
	if path.begins_with("res://"):
		texture = load(path)
	else:
		if not FileAccess.file_exists(path):
			GLogger.warning("Cover file not found: %s" % path, "FileSystemMGR")
			return load_cover_with_cache(DEFAULT_COVER_PATH)
		var image := ImageUtil.load_image_file(path)
		if image:
			texture = ImageTexture.create_from_image(image)
		else:
			GLogger.warning("Failed to load cover image: %s" % path, "FileSystemMGR")
			return load_cover_with_cache(DEFAULT_COVER_PATH)

	if texture:
		# 缓存 WeakRef：不持有强引用，Texture 随列表项引用计数归零自动 GC
		_cover_texture_cache[path] = weakref(texture)
	return texture

## 清除封面纹理缓存（封面文件更新后调用）
## 注：WeakRef 方案下，Texture 生命周期由列表项引用计数决定，此方法仅清空 Dictionary 条目
func clear_cover_cache() -> void:
	_cover_texture_cache.clear()
	_cover_hash_to_path.clear()

## 返回稳定的封面缓存键路径：同一 coverHash 的封面内容必然一致，
## 复用首个解析到的真实路径作为缓存键，实现跨歌曲封面去重（同 hash 只读入一份 Texture）
## cover_hash 为空时无法去重，直接返回原路径
func canonicalize_cover_key(real_path: String, cover_hash: String) -> String:
	if cover_hash.is_empty():
		return real_path
	if _cover_hash_to_path.has(cover_hash):
		return _cover_hash_to_path[cover_hash]
	_cover_hash_to_path[cover_hash] = real_path
	return real_path

## 获取指定chart ID对应的JSON文件完整路径
## 参数: chart_id - MidiData中的id字段或file_hash字段
## 返回: user://files/Charts/[folder_name]/[chart_id].json
func get_chart_json_path(chart_id: String) -> String:
	var result = lookup_chart(chart_id)
	if not result.is_empty():
		var meta: ChartMetadata = result["metadata"]
		# 优先使用已缓存的json_path
		var cached_json_path = meta.json_path
		if not cached_json_path.is_empty():
			return cached_json_path
		var chart_path = meta.path
		if not chart_path.is_empty():
			# 优先标准命名 info.json，旧命名 {id}.json 回退
			var info_path := chart_path.path_join("info.json")
			if FileAccess.file_exists(info_path):
				return info_path
			return chart_path.path_join(meta.id + ".json")
	GLogger.warning("Chart JSON path not found for ID: %s (charts_index has %d entries)" % [chart_id, charts_index.size()], "FileSystemMGR")
	return ""

## 删除单个文件
## 参数: absolute_path - 文件绝对路径（user:// 路径或系统路径均可）
## 返回: 是否成功删除
func delete_file(absolute_path: String) -> bool:
	if absolute_path.is_empty():
		GLogger.warning("delete_file: path is empty", "FileSystemMGR")
		return false
	if not FileAccess.file_exists(absolute_path):
		GLogger.warning("delete_file: file not found: %s" % absolute_path, "FileSystemMGR")
		return false
	var err = DirAccess.remove_absolute(absolute_path)
	if err != OK:
		GLogger.error("delete_file: failed to delete %s (err %d)" % [absolute_path, err], "FileSystemMGR")
		return false
	GLogger.info("Deleted file: %s" % absolute_path, "FileSystemMGR")
	return true

## 递归删除整个目录及其所有内容
## 参数: absolute_path - 目录绝对路径
## 返回: 是否成功删除
func delete_directory_recursive(absolute_path: String) -> bool:
	if absolute_path.is_empty():
		GLogger.warning("delete_directory_recursive: path is empty", "FileSystemMGR")
		return false

	# 手动递归删除（不再依赖外部 rm 命令，避免平台/权限依赖；
	# 若 Android 上出现删除大目录卡顿，另行评估 DirAccess 批量删除方案）
	var dir = DirAccess.open(absolute_path)
	if dir == null:
		if not DirAccess.dir_exists_absolute(absolute_path):
			GLogger.info("Directory already gone: %s" % absolute_path, "FileSystemMGR")
			return true
		GLogger.warning("delete_directory_recursive: cannot open dir: %s" % absolute_path, "FileSystemMGR")
		return false

	var failed_count := 0
	dir.list_dir_begin()
	var entry_name = dir.get_next()
	while entry_name != "":
		if entry_name != "." and entry_name != "..":
			var full_path = absolute_path.path_join(entry_name)
			if dir.current_is_dir():
				delete_directory_recursive(full_path)
			else:
				var err_f := DirAccess.remove_absolute(full_path)
				if err_f != OK:
					GLogger.warning("delete_directory_recursive: failed to remove file (err %d): %s" % [err_f, full_path], "FileSystemMGR")
					failed_count += 1
		entry_name = dir.get_next()
	dir.list_dir_end()

	var err = DirAccess.remove_absolute(absolute_path)
	if err != OK:
		if failed_count > 0:
			GLogger.warning("delete_directory_recursive: could not delete dir %s (%d files remain, err %d)" % [absolute_path, failed_count, err], "FileSystemMGR")
		else:
			GLogger.error("delete_directory_recursive: failed to remove dir %s (err %d)" % [absolute_path, err], "FileSystemMGR")
		return false
	GLogger.info("Deleted directory: %s" % absolute_path, "FileSystemMGR")
	return true

## 从 charts_index 中移除指定 chart_id 对应的条目
## 参数: chart_id - MidiData 中的 file_hash 或 id
func remove_from_charts_index(chart_id: String) -> void:
	var result = lookup_chart(chart_id)
	if not result.is_empty():
		var folder_name: String = result["folder_name"]
		var meta: ChartMetadata = result["metadata"]
		# 同步清理反向索引
		_chart_id_to_folder.erase(meta.id)
		_hash_to_folder.erase(meta.hash)
		_hash_to_folder.erase(meta.file_hash)
		charts_index.erase(folder_name)
		GLogger.info("Removed chart from index: %s (folder: %s)" % [chart_id, folder_name], "FileSystemMGR")
		return
	GLogger.warning("remove_from_charts_index: chart_id not found: %s" % chart_id, "FileSystemMGR")
## 在目录中查找匹配通配符模式（如 "*.mp3"）的所有文件名
## 返回文件名列表（非完整路径）
func find_files_in_dir(dir_path: String, pattern: String) -> PackedStringArray:
	var result: PackedStringArray = []
	if dir_path.is_empty():
		return result
	var d := DirAccess.open(dir_path)
	if d == null:
		GLogger.warning("find_files_in_dir: cannot open dir: %s" % dir_path, "FileSystemMGR")
		return result
	var ext := pattern.replace("*.", ".")
	d.list_dir_begin()
	var fn := d.get_next()
	while fn != "":
		if fn.ends_with(ext) and not d.current_is_dir():
			result.append(fn)
		fn = d.get_next()
	d.list_dir_end()
	return result

# ============================================================
# 统一删除函数（文件 + 索引同步清理）
# ============================================================

## 删除谱面及其全部关联资源，并同步清理所有相关索引
## 返回: 是否成功
func delete_chart(chart_id: String) -> bool:
	var info := _delete_single_chart_files(chart_id)
	if info.is_empty():
		return false
	# 同步移除 DB 中的 chart（含 chart_runtime + 聚合重算），修复原删除残留缓存的洞
	if ChartDB and ChartDB.IsOpen():
		ChartDB.RemoveChart(info["meta"].id)
	clear_cover_cache()
	GLogger.info("Deleted chart: %s (folder: %s)" % [chart_id, info["folder_name"]], "FileSystemMGR")
	return true

## 批量删除谱面（DelView 批量删除用）：逐条删目录 + 清内存索引，最后一次性写 DB
## （单锁 + 单次 RebuildAlbumsSongs，替代逐条 RemoveChart 的 N 次全量聚合重建）
## 每 3 条让一帧，避免大批量删除时主线程长时间无响应
## 返回: 成功删除的 chart_id 数组
func delete_charts_batch(chart_ids: Array) -> Array:
	var removed: Array = []
	var db_keys: Array = []
	var i := 0
	for chart_id in chart_ids:
		var info := _delete_single_chart_files(chart_id)
		if not info.is_empty():
			removed.append(chart_id)
			db_keys.append(info["meta"].id)
		i += 1
		if i % 3 == 0:
			await get_tree().process_frame
	if ChartDB and ChartDB.IsOpen() and not db_keys.is_empty():
		ChartDB.RemoveCharts(db_keys)
	clear_cover_cache()
	GLogger.info("Batch deleted %d charts" % removed.size(), "FileSystemMGR")
	return removed

## 删除单个谱面的文件目录 + 清内存索引（不触碰 DB；DB 由调用方单次/批量提交）
## 返回: {"folder_name", "meta"}；未找到或删除失败返回空字典
func _delete_single_chart_files(chart_id: String) -> Dictionary:
	var result = lookup_chart(chart_id)
	if result.is_empty():
		GLogger.warning("delete_chart: chart not found: %s" % chart_id, "FileSystemMGR")
		return {}

	var folder_name: String = result["folder_name"]
	var meta: ChartMetadata = result["metadata"]
	var folder_path := CHARTS_DIR.path_join(folder_name)

	# 先从 audio_files_index 中移除关联的音频条目
	for i in range(audio_files_index.size() - 1, -1, -1):
		if audio_files_index[i].get("chart_id", "") == chart_id:
			audio_files_index.remove_at(i)

	# 删除目录
	if not delete_directory_recursive(folder_path):
		return {}

	# 从 charts_index 移除
	_chart_id_to_folder.erase(meta.id)
	_hash_to_folder.erase(meta.hash)
	_hash_to_folder.erase(meta.file_hash)
	charts_index.erase(folder_name)
	return {"folder_name": folder_name, "meta": meta}

## 删除音频文件，并从 audio_files_index 移除；同步清理引用该文件的 MidiData 人声配置
func delete_audio(file_path: String) -> bool:
	if not delete_file(file_path):
		return false
	var affected_chart_ids: Array[String] = []
	for i in range(audio_files_index.size() - 1, -1, -1):
		if audio_files_index[i].get("path", "") == file_path:
			var chart_id := str(audio_files_index[i].get("chart_id", ""))
			if not chart_id.is_empty() and not affected_chart_ids.has(chart_id):
				affected_chart_ids.append(chart_id)
			audio_files_index.remove_at(i)
	_clear_vocal_config_for_deleted_audio(file_path, affected_chart_ids)
	return true

## 音频文件删除后，清空引用它的 MidiData 人声路径/开关并写回 chart_runtime
func _clear_vocal_config_for_deleted_audio(file_path: String, chart_ids: Array[String]) -> void:
	if chart_ids.is_empty():
		return
	for chart_id in chart_ids:
		var midi = DataMGR.get_midi_by_id(chart_id) if DataMGR != null else null
		if midi == null:
			GLogger.warning("Cannot find MIDI data for deleted audio: %s (chart: %s)" % [file_path, chart_id], "FileSystemMGR")
			continue
		if midi.vocal_file_path != file_path:
			continue
		midi.vocal_file_path = ""
		midi.vocal_enabled = false
		if ChartDB and ChartDB.IsOpen():
			ChartDB.SaveRuntime(chart_id, midi.export_runtime_config())
			GLogger.info("Cleared vocal config for chart %s after audio deletion: %s" % [chart_id, file_path], "FileSystemMGR")

## 删除 SF2 音源文件，并从 soundfonts_index 移除
func delete_soundfont(file_path: String) -> bool:
	if not delete_file(file_path):
		return false
	for sf_name in soundfonts_index.keys():
		if soundfonts_index[sf_name].get("path", "") == file_path:
			soundfonts_index.erase(sf_name)
			break
	return true

## 删除背景图片文件，并从 backgrounds_index 移除
func delete_background(file_path: String) -> bool:
	if not delete_file(file_path):
		return false
	for bg_name in backgrounds_index.keys():
		if backgrounds_index[bg_name] == file_path:
			backgrounds_index.erase(bg_name)
			break
	return true
