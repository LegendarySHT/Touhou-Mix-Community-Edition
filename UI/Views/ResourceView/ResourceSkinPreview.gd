## 皮肤卡片预览：按运行时同一套「base → core」顺序绘制一个点块。
##
## 不直接加载整张预览图：只按需异步取 short / short-core 两层贴图，
## 避免切到皮肤页时在主线程同步解码大量图片；上色复用 SkinManager 的颜色解析。
extends Control

const PREVIEW_MARGIN := 8.0

var _skin_key: String = ""
var _base_tex: Texture2D = null
var _core_tex: Texture2D = null
var _color: Color = Color.WHITE
var _version: int = 0
var _initialized := false
var _base_request_id := ""
var _core_request_id := ""


func setup(item: Dictionary) -> void:
	var skin_key := str(item.get("key", ""))
	if skin_key.is_empty():
		clear()
		return
	if _initialized and skin_key == _skin_key:
		return
	clear()
	_skin_key = skin_key
	_initialized = true
	_color = _resolve_color()
	_request_texture(SkinMGR.get_skin_texture_path(skin_key, "short"), true)
	_request_texture(SkinMGR.get_skin_texture_path(skin_key, "short_core"), false)
	queue_redraw()


func clear() -> void:
	_version += 1
	_initialized = false
	if not _base_request_id.is_empty():
		CoverLoader.cancel(_base_request_id)
	if not _core_request_id.is_empty():
		CoverLoader.cancel(_core_request_id)
	_base_request_id = ""
	_core_request_id = ""
	_skin_key = ""
	_base_tex = null
	_core_tex = null
	queue_redraw()


func _request_texture(path: String, is_base: bool) -> void:
	if path.is_empty():
		return
	# res:// 贴图已由导入器处理；CoverLoader 的后台线程只接 user://，这里主线程同步取缓存资源。
	if path.begins_with("res://"):
		if ResourceLoader.exists(path):
			_assign_texture(load(path), is_base)
		return
	var version := _version
	var request_id := "resource_skin_%d_%s" % [get_instance_id(), "base" if is_base else "core"]
	if is_base:
		_base_request_id = request_id
	else:
		_core_request_id = request_id
	CoverLoader.request_load(request_id, path, func(_p: String, tex: Texture2D, _v: int) -> void:
		if version != _version:
			return
		_assign_texture(tex, is_base)
	)


func _assign_texture(tex: Texture2D, is_base: bool) -> void:
	if tex == null:
		return
	if is_base:
		_base_tex = tex
	else:
		_core_tex = tex
	queue_redraw()


func _resolve_color() -> Color:
	var config := SkinMGR.get_skin_config(_skin_key)
	if config.is_empty():
		return Color.WHITE
	var globals := _preview_global_colors()
	return SkinManager.resolve_note_colors(config, false, {}, globals).get("short", Color.WHITE)


## 全局随机色无法预知本局实际值；用确定性的代表色，避免预览每次刷新闪烁。
func _preview_global_colors() -> Dictionary:
	var cfg := ConfigManager.instance
	if cfg == null or cfg.get_int("randomize_block_color", 0) != 1:
		return {}
	var unified := cfg.get_int("sync_color_across_block_type", 0) == 1
	var saturation := 0.9
	var value := 0.95
	if unified:
		var same := Color.from_hsv(0.55, saturation, value)
		return {"short": same, "instant": same, "long": same}
	return {
		"short": Color.from_hsv(0.10, saturation, value),
		"instant": Color.from_hsv(0.55, saturation, value),
		"long": Color.from_hsv(0.85, saturation, value),
	}


func _draw() -> void:
	var ref_tex := _base_tex if _base_tex != null else _core_tex
	if ref_tex == null:
		return
	var tex_size := ref_tex.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0 or size.x <= 0.0 or size.y <= 0.0:
		return
	var max_size := size - Vector2(PREVIEW_MARGIN, PREVIEW_MARGIN) * 2.0
	var scale := minf(max_size.x / tex_size.x, max_size.y / tex_size.y)
	if scale <= 0.0:
		return
	var draw_size := tex_size * scale
	var rect := Rect2((size - draw_size) * 0.5, draw_size)
	# 与 NoteBatchDrawer._draw_note_layers 相同的叠加顺序：先 base，后 core 上色。
	if _base_tex != null:
		draw_texture_rect(_base_tex, rect, false)
	if _core_tex != null:
		draw_texture_rect(_core_tex, rect, false, _color)


func _exit_tree() -> void:
	clear()
