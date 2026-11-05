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
##   ThemeMGR.refresh_theme_only()   # 主题变更后刷新主题色（背景由 register_background 的节点自管）
##   ThemeMGR.refresh_backgrounds()  # 通知所有背景节点重新应用
class_name ThemeManager
extends Node

# MainTheme.tres 里 PopupMenu/icons/submenu 的 SVG 描线原色（灰）。重着色时按它做 color_map 的键。
const SUBMENU_ARROW_SRC_COLOR := "#b2b2b2"

func _ready() -> void:
	add_to_group("singleton")
	load_theme()
	apply_clear_color()
	_apply_boot_background_color()
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
	# 延迟初始化主背景节点引用，确保 GlobalNodes.main 已就绪
	call_deferred("_init_main_bg_nodes")

# ============ 配置路径 ============

const DEFAULT_THEME_PATH := "res://Resources/Config/theme.ini"
const DEFAULT_PRESET := "blue"
## 主题配置版本。2.1.0 起背景默认值不再是「每页写死的渐变色」，而是「不设颜色 + 按主题衍生」，
## 因此版本不一致时丢弃旧 theme.ini 的 [backgrounds] 段——否则老配置会盖住新默认值，看起来像没生效。
const THEME_VERSION := "2.1.0"

# 共享按钮 Theme 资源（几何参数收在 .tres，颜色由本管理器按主题统一刷新）
const SHARED_LIST_BTN_THEME_PATH := "res://UI/Theme/BtnTheme/ListBtn-ColorBorder.tres"
const SHARED_R12_BTN_THEME_PATH := "res://UI/Theme/BtnTheme/R12NoBorder.tres"
# 主题目主题资源（从 Main.tscn 抽出，gui/theme/custom 指向它）。运行时换肤直接改此资源，
# 因它是项目默认主题、覆盖全部 Control（含 skew 下 Node2D 子树），无需手动把 Main.theme 往下推。
const MAIN_THEME_PATH := "res://UI/Theme/MainTheme.tres"

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
# 主题目 Theme 资源缓存（首次刷新时 load，之后复用同一实例，改色即全局生效）
var _main_theme: Theme = null
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
var _bg_pending_nodes: Dictionary = {}   # file_name -> Array[{node, stretch}]
var _bg_load_queue: Array[String] = []

# 颜色令牌一览（get_color 可取的键，均来自 theme.ini 的 [common] + 预设）：
#   强调：primary / primary_light / primary_dark / secondary
#   板面：surface_low / surface / surface_high / surface_hover
#   描边：border / border_soft
#   语义：danger / success / warning / info
#   文字：text_primary / text_secondary / text_dim / text_disabled（禁用态专用）
# 说明：语义色也统一走 get_color("danger") 等取值，不再另设常量，避免两处定义漂移。
# 浅色板面层级（v 值）：surface_low 0.80 < surface 0.93 < surface_high 0.99。
# surface_low 是"最凹陷"的一层，LineEdit 默认态 / Button disabled / ProgressBar 槽底都用它，
# 千万别为了"看起来更亮"把它拉高，否则禁用态和输入框会失去凹陷语义。

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
	"text_disabled": Color("#565E70"),
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
	# refresh_theme_only 末尾会重算默认背景（深浅色变了默认背景也要跟着变）
	refresh_theme_only()
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
		# surface_low 必须是**最深**一层：LineEdit 默认态、按钮 disabled、ProgressBar 槽底
		# 都靠它表达「凹陷 / 不可用」。原先取 v=0.97 比 surface 还亮，导致禁用按钮看起来
		# 比可用按钮更"高级"、输入框失去凹陷感。层级顺序与深色模式保持一致。
		"surface_low":   Color.from_hsv(h, min(s * 0.55, 0.38), 0.80),
		"surface":       Color.from_hsv(h, min(s * 0.48, 0.34), 0.93),
		# surface_high 是「凸起面」（卡片/按钮），必须比 surface 亮一档而不是暗一档。
		# 原先取 0.87 比 surface 还暗，浅色下按钮看起来像"凹进去的坑"。
		"surface_high":  Color.from_hsv(h, min(s * 0.44, 0.30), 0.99),
		"surface_hover": Color.from_hsv(h, min(s * 0.62, 0.50), 0.80),
		"border":        Color.from_hsv(h, min(s * 0.58, 0.46), 0.60),
		"border_soft":   Color.from_hsv(h, min(s * 0.42, 0.30), 0.86),
		# 文字：同色相「现代深灰」而非近黑。v=0.13 视觉上等于纯黑，压到 0.22 才有灰调；
		# 二阶/三阶同步提一档，保证三阶之间仍有明显层级（0.22 → 0.38 → 0.52）。
		"text_primary":  Color.from_hsv(h, min(s * 0.30, 0.16), 0.22),
		"text_secondary":Color.from_hsv(h, min(s * 0.28, 0.15), 0.38),
		"text_dim":      Color.from_hsv(h, min(s * 0.26, 0.14), 0.52),
		# 禁用态专用：同色相低饱和深灰。禁用靠「去饱和 + 底色压暗」表达，
		# 不靠把字洗淡——洗到 0.62 在浅蓝板上基本看不清了。这里比 text_dim 更深一档，读得清且明显熄火
		"text_disabled": Color.from_hsv(h, min(s * 0.20, 0.10), 0.44),
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

	# 版本迁移：丢弃旧版存下的 [backgrounds]（背景默认值语义变了，见 THEME_VERSION）
	if _get_str(user_cfg, "Theme", "version", "") != THEME_VERSION:
		if user_cfg.has("backgrounds"):
			GLogger.info("旧版背景配置已丢弃，改用主题衍生默认背景", "ThemeManager")
			user_cfg.erase("backgrounds")

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

## 把启动图（boot image）底色刷成主界面背景色。
## 引擎在 autoload 实例化之前就画好了默认启动图（灰色），而启动图会在主场景首帧渲染后才淡出，
## 所以 autoload 阶段仍可重设它——但必须在首帧之前调用才有意义（主场景 _ready 跑完即出首帧）。
func _apply_boot_background_color() -> void:
	if OS.has_feature("editor"):
		return  # 编辑器内无启动图，跳过

	# 每次启动只算一次代表色：主界面没配背景时直接用默认背景的中值（深浅色 + 主题色都已含在内）
	var boot_color := get_main_bg_base_color()

	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(0, 0, 0, 0))  # 透明：只保留底色，不画 logo
	RenderingServer.set_boot_image_with_stretch(img, boot_color, RenderingServer.SPLASH_STRETCH_MODE_DISABLED, true)

## 主界面背景的代表色（单色场景用：启动图底色、引擎清屏色）。
## 没配背景色 → 默认背景（主题衍生）中值；image/cover 取不到代表色 → 同样退回默认背景色。
func get_main_bg_base_color() -> Color:
	var bg := get_view_background("main")
	match String(bg.get("type", "default")):
		"solid":
			var c := String(bg.get("solid_color", ""))
			if c.is_valid_html_color():
				return Color(c)
		"gradient":
			var top := String(bg.get("gradient_top", ""))
			var bottom := String(bg.get("gradient_bottom", ""))
			if top.is_valid_html_color() and bottom.is_valid_html_color():
				return (Color(top) + Color(bottom)) * 0.5
	return get_default_background_color()

## 引擎清屏色跟随主题背景色。
## 页面/根视口露出底色时（切场景、UI 隐藏、透明区域）会是这张清屏色，
## 不设置就是引擎默认灰，浅色主题下格外突兀。跟随主题后深浅色/强调色变化自动同步。
func apply_clear_color() -> void:
	RenderingServer.set_default_clear_color(get_main_bg_base_color())

func save_theme(file_path: String = "") -> bool:
	var user_path := file_path if not file_path.is_empty() else USER_THEME_PATH
	var cfg: Dictionary = {}

	cfg["Theme"] = {"version": THEME_VERSION, "active_preset": _theme_name, "appearance": _appearance}
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
#
# 分工：
#   ThemeManager —— 配置读写（theme.ini [backgrounds]）、背景图缓存/异步读盘、默认背景生成、主背景双缓冲切换
#   ViewBackground（UI/Theme/ViewBackground.gd）—— 挂在背景 TextureRect 上，自己解析类型并应用纹理
#
# 页面背景不要在这里手动 apply，也不要再往背景上叠主题色：节点自管。

## 已注册的背景节点（instance_id → ViewBackground）
var _background_nodes: Dictionary[int, Node] = {}
## 默认背景纹理（多个页面共用一张，主题色/深浅色变了才重建）
var _default_bg_tex: GradientTexture2D = null
var _default_bg_key: String = ""

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

## 背景节点在 _ready 里自注册（ViewBackground）
func register_background(node: Node) -> void:
	if node:
		_background_nodes[node.get_instance_id()] = node

func unregister_background(node: Node) -> void:
	if node:
		_background_nodes.erase(node.get_instance_id())

## 通知所有背景节点按当前配置/主题重新应用。
## ViewBackground 内部有配置指纹，未变化时不会重建纹理。
func refresh_all_backgrounds() -> void:
	var stale: Array[int] = []
	for id in _background_nodes.keys():
		var node: Node = _background_nodes[id]
		if is_instance_valid(node):
			node.apply()
		else:
			stale.append(id)
	for id in stale:
		_background_nodes.erase(id)

# ---- 默认背景（未设置颜色的页面用） ----

## 默认背景两端颜色：
##   深色 → 近黑的板面底 → 主题强调色暗部（一眼看出当前主题色，又不抢内容）
##   浅色 → 浅板面 → 浅主题色（浅色模式下不许留下整块深底）
func get_default_background_colors() -> Array[Color]:
	if _appearance == "light":
		var top := get_color("surface_low").lightened(0.05)
		return [top, get_color("primary_light").lerp(get_color("surface_low"), 0.35)]
	return [get_color("surface_low").darkened(0.15), get_color("primary_dark").darkened(0.55)]

## 默认背景的代表色（启动图底色等单色场景用）
func get_default_background_color() -> Color:
	var cols := get_default_background_colors()
	return (cols[0] + cols[1]) * 0.5

## 默认背景的颜色指纹（背景节点判断要不要重建纹理用）
func get_default_background_key() -> String:
	var cols := get_default_background_colors()
	return cols[0].to_html() + cols[1].to_html()

## 默认背景纹理：竖直渐变，所有未配置颜色的页面共用这一张
func get_default_background_texture() -> Texture2D:
	var cols := get_default_background_colors()
	var key := get_default_background_key()
	if _default_bg_tex != null and key == _default_bg_key:
		return _default_bg_tex
	_default_bg_key = key
	var gradient := Gradient.new()
	gradient.set_color(0, cols[0])
	gradient.set_color(1, cols[1])
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 256
	tex.height = 256
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.0, 1.0)
	_default_bg_tex = tex
	return tex

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
## 批量应用背景请走 ViewBackground.apply（缓存命中立即、未命中走异步加载）。
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
func request_background_image(file_name: String, node: Node, stretch: String) -> void:
	if file_name.is_empty() or not is_instance_valid(node):
		return
	var cached := get_cached_background_image(file_name)
	if cached:
		node.set_background_image(cached, stretch)
		return
	if not _bg_pending_nodes.has(file_name):
		_bg_pending_nodes[file_name] = []
		_bg_load_queue.append(file_name)
	_bg_pending_nodes[file_name].append({"node": node, "stretch": stretch})
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

## 主线程：把后台加载的图片应用到所有等待中的背景节点
func _on_bg_image_loaded(file_name: String, img: Image) -> void:
	if _bg_load_thread:
		_bg_load_thread.wait_to_finish()
		_bg_load_thread = null
	var tex: Texture2D = null
	if img:
		tex = ImageTexture.create_from_image(img)
		if tex:
			_bg_image_cache[file_name] = tex
	var entries: Array = _bg_pending_nodes.get(file_name, [])
	_bg_pending_nodes.erase(file_name)
	for entry in entries:
		var node: Node = entry.get("node")
		# 加载失败：保持占位（ViewBackground 已铺默认背景）
		if tex and is_instance_valid(node):
			node.set_background_image(tex, str(entry.get("stretch", "cover")))
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
	_apply_color_to_stylebox(node.get_theme_stylebox("panel"), get_color(color_key))

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
	# StyleBoxFlat 与原生/自定义渐变风格框（StyleBoxHighlightGradient 继承 StyleBox 基类，属性命名一致）走同一套改色
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
		_apply_color_to_stylebox(btn.get_theme_stylebox(spec[0]), spec[1])

## 原地改 theme 里某个状态 StyleBox 的颜色。几何（圆角/边框宽/边距/阴影尺寸）全部来自
## MainTheme.tres，这里只碰颜色；唯一的例外是 corner_detail —— 它由圆角半径推导，
## 半径不同的样式盒写死同一个值反而更糟，故按 r/3 归一化。
## 取到的就是 theme 内那一份实例，改完即生效，不需要再 set_stylebox 写回一次。
## alpha 给禁用态整体降不透明度用。
## 取主题里某类型/状态的样式盒；主题没定义时返回 null。
## 不能直接 `get_stylebox`：它在缺项时会回落到基类型（或引擎默认主题）的那一份，
## 对它赋色等于把基类型染了。
func _theme_box(thm: Theme, type: String, state: String) -> StyleBox:
	if not thm.has_theme_item(Theme.DATA_TYPE_STYLEBOX, state, type):
		return null
	return thm.get_stylebox(state, type)

func _set_theme_stylebox(theme: Theme, type: String, state: String, bg: Color, border: Color, shadow: Color = Color(0, 0, 0, 0), alpha: float = 1.0) -> void:
	if not theme.has_theme_item(Theme.DATA_TYPE_STYLEBOX, state, type):
		return
	var sb := theme.get_stylebox(state, type)
	var bg_c := Color(bg.r, bg.g, bg.b, bg.a * alpha)
	var bd_c := Color(border.r, border.g, border.b, border.a * alpha)
	
	sb.bg_color = bg_c
	sb.border_color = bd_c
	sb.shadow_color = shadow
	
	if sb is StyleBoxFlat:
		var r := maxi(sb.corner_radius_top_left, maxi(sb.corner_radius_top_right,
			maxi(sb.corner_radius_bottom_right, sb.corner_radius_bottom_left)))
		sb.corner_detail = clampi(int(r / 3.0), 3, 8)

## 取色器（ColorPicker）主题里唯一还随主题变的东西：取色光标颜色。
## 尺寸（label_width/sv_width/sv_height/h_width/margin）已全部收进 MainTheme.tres，
## 不再每帧/每次切主题都重写一遍常量。
func _style_color_picker(tmp: Theme) -> void:
	# 取色光标：外圈用正文色，浅色模式下避免白圈糊在浅色色板上
	tmp.set_color("focused_not_editing_cursor_color", "ColorPicker", get_color("text_primary"))

## 取色器弹层（ColorPickerButton.get_popup() 返回的 PopupPanel）
func style_color_picker_popup(btn: ColorPickerButton) -> void:
	if not btn:
		return
	var pop := btn.get_popup()
	if not pop:
		return
	if pop.has_theme_stylebox_override("panel"):
		pop.remove_theme_stylebox_override("panel")

## 取色器尺寸。
## label_width / sv_width / sv_height / h_width / margin 这些纯静态常量已经写进
## MainTheme.tres 的 ColorPicker/constants/*，不必每个实例再 override 一遍。
## 这里只处理「主题常量管不到」的两件事——它们都得靠遍历节点才能做：
##   1. GridContainer 里 SpinBox 太宽会把滑条挤扁（spin_box 最小宽 = LineEdit 最小宽 + 按钮块）；
##   2. 滑块默认只有 ~16px 高，触摸点不中。
func _enlarge_color_picker(pk: ColorPicker) -> void:
	# 滑条热区：滑块本身要有足够高度才点得中（默认 ~16px）
	for child in pk.find_children("*", "HSlider", true, false):
		var s := child as HSlider
		s.custom_minimum_size.y = maxf(s.custom_minimum_size.y, 44.0)
		s.focus_mode = Control.FOCUS_NONE
	# 数值输入框（R/G/B/A/I 右侧那格）压窄：它是滑条的竞争对手，不是主角。
	# 只动横向最小宽度，纵向保持原样，触摸热区不受影响。
	for child in pk.find_children("*", "SpinBox", true, false):
		var sb := child as SpinBox
		sb.custom_minimum_size.x = 96
		sb.size_flags_horizontal = Control.SIZE_FILL
		# 内部 LineEdit 也要一并收窄，否则 get_bound_minimum_size() 仍按大字撑开
		sb.get_line_edit().custom_minimum_size.x = 0
	pk.custom_minimum_size = Vector2(maxf(pk.custom_minimum_size.x, 640.0), 0)

## TabContainer 主题样式
## 几何（content margin 撑高度/左右留白、圆角、字号）与基础样式全部由 Main.tscn 的
##   - 选中标签：背景 = 内容面板同色(surface)，与面板视觉合并；
##   - 未选中标签：tscn 已设纯透明，这里不额外上色；
##   - 标签按钮在顶部时，底部与内容相接故不圆角、仅顶部圆角（默认按"上方"布局，不区分左右）。
func _style_tab_container(theme: Theme, tmp: Theme) -> void:
	var surface := get_color("surface")
	var border_soft := get_color("border_soft")

	# 选中标签与内容面板同色 → 无缝合并（几何沿用 tscn，仅改底色）
	_set_theme_stylebox(theme, "TabContainer", "tab_selected", surface, Color(0, 0, 0, 0))
	# 内容面板：surface + 弱描边
	_set_theme_stylebox(theme, "TabContainer", "panel", surface, border_soft)
	# 未选中标签保持 tscn 的透明，不在这里上色

	# 文字色随外观模式翻转（深色浅字 / 浅色深字），字号仍由 tscn 的 font_size 决定
	tmp.set_color("font_selected_color", "TabContainer", get_color("text_primary"))
	tmp.set_color("font_unselected_color", "TabContainer", get_color("text_secondary"))

func _theme_button_set_color(theme: Theme, base_color: Color, type: String = "Button") -> void:
	var surface := get_color("surface_high")
	var surface_hover := get_color("surface_hover")
	var surface_low := get_color("surface_low")
	var border := get_color("border")
	var border_soft := get_color("border_soft")

	_set_theme_stylebox(theme, type, "normal", surface, border)
	_set_theme_stylebox(theme, type, "hover", surface_hover, Color(base_color.r, base_color.g, base_color.b, 0.85))
	_set_theme_stylebox(theme, type, "pressed", base_color.darkened(0.15), base_color.lightened(0.1))
	_set_theme_stylebox(theme, type, "hover_pressed", base_color.darkened(0.32), base_color.darkened(0.05))
	_set_theme_stylebox(theme, type, "focus", Color(0, 0, 0, 0), base_color)
	# 禁用态：底色压到 surface_low（浅色下这是最深的一层）+ 弱描边，让它明确"凹下去且不可点"。
	# 不做整体降透明度——降了会把里面的文字/图标一起洗淡，禁用字必须仍然读得清。
	var dis_bg := surface_low.darkened(0.06) if _appearance == "light" else surface_low
	_set_theme_stylebox(theme, type, "disabled", dis_bg, border_soft)

## 共享 R12 按钮是实心强调色填充，禁用后就算换成 surface_low 仍显得"能按"，
## 额外降到 0.6 不透明度拉开对比。主 Theme 的按钮不走这条（保持全不透明，字才清楚）。
func _style_shared_r12_disabled(theme: Theme) -> void:
	var dis_bg := get_color("surface_low").darkened(0.06) \
		if _appearance == "light" else get_color("surface_low")
	_set_theme_stylebox(theme, "Button", "disabled", dis_bg, get_color("border_soft"), Color.TRANSPARENT, 0.6)

# ============ 共享按钮 Theme（几何 .tres，颜色随主题） ============

## 刷新共享按钮 Theme 资源的四态颜色。
## 几何参数（圆角/边框宽度/边距）收在 UI/Theme/BtnTheme/*.tres 里，颜色在此按当前主题统一写入。
## 资源按 uid 单例缓存，改一次即同步所有引用场景（含 duplicate 的列表项）。
func _refresh_shared_btn_themes() -> void:
	# 每个 Theme 各自静默写入、末尾抛一次 changed（原因同 _refresh_theme_colors：
	# 原地改 StyleBox 属性每次都会触发一轮整树重算，这里 5 态 × 3 属性 = 15 轮）
	# ListBtn-ColorBorder — 列表项按钮（album/song/sorted 共用）：与专辑节点同款（边框 pri_light + 半透明底 + focus 阴影）
	var list_theme := load(SHARED_LIST_BTN_THEME_PATH) as Theme
	list_theme.set_block_signals(true)
	_style_shared_list_btn_theme(list_theme)
	list_theme.set_block_signals(false)
	list_theme.emit_changed()
	# R12NoBorder — 圆角12 无边框按钮（PopupWindow/KeySequenceItem/MidiView/PlayView/ValueButton 共用）：与主 Theme 按钮同款（primary 三阶）
	var r12_theme := load(SHARED_R12_BTN_THEME_PATH) as Theme
	r12_theme.set_block_signals(true)
	_style_shared_flat_btn_theme(r12_theme)
	_style_shared_r12_disabled(r12_theme)
	r12_theme.set_block_signals(false)
	r12_theme.emit_changed()

## 列表项按钮 Theme 四态颜色（现代风格：不透明描边 + 透明底，四态用不同色阶区分）。
## 列表项的封面/标题是 show_behind_parent（画在 StyleBox 之下），因此这里**不使用任何填充**
## （哪怕半透明也会盖住封面、透出封面方角）；交互态改用卡片外侧的辉光来表达。
## 色阶：normal 中性描边 → hover 强调色 → pressed/hover_pressed 亮强调色（选中）→ focus 亮强调色
func _style_shared_list_btn_theme(theme: Theme) -> void:
	var p := get_color("primary")
	var pl := get_color("primary_light")
	var border := get_color("border")
	# normal — 中性描边，透明底，无辉光。border 在深色模式偏暗，压在暗背景上看不出卡片轮廓，故提亮一档
	_set_theme_stylebox(theme, "Button", "normal", Color(0, 0, 0, 0), border.lightened(0.18) if _appearance != "light" else border, Color(0, 0, 0, 0))
	# hover — 强调色描边 + 强调色辉光
	_set_theme_stylebox(theme, "Button", "hover", Color(0, 0, 0, 0), p, Color(p.r, p.g, p.b, 0.45))
	# pressed / hover_pressed — 亮强调色描边 + 更强辉光（.tres 中二者共享同一 StyleBox）
	_set_theme_stylebox(theme, "Button", "pressed", Color(0, 0, 0, 0), pl, Color(pl.r, pl.g, pl.b, 0.6))
	_set_theme_stylebox(theme, "Button", "hover_pressed", Color(0, 0, 0, 0), pl, Color(pl.r, pl.g, pl.b, 0.6))
	# focus — 亮强调色描边 + 轻微辉光
	_set_theme_stylebox(theme, "Button", "focus", Color(0, 0, 0, 0), pl, Color(pl.r, pl.g, pl.b, 0.35))

## 圆角12 无边框按钮 Theme 四态颜色（solid 强调填充，交互态提亮/压暗）
func _style_shared_flat_btn_theme(theme: Theme) -> void:
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
		_set_theme_stylebox(theme, "Button", state, colors[state], Color(0, 0, 0, 0))
	# focus 态在 .tres 里是「空心描边」（draw_center=false），bg_color 不生效，需同步描边色
	_set_theme_stylebox(theme, "Button", "focus", Color(0, 0, 0, 0), base)

func _style_panel_set_bg_color(panel: Control, color: Color) -> void:
	if not has_local_stylebox(panel, "panel"):
		return
	var sb := panel.get_theme_stylebox("panel")
	sb.bg_color = _tint_keep_alpha(color, sb.bg_color.a)
	sb.border_color = _tint_keep_alpha(_border_from(color), sb.border_color.a)

## 修改按钮自带的 normal/pressed/hover StyleBoxFlat 颜色（保留 tscn 的 skew/border/shadow/alpha 配置）
## 仅处理按钮本地覆盖的状态样式（见 has_local_stylebox），避免误改共享 Theme 资源
func _style_button_set_bg_color(btn: Button, color: Color) -> void:
	for spec in [
		["normal", color],
		["pressed", color.darkened(0.25)],
		["hover", color.lightened(0.15)],
	]:
		if not has_local_stylebox(btn, spec[0]):
			continue
		var sb := btn.get_theme_stylebox(spec[0])
		sb.bg_color = _tint_keep_alpha(spec[1], sb.bg_color.a)

## 次级扁平按钮（商店/资源页的工具条、分页、标签页按钮）统一上色。
## 几何（圆角/边距）仍由各 .tscn 的本地样式盒决定，这里只写三态底色与字色。
## 常态底=surface_high、悬停=surface_hover、按下=primary_dark，描边=border；
## 字色常态走 text_secondary（弱化），悬停/焦点回到 text_primary。
## 原先 StoreView 与 ResourceView 各有一份几乎相同的 _style_flat_button，
## 调用点传的 5 个参数也全都一样，故合并到此处。
func style_flat_button(btn: Button) -> void:
	var surface_high := get_color("surface_high")
	var surface_hover := get_color("surface_hover")
	var primary_dark := get_color("primary_dark")
	var primary_light := get_color("primary_light")
	var border := get_color("border")
	var hover_border := get_color("primary") if _appearance == "light" else primary_light

	for spec in [
		["normal", surface_high, border],
		["hover", surface_hover, hover_border],
		["pressed", primary_dark, primary_light],
	]:
		var sb: StyleBoxFlat = btn.get_theme_stylebox(spec[0])
		sb.bg_color = _tint_keep_alpha(spec[1], sb.bg_color.a)
		sb.border_color = spec[2]

	btn.add_theme_color_override("font_color", get_color("text_secondary"))
	btn.add_theme_color_override("font_hover_color", get_color("text_primary"))
	# 禁用态统一走 text_disabled（低饱和深灰）。不要再额外降透明度：
	# 颜色本身已经够"熄火"，再叠 alpha 会淡到看不清
	var disabled_text := get_color("text_disabled")
	btn.add_theme_color_override("font_disabled_color", disabled_text)
	btn.add_theme_color_override("icon_disabled_color", disabled_text)

# ============ 取色器统一配置 ============

## 统一所有 ColorPicker 的可见元素与交互参数。
## 手机上学一个复杂取色器毫无意义：色板点选 + HSV/Alpha 滑条足够，其余全关。
## 任何新建 ColorPickerButton 的地方都应调用本函数，避免各处各写一套导致风格漂移。
##   edit_alpha — 是否显示透明度滑条（背景色类需要，音符颜色类不需要）
func setup_color_picker(btn: ColorPickerButton, edit_alpha: bool = false) -> void:
	var pk := btn.get_picker()
	pk.edit_alpha = edit_alpha
	# 纯色模式下不需要强度滑条
	pk.edit_intensity = false
	# 以下全是"占地方且在小屏上点不动"的元素，统一关掉
	pk.sampler_visible = false      # 屏幕吸管
	pk.presets_visible = false      # 预设色块网格
	pk.can_add_swatches = false     # 自定义色板增删
	pk.sliders_visible = true       # 保留：HSV / Alpha / Hex 滑条（这是唯一需要的输入方式）
	pk.color_modes_visible = false   # RGB/HSV/RAW 模式切换标签
	pk.hex_visible = true           # 保留十六进制输入
	_enlarge_color_picker(pk)
	style_color_picker_popup(btn)

## 把「裸 ColorPickerButton」升级成 SettingView 那套形态：色块按钮 + 十六进制输入框。
## 弹窗里原本只有一个小色块，点开才知道颜色是什么；设置页是 色块 + #RRGGBB 输入框，
## 统一成后者的形态与尺寸。返回输入框（调用方不需要可忽略）。
## 前提：btn 已在树里（需要取父容器插入兄弟节点）。
func attach_hex_edit(btn: ColorPickerButton, edit_alpha: bool = false) -> LineEdit:
	if not btn or not btn.is_inside_tree():
		return null
	var parent := btn.get_parent()
	if parent is not HBoxContainer:
		return null
	# 已有就不再建（幂等）
	var exist := btn.get_node_or_null("HexEdit") as LineEdit
	if exist:
		return exist

	var edit := LineEdit.new()
	edit.name = "HexEdit"
	edit.max_length = 10
	edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	edit.custom_minimum_size = Vector2(0, 80)
	edit.add_theme_font_size_override("font_size", 48)
	# 插到色块左边（与设置页一致：输入框在左、色块在右）
	parent.add_child(edit)
	parent.move_child(edit, btn.get_index())

	edit.text = "#" + btn.color.to_html(edit_alpha)
	btn.color_changed.connect(func(c: Color) -> void:
		edit.set_block_signals(true)
		edit.text = "#" + c.to_html(edit_alpha)
		edit.set_block_signals(false)
	)
	edit.text_changed.connect(func(t: String) -> void:
		var cleaned := t.strip_edges()
		if cleaned.begins_with("#"):
			cleaned = cleaned.substr(1)
		if cleaned.length() != 6 and cleaned.length() != 8:
			return
		if not ("#" + cleaned).is_valid_html_color():
			return
		btn.set_block_signals(true)
		btn.color = Color("#" + cleaned)
		btn.set_block_signals(false)
	)
	return edit

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

## 刷新主题色（同时刷新由主题衍生的默认背景）
## 仅刷新调色板、Theme 资源，并广播通知所有已注册应用者各自更新内部样式；
## 背景图不再重新读盘（用户配了具体背景的节点会因配置指纹未变而跳过），
## 只有 type=default 的页面会重新生成主题渐变。
##
## 注意：本函数是协程（含 await get_tree().process_frame），但调用方无需 await：
## - 主题色挨个帧更新在视觉上可接受；
## - 真正的痛点是 godot 内部对 StyleBox/Theme 的批量重绘卡顿，分帧是把卡顿摊到多帧而非消除。
## - 短时间内连续调用会并发执行多个协程，但 _palette 已是终态值，每帧的阶段幂等。
func refresh_theme_only() -> void:
	# 清屏色纯 Palette 计算，不依赖 Main，先同步掉（避免露底时看到上一套主题的底色）
	apply_clear_color()
	var main := GlobalNodes.main
	if not main:
		return

	# 第一阶段：全局 Theme 资源（触发大面积重绘，单独一帧）
	# 注意：切换主题色不再清空背景缓存，背景与主题色独立（避免 Image.load_from_file 同步阻塞）
	# 主题已抽成独立 .tres（gui/theme/custom 指向它），作为项目默认主题覆盖全部 Control，
	# 不再需要把 Main 的 theme 手动下推（含 skew 下 Node2D 子树）—— 那些节点自动继承项目默认主题。
	if _main_theme == null:
		_main_theme = load(MAIN_THEME_PATH) as Theme
	_refresh_theme_colors(_main_theme)
	# 共享按钮 Theme（几何 .tres，颜色随主题）—— 资源单例，改一次即同步所有引用场景
	_refresh_shared_btn_themes()
	await get_tree().process_frame

	# 第二阶段：广播通知所有已注册应用者各自更新内部样式
	# 视图/组件在 _ready 时 register_theme_applier(self) 并自调 apply_theme() 完成首次着色；
	# 懒加载视图实例化后自动注册，不再有"启动阶段查找节点落空"的问题。
	# apply_theme() 可能触发节点释放进而 unregister，故先收集再统一 erase（不在迭代中改字典）
	var stale: Array[int] = []
	# 先取 key 快照：apply_theme 期间可能有节点注销/新注册，不能边遍历边改字典。
	var ids: Array = _theme_appliers.keys()
	var applied := 0
	for id in ids:
		if not _theme_appliers.has(id):
			continue
		var applier: Node = _theme_appliers[id]
		if is_instance_valid(applier) and applier.has_method("apply_theme"):
			applier.apply_theme()
			applied += 1
			# 分帧广播：即使个别视图较重，也不会一次性冻结整个切换过程
			if applied % 12 == 0:
				await get_tree().process_frame
		else:
			stale.append(id)
	for id in stale:
		_theme_appliers.erase(id)
	# 第三阶段：默认背景由主题色衍生，强调色/深浅色变了必须重算
	# （配了 solid/gradient/image/cover 的节点指纹未变，apply 直接返回，不会重建纹理）
	refresh_backgrounds()
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

## 仅刷新背景（设置界面改背景、或主题色/深浅色变化后调用）
func refresh_backgrounds() -> void:
	apply_clear_color()
	refresh_all_backgrounds()

func get_theme_name() -> String:
	return _theme_name

func is_loaded() -> bool:
	return _loaded

# ============ 主背景交叉淡入淡出切换 ============

# 主背景交叉淡入淡出状态
var _active_bg: ViewBackground = null       # 当前可见的背景节点（初始为 Background）
var _inactive_bg: ViewBackground = null      # 备用背景节点（初始为 Background2）
var _current_main_bg_view: String = "main" # 当前主背景所属的 view_name
var _bg_switch_tween: Tween = null        # 切换补间
const _BG_SWITCH_DURATION := 0.4         # 交叉淡入淡出时长（秒）

## 初始化主背景节点引用（延迟调用确保 Main 就绪）
func _init_main_bg_nodes() -> void:
	var main := GlobalNodes.main
	if not main:
		return
	_active_bg = main.get_node_or_null("Background") as ViewBackground
	_inactive_bg = main.get_node_or_null("Background2") as ViewBackground
	if _active_bg and _inactive_bg:
		_active_bg.modulate.a = 1.0
		_active_bg.visible = true
		_inactive_bg.modulate.a = 0.0
		_inactive_bg.visible = false
		# 应用初始背景（main 组）
		_active_bg.set_view("main")
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
	_inactive_bg.set_view(target_view)
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
## 颜色（set_color / set_constant / set_font_size）先汇入临时 Theme，末尾 merge_with 一次性
## 并入 thm：Godot 在 merge_with 内部 freeze 期间完成全部写入、帧末只 emit 一次 changed，
## 避免每次 set_color 都触发一轮整树主题传播。
## 注意 StyleBox 的颜色不在此列——它们是原地改 .tres 里的共享实例，改的瞬间就生效，
## 既没法也不该塞进 tmp 再合并。
## 主题写入必须整段静默，避免主题树反复重算
func _refresh_theme_colors(thm: Theme) -> void:
	thm.set_block_signals(true)
	_refresh_theme_colors_impl(thm)
	thm.set_block_signals(false)
	thm.emit_changed()

func _refresh_theme_colors_impl(thm: Theme) -> void:
	var p := get_color("primary")
	var pl := get_color("primary_light")
	var surface := get_color("surface")
	var surface_low := get_color("surface_low")
	var surface_high := get_color("surface_high")
	var surface_hover := get_color("surface_hover")
	var border := get_color("border")
	var border_soft := get_color("border_soft")
	var text_primary := get_color("text_primary")
	var tmp := Theme.new()

	# 按钮 / 选项按钮：中性板面 + 强调色交互态
	_theme_button_set_color(thm, p, "Button")
	_theme_button_set_color(thm, p, "OptionButton")

	# 全局面板底色（Panel / PanelContainer）
	for type in ["Panel", "PanelContainer"]:
		_set_theme_stylebox(thm, type, "panel", surface, border_soft)

	# CheckBox 悬停按下底色
	_set_theme_stylebox(thm, "CheckBox", "hover_pressed", surface_hover, border)

	tmp.set_color("font_disabled_color", "Button", get_color("text_disabled"))
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
	tmp.set_color("icon_disabled_color", "Button", get_color("text_disabled"))
	# OptionButton / CheckBox / CheckButton / PopupMenu 的字色（Main.tscn 同样写死近白）
	tmp.set_color("font_color", "OptionButton", text_primary)
	tmp.set_color("font_hover_color", "OptionButton", text_primary)
	tmp.set_color("font_pressed_color", "OptionButton", text_primary)
	tmp.set_color("font_focus_color", "OptionButton", text_primary)
	# 下拉箭头：OptionButton 的 arrow 图标**不吃** icon_*_color（option_button.cpp 里
	# arrow_icon->draw(ci, ofs, clr) 的 clr 由常量 modulate_arrow 决定）。该常量已在
	# MainTheme.tres 里设为 1，箭头于是跟随 font_*_color 自动变色，无需在这里重复设置。
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
	tmp.set_color("font_disabled_color", "PopupMenu", get_color("text_disabled"))
	tmp.set_color("selection_color", "LineEdit", p)
	tmp.set_color("caret_color", "LineEdit", get_color("text_primary"))
	tmp.set_color("font_color", "LineEdit", get_color("text_primary"))
	tmp.set_color("font_placeholder_color", "LineEdit", get_color("text_dim"))
	tmp.set_color("font_uneditable_color", "LineEdit", get_color("text_disabled"))

	# LineEdit 三态：可编辑态与 OptionButton/Button 默认态（surface_high）同色，
	# 保证设置页里"输入框 + 选项按钮"并排时不出现"一个像禁用"的色差。
	# 凹陷感改由描边表达（border + 2px，见 MainTheme.tres 的 StyleBoxFlat_gb15f）；
	# read_only 才用 surface_low（真正更深的面）+ border_soft，用来区分"不可编辑"。
	_set_theme_stylebox(thm, "LineEdit", "normal", surface_high, border)
	_set_theme_stylebox(thm, "LineEdit", "focus", Color(0, 0, 0, 0), p)
	_set_theme_stylebox(thm, "LineEdit", "read_only", surface_low, border_soft)

	# 深色输入框变体：基类型 LineEdit 刻意用 surface_high（与 OptionButton 并排时不显色差），
	# 但搜索框、面板内嵌输入框需要真正"凹"下去一档，于是把底色压到 surface_low。
	# LineEditDeep 是通用款；LineEditSearch 右侧多留 70 给搜索图标（图标是 LineEdit 子节点，
	# 靠 content_margin_right 让出位置，用样式盒而不是结构）。
	var is_light := _appearance == "light"
	var placeholder_c := get_color("text_secondary") if is_light else get_color("text_dim")
	for t in ["LineEditDeep", "LineEditSearch"]:
		_set_theme_stylebox(thm, t, "normal", surface_low, border)
		_set_theme_stylebox(thm, t, "focus", surface_low.lightened(0.04), _tint_keep_alpha(p, 0.9))
		_set_theme_stylebox(thm, t, "read_only", surface_low.darkened(0.05), border_soft)
		tmp.set_color("caret_color", t, p)
		tmp.set_color("font_placeholder_color", t, placeholder_c)

	# Label
	tmp.set_color("font_color", "Label", get_color("text_primary"))
	# 文字角色变体：只覆盖 font_color，字体/字号/描边全部回落 Label（变体项是稀疏的）。
	# 原先这些字色散落在 StoreView / ResourceView / ChartDetailPanel / 卡片脚本里逐个 override，
	# 现在一处定义，节点只在 tscn 挂 variation 名字。
	tmp.set_color("font_color", "LabelMuted", get_color("text_secondary") if is_light else get_color("text_dim"))
	tmp.set_color("font_color", "LabelSecondary", get_color("text_secondary"))
	tmp.set_color("font_color", "LabelAccent", get_color("primary_dark") if is_light else get_color("primary_light"))
	tmp.set_color("font_color", "LabelOnAccent", Color.WHITE)

	# 按钮角色变体：原先 StoreView / ResourceView 各自把手写一遍的六态颜色（20 个按钮、
	# 每个约 12 行 override）现在收进主题。节点只在 tscn 挂 theme_type_variation，
	# 几何（圆角 12 / 内边距 / 描边）全在 MainTheme.tres，这里只刷颜色与状态语义。
	var pd := get_color("primary_dark")
	var text_secondary := get_color("text_secondary")
	var text_disabled := get_color("text_disabled")
	var accent := pd if is_light else pl

	# ButtonTab：未选中是透明底（alpha 0，不能给纯色，否则标签变成一排实心块）
	# 悬停淡浮起；选中态深色模式实心强调底、浅色模式淡主色底 + 深字，避免白字压浅蓝。
	var tab_fill := p if is_light else pd
	var tab_alpha := 0.16 if is_light else 0.55
	_set_theme_stylebox(thm, "ButtonTab", "normal", surface_high, border, Color(0, 0, 0, 0), 0.0)
	_set_theme_stylebox(thm, "ButtonTab", "hover", surface_hover, border, Color(0, 0, 0, 0), 0.85)
	_set_theme_stylebox(thm, "ButtonTab", "pressed", tab_fill, accent, Color(0, 0, 0, 0), tab_alpha)
	_set_theme_stylebox(thm, "ButtonTab", "hover_pressed", tab_fill, accent, Color(0, 0, 0, 0), tab_alpha)
	_set_theme_stylebox(thm, "ButtonTab", "disabled", surface_low, border_soft, Color(0, 0, 0, 0), 0.0)
	_set_theme_stylebox(thm, "ButtonTab", "focus", Color(0, 0, 0, 0), accent)

	# ButtonFlat：工具条按钮。常态浅凸面 → 悬停提亮描边 → 按下实心强调底。
	# 原本各处的 alpha 在 0.76~0.95 之间浮动，统一为不透明（差异肉眼不可辨）。
	var flat_disabled_bg := surface_low.darkened(0.06) if is_light else surface_low
	_set_theme_stylebox(thm, "ButtonFlat", "normal", surface_high, border)
	_set_theme_stylebox(thm, "ButtonFlat", "hover", surface_hover, p if is_light else pl)
	_set_theme_stylebox(thm, "ButtonFlat", "pressed", pd, pl)
	_set_theme_stylebox(thm, "ButtonFlat", "hover_pressed", pd, pl)
	_set_theme_stylebox(thm, "ButtonFlat", "disabled", flat_disabled_bg, border_soft)
	_set_theme_stylebox(thm, "ButtonFlat", "focus", Color(0, 0, 0, 0), accent)

	# 字色 / 图标色：常态次要 → 悬停正文 → 按下强调。
	# ButtonFlat 按下底色是实心主色，文字必须反白；ButtonTab 浅色下底色很淡，仍用深强调色。
	var on_fill := Color.WHITE if is_light else pl
	for t in ["ButtonTab", "ButtonFlat"]:
		var press_c := accent if t == "ButtonTab" else on_fill
		tmp.set_color("font_color", t, text_secondary)
		tmp.set_color("font_hover_color", t, get_color("text_primary"))
		tmp.set_color("font_pressed_color", t, press_c)
		tmp.set_color("font_hover_pressed_color", t, press_c)
		tmp.set_color("font_focus_color", t, get_color("text_primary"))
		tmp.set_color("font_disabled_color", t, text_disabled)
		tmp.set_color("icon_normal_color", t, text_secondary)
		tmp.set_color("icon_hover_color", t, get_color("text_primary"))
		tmp.set_color("icon_pressed_color", t, press_c)
		tmp.set_color("icon_hover_pressed_color", t, press_c)
		tmp.set_color("icon_focus_color", t, accent)
		tmp.set_color("icon_disabled_color", t, text_disabled)

	# 下载按钮：状态只有四种（未下载 / 下载中 / 已下载 / 失败），基色由状态唯一决定，
	# 所以四个变体共享整套样式盒，卡片不再 resource_local_to_scene 各复制一份。
	# 原先三处 _set_download_colors 的压暗系数还各不相同（0.12 vs 0.15、0.2 vs 0.22），这里统一。
	var dl_specs := {
		"ButtonDownloadIdle": p,
		"ButtonDownloadBusy": get_color("warning"),
		"ButtonDownloadDone": get_color("success"),
		"ButtonDownloadError": get_color("danger"),
	}
	var dl_disabled_bg := surface_high if is_light else surface_low
	var dl_disabled_text := get_color("text_secondary") if is_light else get_color("text_dim")
	for t in dl_specs:
		var base: Color = dl_specs[t]
		_set_theme_stylebox(thm, t, "normal", base.darkened(0.13), base.lightened(0.35))
		_set_theme_stylebox(thm, t, "hover", base, base.lightened(0.55))
		_set_theme_stylebox(thm, t, "pressed", base.darkened(0.21), base)
		_set_theme_stylebox(thm, t, "focus", Color(0, 0, 0, 0),
			base.darkened(0.08) if is_light else base.lightened(0.5),
			Color(base.r, base.g, base.b, 0.4))
		_set_theme_stylebox(thm, t, "disabled", dl_disabled_bg, border)
		# 饱和底色上字与图标固定白（浅色模式也不翻深色，否则浅底深字会糊）
		for c in ["font_color", "font_hover_color", "font_pressed_color",
				"font_hover_pressed_color", "font_focus_color",
				"icon_normal_color", "icon_hover_color", "icon_pressed_color",
				"icon_hover_pressed_color", "icon_focus_color"]:
			tmp.set_color(c, t, Color.WHITE)
		tmp.set_color("font_disabled_color", t, dl_disabled_text)
		tmp.set_color("icon_disabled_color", t, dl_disabled_text)
	# 卡片 / 列表项变体：样式盒几何已经搬进 MainTheme.tres（原先散在各卡片的 .tscn 里），
	# 这里只刷颜色，各卡片原本的 alpha 语义原样保留。
	# 它们都是池化列表项 —— N 个实例共用主题里这一份实例，所以一处写入即全省生效，
	# 池化脚本的 apply_theme 里不再需要「共享样式盒写前比对」那套逻辑。
	var card_states := [
		["normal", surface_high, 0.94, border, 0.85],
		["hover", surface_hover, 0.98, p, 0.85],
		["pressed", surface_low, 1.0, pl, 0.85],
	]
	for t in ["ButtonCardLarge", "ButtonCardCompact"]:
		for s in card_states:
			var csb := _theme_box(thm, t, s[0])
			csb.bg_color = _tint_keep_alpha(s[1], s[2])
			csb.border_color = _tint_keep_alpha(s[3], s[4])
		var focus_box := _theme_box(thm, t, "focus")
		focus_box.border_color = _tint_keep_alpha(accent, 0.9)
		focus_box.shadow_color = Color(p.r, p.g, p.b, 0.35)

	# 下载管理行：常态近乎透明，靠悬停 / 按下浮现
	var row_states := [
		["normal", surface, 0.42, border_soft, 0.55],
		["hover", surface_hover, 0.7, p, 0.55],
		["pressed", surface_low, 0.9, p, 0.55],
	]
	for s in row_states:
		var dsb := _theme_box(thm, "ButtonRowDownload", s[0])
		dsb.bg_color = _tint_keep_alpha(s[1], s[2])
		dsb.border_color = _tint_keep_alpha(s[3], s[4])
	_theme_box(thm, "ButtonRowDownload", "focus").border_color = _tint_keep_alpha(accent, 0.9)

	# 待操作行：底色更淡，三态描边统一用弱边框
	for s in [["normal", surface, 0.25], ["hover", surface_hover, 0.65], ["pressed", surface_low, 0.9]]:
		var psb := _theme_box(thm, "ButtonRowPending", s[0])
		psb.bg_color = _tint_keep_alpha(s[1], s[2])
		psb.border_color = _tint_keep_alpha(border_soft, 0.6)
	_theme_box(thm, "ButtonRowPending", "focus").border_color = accent

	# 封面框：浅色模式比卡片深一档，白底上白色音符预览才看得见
	var cover_bg := surface_high if is_light else surface_low
	for t in ["PanelCardCover", "PanelCardCoverCompact"]:
		var cover_box := _theme_box(thm, t, "panel")
		cover_box.bg_color = cover_bg
		cover_box.border_color = border
	_theme_box(thm, "PanelCardSelected", "panel").border_color = _tint_keep_alpha(accent, 0.95)
	_theme_box(thm, "LabelCardBadge", "normal").bg_color = _tint_keep_alpha(pd, 0.9)
	var record_box := _theme_box(thm, "PanelRecordRow", "panel")
	record_box.bg_color = surface_high
	record_box.border_color = border_soft
	var comment_box := _theme_box(thm, "PanelContainerCommentCard", "panel")
	comment_box.bg_color = _tint_keep_alpha(surface_high, 0.9)
	comment_box.border_color = border_soft

	_set_theme_stylebox(thm, "PanelSunken", "panel", surface_low, border)

	# RichTextLabel（如 MidiView 谱面简介）：正文色走 default_color，不设会停留在引擎默认的浅色上
	tmp.set_color("default_color", "RichTextLabel", get_color("text_primary"))

	# PopupMenu：面板用凸起面，悬停用半透明强调色
	_set_theme_stylebox(thm, "PopupMenu", "panel", surface_high, border)
	_set_theme_stylebox(thm, "PopupMenu", "hover", Color(p.r, p.g, p.b, 0.22), border_soft)
	# 子菜单右箭头
	thm.get_icon("submenu", "PopupMenu").set_color_map({Color(SUBMENU_ARROW_SRC_COLOR): text_primary})
	# PopupPanel：所有弹层容器（含 ColorPickerButton 的取色器弹窗）
	_set_theme_stylebox(thm, "PopupPanel", "panel", surface_high, border, Color(0, 0, 0, 0.34))

	# 滚动条：几何统一收在 MainTheme.tres（V/HScrollBar 的 grabber/scroll 样式盒 content_margin=10
	for type in ["VScrollBar", "HScrollBar"]:
		_set_theme_stylebox(thm, type, "grabber", border, border)
		_set_theme_stylebox(thm, type, "grabber_highlight", p, p)
		_set_theme_stylebox(thm, type, "grabber_pressed", pl, pl)

	# HSlider（音量条等）：滑轨在浅色下需压暗、已填充段用强调色（原写死的近白填充在浅底上不可见）
	var groove := Color(0, 0, 0, 0.22) if _appearance == "light" else Color(0, 0, 0, 0.6)
	_set_theme_stylebox(thm, "HSlider", "slider", groove, Color(0, 0, 0, 0))
	_set_theme_stylebox(thm, "HSlider", "grabber_area", p, p)
	_set_theme_stylebox(thm, "HSlider", "grabber_area_highlight", pl, pl)

	# ProgressBar（等级/经验条 / 下载进度）
	_set_theme_stylebox(thm, "ProgressBar", "background", Color(0, 0, 0, 0.12) if _appearance == "light" else surface_hover, border)
	_set_theme_stylebox(thm, "ProgressBar", "fill", p, p)
	tmp.set_color("font_color", "ProgressBar", text_primary)

	# TabContainer
	_style_tab_container(thm, tmp)

	# 工具提示（鼠标悬停 tooltip_text / 触屏长按）：面板几何在 MainTheme.tres 的
	# TooltipPanel/styles/panel，这里只刷底色/描边，跟随明暗模式。
	_set_theme_stylebox(thm, "TooltipPanel", "panel", surface_high, border, Color(0, 0, 0, 0.28))
	tmp.set_color("font_color", "TooltipLabel", get_color("text_primary"))
	# 触屏上 tooltip 由长按触发，字号比正文小一档，避免挡住内容
	tmp.set_font_size("font_size", "TooltipLabel", int(get_font_size("body", 32) * 0.8))

	# 取色器（ColorPicker 弹窗）：默认样式是深灰方角 + 细碎控件，手机上好点的只有色板与滑条。
	_style_color_picker(tmp)

	# Tree
	tmp.set_font_size("font_size", "Tree", get_font_size("body", 32))

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
