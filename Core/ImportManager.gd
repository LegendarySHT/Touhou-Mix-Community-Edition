## 外部文件导入管理器
##
## 入口（三者最终走同一套处理）：
##   1. 桌面端「打开方式」：文件路径由命令行参数带入，启动时处理
##   2. 拖入游戏窗口：Window.files_dropped 信号
##   3. Android「打开方式」：AndroidBridge 插件把 content:// 复制到缓存后发出信号
##
## 支持单文件：
##   - .mid/.midi  → 新建 {md5}_{文件名}/ 谱面文件夹（info.json + song.mid）
##   - .sf2        → 复制到 Soundfont/
##   - 音频         → 文件名（去扩展名）= 已有谱面 hash，复制为该谱面的 vocal.<ext>
##   - .zip        → 解析后按文件内结构导入，导入前有确认弹窗
##
## ZIP 结构判定：
##   - 只要在**同一层级**发现 BackgroundImage / Charts / Particles / Skins / Soundfont
##     中的任意数量文件夹，或 settings.ini / theme.ini，即按资源包导入；
##     允许外面套一层（或多层）普通文件夹，例如 zip 内的 files/Charts/...
##   - 否则若整个压缩包只有一个文件夹且其中有多张图片，按皮肤包导入，文件夹名为皮肤名
##   - 否则若压缩包根目录直接有多张图片，按皮肤包导入，压缩包文件名为皮肤名
class_name ImportManager
extends Node

static var instance: ImportManager

const AUDIO_EXTS: Array[String] = ["mp3", "wav", "ogg", "flac"]
const MIDI_EXTS: Array[String] = ["mid", "midi"]
const SKIN_IMAGE_EXTS: Array[String] = ["png", "jpg", "jpeg", "webp", "svg", "bmp"]
const BACKGROUND_EXTS: Array[String] = ["jpg", "jpeg", "png", "webp"]
const SOUNDFONT_EXTS: Array[String] = ["sf2"]

## ZIP 内可识别的资源目录（小写 → 类别）
const ZIP_LAYOUT_FOLDERS := {
	"backgroundimage": "background",
	"charts": "charts",
	"particles": "particles",
	"skins": "skins",
	"soundfont": "soundfont",
}
## ZIP 内可识别的顶层配置文件
const ZIP_CONFIG_FILES: Array[String] = ["settings.ini", "theme.ini"]

## 单块读写大小（大文件分块，避免主线程长时间阻塞）
const COPY_CHUNK_SIZE := 4 * 1024 * 1024

## Android 插件就绪重试帧数（与 MemoryGC 同机制）
const ANDROID_PLUGIN_RETRY_FRAMES := 600

## 是否正在处理一批导入
var _busy: bool = false
## 启动阶段是否已经结束（启动期导入需在资源扫描前完成，运行期导入需即时刷新）
var _startup_done: bool = false
## 启动阶段暂存的文件路径
var _startup_files: Array[String] = []
## 运行期到达、等待串行处理的文件路径
var _queue: Array[String] = []
## 启动期导入进行中：进度提示收起时保留「加载中」文案，直到资源扫描完成
var _startup_import_active: bool = false

## AndroidBridge 插件实例与重试计数
var _android_plugin: Object = null
var _android_retry_frames: int = 0

func _ready() -> void:
	instance = self
	_connect_window_drop()
	_collect_cmdline_files()
	if PathHelper.is_android():
		_connect_android_plugin.call_deferred()

func _exit_tree() -> void:
	if instance == self:
		instance = null

# ============================================================
# 入口
# ============================================================

## 启动期处理命令行 / Android intent 带来的文件
## 由 FileSystemManager.initialize_directory_structure() 在复制默认资源之后、
## 扫描资源之前调用，使导入结果能随本次启动扫描一并进入索引。
## 返回 false 表示已提示重启并准备退出，调用方不再继续扫描。
func process_startup_files() -> bool:
	if _startup_done:
		return true

	# Android：等待插件就绪并拉取启动 intent（信号可能早于本节点连接）
	if PathHelper.is_android():
		for _i in range(10):
			if _android_plugin != null:
				break
			await get_tree().process_frame
		_pull_android_pending()

	var files := _startup_files.duplicate()
	_startup_files.clear()
	_startup_done = true
	if files.is_empty():
		return true
	GLogger.info("启动导入文件 %d 个：%s" % [files.size(), str(files)], "ImportMGR")

	var result := await _process_files(files, true)
	_drain_queue.call_deferred()
	return not bool(result.get("restart_required", false))

## 运行期拖入窗口
func _on_files_dropped(files: PackedStringArray) -> void:
	var valid: Array[String] = []
	for raw in files:
		var path := str(raw)
		if FileAccess.file_exists(path):
			valid.append(path)
	if valid.is_empty():
		return
	_enqueue_files(valid)

## AndroidBridge 推送的文件路径（content:// 已在 Java 侧复制为本地缓存文件）
func _on_android_file_open(path: String) -> void:
	GLogger.info("收到 Android 导入文件：%s（存在=%s）" % [path, str(FileAccess.file_exists(path))], "ImportMGR")
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	_enqueue_files([path])

## 把运行期文件放入串行队列
func _enqueue_files(files: Array) -> void:
	if not _startup_done:
		for f in files:
			_append_unique(_startup_files, str(f))
		return
	for f in files:
		_queue.append(str(f))
	_drain_queue()

func _drain_queue() -> void:
	if _busy or _queue.is_empty():
		return
	var files := _queue.duplicate()
	_queue.clear()
	await _process_files(files, false)
	if not _queue.is_empty():
		_drain_queue()

## 串行处理一批文件（同一批只做一次资源刷新）
func _process_files(files: Array, startup: bool) -> Dictionary:
	if _busy:
		return {"ok": false, "restart_required": false}
	_busy = true
	_startup_import_active = startup
	var acc := {
		"ok": true,
		"changed": false,
		"restart_required": false,
		"chart_folders": [] as Array[String],
		"soundfonts": [] as Array[String],
		"skins_imported": false,
		"particles_imported": false,
		"backgrounds_imported": false,
	}
	for raw in files:
		var path := str(raw)
		var result := await _import_path(path, startup)
		if not bool(result.get("ok", false)):
			acc["ok"] = false
		for folder in result.get("chart_folders", []):
			_append_unique(acc["chart_folders"], str(folder))
			acc["changed"] = true
		for sf in result.get("soundfonts", []):
			_append_unique(acc["soundfonts"], str(sf))
			acc["changed"] = true
		if bool(result.get("skins_imported", false)):
			acc["skins_imported"] = true
			acc["changed"] = true
		if bool(result.get("particles_imported", false)):
			acc["particles_imported"] = true
			acc["changed"] = true
		if bool(result.get("backgrounds_imported", false)):
			acc["backgrounds_imported"] = true
			acc["changed"] = true
		if bool(result.get("restart_required", false)):
			acc["restart_required"] = true
			break
	# 整批导入 + 资源刷新都完成后再解锁，避免刷新期间又启动一批导入
	if not startup and bool(acc.get("changed", false)) and not bool(acc.get("restart_required", false)):
		await _refresh_resources(acc)
	_busy = false
	_startup_import_active = false
	if not _queue.is_empty():
		_drain_queue.call_deferred()
	return acc

func _import_path(path: String, startup: bool) -> Dictionary:
	if not FileAccess.file_exists(path):
		_notify("导入失败：文件不存在（%s）" % path.get_file())
		return {"ok": false}

	var ext := path.get_extension().to_lower()
	if ext == "zip":
		return await _import_zip(path, startup)
	if MIDI_EXTS.has(ext):
		return _import_midi_file(path)
	if SOUNDFONT_EXTS.has(ext):
		return _import_soundfont_file(path)
	if AUDIO_EXTS.has(ext):
		return _import_audio_file(path)

	_notify("导入失败：不支持的文件类型（%s）" % path.get_file())
	return {"ok": false}

# ============================================================
# 单文件导入
# ============================================================

## MIDI：以 MD5 为谱面 hash，创建 Charts/{hash}_{文件名}/info.json+song.mid
func _import_midi_file(path: String) -> Dictionary:
	var hash := FileAccess.get_md5(path).to_lower()
	if hash.is_empty():
		_notify("导入失败：无法读取 MIDI 文件（%s）" % path.get_file())
		return {"ok": false}

	var existing := _find_chart_folder_by_hash(hash)
	if not existing.is_empty():
		_notify("导入失败：谱面已存在（%s）" % path.get_file())
		return {"ok": false}

	var folder := _create_chart_folder_from_file(path, hash, path.get_file().get_basename())
	if folder.is_empty():
		_notify("导入失败：无法创建谱面文件夹（%s）" % path.get_file())
		return {"ok": false}

	_notify("已导入歌曲：%s" % path.get_file().get_basename())
	return {"ok": true, "chart_folders": [folder]}

## SF2：复制到音源目录；同名且内容一致视为已存在，内容不同则覆盖
func _import_soundfont_file(path: String) -> Dictionary:
	var file_name := path.get_file()
	var dest := FileSystemManager.SOUNDFONT_DIR.path_join(file_name)
	if _is_same_path(path, dest):
		_notify("导入失败：音源已存在（%s）" % file_name)
		return {"ok": false}
	if FileAccess.file_exists(dest):
		if _files_equal(path, dest):
			_notify("导入失败：音源已存在（%s）" % file_name)
			return {"ok": false}
	if DirAccess.copy_absolute(path, dest) != OK:
		_notify("导入失败：无法写入音源目录（%s）" % file_name)
		return {"ok": false}
	_notify("已导入音源：%s" % file_name)
	return {"ok": true, "soundfonts": [file_name.get_basename()]}

## 音频：文件名（去扩展名）必须匹配已有谱面的 hash，复制为该谱面的人声文件
func _import_audio_file(path: String) -> Dictionary:
	var stem := path.get_file().get_basename()
	var hash := stem.to_lower()
	var folder := _find_chart_folder_by_hash(hash)
	if folder.is_empty():
		_notify("导入失败：找不到与文件名匹配的谱面（文件名需为 MIDI 哈希）")
		return {"ok": false}

	var ext := path.get_extension().to_lower()
	var chart_dir := FileSystemManager.CHARTS_DIR.path_join(folder)
	var dest := chart_dir.path_join("vocal." + ext)
	if FileAccess.file_exists(dest):
		if _files_equal(path, dest):
			_notify("导入失败：人声音频已存在（%s）" % path.get_file())
			return {"ok": false}

	if DirAccess.copy_absolute(path, dest) != OK:
		_notify("导入失败：无法写入人声音频（%s）" % path.get_file())
		return {"ok": false}
	_notify("已导入人声音频：%s" % path.get_file())
	return {"ok": true, "chart_folders": [folder]}

# ============================================================
# ZIP 导入
# ============================================================

func _import_zip(path: String, startup: bool) -> Dictionary:
	var plan := await _scan_zip_plan(path)
	if not bool(plan.get("ok", false)):
		_notify("导入失败：%s" % str(plan.get("error", "压缩包结构异常")))
		return {"ok": false}

	if not await _confirm_zip_import(plan, startup):
		_notify("已取消导入")
		return {"ok": false}

	var result := await _execute_zip_plan(path, plan)
	if result.has("error"):
		_notify("导入失败：%s" % str(result.get("error", "压缩包内容写入失败")))
		return result
	_notify(_build_zip_result_text(plan, result))

	# 覆盖了配置文件：不刷新资源，直接提示重启并结束游戏
	if bool(plan.get("has_config", false)):
		await _prompt_restart()
		result["restart_required"] = true
	return result

## 解析 ZIP 内容并生成导入计划（含计数），解析期间复用资源扫描进度条
func _scan_zip_plan(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return {"ok": false, "error": "无法打开压缩包"}
	var entries := _collect_zip_entries(zip)
	if entries.is_empty():
		zip.close()
		return {"ok": false, "error": "压缩包为空"}

	var ui := _show_progress("正在解析压缩包，请稍后", entries.size())
	var bar: ProgressBar = ui.get("bar")
	var stem := path.get_file().get_basename()
	var layout := _detect_zip_layout(entries, stem)
	if not bool(layout.get("ok", false)):
		zip.close()
		_hide_progress()
		return layout

	var plan := await _build_zip_plan(zip, entries, layout, bar)
	zip.close()
	_hide_progress()
	if not bool(plan.get("ok", false)):
		return plan
	if _counts_total(plan.get("counts", {})) == 0 and not bool(plan.get("has_config", false)):
		return {"ok": false, "error": "压缩包内没有可导入内容"}
	GLogger.info("压缩包解析完成：%s，配置文件=%s" % [str(plan.get("counts", {})), str(plan.get("has_config", false))], "ImportMGR")
	return plan

## 收集并规范化 ZIP 内文件条目（忽略目录项、系统垃圾文件、越界路径）
func _collect_zip_entries(zip: ZIPReader) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var seen := {}
	for raw in zip.get_files():
		var orig := str(raw)
		if orig.ends_with("/"):
			continue
		var rel := _normalize_zip_path(orig)
		if rel.is_empty() or _is_zip_junk(rel) or not _is_safe_zip_path(rel):
			continue
		if seen.has(rel):
			continue
		seen[rel] = true
		entries.append({"orig": orig, "rel": rel})
	return entries

## 结构判定：优先按资源目录/配置文件；不满足时回退为皮肤包
func _detect_zip_layout(entries: Array[Dictionary], zip_stem: String) -> Dictionary:
	var groups := {}
	for item in entries:
		var rel: String = item["rel"]
		var parts := rel.split("/", false)
		for i in range(parts.size()):
			var low := parts[i].to_lower()
			if i < parts.size() - 1 and ZIP_LAYOUT_FOLDERS.has(low):
				var base := "/".join(parts.slice(0, i))
				if not groups.has(base):
					groups[base] = true
			elif i == parts.size() - 1 and ZIP_CONFIG_FILES.has(low):
				var base2 := "/".join(parts.slice(0, i))
				if not groups.has(base2):
					groups[base2] = true

	if groups.size() == 1:
		return {"ok": true, "mode": "layout", "base": str(groups.keys()[0])}
	if groups.size() > 1:
		return {"ok": false, "error": "压缩包结构异常（资源文件夹不在同一层级）"}

	# 回退 1：仅一个顶层文件夹，且其内有多张图片 → 文件夹名为皮肤名
	var top_dirs := {}
	var root_images: Array[Dictionary] = []
	for item in entries:
		var rel: String = item["rel"]
		var parts := rel.split("/", false)
		if parts.size() <= 1:
			if _is_image_name(rel, SKIN_IMAGE_EXTS):
				root_images.append(item)
		else:
			top_dirs[parts[0]] = true

	if top_dirs.size() == 1:
		var folder := str(top_dirs.keys()[0])
		# 找图片直接所在的目录：兼容外面再套一层普通文件夹（如 files/MySkin/*.png）
		var image_parents := {}
		for item in entries:
			var rel: String = item["rel"]
			if _is_image_name(rel, SKIN_IMAGE_EXTS):
				var parent := rel.get_base_dir()
				if parent == folder or parent.begins_with(folder + "/"):
					image_parents[parent] = true
		if image_parents.size() == 1:
			var skin_base := str(image_parents.keys()[0])
			var skin_name := skin_base.get_file()
			if skin_name.is_empty():
				skin_name = skin_base
			return {"ok": true, "mode": "skin", "base": skin_base, "skin_name": skin_name}
		if not image_parents.is_empty():
			return {"ok": true, "mode": "skin", "base": folder, "skin_name": folder}

	# 回退 2：压缩包根目录直接有多张图片 → 压缩包文件名为皮肤名
	if top_dirs.is_empty() and not root_images.is_empty():
		return {"ok": true, "mode": "skin", "base": "", "skin_name": zip_stem}

	return {"ok": false, "error": "压缩包结构异常"}

## 生成导入计划（不写盘）：分类、计数、目标路径
func _build_zip_plan(zip: ZIPReader, entries: Array[Dictionary], layout: Dictionary, bar: ProgressBar) -> Dictionary:
	var mode: String = layout.get("mode", "layout")
	var base: String = layout.get("base", "")
	var zip_stem: String = str(layout.get("skin_name", "skin"))
	var plan := {
		"ok": true,
		"has_config": false,
		"configs": [] as Array[Dictionary],
		"chart_folders": [] as Array[Dictionary],
		"loose_midis": [] as Array[Dictionary],
		"skins": [] as Array[Dictionary],
		"particles": [] as Array[Dictionary],
		"soundfonts": [] as Array[Dictionary],
		"backgrounds": [] as Array[Dictionary],
		"counts": {"midi": 0, "vocal": 0, "skin": 0, "particle": 0, "soundfont": 0, "background": 0},
	}

	if mode == "skin":
		var skin_entries: Array[Dictionary] = []
		var prefix := "" if base.is_empty() else base + "/"
		for item in entries:
			var rel: String = item["rel"]
			if not prefix.is_empty():
				if not rel.begins_with(prefix):
					continue
				rel = rel.substr(prefix.length())
			if rel.is_empty() or rel.ends_with("/"):
				continue
			skin_entries.append({"orig": item["orig"], "sub": rel})
		if not skin_entries.is_empty():
			plan["skins"].append({"name": _sanitize_filename(zip_stem), "entries": skin_entries})
			plan["counts"]["skin"] = 1
		return plan

	var base_prefix := "" if base.is_empty() else base + "/"
	var chart_map := {}
	var loose_midi_entries: Array[Dictionary] = []
	var skin_map := {}
	var particle_map := {}
	var direct_skin: Array[Dictionary] = []
	var direct_particle: Array[Dictionary] = []
	var sf_map := {}
	var bg_map := {}
	var config_map := {}
	var scanned := 0

	for item in entries:
		var rel: String = item["rel"]
		if not base_prefix.is_empty():
			if not rel.begins_with(base_prefix):
				continue
			rel = rel.substr(base_prefix.length())
		if rel.is_empty():
			continue
		var parts := rel.split("/", false)
		if parts.is_empty():
			continue
		var kind := parts[0].to_lower()

		if parts.size() == 1 and ZIP_CONFIG_FILES.has(kind):
			config_map[kind] = item["orig"]
		elif kind == "charts":
			if parts.size() == 2 and _is_midi_name(parts[1]):
				# Charts 根目录散落的 MIDI
				loose_midi_entries.append({"orig": item["orig"], "sub": parts[1]})
			elif parts.size() >= 3:
				var folder := parts[1]
				if not chart_map.has(folder):
					chart_map[folder] = []
				chart_map[folder].append({"orig": item["orig"], "sub": "/".join(parts.slice(2))})
		elif kind == "skins":
			if parts.size() == 2:
				if _is_image_name(parts[1], SKIN_IMAGE_EXTS) or parts[1].to_lower() == "skin.ini":
					direct_skin.append({"orig": item["orig"], "sub": parts[1]})
			elif parts.size() >= 3:
				var skin_name := parts[1]
				if not skin_map.has(skin_name):
					skin_map[skin_name] = []
				skin_map[skin_name].append({"orig": item["orig"], "sub": "/".join(parts.slice(2))})
		elif kind == "particles":
			if parts.size() == 2:
				direct_particle.append({"orig": item["orig"], "sub": parts[1]})
			elif parts.size() >= 3:
				var pack_name := parts[1]
				if not particle_map.has(pack_name):
					particle_map[pack_name] = []
				particle_map[pack_name].append({"orig": item["orig"], "sub": "/".join(parts.slice(2))})
		elif kind == "soundfont":
			if parts.size() >= 2:
				var sf_name := parts[parts.size() - 1]
				if SOUNDFONT_EXTS.has(sf_name.get_extension().to_lower()):
					sf_map[sf_name.to_lower()] = {"orig": item["orig"], "name": sf_name}
		elif kind == "backgroundimage":
			if parts.size() >= 2:
				var bg_name := parts[parts.size() - 1]
				if BACKGROUND_EXTS.has(bg_name.get_extension().to_lower()):
					bg_map[bg_name.to_lower()] = {"orig": item["orig"], "name": bg_name}

		scanned += 1
		if scanned % 8 == 0:
			if bar:
				bar.value = scanned
			await get_tree().process_frame

	# Charts：图表文件夹需要 info.json 才能确定 hash；散落 MIDI 单独处理
	var existing_hashes := _collect_existing_chart_hashes()
	var seen_hashes := {}
	var chart_checked := 0
	for folder in chart_map.keys():
		chart_checked += 1
		if chart_checked % 8 == 0:
			await get_tree().process_frame
		var folder_entries: Array = chart_map[folder]
		var info_orig := ""
		var midi_orig := ""
		var midi_sub := ""
		var midi_count := 0
		for f in folder_entries:
			var sub: String = f["sub"]
			var low := sub.to_lower()
			if low == "info.json":
				info_orig = f["orig"]
			if _is_midi_name(low):
				midi_count += 1
				if low == "song.mid":
					midi_orig = f["orig"]
					midi_sub = sub
				elif midi_orig.is_empty():
					midi_orig = f["orig"]
					midi_sub = sub
		if midi_count == 0:
			continue

		var info_hash := ""
		if not info_orig.is_empty():
			info_hash = _read_zip_json_hash(zip, info_orig)
		var hash := info_hash
		if hash.is_empty() and not midi_orig.is_empty():
			hash = _read_zip_md5(zip, midi_orig)
		if hash.is_empty() or seen_hashes.has(hash):
			continue
		seen_hashes[hash] = true

		# info.json 缺失/缺 hash 时在导入后补写，避免生成不可见的谱面
		var info_mode := "keep"
		if info_orig.is_empty():
			info_mode = "generate"
		elif info_hash.is_empty():
			info_mode = "patch"

		var target := str(existing_hashes.get(hash, ""))
		if target.is_empty():
			target = _zip_chart_target_folder(folder, hash)
		existing_hashes[hash] = target
		# 只有一个 MIDI 且不叫 song.mid 时复制为 song.mid，保证扫描器能找到主 MIDI
		var rename_midi_sub := ""
		if midi_count == 1 and midi_sub.to_lower() != "song.mid":
			rename_midi_sub = midi_sub
		plan["chart_folders"].append({
			"folder": target,
			"entries": folder_entries,
			"hash": hash,
			"name": folder,
			"info_mode": info_mode,
			"rename_midi_sub": rename_midi_sub,
		})
		plan["counts"]["midi"] = int(plan["counts"]["midi"]) + 1
		for f in folder_entries:
			if _is_audio_name(str(f["sub"])):
				plan["counts"]["vocal"] = int(plan["counts"]["vocal"]) + 1

	# Charts 根目录散落的 MIDI
	if not loose_midi_entries.is_empty():
		var loose_idx := 0
		for f in loose_midi_entries:
			loose_idx += 1
			if loose_idx % 8 == 0:
				await get_tree().process_frame
			var bytes := zip.read_file(str(f["orig"]))
			if bytes.is_empty():
				continue
			var hash := _md5_bytes(bytes)
			if hash.is_empty() or seen_hashes.has(hash) or existing_hashes.has(hash):
				continue
			seen_hashes[hash] = true
			var name := str(f["sub"]).get_basename()
			plan["loose_midis"].append({"orig": f["orig"], "hash": hash, "name": name})
			plan["counts"]["midi"] = int(plan["counts"]["midi"]) + 1

	# Skins：子文件夹各算一套；Skin 根目录直接放图片时按一套处理，名字用压缩包名
	for skin_name in skin_map.keys():
		var list: Array = skin_map[skin_name]
		var has_image := false
		for f in list:
			if _is_image_name(str(f["sub"]), SKIN_IMAGE_EXTS):
				has_image = true
				break
		if has_image:
			plan["skins"].append({"name": _sanitize_filename(skin_name), "entries": list})
	if not direct_skin.is_empty():
		var has_direct_image := false
		for f in direct_skin:
			if _is_image_name(str(f["sub"]), SKIN_IMAGE_EXTS):
				has_direct_image = true
				break
		if has_direct_image:
			plan["skins"].append({"name": _sanitize_filename(zip_stem), "entries": direct_skin})
	plan["counts"]["skin"] = plan["skins"].size()

	# Particles：包内必须有 particle.ini
	for pack_name in particle_map.keys():
		var list: Array = particle_map[pack_name]
		var has_config := false
		for f in list:
			if str(f["sub"]).to_lower() == "particle.ini":
				has_config = true
				break
		if has_config:
			plan["particles"].append({"name": _sanitize_filename(pack_name), "entries": list})
	if not direct_particle.is_empty():
		var has_direct_particle := false
		for f in direct_particle:
			if str(f["sub"]).to_lower() == "particle.ini":
				has_direct_particle = true
				break
		if has_direct_particle:
			plan["particles"].append({"name": _sanitize_filename(zip_stem), "entries": direct_particle})
	plan["counts"]["particle"] = plan["particles"].size()

	# Soundfont / BackgroundImage：扁平化到各自根目录
	for key in sf_map.keys():
		plan["soundfonts"].append(sf_map[key])
	for key in bg_map.keys():
		plan["backgrounds"].append(bg_map[key])
	plan["counts"]["soundfont"] = plan["soundfonts"].size()
	plan["counts"]["background"] = plan["backgrounds"].size()

	# 配置文件
	for key in config_map.keys():
		plan["configs"].append({"orig": config_map[key], "name": str(key)})
	plan["has_config"] = not plan["configs"].is_empty()

	return plan

## 按计划写盘，进度条按文件条目推进
func _execute_zip_plan(path: String, plan: Dictionary) -> Dictionary:
	var jobs := _build_zip_jobs(plan)
	if jobs.is_empty():
		return {"ok": true, "skipped": 0, "failed": 0, "chart_folders": [], "soundfonts": []}

	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return {"ok": false, "error": "无法打开压缩包", "skipped": 0, "failed": 1}

	var ui := _show_progress("正在导入，请稍后", jobs.size())
	var bar: ProgressBar = ui.get("bar")
	var skipped := 0
	var failed := 0
	var done := 0
	for job in jobs:
		var outcome := await _execute_zip_job(zip, job)
		if outcome == "skipped":
			skipped += 1
		elif outcome != "ok":
			failed += 1
		done += 1
		if bar:
			bar.value = done
	zip.close()
	_hide_progress()

	# info.json 缺失/缺 hash 的谱面在文件落盘后补齐元数据；hash 统一为小写，避免与目录前缀不一致
	for cf in plan.get("chart_folders", []):
		var mode := str(cf.get("info_mode", "keep"))
		var chart_dir := FileSystemManager.CHARTS_DIR.path_join(str(cf["folder"]))
		var info_path := chart_dir.path_join("info.json")
		if mode == "generate" and FileAccess.file_exists(info_path):
			continue
		_patch_chart_info_hash(info_path, str(cf["hash"]), str(cf.get("name", cf["folder"])))

	var chart_folders: Array[String] = []
	for cf in plan.get("chart_folders", []):
		chart_folders.append(str(cf["folder"]))
	var soundfonts: Array[String] = []
	for sf in plan.get("soundfonts", []):
		soundfonts.append(str(sf["name"]).get_basename())

	return {
		"ok": failed == 0,
		"skipped": skipped,
		"failed": failed,
		"chart_folders": chart_folders,
		"soundfonts": soundfonts,
		"skins_imported": not plan.get("skins", []).is_empty(),
		"particles_imported": not plan.get("particles", []).is_empty(),
		"backgrounds_imported": not plan.get("backgrounds", []).is_empty(),
		"restart_required": bool(plan.get("has_config", false)),
	}

func _build_zip_jobs(plan: Dictionary) -> Array[Dictionary]:
	var jobs: Array[Dictionary] = []
	for cf in plan.get("chart_folders", []):
		var chart_dir := FileSystemManager.CHARTS_DIR.path_join(str(cf["folder"]))
		var rename_sub := str(cf.get("rename_midi_sub", ""))
		for f in cf["entries"]:
			var sub := _sanitize_rel_path(str(f["sub"]))
			if sub.is_empty():
				continue
			if not rename_sub.is_empty() and str(f["sub"]) == rename_sub:
				sub = "song.mid"
			jobs.append({"kind": "file", "orig": f["orig"], "dest": chart_dir.path_join(sub)})
	for lm in plan.get("loose_midis", []):
		jobs.append({"kind": "midi", "orig": lm["orig"], "hash": lm["hash"], "name": lm["name"]})
	for skin in plan.get("skins", []):
		var skin_dir := FileSystemManager.SKINS_DIR.path_join(str(skin["name"]))
		for f in skin["entries"]:
			var sub := _sanitize_rel_path(str(f["sub"]))
			if sub.is_empty():
				continue
			jobs.append({"kind": "file", "orig": f["orig"], "dest": skin_dir.path_join(sub)})
	for pack in plan.get("particles", []):
		var pack_dir := FileSystemManager.PARTICLES_DIR.path_join(str(pack["name"]))
		for f in pack["entries"]:
			var sub := _sanitize_rel_path(str(f["sub"]))
			if sub.is_empty():
				continue
			jobs.append({"kind": "file", "orig": f["orig"], "dest": pack_dir.path_join(sub)})
	for sf in plan.get("soundfonts", []):
		var name := _sanitize_filename(str(sf["name"]).get_file())
		jobs.append({"kind": "file", "orig": sf["orig"], "dest": FileSystemManager.SOUNDFONT_DIR.path_join(name)})
	for bg in plan.get("backgrounds", []):
		var name := _sanitize_filename(str(bg["name"]).get_file())
		jobs.append({"kind": "file", "orig": bg["orig"], "dest": FileSystemManager.BACKGROUND_DIR.path_join(name)})
	for cfg in plan.get("configs", []):
		jobs.append({"kind": "file", "orig": cfg["orig"], "dest": PathHelper.get_files_dir().path_join(str(cfg["name"]))})
	return jobs

## 返回 "ok" / "skipped" / "failed"
func _execute_zip_job(zip: ZIPReader, job: Dictionary) -> String:
	var bytes := zip.read_file(str(job["orig"]))
	if job["kind"] == "midi":
		var hash := str(job["hash"])
		if not _find_chart_folder_by_hash(hash).is_empty():
			return "skipped"
		var folder := await _create_chart_folder_from_bytes(hash, str(job["name"]), bytes)
		return "ok" if not folder.is_empty() else "failed"

	var dest := str(job["dest"])
	if FileAccess.file_exists(dest):
		if _md5_bytes(bytes) == FileAccess.get_md5(dest).to_lower():
			return "skipped"
	if await _write_bytes_chunked(bytes, dest):
		return "ok"
	return "failed"

## 导入确认弹窗（数量为 0 的类别不显示）
func _confirm_zip_import(plan: Dictionary, _startup: bool) -> bool:
	var popup := PopupWindow.instance
	if popup == null:
		return true
	var lines: Array[String] = []
	var counts: Dictionary = plan.get("counts", {})
	var specs := [
		["midi", "MIDI 歌曲"],
		["vocal", "人声音频"],
		["skin", "皮肤"],
		["particle", "特效"],
		["soundfont", "音源"],
		["background", "背景"],
	]
	for spec in specs:
		var n := int(counts.get(spec[0], 0))
		if n > 0:
			lines.append("· %s：%d" % [spec[1], n])
	if not lines.is_empty():
		lines.insert(0, "将要导入以下内容：")
	if bool(plan.get("has_config", false)):
		if not lines.is_empty():
			lines.append("")
		lines.append("压缩包含 settings.ini / theme.ini，导入后配置将被覆盖，需要重启游戏。")
	lines.append("")
	lines.append("是否继续导入？")
	return await popup.show_message("\n".join(lines), true)

func _build_zip_result_text(plan: Dictionary, result: Dictionary) -> String:
	var counts: Dictionary = plan.get("counts", {})
	var parts: Array[String] = []
	var specs := [
		["midi", "歌曲"],
		["vocal", "人声"],
		["skin", "皮肤"],
		["particle", "特效"],
		["soundfont", "音源"],
		["background", "背景"],
	]
	for spec in specs:
		var n := int(counts.get(spec[0], 0))
		if n > 0:
			parts.append("%s %d" % [spec[1], n])
	var msg := "导入完成"
	if not parts.is_empty():
		msg += "：" + "、".join(parts)
	var skipped := int(result.get("skipped", 0))
	var failed := int(result.get("failed", 0))
	if skipped > 0:
		msg += "（跳过 %d 个已存在文件）" % skipped
	if failed > 0:
		msg += "（失败 %d 个文件）" % failed
	return msg

## 配置已覆盖：强制弹窗提示重启，确认后退出游戏
func _prompt_restart() -> void:
	var popup := PopupWindow.instance
	if popup:
		await popup.show_message("配置文件已导入并覆盖，需要重启游戏才能生效。", false, [], true)
	var main := get_tree().current_scene
	if main != null and main.has_method("shutdown_and_quit"):
		main.shutdown_and_quit()
	else:
		get_tree().quit()

# ============================================================
# 运行期资源刷新
# ============================================================

func _refresh_resources(acc: Dictionary) -> void:
	var fsm := FileSystemManager.instance
	if fsm == null:
		return

	# 覆盖过 MIDI 时清掉解析缓存，避免继续使用旧音符数据
	var chart_folders: Array = acc.get("chart_folders", [])
	if MidiCore != null:
		for folder in chart_folders:
			var midi_path := FileSystemManager.CHARTS_DIR.path_join(str(folder)).path_join("song.mid")
			MidiCore.DropParsed(midi_path)

	var ui := _show_progress("正在更新资源，请稍后", 1)
	var bar: ProgressBar = ui.get("bar")
	if bar:
		bar.value = 0

	await fsm.refresh_after_import(chart_folders)

	# 贴图缓存与索引是两套数据，重扫后仍需按资源类别清理
	if bool(acc.get("skins_imported", false)):
		SkinMGR.clear_skin_cache()
	if bool(acc.get("particles_imported", false)):
		ParticleMGR.clear_texture_cache()
	if bool(acc.get("backgrounds_imported", false)):
		ThemeMGR.invalidate_background_cache()
		ThemeMGR.refresh_backgrounds()

	# 当前使用的音源被同名覆盖时，后端仍持有旧数据，需要重新加载
	var soundfonts: Array = acc.get("soundfonts", [])
	if not soundfonts.is_empty() and PlaybackDisplay.instance != null:
		var current := PlaybackDisplay.instance.current_soundfont_path.get_file().get_basename().to_lower()
		for sf in soundfonts:
			if str(sf).to_lower() == current:
				PlaybackDisplay.instance.reload_soundfont_preserving_position()
				break

	_hide_progress()

# ============================================================
# 进度 UI（复用 FileSystemManager 的遮罩 + 提示 + 进度条）
# ============================================================

func _show_progress(text: String, max_value: int) -> Dictionary:
	var fsm := FileSystemManager.instance
	if fsm == null:
		return {}
	return fsm.show_progress_ui(text, max_value)

func _hide_progress() -> void:
	var fsm := FileSystemManager.instance
	if fsm != null:
		fsm.hide_progress_ui()
	# 启动期保留「加载中」提示，运行期导入结束后不应留下常驻提示
	if _startup_done and not _startup_import_active:
		var tip := get_node_or_null(PathRegistry.PROCESS_TIP) as Label
		if tip:
			tip.visible = false

# ============================================================
# 谱面/文件工具
# ============================================================

## 按 hash 查找已有谱面文件夹（磁盘文件夹名前缀，启动期索引尚未建立时也可用）
func _find_chart_folder_by_hash(hash: String) -> String:
	if hash.is_empty():
		return ""
	var low := hash.to_lower()
	var dir := DirAccess.open(FileSystemManager.CHARTS_DIR)
	if dir != null:
		dir.list_dir_begin()
		var fn := dir.get_next()
		while fn != "":
			if dir.current_is_dir():
				var fn_low := fn.to_lower()
				if fn_low == low or fn_low.begins_with(low + "_"):
					dir.list_dir_end()
					return fn
			fn = dir.get_next()
		dir.list_dir_end()

	var fsm := FileSystemManager.instance
	if fsm != null:
		var found := fsm.lookup_chart(low)
		if not found.is_empty():
			return str(found.get("folder_name", ""))
	return ""

## 一次性建立 已存在谱面 hash(小写) → 文件夹名 映射（ZIP 批量导入用，避免逐条扫目录）
func _collect_existing_chart_hashes() -> Dictionary:
	var hashes := {}
	var dir := DirAccess.open(FileSystemManager.CHARTS_DIR)
	if dir == null:
		return hashes
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if dir.current_is_dir() and not fn.begins_with("."):
			var idx := fn.find("_")
			var h := fn if idx < 0 else fn.substr(0, idx)
			if not h.is_empty():
				hashes[h.to_lower()] = fn
		fn = dir.get_next()
	dir.list_dir_end()
	return hashes

## 由 MIDI 文件创建谱面文件夹，返回文件夹名（空串表示失败）
func _create_chart_folder_from_file(midi_src: String, hash: String, name: String) -> String:
	var folder := _new_chart_folder_name(hash, name)
	var chart_dir := FileSystemManager.CHARTS_DIR.path_join(folder)
	if DirAccess.make_dir_recursive_absolute(chart_dir) != OK:
		return ""
	var info_path := chart_dir.path_join("info.json")
	if not _write_chart_info(info_path, hash, name):
		_cleanup_failed_chart(chart_dir, info_path)
		return ""
	var midi_dst := chart_dir.path_join("song.mid")
	if DirAccess.copy_absolute(midi_src, midi_dst) != OK:
		_cleanup_failed_chart(chart_dir, info_path)
		return ""
	return folder

## 由 MIDI 字节创建谱面文件夹（ZIP 内散落 MIDI 用）
func _create_chart_folder_from_bytes(hash: String, name: String, bytes: PackedByteArray) -> String:
	var folder := _new_chart_folder_name(hash, name)
	var chart_dir := FileSystemManager.CHARTS_DIR.path_join(folder)
	if DirAccess.make_dir_recursive_absolute(chart_dir) != OK:
		return ""
	var info_path := chart_dir.path_join("info.json")
	if not _write_chart_info(info_path, hash, name):
		_cleanup_failed_chart(chart_dir, info_path)
		return ""
	if not await _write_bytes_chunked(bytes, chart_dir.path_join("song.mid")):
		_cleanup_failed_chart(chart_dir, info_path)
		return ""
	return folder

func _new_chart_folder_name(hash: String, name: String) -> String:
	var clean := _sanitize_filename(name)
	if clean.is_empty():
		clean = hash
	return "%s_%s" % [hash, clean]

func _write_chart_info(info_path: String, hash: String, name: String) -> bool:
	var now := Time.get_datetime_string_from_system(true) + "Z"
	var data := {
		"hash": hash,
		"uploaderId": "",
		"uploaderName": "本地导入",
		"uploaderAvatarUrl": "",
		"name": name,
		"desc": "",
		"artistName": "",
		"artistUrl": "",
		"coverHash": "",
		"uploadedDate": now,
		"approvedDate": now,
		"status": "APPROVED",
		"downloadCount": 0,
		"trialCount": 0,
		"upCount": 0,
		"downCount": 0,
		"song": {
			"_id": "song_" + hash,
			"name": name,
			"track": 0,
			"author": "",
		},
		"album": {
			"_id": "album_local",
			"name": "本地歌曲",
			"abbr": "",
			"date": "",
		},
	}
	ChartNormalizer.cleanup_types_recursive(data)
	var f := FileAccess.open(info_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "\t", false))
	f.close()
	return true

func _cleanup_failed_chart(chart_dir: String, info_path: String) -> void:
	DirAccess.remove_absolute(chart_dir.path_join("song.mid"))
	DirAccess.remove_absolute(info_path)
	DirAccess.remove_absolute(chart_dir)

## ZIP 内 info.json 存在但缺 hash 字段：补写 hash，其余元数据保持不变
func _patch_chart_info_hash(info_path: String, hash: String, name: String) -> void:
	if not FileAccess.file_exists(info_path):
		_write_chart_info(info_path, hash, name)
		return
	var f := FileAccess.open(info_path, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		_write_chart_info(info_path, hash, name)
		return
	var data: Dictionary = parsed
	var changed := false
	if str(data.get("hash", "")) != hash:
		data["hash"] = hash
		changed = true
	if data.has("file_hash") and str(data.get("file_hash", "")) != hash:
		data["file_hash"] = hash
		changed = true
	if not changed:
		return
	var out := FileAccess.open(info_path, FileAccess.WRITE)
	if out == null:
		return
	out.store_string(JSON.stringify(data, "\t", false))
	out.close()

## ZIP 内图表文件夹目标名：已带 hash 前缀则保留，否则补前缀
func _zip_chart_target_folder(folder: String, hash: String) -> String:
	var clean := _sanitize_filename(folder)
	var low := clean.to_lower()
	if low == hash or low.begins_with(hash + "_"):
		return clean
	return "%s_%s" % [hash, clean]

## 递归建父目录并写入字节（大文件分块让出主线程）
func _write_bytes_chunked(bytes: PackedByteArray, dest: String) -> bool:
	var parent := dest.get_base_dir()
	if not parent.is_empty() and not DirAccess.dir_exists_absolute(parent):
		if DirAccess.make_dir_recursive_absolute(parent) != OK:
			return false
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		return false
	var total := bytes.size()
	if total == 0:
		f.close()
		return true
	var offset := 0
	while offset < total:
		var n := mini(COPY_CHUNK_SIZE, total - offset)
		f.store_buffer(bytes.slice(offset, offset + n))
		offset += n
		if total > COPY_CHUNK_SIZE:
			await get_tree().process_frame
	f.close()
	return true

## 读取 ZIP 内 info.json 的 hash / file_hash
func _read_zip_json_hash(zip: ZIPReader, entry: String) -> String:
	var bytes := zip.read_file(entry)
	if bytes.is_empty():
		return ""
	if bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF:
		bytes = bytes.slice(3)
	var parsed = JSON.parse_string(bytes.get_string_from_utf8())
	if parsed == null or not parsed is Dictionary:
		return ""
	var data: Dictionary = parsed
	var h := str(data.get("hash", ""))
	if h.is_empty():
		h = str(data.get("file_hash", ""))
	return h.to_lower()

func _read_zip_md5(zip: ZIPReader, entry: String) -> String:
	return _md5_bytes(zip.read_file(entry))

func _md5_bytes(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_MD5) != OK:
		return ""
	ctx.update(bytes)
	return ctx.finish().hex_encode().to_lower()

# ============================================================
# 通用小工具
# ============================================================

func _collect_cmdline_files() -> void:
	var args: Array[String] = []
	for a in OS.get_cmdline_args():
		args.append(str(a))
	for a in OS.get_cmdline_user_args():
		args.append(str(a))
	for raw in args:
		var path := raw.strip_edges().trim_prefix("\"").trim_suffix("\"")
		if path.is_empty() or path.begins_with("-"):
			continue
		if path.begins_with("res://") or path.begins_with("user://"):
			path = ProjectSettings.globalize_path(path)
		if not FileAccess.file_exists(path):
			continue
		var ext := path.get_extension().to_lower()
		if ext == "zip" or MIDI_EXTS.has(ext) or SOUNDFONT_EXTS.has(ext) or AUDIO_EXTS.has(ext):
			_append_unique(_startup_files, path)

func _connect_window_drop() -> void:
	var win := get_window()
	if win != null and not win.files_dropped.is_connected(_on_files_dropped):
		win.files_dropped.connect(_on_files_dropped)

func _connect_android_plugin() -> void:
	if _android_plugin == null:
		_android_plugin = _android_singleton()
	if _android_plugin == null:
		_android_retry_frames += 1
		if _android_retry_frames < ANDROID_PLUGIN_RETRY_FRAMES:
			_connect_android_plugin.call_deferred()
		else:
			GLogger.warning("AndroidBridge singleton never became available; 打开方式导入不可用", "ImportMGR")
		return
	var plugin := _android_plugin
	GLogger.info("AndroidBridge 已就绪（file_open_requested=%s）" % str(plugin.has_signal("file_open_requested")), "ImportMGR")
	if plugin.has_signal("file_open_requested"):
		if not plugin.is_connected("file_open_requested", _on_android_file_open):
			plugin.connect("file_open_requested", _on_android_file_open)
	# 单例注册与方法注册分两步完成：单例已可见时 consume_pending_open_file 可能还没注册。
	# 这里等方法就绪后再拉一次，兜住"信号在 GDScript 连接前已发出"的冷启动场景。
	_pull_android_pending_when_ready()

func _android_singleton() -> Object:
	if not Engine.has_singleton("AndroidBridge"):
		return null
	return Engine.get_singleton("AndroidBridge")

func _pull_android_pending() -> void:
	if _android_plugin == null:
		return
	if not _plugin_has_java_method("consume_pending_open_file"):
		return
	var path := str(_android_plugin.call("consume_pending_open_file"))
	if not path.is_empty():
		GLogger.info("拉取 Android 待导入文件：%s" % path, "ImportMGR")
		_on_android_file_open(path)

## 等待插件方法注册完成后再拉取（单例注册早于方法注册）
func _pull_android_pending_when_ready() -> void:
	for _i in range(180):
		if _android_plugin == null:
			return
		# 信号也可能晚于单例注册，这里顺手补连一次
		if _android_plugin.has_signal("file_open_requested") \
				and not _android_plugin.is_connected("file_open_requested", _on_android_file_open):
			_android_plugin.connect("file_open_requested", _on_android_file_open)
		if _plugin_has_java_method("consume_pending_open_file"):
			_pull_android_pending()
			return
		await get_tree().process_frame
	GLogger.warning("AndroidBridge 未暴露 consume_pending_open_file，无法拉取启动文件", "ImportMGR")

## Android 侧插件是 JNISingleton：@UsedByGodot 方法不在 get_method_list 里，
## 不能用 has_method 判断，必须走它绑定的 has_java_method。
func _plugin_has_java_method(method: String) -> bool:
	if _android_plugin == null:
		return false
	if _android_plugin.has_method("has_java_method"):
		return bool(_android_plugin.call("has_java_method", method))
	return _android_plugin.has_method(method)

## 统一提示：顶部横幅 + 日志
func _notify(text: String) -> void:
	GLogger.info(text, "ImportMGR")
	if EvtBus != null:
		EvtBus.notify(text)

func _append_unique(arr: Array, value: String) -> void:
	if value.is_empty():
		return
	if not arr.has(value):
		arr.append(value)

static func _counts_total(counts: Dictionary) -> int:
	var total := 0
	for key in counts.keys():
		total += int(counts[key])
	return total

static func _is_midi_name(name: String) -> bool:
	return MIDI_EXTS.has(name.get_extension().to_lower())

static func _is_audio_name(name: String) -> bool:
	return AUDIO_EXTS.has(name.get_extension().to_lower())

static func _is_image_name(name: String, exts: Array[String]) -> bool:
	return exts.has(name.get_extension().to_lower())

static func _is_same_path(a: String, b: String) -> bool:
	return a.replace("\\", "/") == b.replace("\\", "/")

static func _files_equal(a: String, b: String) -> bool:
	return FileAccess.get_md5(a).to_lower() == FileAccess.get_md5(b).to_lower()

func _is_zip_junk(rel: String) -> bool:
	var low := rel.to_lower()
	if low.begins_with("__macosx/"):
		return true
	if low == ".ds_store" or low.ends_with("/.ds_store"):
		return true
	if low == "thumbs.db" or low.ends_with("/thumbs.db"):
		return true
	var file_name := low.get_file()
	if file_name.begins_with("._"):
		return true
	return false

func _is_safe_zip_path(rel: String) -> bool:
	var parts := rel.split("/", false)
	for p in parts:
		if p == ".." or p == ".":
			return false
		if p.contains(":"):
			return false
		for c in p:
			if c.unicode_at(0) < 32:
				return false
	return true

func _normalize_zip_path(p: String) -> String:
	var s := p.replace("\\", "/")
	while s.begins_with("./"):
		s = s.substr(2)
	s = s.trim_prefix("/")
	while s.contains("//"):
		s = s.replace("//", "/")
	return s

## 把 ZIP 内相对路径逐段清洗（拒绝越界路径）
func _sanitize_rel_path(rel: String) -> String:
	var out: Array[String] = []
	for p in rel.split("/", false):
		if p == "." or p.is_empty():
			continue
		if p == "..":
			return ""
		out.append(_sanitize_filename(p))
	return "/".join(out)

static func _sanitize_filename(nm: String) -> String:
	const INVALID := "<>:\"/\\|?*"
	var result := ""
	for c in nm:
		var cu := c.unicode_at(0)
		if cu < 32 or c in INVALID:
			result += "_"
		else:
			result += c
	result = result.strip_edges()
	while result.contains("  "):
		result = result.replace("  ", " ")
	while result.ends_with(".") or result.ends_with(" "):
		result = result.substr(0, result.length() - 1)
	if result.length() > 80:
		result = result.substr(0, 80).strip_edges()
		if result.ends_with(".") or result.ends_with(" "):
			result = result.substr(0, result.length() - 1)
	const RESERVED := ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]
	if RESERVED.has(result.to_upper()):
		result = "_" + result
	if result.is_empty():
		result = "unknown"
	return result
