## 主题管理器（单例）
## 统一管理全局颜色调色板、背景图片和字号配置
## 通过 autoload 注册，引擎启动时自动实例化
##
## 颜色来源：theme.ini 的 [preset_*] 段 → active_preset 选择 → _palette（7 色）
## 背景色由 primary_dark 自动衍生，语义色（danger/success 等）写死在代码中
##
## 外部接口：
##   ThemeMGR.get_color("primary")
##   ThemeMGR.apply_preset("pink")
##   ThemeMGR.refresh_theme_only()   # 主题变更后刷新主题色（不刷新背景）
##   ThemeMGR.refresh_backgrounds()  # 仅刷新背景（给设置界面）
class_name ThemeManager
extends Node

func _ready() -> void:
	add_to_group("singletons")
	load_theme()
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DEBOUNCE_SECONDS
	_save_timer.timeout.connect(_flush_scheduled_save)
	add_child(_save_timer)
	if EvtBus:
		EvtBus.theme_changed.connect(_on_theme_changed)
	# 监听 UI 状态变化，触发主背景交叉淡入淡出
	if UiStatMGR:
		UiStatMGR.state_changed.connect(_on_state_changed_for_bg)
	# 延迟初始化主背景节点引用，确保 PathRegistry.MAIN 已就绪
	call_deferred("_init_main_bg_nodes")

# ============ 配置路径 ============

const DEFAULT_THEME_PATH := "res://Resources/Config/theme.ini"
const DEFAULT_PRESET := "blue"

# 共享按钮 Theme 资源（几何参数收在 .tres，颜色由本管理器按主题统一刷新）
const SHARED_LIST_BTN_THEME_PATH := "res://UI/Theme/BtnTheme/ListBtn-ColorBorder.tres"
const SHARED_R12_BTN_THEME_PATH := "res://UI/Theme/BtnTheme/R12NoBorder.tres"

static var USER_THEME_PATH: String:
	get: return PathHelper.get_files_dir() + "theme.ini"

# ============ 内部状态 ============

var _palette: Dictionary = {}
var _font_sizes: Dictionary = {}
var _backgrounds: Dictionary = {}
var _presets: Dictionary = {}
# 中性色板（[common] 段，深色模式用）。浅色模式不读取此字典，
# 而是从当前强调色实时衍生（见 _apply_light_neutral_layer），保证浅色也以主题色为主。
var _common: Dictionary = {}
# 外观模式：dark（深色，默认）/ light（浅色）。独立于预设（强调色），可任意组合。
var _appearance: String = "dark"
var _theme_name: String = "default"
var _loaded: bool = false

# 背景图片纹理缓存（file_name → Texture2D），避免主题切换时重复读盘
var _bg_image_cache: Dictionary = {}

# 主题保存防抖（颜色选择器拖动等高频回调只落盘一次）
var _save_timer: Timer = null
var _save_pending: bool = false
const SAVE_DEBOUNCE_SECONDS := 0.25

# 背景图异步加载（TMX-037）：缓存未命中时由后台线程读盘，避免主线程同步 IO 卡顿
var _bg_load_thread: Thread = null
var _bg_pending_rects: Dictionary = {}   # file_name -> Array[{rect, stretch}]
var _bg_load_queue: Array[String] = []

# 颜色令牌一览（get_color 可取的键，均来自 theme.ini 的 [common] + 预设）：
#   强调：primary / primary_light / primary_dark / secondary
#   板面：surface_low / surface / surface_high / surface_hover
#   描边：border / border_soft
#   语义：danger / success / warning / info
#   文字：text_primary / text_secondary / text_dim
# 说明：语义色也统一走 get_color("danger") 等取值，不再另设常量，避免两处定义漂移。

# 语义色的兜底默认值（用户配置缺键时 get_color 的返回值）
const SEMANTIC_FALLBACK := {
	"danger": Color("#FF5C6C"),
	"success": Color("#3ED88C"),
	"warning": Color("#FFC24B"),
	"info": Color("#5B8CFF"),
	"surface_low": Color("#090C13"),
	"surface": Color("#10141D"),
	"surface_high": Color("#181E2B"),
	"surface_hover": Color("#222A3B"),
	"border": Color("#2B3446"),
	"border_soft": Color("#1F2634"),
	"text_primary": Color("#F2F5FB"),
	"text_secondary": Color("#A6B1C9"),
	"text_dim": Color("#5C6883"),
}

# ============ 颜色 API ============

func get_color(key: String, default: Color = Color.WHITE) -> Color:
	var k := key.to_lower()
	if _palette.has(k):
		return _palette[k]
	if SEMANTIC_FALLBACK.has(k):
		GLogger.warning("Theme color key missing, using fallback: %s" % key, "ThemeManager")
		return SEMANTIC_FALLBACK[k]
	GLogger.warning("Theme color key not found: %s" % key, "ThemeManager")
	return default

func set_color(key: String, value: Color) -> void:
	# 注意：此方法会立即同步落盘 + 触发完整主题刷新（含 4 帧分帧），
	# 不适合连接到颜色选择器拖动等高频回调（每帧调用会堆叠 I/O 与 refresh 协程）。
	_palette[key.to_lower()] = value
	GLogger.info("Theme color changed: %s = %s" % [key, value.to_html(true)], "ThemeManager")
	_schedule_save_theme()
	refresh_theme_only()
	if EvtBus:
		EvtBus.theme_changed.emit(_theme_name)

# ============ 预设颜色方案 ============

func get_available_presets() -> PackedStringArray:
	var names: PackedStringArray = []
	for key in _presets:
		names.append(key)
	return names

func apply_preset(preset_name: String) -> void:
	if not _presets.has(preset_name):
		GLogger.warning("预设不存在: %s，回退到 %s" % [preset_name, DEFAULT_PRESET], "ThemeManager")
		if preset_name != DEFAULT_PRESET and _presets.has(DEFAULT_PRESET):
			apply_preset(DEFAULT_PRESET)
		return

	var p: Dictionary = _presets[preset_name]
	for key in p:
		var val: String = p[key]
		if val.is_valid_html_color():
			_palette[key.to_lower()] = Color(val)

	# 强调色就位后，按当前外观模式并入中性层（深色读 _common，浅色从强调色衍生）
	_apply_neutral_layer()

	_theme_name = preset_name
	GLogger.info("主题预设已应用: %s (%d 色)" % [preset_name, _palette.size()], "ThemeManager")

	# apply_preset 自身负责 save + refresh；emit theme_changed 仅通知外部监听者
	# _on_theme_changed 收到信号时 _theme_name 已等于 preset_name，会跳过 re-apply 并跳过重复 save/refresh
	save_theme()
	refresh_theme_only()
	if EvtBus:
		EvtBus.theme_changed.emit(_theme_name)

func set_palette_colors(pri: Color, pri_light: Color, pri_dark: Color) -> void:
	_palette["primary"] = pri
	_palette["primary_light"] = pri_light
	_palette["primary_dark"] = pri_dark
	_theme_name = "custom"
	# 强调色变了，浅色模式的中性层依赖强调色，需重新衍生
	_apply_neutral_layer()
	GLogger.info("主题色已自定义设置", "ThemeManager")
	_schedule_save_theme()
	refresh_theme_only()
	if EvtBus:
		EvtBus.theme_changed.emit(_theme_name)

# ============ 外观模式（深色 / 浅色） ============

func get_appearance() -> String:
	return _appearance

## 切换外观模式（dark / light）。浅色模式的中性层从当前强调色实时衍生，
## 因此浅色界面以主题色为主，而非通用灰白；切换同时刷新主题色与背景。
func set_appearance(mode: String) -> void:
	if mode != "dark" and mode != "light":
		GLogger.warning("未知外观模式: %s" % mode, "ThemeManager")
		return
	if mode == _appearance:
		return
	_appearance = mode
	_apply_neutral_layer()
	GLogger.info("外观模式已切换: %s" % _appearance, "ThemeManager")
	_schedule_save_theme()
	refresh_theme_only()
	refresh_backgrounds()
	if EvtBus:
		EvtBus.theme_changed.emit(_theme_name)

## 根据当前外观模式把中性层并入 _palette：
##   dark  → 直接采用 [common] 静态中性色
##   light → 从当前强调色（primary 色相）衍生浅色中性层，确保浅色也以主题色为主
func _apply_neutral_layer() -> void:
	if _appearance == "light":
		_apply_light_neutral_layer()
		return
	for key in _common:
		_palette[key] = _common[key]

## 从强调色衍生浅色中性层。
## 思路：取 primary 的色相 h 与饱和 s，把板面/描边做成「高亮度 + 同色相明显染色」。
## 参考上个提交（深色模式）之前那套「以主题色为主」的配色：当时的板面/按钮都强绑定强调色，
## 因此这里刻意拉高染色饱和，让浅色板面不只是灰白而是一眼看出主题色（蓝主题→浅蓝、粉主题→浅粉……）。
## 文字取同色相近黑，语义色取在该浅底上可读的固定值。
func _apply_light_neutral_layer() -> void:
	var accent := get_color("primary")
	var h := accent.h
	var s := accent.s
	# 板面/描边的「同色相染色」：越靠前的面越浅，但都保留可辨识的主题色偏
	var light := {
		"surface_low":   Color.from_hsv(h, min(s * 0.45, 0.30), 0.97),
		"surface":       Color.from_hsv(h, min(s * 0.48, 0.34), 0.93),
		"surface_high":  Color.from_hsv(h, min(s * 0.55, 0.42), 0.87),
		"surface_hover": Color.from_hsv(h, min(s * 0.62, 0.50), 0.80),
		"border":        Color.from_hsv(h, min(s * 0.58, 0.46), 0.60),
		"border_soft":   Color.from_hsv(h, min(s * 0.42, 0.30), 0.86),
		# 文字：同色相近黑，保证在浅底上对比足够
		"text_primary":  Color.from_hsv(h, min(s * 0.40, 0.30), 0.13),
		"text_secondary":Color.from_hsv(h, min(s * 0.35, 0.26), 0.32),
		"text_dim":      Color.from_hsv(h, min(s * 0.32, 0.24), 0.48),
		# 语义色：浅底上需更深更收敛，避免刺眼且保证可读
		"danger":  Color("#C7303F"),
		"success": Color("#128A4C"),
		"warning": Color("#A8700A"),
		"info":    Color("#245FC4")
	}
	for key in light:
		_palette[key] = light[key]

# ============ 主题加载/保存 ============

func load_theme(file_path: String = "") -> bool:
	_palette.clear()
	_presets.clear()
	_font_sizes.clear()
	_backgrounds.clear()

	var default_cfg := ConfigManager.instance.load_config(DEFAULT_THEME_PATH)
	if default_cfg.is_empty():
		push_error("ThemeManager: 默认主题配置加载失败: " + DEFAULT_THEME_PATH)
		return false

	var user_path := file_path if not file_path.is_empty() else USER_THEME_PATH
	var user_cfg: Dictionary = {}
	if FileAccess.file_exists(user_path):
		user_cfg = ConfigManager.instance.load_config(user_path)

	var merged := ConfigManager.instance.merge_with_defaults(user_cfg, default_cfg)
	_parse_theme_config(merged)

	var active: String = _get_str(merged, "Theme", "active_preset", DEFAULT_PRESET)
	# 外观模式独立于预设：读取后校验，非法值回退 dark
	var appr: String = _get_str(merged, "Theme", "appearance", "dark")
	_appearance = "light" if appr == "light" else "dark"
	apply_preset(active)

	_loaded = true
	if EvtBus:
		EvtBus.theme_changed.emit(_theme_name)
	return true

func save_theme(file_path: String = "") -> bool:
	var user_path := file_path if not file_path.is_empty() else USER_THEME_PATH
	var cfg: Dictionary = {}

	cfg["Theme"] = {"version": "2.0.0", "active_preset": _theme_name, "appearance": _appearance}
	cfg["preset_" + _theme_name] = {}
	for key in _palette:
		cfg["preset_" + _theme_name][key] = (_palette[key] as Color).to_html(true)

	for p_name in _presets:
		if p_name != _theme_name:
			cfg["preset_" + p_name] = _presets[p_name].duplicate()

	cfg["backgrounds"] = {}
	for key in _backgrounds:
		cfg["backgrounds"][key] = str(_backgrounds[key])

	cfg["font_sizes"] = {}
	for key in _font_sizes:
		cfg["font_sizes"][key] = str(_font_sizes[key])

	return ConfigManager.instance.save_config(user_path, cfg)

# ============ 字号 API ============

func get_font_size(key: String, default: int = 32) -> int:
	if _font_sizes.has(key):
		return _font_sizes[key]
	GLogger.warning("Font size key not found: %s" % key, "ThemeManager")
	return default

# ============ 背景管理 ============

func get_view_background(view_name: String) -> Dictionary:
	var bg: Dictionary = {}
	var prefix := "bg_" + view_name + "_"
	for key in _backgrounds:
		if key.begins_with(prefix):
			bg[key.substr(prefix.length())] = _backgrounds[key]
	return bg

func set_view_background(view_name: String, config: Dictionary) -> void:
	var prefix := "bg_" + view_name + "_"
	for key in config:
		_backgrounds[prefix + key] = config[key]
	GLogger.info("背景设置已更新: %s" % view_name, "ThemeManager")
	save_theme()
	# 仅刷新背景（不 emit theme_changed，避免触发 refresh_theme_only 完整主题刷新导致卡顿）
	refresh_backgrounds()

func apply_background(texture_rect: TextureRect, view_name: String) -> void:
	if texture_rect == null:
		return

	var prefix := "bg_" + view_name + "_"
	var bg_type: String = _backgrounds.get(prefix + "type", "gradient")

	match bg_type:
		"cover":
			# 封面模式由 PlayView 自己处理（需要曲包封面 + 模糊烘焙）
			# ThemeManager 不实际应用，仅作为配置占位，让 PlayView 完全接管
			return
		"solid":
			var color_str: String = _backgrounds.get(prefix + "solid_color", "#0A0D14")
			var solid_color := Color(color_str) if color_str.is_valid_html_color() else Color("#0A0D14")
			texture_rect.texture = _create_solid_gradient_texture(solid_color)
			texture_rect.modulate = Color.WHITE
		"image":
			var img_path: String = _backgrounds.get(prefix + "image_path", "")
			if not img_path.is_empty():
				var tex := get_cached_background_image(img_path)
				if tex:
					texture_rect.texture = tex
					texture_rect.modulate = Color.WHITE
					var stretch: String = _backgrounds.get(prefix + "image_stretch", "cover")
					texture_rect.stretch_mode = _parse_stretch_mode(stretch)
					return
				# 缓存未命中：先应用渐变占位，再异步加载背景图（避免主线程同步 IO 卡顿）
				_apply_gradient(texture_rect, prefix)
				_request_background_image_load(img_path, texture_rect, _parse_stretch_mode(_backgrounds.get(prefix + "image_stretch", "cover")))
				return
			_apply_gradient(texture_rect, prefix)
		_:
			_apply_gradient(texture_rect, prefix)

## 获取已缓存的背景图（不触发磁盘 IO）；未缓存返回 null
func get_cached_background_image(file_name: String) -> Texture2D:
	if file_name.is_empty():
		return null
	# 缓存命中检查（同时校验纹理是否仍有效，避免引用已释放资源）
	if _bg_image_cache.has(file_name):
		var cached = _bg_image_cache[file_name]
		if is_instance_valid(cached):
			return cached
		_bg_image_cache.erase(file_name)
	return null

## 同步加载背景图（读盘 + 缓存）。仅限用户触发的单图预览（如 ImageAdjust 弹窗），
## 批量应用背景请走 apply_background（缓存命中立即、未命中走异步加载）。
func load_background_image(file_name: String) -> Texture2D:
	var cached := get_cached_background_image(file_name)
	if cached:
		return cached
	var full_path := PathHelper.get_background_dir().path_join(file_name)
	if not FileAccess.file_exists(full_path):
		return null
	var img := ImageUtil.load_image_file(full_path)
	if img == null:
		return null
	var tex := ImageTexture.create_from_image(img)
	if tex:
		_bg_image_cache[file_name] = tex
	return tex

## 请求异步加载背景图：命中缓存立即应用；否则入队由后台线程读盘（TMX-037）
func _request_background_image_load(file_name: String, rect: TextureRect, stretch: int) -> void:
	if file_name.is_empty() or not is_instance_valid(rect):
		return
	var cached := get_cached_background_image(file_name)
	if cached:
		rect.texture = cached
		rect.modulate = Color.WHITE
		rect.stretch_mode = stretch as TextureRect.StretchMode
		return
	if not _bg_pending_rects.has(file_name):
		_bg_pending_rects[file_name] = []
		_bg_load_queue.append(file_name)
	var rects: Array = _bg_pending_rects[file_name]
	rects.append({"rect": rect, "stretch": stretch})
	_bg_pending_rects[file_name] = rects
	_start_bg_load_if_idle()

func _start_bg_load_if_idle() -> void:
	if _bg_load_thread != null or _bg_load_queue.is_empty():
		return
	var file_name: String = _bg_load_queue[0]
	_bg_load_queue.pop_front()
	_bg_load_thread = Thread.new()
	_bg_load_thread.start(_bg_image_load_worker.bind(file_name))

## 后台线程：读取图片文件（纯文件 IO，不在主线程执行）
func _bg_image_load_worker(file_name: String) -> void:
	var full_path := PathHelper.get_background_dir().path_join(file_name)
	var img: Image = null
	if FileAccess.file_exists(full_path):
		img = ImageUtil.load_image_file(full_path)
	# call_deferred 跨线程投递到主线程是安全的
	call_deferred("_on_bg_image_loaded", file_name, img)

## 主线程：把后台加载的图片应用到所有等待中的 TextureRect
func _on_bg_image_loaded(file_name: String, img: Image) -> void:
	if _bg_load_thread:
		_bg_load_thread.wait_to_finish()
		_bg_load_thread = null
	var tex: Texture2D = null
	if img:
		tex = ImageTexture.create_from_image(img)
		if tex:
			_bg_image_cache[file_name] = tex
	var rects: Array = _bg_pending_rects.get(file_name, [])
	_bg_pending_rects.erase(file_name)
	for entry in rects:
		var rect: TextureRect = entry.get("rect")
		if is_instance_valid(rect):
			if tex:
				rect.texture = tex
				rect.modulate = Color.WHITE
				rect.stretch_mode = entry.get("stretch", rect.stretch_mode)
			# 加载失败：保持渐变占位（apply_background 已应用）
	_start_bg_load_if_idle()

func _exit_tree() -> void:
	_flush_scheduled_save()
	if _bg_load_thread:
		_bg_load_thread.wait_to_finish()
		_bg_load_thread = null

## 计划一次延迟落盘（高频调用合并为最后一次变更后 0.25s 写一次）
func _schedule_save_theme() -> void:
	_save_pending = true
	if _save_timer:
		_save_timer.start()

func _flush_scheduled_save() -> void:
	if not _save_pending:
		return
	_save_pending = false
	if not save_theme():
		GLogger.error("Theme save failed after debounce", "ThemeManager")

## 清除背景图片缓存（删除背景文件后调用，避免缓存指向已删除的文件）
## 传空字符串清空全部缓存，否则只清除指定 file_name
func invalidate_background_cache(file_name: String = "") -> void:
	if file_name.is_empty():
		_bg_image_cache.clear()
	else:
		_bg_image_cache.erase(file_name)

# ============ 样式工具方法 ============

## 判断节点是否对某个状态持有「本地覆盖」的 StyleBox（theme_override_styles）。
## 只有本地覆盖的 StyleBox 才是该节点私有的，可以安全就地改色；
## 若某状态没有覆盖，get_theme_stylebox 会沿 Theme 链返回**共享**的 StyleBox，
## 就地修改会连带改掉所有使用该 Theme 的控件（别名污染），故一律跳过。
func has_local_stylebox(node: Control, state: String) -> bool:
	return node != null and node.has_theme_stylebox_override(state)

## 修改节点已有 StyleBox 的 bg_color（不新建 StyleBox，保留 tscn 预设的圆角/边框等配置）
## 仅作用于节点自带的 theme_override_styles，避免误改共享 Theme 资源
func _modify_panel_color(node: Control, color_key: String) -> void:
	if not has_local_stylebox(node, "panel"):
		return
	var sb := node.get_theme_stylebox("panel")
	if sb == null or sb is StyleBoxEmpty:
		return
	_apply_color_to_stylebox(sb, get_color(color_key))

## 只替换 RGB，保留目标 StyleBox 原有的 alpha（避免主题改色时把作者设定的透明度覆盖掉）
func _tint_keep_alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha)

## 由底色推导描边色：深色模式往上提亮、浅色模式往下压暗，
## 否则浅色模式下 lightened(0.3) 会趋近纯白而导致面板边框「蒸发」。
func _border_from(color: Color) -> Color:
	return color.darkened(0.18) if _appearance == "light" else color.lightened(0.3)

## 统一给（原生 StyleBoxFlat 或自定义自绘风格框）设置 bg_color/border_color
## 只改色相，透明度沿用各 StyleBox 自身配置
func _apply_color_to_stylebox(sb: StyleBox, color: Color) -> void:
	if sb is StyleBoxFlat:
		sb.bg_color = _tint_keep_alpha(color, sb.bg_color.a)
		sb.border_color = _tint_keep_alpha(_border_from(color), sb.border_color.a)
	# StyleBoxHighlightGradient（GDScript 自绘渐变风格框，继承 StyleBox 基类，属性命名与原生命名一致）
	elif sb is StyleBoxHighlightGradient:
		sb.bg_color = _tint_keep_alpha(color, sb.bg_color.a)
		sb.border_color = _tint_keep_alpha(_border_from(color), sb.border_color.a)

## 对按钮各状态（normal/hover/pressed/hover_pressed）stylebox 应用主题色，各状态自带明暗变体
## 仅处理按钮本地覆盖的状态样式（见 has_local_stylebox）
func _modify_button_states_color(btn: Button, color_key: String) -> void:
	var base := get_color(color_key)
	for spec in [
		["normal", base],
		["hover", base.lightened(0.12)],
		["pressed", base.darkened(0.15)],
		["hover_pressed", base],
	]:
		if not has_local_stylebox(btn, spec[0]):
			continue
		var sb := btn.get_theme_stylebox(spec[0])
		if sb == null or sb is StyleBoxEmpty:
			continue
		_apply_color_to_stylebox(sb, spec[1])

# ============ 列表项样式 ============

## 修改 albumNode 列表项上的 SongCount 圆形标签背景色（共享 StyleBox，改一次同步全部列表项）
## （按钮四态已由共享 theme ListBtn-ColorBorder.tres 统一处理，不再逐实例改色；
##   数字文字固定白色由 .tscn 的 theme_override_colors 静态设置，见 albumNode.tscn）
func _style_album_instance(item: Control, pri_light: Color) -> void:
	var song_count := item.get_node_or_null("SongCount") as Label
	if song_count:
		var sb := song_count.get_theme_stylebox("normal")
		if sb is StyleBoxFlat:
			sb.bg_color = pri_light

## 修改 songNode 列表项上的 SongCount 圆形标签背景色
func _style_song_instance(item: Control, pri_light: Color) -> void:
	var song_count := item.get_node_or_null("HBoxC/SongCount") as Label
	if song_count:
		var sb := song_count.get_theme_stylebox("normal")
		if sb is StyleBoxFlat:
			sb.bg_color = pri_light


## 统一设置按钮各状态样式（通过 Theme 的 StyleBoxFlat 引用）。
## 现代配色：常规态为中性板面 + 细描边，交互态才引入强调色。
## 几何参数（圆角/边框宽/边距）由 .tscn 上的 StyleBox 决定，此处只写颜色。
## 把某状态的 StyleBox 颜色写入 tmp（复制原 StyleBox 以保留几何，最后由 merge_with 一次性并入 theme）。
## 复制而非就地改色，是为了让所有写入在 Theme.freeze 期间完成、帧末只产生一次全树传播。
func _set_theme_stylebox(theme: Theme, tmp: Theme, type: String, state: String, bg: Color, border: Color, shadow: Color = Color(0, 0, 0, 0)) -> void:
	if not theme.has_theme_item(Theme.DATA_TYPE_STYLEBOX, state, type):
		return
	var sb := theme.get_stylebox(state, type)
	if sb == null:
		return
	var dup := sb.duplicate()
	if dup is StyleBoxFlat:
		(dup as StyleBoxFlat).bg_color = bg
		(dup as StyleBoxFlat).border_color = border
		(dup as StyleBoxFlat).shadow_color = shadow
	elif dup is StyleBoxHighlightGradient:
		dup.bg_color = bg
		dup.border_color = border
		dup.shadow_color = shadow
	tmp.set_stylebox(state, type, dup)

func _theme_button_set_color(theme: Theme, tmp: Theme, base_color: Color, type: String = "Button") -> void:
	var surface := get_color("surface_high")
	var surface_hover := get_color("surface_hover")
	var surface_low := get_color("surface_low")
	var border := get_color("border")
	var border_soft := get_color("border_soft")

	_set_theme_stylebox(theme, tmp, type, "normal", surface, border)
	_set_theme_stylebox(theme, tmp, type, "hover", surface_hover, Color(base_color.r, base_color.g, base_color.b, 0.85))
	_set_theme_stylebox(theme, tmp, type, "pressed", base_color.darkened(0.15), base_color.lightened(0.1))
	_set_theme_stylebox(theme, tmp, type, "hover_pressed", base_color.darkened(0.32), base_color.darkened(0.05))
	_set_theme_stylebox(theme, tmp, type, "focus", Color(0, 0, 0, 0), base_color)
	_set_theme_stylebox(theme, tmp, type, "disabled", surface_low, border_soft)

# ============ 共享按钮 Theme（几何 .tres，颜色随主题） ============

## 刷新共享按钮 Theme 资源的四态颜色。
## 几何参数（圆角/边框宽度/边距）收在 UI/Theme/BtnTheme/*.tres 里，颜色在此按当前主题统一写入。
## 资源按 uid 单例缓存，改一次即同步所有引用场景（含 duplicate 的列表项）。
func _refresh_shared_btn_themes() -> void:
	# ListBtn-ColorBorder — 列表项按钮（album/song/sorted 共用）：与专辑节点同款（边框 pri_light + 半透明底 + focus 阴影）
	var list_theme := load(SHARED_LIST_BTN_THEME_PATH) as Theme
	if list_theme:
		var tmp := Theme.new()
		_style_shared_list_btn_theme(list_theme, tmp)
		list_theme.merge_with(tmp)
	# R12NoBorder — 圆角12 无边框按钮（PopupWindow/KeySequenceItem/MidiView/PlayView/ValueButton 共用）：与主 Theme 按钮同款（primary 三阶）
	var r12_theme := load(SHARED_R12_BTN_THEME_PATH) as Theme
	if r12_theme:
		var tmp := Theme.new()
		_style_shared_flat_btn_theme(r12_theme, tmp)
		r12_theme.merge_with(tmp)

## 列表项按钮 Theme 四态颜色（现代风格：不透明描边 + 透明底，四态用不同色阶区分）。
## 列表项的封面/标题是 show_behind_parent（画在 StyleBox 之下），因此这里**不使用任何填充**
## （哪怕半透明也会盖住封面、透出封面方角）；交互态改用卡片外侧的辉光来表达。
## 色阶：normal 中性描边 → hover 强调色 → pressed/hover_pressed 亮强调色（选中）→ focus 亮强调色
func _style_shared_list_btn_theme(theme: Theme, tmp: Theme) -> void:
	var p := get_color("primary")
	var pl := get_color("primary_light")
	var border := get_color("border")
	# normal — 中性描边，透明底，无辉光
	_set_theme_stylebox(theme, tmp, "Button", "normal", Color(0, 0, 0, 0), border, Color(0, 0, 0, 0))
	# hover — 强调色描边 + 强调色辉光
	_set_theme_stylebox(theme, tmp, "Button", "hover", Color(0, 0, 0, 0), p, Color(p.r, p.g, p.b, 0.45))
	# pressed / hover_pressed — 亮强调色描边 + 更强辉光（.tres 中二者共享同一 StyleBox）
	_set_theme_stylebox(theme, tmp, "Button", "pressed", Color(0, 0, 0, 0), pl, Color(pl.r, pl.g, pl.b, 0.6))
	_set_theme_stylebox(theme, tmp, "Button", "hover_pressed", Color(0, 0, 0, 0), pl, Color(pl.r, pl.g, pl.b, 0.6))
	# focus — 亮强调色描边 + 轻微辉光
	_set_theme_stylebox(theme, tmp, "Button", "focus", Color(0, 0, 0, 0), pl, Color(pl.r, pl.g, pl.b, 0.35))

## 圆角12 无边框按钮 Theme 四态颜色（solid 强调填充，交互态提亮/压暗）
func _style_shared_flat_btn_theme(theme: Theme, tmp: Theme) -> void:
	var base := get_color("primary")
	var colors: Dictionary
	if _appearance == "light":
		# 浅色模式：实心强调色填充（呼应浅色前「以主题色为主」的风格），文字深色（见 _refresh_theme_colors 的 Button font_color）
		colors = {
			"normal": base,
			"hover": base.lightened(0.10),
			"pressed": base.darkened(0.18),
			"focus": base.lightened(0.10),
		}
	else:
		colors = {
			"normal": base.darkened(0.28),
			"hover": base.darkened(0.05),
			"pressed": base.darkened(0.48),
			"focus": base.lightened(0.05),
		}
	for state in colors:
		_set_theme_stylebox(theme, tmp, "Button", state, colors[state], Color(0, 0, 0, 0))
	# focus 态在 .tres 里是「空心描边」（draw_center=false），bg_color 不生效，需同步描边色
	_set_theme_stylebox(theme, tmp, "Button", "focus", Color(0, 0, 0, 0), base)

func _style_panel_set_bg_color(panel: Control, color: Color) -> void:
	if not has_local_stylebox(panel, "panel"):
		return
	var sb := panel.get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		sb.bg_color = _tint_keep_alpha(color, sb.bg_color.a)
		sb.border_color = _tint_keep_alpha(_border_from(color), sb.border_color.a)

## 修改按钮自带的 normal/pressed/hover StyleBoxFlat 颜色（保留 tscn 的 skew/border/shadow/alpha 配置）
## 仅处理按钮本地覆盖的状态样式（见 has_local_stylebox），避免误改共享 Theme 资源
func _style_button_set_bg_color(btn: Button, color: Color) -> void:
	if not btn:
		return
	for spec in [
		["normal", color],
		["pressed", color.darkened(0.25)],
		["hover", color.lightened(0.15)],
	]:
		if not has_local_stylebox(btn, spec[0]):
			continue
		var sb := btn.get_theme_stylebox(spec[0])
		if sb is StyleBoxFlat:
			sb.bg_color = _tint_keep_alpha(spec[1], sb.bg_color.a)

# ============ MidiView 主题 ============

## 修改 MidiView 中通过 theme_override_styles 单独设置的节点样式
func _style_midi_individual_nodes(info_ui: Node) -> void:
	var p := get_color("primary")
	var surface := get_color("surface")
	var surface_high := get_color("surface_high")
	var surface_low := get_color("surface_low")

	# InfoWindow 边框
	var info_window := info_ui.get_node_or_null("LeftArea/InfoWindow") as PanelContainer
	_style_panel_set_bg_color(info_window, surface)

	# Fold 面板（与 Center 共享同一 StyleBoxFlat_5h6qm）
	var fold := info_ui.get_node_or_null("LeftArea/InfoWindow/HBoxC/Left/Fold") as Panel
	_style_panel_set_bg_color(fold, surface_high)

	# Fold/Btn — 只改 pressed（normal 透明，hover 暗色遮罩保留）
	var fold_btn := info_ui.get_node_or_null("LeftArea/InfoWindow/HBoxC/Left/Fold/Btn") as Button
	if fold_btn:
		var sb := fold_btn.get_theme_stylebox("pressed")
		if sb is StyleBoxFlat:
			sb.bg_color = surface_low

	# Description 背景 — 强调色淡底
	var desc := info_ui.get_node_or_null("LeftArea/InfoWindow/HBoxC/Description") as RichTextLabel
	if desc:
		var sb := desc.get_theme_stylebox("normal")
		if sb is StyleBoxFlat:
			sb.bg_color = Color(p.r, p.g, p.b, 0.14)
			sb.border_color = Color(p.r, p.g, p.b, 0.35)

	# PlayBtn — 主操作，强调色填充
	var play_btn := info_ui.get_node_or_null("LeftArea/MainBtn/PlayBtn") as Button
	_style_button_set_bg_color(play_btn, p.darkened(0.1))

	# DetailData 的 PC1 面板（亮）/ PC2 面板（暗）
	var pc1 := info_ui.get_node_or_null("LeftArea/DetailData/PC1") as PanelContainer
	_style_panel_set_bg_color(pc1, surface_high)
	var pc2 := info_ui.get_node_or_null("LeftArea/DetailData/PC2") as PanelContainer
	_style_panel_set_bg_color(pc2, surface_low)

	# OptionPanel 背景
	var option_panel := info_ui.get_node_or_null("OptionPanel") as PanelContainer
	_style_panel_set_bg_color(option_panel, surface_low)

# ============ 全局刷新 ============

## 主题应用者注册表：视图/组件在 _ready 时注册，refresh_theme_only 遍历调用其 apply_theme()
## 懒加载视图实例化后自动注册，不再依赖 ThemeManager 主动按路径查找节点，从根本上解决懒加载时序问题
## 用 instance_id → Node 的字典而非 Array：DelView 展开 2200 首会注册数千个
## TextScrollHelper，Array.has() 的线性查找会让注册退化成O(N²)
var _theme_appliers: Dictionary[int, Node] = {}

## 注册主题应用者（视图/组件 _ready 时调用，并自调一次 apply_theme() 完成首次着色）
func register_theme_applier(node: Node) -> void:
	if node:
		_theme_appliers[node.get_instance_id()] = node

## 注销主题应用者（视图/组件 _exit_tree 时调用，防止 refresh 时访问已释放节点）
func unregister_theme_applier(node: Node) -> void:
	if node:
		_theme_appliers.erase(node.get_instance_id())

## 刷新主题色（不刷新背景）
## 仅刷新调色板、Theme 资源，并广播通知所有已注册应用者各自更新内部样式；
## 不调用 _apply_all_backgrounds，因为背景与主题色独立，切换主题不应触发背景重新加载（避免 Image.load_from_file 同步阻塞）。
## 若需要刷新背景，调用 refresh_backgrounds()。
##
## 注意：本函数是协程（含 await get_tree().process_frame），但调用方无需 await：
## - 主题色挨个帧更新在视觉上可接受；
## - 真正的痛点是 godot 内部对 StyleBox/Theme 的批量重绘卡顿，分帧是把卡顿摊到多帧而非消除。
## - 短时间内连续调用会并发执行多个协程，但 _palette 已是终态值，每帧的阶段幂等。
func refresh_theme_only() -> void:
	var main := get_node_or_null(PathRegistry.MAIN)
	if not main:
		return

	# 第一阶段：全局 Theme 资源（触发大面积重绘，单独一帧）
	# 注意：切换主题色不再清空背景缓存，背景与主题色独立（避免 Image.load_from_file 同步阻塞）
	_refresh_theme_colors(main.theme)
	# 共享按钮 Theme（几何 .tres，颜色随主题）—— 资源单例，改一次即同步所有引用场景
	_refresh_shared_btn_themes()
	var skew_part: Control = main.get_node_or_null("skew/C")
	if skew_part and skew_part.theme != main.theme:
		skew_part.theme = main.theme  # 让子节点继承更新后的 Theme （因为skew会导致子节点不继承theme）
	await get_tree().process_frame

	# 第二阶段：广播通知所有已注册应用者各自更新内部样式
	# 视图/组件在 _ready 时 register_theme_applier(self) 并自调 apply_theme() 完成首次着色；
	# 懒加载视图实例化后自动注册，不再有"启动阶段查找节点落空"的问题。
	# apply_theme() 可能触发节点释放进而 unregister，故先收集再统一 erase（不在迭代中改字典）
	var stale: Array[int] = []
	for id in _theme_appliers:
		var applier: Node = _theme_appliers[id]
		if is_instance_valid(applier) and applier.has_method("apply_theme"):
			applier.apply_theme()
		else:
			stale.append(id)
	for id in stale:
		_theme_appliers.erase(id)
	GLogger.info("主题刷新完成: %s" % _theme_name, "ThemeManager")

func _on_theme_changed(preset_name: String) -> void:
	# 如果信号携带的预设名在配置中存在且与当前不同，应用它
	if _presets.has(preset_name) and preset_name != _theme_name:
		var p: Dictionary = _presets[preset_name]
		for key in p:
			var val: String = p[key]
			if val.is_valid_html_color():
				_palette[key.to_lower()] = Color(val)
		# 强调色就位后，按当前外观模式并入中性层（浅色需重新从强调色衍生）
		_apply_neutral_layer()
		_theme_name = preset_name
		GLogger.info("主题预设已应用: %s (%d 色)" % [preset_name, _palette.size()], "ThemeManager")
		# 外部驱动的预设切换：re-apply 后需要 save + refresh
		save_theme()
		refresh_theme_only()
	# 若 _theme_name == preset_name，说明是内部已 emit 的通知，无需重复 save+refresh：
	# - apply_preset / load_theme 自身已完成 save+refresh_theme_only 后再 emit
	# - set_color / set_palette_colors 同理（_theme_name 保持不变或改为 "custom"，
	#   但 emit 时 preset_name 等于 _theme_name，故也走此跳过分支）
	# 此处跳过避免了双重 save/refresh 导致的卡顿

## 仅刷新背景（设置界面修改背景配置后调用）
func refresh_backgrounds() -> void:
	var main := get_node_or_null(PathRegistry.MAIN)
	if not main:
		return
	_apply_all_backgrounds(main)
	GLogger.info("背景刷新完成", "ThemeManager")

# ============ 内部：背景批量应用 ============

func _apply_all_backgrounds(main: Node) -> void:
	# 独立背景节点（score/store/play 有自己的 Background 子节点）
	# main/midi/track/setting 共享主场景的 Background / Background2，由 _switch_main_bg 切换
	var bg_map := {
		"score": "ScoreView/BackGround",
		"store": "Store/Background",
		"play": "PlayView/Background",
	}

	for view_name in bg_map:
		var rect := main.get_node_or_null(bg_map[view_name])
		if rect:
			apply_background(rect, view_name)

	# 主背景节点：应用当前 view_name 的背景（首次或主题刷新时）
	if _active_bg and not _current_main_bg_view.is_empty():
		apply_background(_active_bg, _current_main_bg_view)

func get_theme_name() -> String:
	return _theme_name

func is_loaded() -> bool:
	return _loaded

# ============ 主背景交叉淡入淡出切换 ============

# 主背景交叉淡入淡出状态
var _active_bg: TextureRect = null       # 当前可见的背景节点（初始为 Background）
var _inactive_bg: TextureRect = null      # 备用背景节点（初始为 Background2）
var _current_main_bg_view: String = "main" # 当前主背景所属的 view_name
var _bg_switch_tween: Tween = null        # 切换补间
const _BG_SWITCH_DURATION := 0.4         # 交叉淡入淡出时长（秒）

## 初始化主背景节点引用（延迟调用确保 Main 就绪）
func _init_main_bg_nodes() -> void:
	var main := get_node_or_null(PathRegistry.MAIN)
	if not main:
		return
	_active_bg = main.get_node_or_null("Background")
	_inactive_bg = main.get_node_or_null("Background2")
	if _active_bg and _inactive_bg:
		_active_bg.modulate.a = 1.0
		_active_bg.visible = true
		_inactive_bg.modulate.a = 0.0
		_inactive_bg.visible = false
		# 应用初始背景（main 组）
		apply_background(_active_bg, "main")
		_current_main_bg_view = "main"

## UIState → 主背景组映射（空字符串表示不切主背景，使用独立节点）
func _get_bg_view_name_for_state(state: int) -> String:
	match state:
		UIStateManager.UIState.ALBUM_VIEW, \
		UIStateManager.UIState.SONG_VIEW, \
		UIStateManager.UIState.SORTED_VIEW:
			return "main"
		UIStateManager.UIState.MIDI_VIEW:
			return "midi"
		UIStateManager.UIState.TRACK_VIEW:
			return "track"
		UIStateManager.UIState.SETTINGS_VIEW:
			return "setting"
		_:
			return ""

## state_changed 回调：触发主背景交叉淡入淡出
func _on_state_changed_for_bg(_old_state: int, new_state: int) -> void:
	var target_view := _get_bg_view_name_for_state(new_state)
	if target_view.is_empty():
		return  # PLAY_VIEW/SCORE_VIEW/STORE_VIEW 等有独立背景节点，不切主背景
	if target_view == _current_main_bg_view:
		return  # 同组内不切换（如 main 组内 AlbumView↔SongView）
	_switch_main_bg(target_view)

## 交叉淡入淡出切换主背景到 target_view
func _switch_main_bg(target_view: String) -> void:
	if not _active_bg or not _inactive_bg:
		return
	# 杀掉正在进行的切换补间，并同步状态（避免补间中途被 kill 时角色未交换导致闪烁）
	if _bg_switch_tween and _bg_switch_tween.is_valid():
		_bg_switch_tween.kill()
		# 补间未完成时，active 仍是当前可见节点，强制对齐状态
		_active_bg.modulate.a = 1.0
		_active_bg.visible = true
		_inactive_bg.modulate.a = 0.0
		_inactive_bg.visible = false
	# 把新背景应用到 inactive 节点
	_inactive_bg.visible = true
	_inactive_bg.modulate.a = 0.0
	apply_background(_inactive_bg, target_view)
	# 交叉淡入淡出（inactive 0→1，active 1→0）
	_bg_switch_tween = AniMGR.create_managed_tween(self)
	_bg_switch_tween.set_parallel(true)
	_bg_switch_tween.tween_property(_inactive_bg, "modulate:a", 1.0, _BG_SWITCH_DURATION)
	_bg_switch_tween.tween_property(_active_bg, "modulate:a", 0.0, _BG_SWITCH_DURATION)
	_bg_switch_tween.chain()
	_bg_switch_tween.tween_callback(func():
		_active_bg.visible = false
		# 交换 active/inactive 角色，下次切换时新背景应用到刚变成 inactive 的节点
		var tmp := _active_bg
		_active_bg = _inactive_bg
		_inactive_bg = tmp
	)
	_current_main_bg_view = target_view

# ============ Theme 颜色刷新 ============

## 更新 Main 节点上已有 Theme 资源的 StyleBoxFlat 颜色（不新建 Theme）。
## 所有 set_*/stylebox 先汇入临时 Theme，末尾 merge_with 一次性并入 thm：
## Godot 在 merge_with 内部 freeze 期间完成全部写入、帧末只 emit 一次 changed，
## 把原本 ~85 次独立 set 造成的 ~85 次整树传播塌缩成 1 次。
func _refresh_theme_colors(thm: Theme) -> void:
	var p := get_color("primary")
	var pl := get_color("primary_light")
	var surface := get_color("surface")
	var surface_low := get_color("surface_low")
	var surface_high := get_color("surface_high")
	var surface_hover := get_color("surface_hover")
	var border := get_color("border")
	var border_soft := get_color("border_soft")
	var text_primary := get_color("text_primary")
	var text_dim := get_color("text_dim")
	var tmp := Theme.new()

	# 按钮 / 选项按钮：中性板面 + 强调色交互态
	_theme_button_set_color(thm, tmp, p, "Button")
	_theme_button_set_color(thm, tmp, p, "OptionButton")

	# 全局面板底色（Panel / PanelContainer）
	for type in ["Panel", "PanelContainer"]:
		_set_theme_stylebox(thm, tmp, type, "panel", surface, border_soft)

	# CheckBox 悬停按下底色
	_set_theme_stylebox(thm, tmp, "CheckBox", "hover_pressed", surface_hover, border)

	tmp.set_color("font_disabled_color", "Button", get_color("text_dim"))
	# 按钮文字色：深色模式为浅色文字、浅色模式为深色文字（text_primary 随模式翻转），
	# 保证两种模式下实心按钮（R12 / 主操作）文字均可读
	tmp.set_color("font_color", "Button", text_primary)
	# 按钮交互态字色（Main.tscn 里写死近白，浅色模式会变成「浅底浅字」）
	tmp.set_color("font_hover_color", "Button", text_primary)
	tmp.set_color("font_pressed_color", "Button", text_primary)
	tmp.set_color("font_hover_pressed_color", "Button", text_primary)
	# 按钮图标着色：图标贴图是白色描线，浅色模式下必须翻成深色才能在浅底上可见
	tmp.set_color("icon_normal_color", "Button", text_primary)
	tmp.set_color("icon_hover_color", "Button", get_color("primary"))
	tmp.set_color("icon_pressed_color", "Button", get_color("primary"))
	tmp.set_color("icon_disabled_color", "Button", text_dim)
	# OptionButton / CheckBox / CheckButton / PopupMenu 的字色（Main.tscn 同样写死近白）
	tmp.set_color("font_color", "OptionButton", text_primary)
	tmp.set_color("font_hover_color", "OptionButton", text_primary)
	tmp.set_color("font_pressed_color", "OptionButton", text_primary)
	tmp.set_color("font_focus_color", "OptionButton", text_primary)
	tmp.set_color("font_color", "CheckBox", text_primary)
	tmp.set_color("font_color", "CheckButton", text_primary)
	# CheckBox/CheckButton 的勾选图标是自带白底贴图，不应随 Button 图标色被染色，显式保持白色
	tmp.set_color("icon_normal_color", "CheckBox", Color.WHITE)
	tmp.set_color("icon_disabled_color", "CheckBox", Color(1, 1, 1, 0.4))
	tmp.set_color("icon_normal_color", "CheckButton", text_primary)
	# PopupMenu（所有下拉菜单）面板在浅色模式变浅，文字必须跟着翻深
	tmp.set_color("font_color", "PopupMenu", text_primary)
	tmp.set_color("font_hover_color", "PopupMenu", text_primary)
	tmp.set_color("font_separator_color", "PopupMenu", get_color("text_secondary"))
	tmp.set_color("font_disabled_color", "PopupMenu", text_dim)
	tmp.set_color("selection_color", "LineEdit", p)
	tmp.set_color("caret_color", "LineEdit", get_color("text_primary"))
	tmp.set_color("font_color", "LineEdit", get_color("text_primary"))
	tmp.set_color("font_placeholder_color", "LineEdit", get_color("text_dim"))

	# LineEdit 三态：normal 用更深的 surface_low 做出凹陷感，与 surface/surface_high 面板拉开层次；
	# 边框用 border（比 border_soft 明显）+ 2px 宽度（见 Main.tscn 的 StyleBoxFlat_lineedit_normal）。
	# read_only 维持更弱的 border_soft 以便与可编辑输入框区分。
	_set_theme_stylebox(thm, tmp, "LineEdit", "normal", surface_low, border)
	_set_theme_stylebox(thm, tmp, "LineEdit", "focus", Color(0, 0, 0, 0), p)
	_set_theme_stylebox(thm, tmp, "LineEdit", "read_only", surface_low, border_soft)

	# Label
	tmp.set_color("font_color", "Label", get_color("text_primary"))
	# RichTextLabel（如 MidiView 谱面简介）：正文色走 default_color，不设会停留在引擎默认的浅色上
	tmp.set_color("default_color", "RichTextLabel", get_color("text_primary"))

	# PopupMenu：面板用凸起面，悬停用半透明强调色
	_set_theme_stylebox(thm, tmp, "PopupMenu", "panel", surface_high, border)
	_set_theme_stylebox(thm, tmp, "PopupMenu", "hover", Color(p.r, p.g, p.b, 0.22), border_soft)

	# 滚动条抓取柄
	for type in ["VScrollBar", "HScrollBar"]:
		_set_theme_stylebox(thm, tmp, type, "grabber", border, border)
		_set_theme_stylebox(thm, tmp, type, "grabber_highlight", p, p)
		_set_theme_stylebox(thm, tmp, type, "grabber_pressed", pl, pl)

	# HSlider（音量条等）：滑轨在浅色下需压暗、已填充段用强调色（原写死的近白填充在浅底上不可见）
	var groove := Color(0, 0, 0, 0.22) if _appearance == "light" else Color(0, 0, 0, 0.6)
	_set_theme_stylebox(thm, tmp, "HSlider", "slider", groove, Color(0, 0, 0, 0))
	_set_theme_stylebox(thm, tmp, "HSlider", "grabber_area", p, p)
	_set_theme_stylebox(thm, tmp, "HSlider", "grabber_area_highlight", pl, pl)

	# TabContainer
	_set_theme_stylebox(thm, tmp, "TabContainer", "tab_unselected", surface_low, border_soft)
	_set_theme_stylebox(thm, tmp, "TabContainer", "tab_selected", surface_high, border)
	_set_theme_stylebox(thm, tmp, "TabContainer", "panel", surface, border_soft)

	# Tree
	tmp.set_font_size("font_size", "Tree", get_font_size("body", 32))
	tmp.set_constant("item_margin", "Tree", 48)
	tmp.set_constant("button_margin", "Tree", 10)
	tmp.set_constant("h_separation", "Tree", 6)

	thm.merge_with(tmp)

# ============ 内部方法 ============

func _parse_theme_config(cfg: Dictionary) -> void:
	# 全局中性色 / 语义色（[common] 段）收进 _common，apply_preset 时再按外观模式并入 _palette
	if cfg.has("common"):
		for key in cfg["common"]:
			var val: String = str(cfg["common"][key])
			if val.is_valid_html_color():
				_common[key.to_lower()] = Color(val)

	for section in cfg:
		if section is String and (section as String).begins_with("preset_"):
			var _name: String = (section as String).replace("preset_", "")
			_presets[_name] = cfg[section].duplicate()

	GLogger.info("加载了 %d 个主题预设" % _presets.size(), "ThemeManager")

	if cfg.has("backgrounds"):
		for key in cfg["backgrounds"]:
			_backgrounds[key] = cfg["backgrounds"][key]

	if cfg.has("font_sizes"):
		for key in cfg["font_sizes"]:
			_font_sizes[key] = int(cfg["font_sizes"][key])

func _get_str(cfg: Dictionary, section: String, key: String, default: String) -> String:
	if cfg.has(section) and cfg[section].has(key):
		return cfg[section][key]
	return default

func _apply_gradient(texture_rect: TextureRect, prefix: String) -> void:
	var top_str: String = _backgrounds.get(prefix + "gradient_top", "#0B0F1A")
	var bottom_str: String = _backgrounds.get(prefix + "gradient_bottom", "#0A0D15")

	var top_color := Color(top_str) if top_str.is_valid_html_color() else Color("#0B0F1A")
	var bottom_color := Color(bottom_str) if bottom_str.is_valid_html_color() else Color("#0A0D15")
	top_color = _lightify_bg(top_color)
	bottom_color = _lightify_bg(bottom_color)

	var gradient := Gradient.new()
	# 用 set_color 替换默认黑白点，而非 add_point 追加导致 4 个点
	gradient.set_color(0, top_color)
	gradient.set_color(1, bottom_color)

	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 256
	tex.height = 256
	tex.fill_from = Vector2(
		float(_backgrounds.get(prefix + "gradient_from_x", "0.0")),
		float(_backgrounds.get(prefix + "gradient_from_y", "0.0"))
	)
	tex.fill_to = Vector2(
		float(_backgrounds.get(prefix + "gradient_to_x", "0.0")),
		float(_backgrounds.get(prefix + "gradient_to_y", "1.0"))
	)

	texture_rect.texture = tex
	texture_rect.modulate = Color.WHITE

## 浅色模式下把背景色转为「同色相浅染色」：保留各视图原始渐变色相（本就带主题味），
## 拉高明度的同时尽量保留饱和，让浅色背景也像上个提交之前那样有鲜明的色彩，
## 而不是退化成通用灰白。非浅色模式原样返回。
func _lightify_bg(c: Color) -> Color:
	if _appearance != "light":
		return c
	var v :float = 0.80 + clamp(c.v, 0.0, 1.0) * 0.12
	return Color.from_hsv(c.h, min(c.s * 0.75, 0.55), v)

## 创建单色 GradientTexture2D（两个点都设为同色，避免 texture=null 时 modulate 失效）
func _create_solid_gradient_texture(color: Color) -> GradientTexture2D:
	var c := _lightify_bg(color)
	var g := Gradient.new()
	g.set_color(0, c)
	g.set_color(1, c)
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 4
	tex.height = 4
	return tex

func _parse_stretch_mode(mode: String) -> TextureRect.StretchMode:
	match mode:
		"scale": return TextureRect.STRETCH_SCALE
		"tile": return TextureRect.STRETCH_TILE
		"cover": return TextureRect.STRETCH_KEEP_ASPECT_COVERED
		"fit": return TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		"center": return TextureRect.STRETCH_KEEP_CENTERED
		"keep": return TextureRect.STRETCH_KEEP
	return TextureRect.STRETCH_KEEP_ASPECT_COVERED
