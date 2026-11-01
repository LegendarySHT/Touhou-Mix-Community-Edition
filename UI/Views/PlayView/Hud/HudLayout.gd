class_name HudLayout
extends RefCounted

## 自定义 HUD 布局的读写。
## 存成独立的 hud_layout.json（放在存储根 Settings/ 下，随存储根一起迁移），
## 不塞进 settings.ini：布局是结构化数据，且增删组件不该触发配置系统的默认值校验。

const FILE_NAME := "hud_layout.json"
const VERSION := 1


static func file_path() -> String:
	return PathHelper.get_settings_dir() + FILE_NAME


## 读取布局。文件缺失 / 解析失败 / 内容全部非法时回退默认布局；
## 文件里明确写了空列表（玩家把组件全删了）则尊重它，不再塞回默认布局。
static func load_layout() -> Array:
	var path := file_path()
	if not FileAccess.file_exists(path):
		return HudSchema.default_layout()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return HudSchema.default_layout()
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		return HudSchema.default_layout()
	var raw: Variant = (parsed as Dictionary).get("components", null)
	if not (raw is Array):
		return HudSchema.default_layout()
	var out := _normalize_list(raw as Array)
	if out.is_empty() and not (raw as Array).is_empty():
		# 有内容但全被剔除（组件 id 失配等）→ 当损坏处理
		GLogger.warning("HUD 布局内容非法，回退默认布局", "HudLayout")
		return HudSchema.default_layout()
	return out


static func save_layout(list: Array) -> bool:
	var dir := PathHelper.get_settings_dir()
	if not PathHelper.ensure_dir_exists(dir):
		GLogger.warning("HUD 布局目录创建失败: %s" % dir, "HudLayout")
		return false
	var f := FileAccess.open(file_path(), FileAccess.WRITE)
	if f == null:
		GLogger.warning("HUD 布局写入失败: %s" % file_path(), "HudLayout")
		return false
	f.store_string(JSON.stringify({
		"version": VERSION,
		"components": list,
	}, "  "))
	f.close()
	GLogger.info("HUD 布局已保存: %s" % file_path(), "HudLayout")
	return true


## 逐项校验：类型错位、组件 id 失配、同 id 重复都就地剔除。
static func _normalize_list(raw: Array) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for item in raw:
		if not (item is Dictionary):
			continue
		var d := _normalize_item(item as Dictionary)
		if d.is_empty():
			continue
		var id := String(d["id"])
		if seen.has(id):
			continue
		seen[id] = true
		out.append(d)
	return out


static func _normalize_item(src: Dictionary) -> Dictionary:
	var id := String(src.get("id", ""))
	if not HudSchema.exists(id):
		return {}
	var anchor: Array = src.get("anchor", [0.5, 0.5])
	var offset: Array = src.get("offset", [0.0, 0.0])
	if not (anchor is Array) or anchor.size() < 2:
		anchor = [0.5, 0.5]
	if not (offset is Array) or offset.size() < 2:
		offset = [0.0, 0.0]
	var params: Variant = src.get("params", {})
	if not (params is Dictionary):
		params = {}
	return {
		"id": id,
		"variant": int(src.get("variant", 0)),
		"anchor": [clampf(float(anchor[0]), 0.0, 1.0), clampf(float(anchor[1]), 0.0, 1.0)],
		"offset": [float(offset[0]), float(offset[1])],
		"scale": clampf(float(src.get("scale", 1.0)), 0.1, 5.0),
		"visible": bool(src.get("visible", true)),
		"params": (params as Dictionary).duplicate(true),
	}
