class_name ViewBackground
extends TextureRect

## 页面背景自管理节点。
##
## 给页面背景的 TextureRect 挂上本脚本即可：读 theme.ini 的 [backgrounds] 段 → 选纹理 → 跟随主题自动刷新。
## 视图脚本不要再自己 set texture / modulate / stretch_mode，也不要再往背景上叠主题色——
## 颜色只由 theme.ini 决定；没配置（type=default）时用主题衍生的默认渐变。
##
## view_name 留空表示由外部驱动（Main 的 Background / Background2 双缓冲交叉淡入淡出用 set_view()）。

const COVER_BLUR_SHADER := "res://UI/Views/PlayView/Shaders/BackgroundBlur.gdshader"
const COMPOSITE_SHADER := "res://UI/Views/PlayView/Shaders/BackgroundComposite.gdshader"
## 封面模糊未配置时的兜底强度
const DEFAULT_COVER_BLUR := 0.8
## 封面模糊算法表。索引即 shader 的 style 值，顺序必须与 BackgroundBlur.gdshader 一致。
## 设置界面下拉项（PopupWindow.tscn 的 BlurStyle）也按这个顺序排列。
const COVER_BLUR_STYLES: Array[String] = [
	"none",      # 原图
	"gaussian",  # 高斯
	"box",       # 盒式均值
	"tent",      # 三角/帐篷
	"bokeh",     # 圆盘散景
	"glass",     # 磨砂玻璃
	"pixelate",  # 方块马赛克
	"soft",      # 模糊马赛克
	"cells",     # 瓷砖马赛克
]
const DEFAULT_COVER_STYLE := "gaussian"

## 风格名 -> shader style 索引（未知值退回默认）
static func cover_blur_style_index(style_name: String) -> int:
	var idx := COVER_BLUR_STYLES.find(style_name)
	if idx < 0:
		idx = COVER_BLUR_STYLES.find(DEFAULT_COVER_STYLE)
	return idx

## 视图名：main / midi / track / setting / score / store / play
@export var view_name: String = ""
## 是否挂「暗化 + 判定闪光」合成材质（只有游玩界面需要）
@export var use_dim: bool = false

var _view: String = ""
## 上次应用的配置指纹：配置/主题没变就不重建纹理（避免切换主题时无谓重建）
var _applied_tag: String = ""

var _dim_material: ShaderMaterial = null
var _flash_color: Color = Color(1, 1, 1, 0)
var _flash_tween: Tween = null

# 封面模式（play 专用）：纹理由视图通过 set_cover() 提供，模糊在本节点烘焙
var _cover_texture: Texture2D = null
var _cover_key: String = ""
var _bake_viewport: SubViewport = null
var _bake_rect: TextureRect = null
## clear_bake() 请求了释放，但本节点还在退出淡出中（可见）→ 等隐藏了再真正释放
var _bake_free_pending: bool = false
var _bake_id: int = 0
var _baked_key: String = ""
var _baked_blur: float = -1.0
var _baked_style: int = -1
## 带 mipmap 的封面副本（shader 的 textureLod 依赖它，原纹理由文件管理器持有，不能就地加 mip）
var _cover_mip_texture: Texture2D = null
var _cover_mip_key: String = ""
## 纹理代次：异步操作（mipmap 生成）回主线程时用它判断背景是否已被换掉
var _texture_gen: int = 0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view = view_name
	if ThemeMGR:
		ThemeMGR.register_background(self)
	apply()

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_background(self)
	_discard_bake()

# ============ 对外接口 ============

## 切换本节点所属视图（双缓冲主背景用）。view 变化才重新应用。
func set_view(view: String) -> void:
	if view == _view:
		return
	_view = view
	_applied_tag = ""
	apply()

## 按当前配置重新应用背景。配置指纹没变则直接返回。
func apply(force: bool = false) -> void:
	if _view.is_empty() or not is_inside_tree() or ThemeMGR == null or not ThemeMGR.is_loaded():
		return
	var cfg := ThemeMGR.get_view_background(_view)
	var type := String(cfg.get("type", "default"))
	var tag := type + "|" + str(cfg)
	if type == "cover":
		tag += "|%s|%.3f|%s" % [
			_cover_key,
			float(cfg.get("cover_blur", DEFAULT_COVER_BLUR)),
			String(cfg.get("cover_blur_style", DEFAULT_COVER_STYLE)),
		]
	elif type == "default":
		# 默认背景的颜色是主题色衍生的，深浅色/强调色变了必须重算
		tag += "|" + ThemeMGR.get_default_background_key()
	if not force and tag == _applied_tag:
		return
	_applied_tag = tag

	match type:
		"solid":
			_apply_solid(cfg)
		"gradient":
			_apply_gradient(cfg)
		"image":
			_apply_image(cfg)
		"cover":
			_apply_cover(cfg)
		_:
			_apply_default()

	if use_dim:
		refresh_dim()

## 设置封面（play 专用）。key 用于复用已烘焙结果，同谱面重试不再重新烘焙。
func set_cover(tex: Texture2D, key: String = "") -> void:
	var key_changed := key != _cover_key
	if key_changed:
		_cover_mip_texture = null
		_cover_mip_key = ""
	_cover_texture = tex
	_cover_key = key
	if key_changed:
		_discard_bake()
	_applied_tag = ""
	apply()

## 释放封面模糊烘焙的 SubViewport（离开游玩界面时调用）。
## 不立即释放：调用时本节点通常还在做退出淡出（PlayView 0.45s modulate 淡出后才 visible=false），
## 期间纹理还在画面上；一旦提前释放，TextureRect 的 ViewportTexture 就指向已销毁的 viewport，
## 采样兜底为白色，再叠上暗化色（#0000007F）就是一整片 #808080 的灰——不是清屏色，看着很突兀。
func clear_bake() -> void:
	_bake_free_pending = true
	_try_free_bake()

func _try_free_bake() -> void:
	if not _bake_free_pending:
		return
	# 还在淡出/仍然可见：等隐藏了再释放（见 _notification）
	if visible and is_visible_in_tree():
		return
	_bake_free_pending = false
	_discard_bake()

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		_try_free_bake()

## 重新读取暗化/闪光色（config_changed 热更新）
func refresh_dim() -> void:
	if not use_dim:
		return
	var mat := _ensure_dim_material()
	if mat == null:
		return
	var dim_html := ConfigManager.instance.get_string("background_dim_color", "#0000007F")
	var dim := Color(dim_html) if dim_html.is_valid_html_color() else Color(0, 0, 0, 0.5)
	mat.set_shader_parameter("dim_color", dim)
	var flash_html := ConfigManager.instance.get_string("background_image_flash_color", "#FFFFFF00")
	_flash_color = Color(flash_html) if flash_html.is_valid_html_color() else Color(1, 1, 1, 0)
	mat.set_shader_parameter("flash_color", _flash_color)

## 判定命中闪光
func flash() -> void:
	if _flash_color.a <= 0:
		return
	var mat := _ensure_dim_material()
	if mat == null:
		return
	if _flash_tween and _flash_tween.is_valid():
		_flash_tween.kill()
	mat.set_shader_parameter("flash_progress", 1.0)
	_flash_tween = AniMGR.create_managed_tween(self)
	_flash_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_flash_tween.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("flash_progress", v), 1.0, 0.0, 1.0
	)

## 后台线程读完背景图后由 ThemeManager 回调
func set_background_image(tex: Texture2D, stretch: String) -> void:
	if tex == null or not is_inside_tree():
		return
	_set_texture(tex, _parse_stretch(stretch), CanvasItem.TEXTURE_FILTER_LINEAR)
	_discard_bake()

# ============ 各类型应用 ============

## 默认背景：不设置颜色的页面用，颜色随深浅色 + 主题色走（见 ThemeManager.get_default_background_texture）
func _apply_default() -> void:
	_set_texture(ThemeMGR.get_default_background_texture(), TextureRect.STRETCH_SCALE, CanvasItem.TEXTURE_FILTER_LINEAR)
	_discard_bake()

func _apply_solid(cfg: Dictionary) -> void:
	var html := String(cfg.get("solid_color", ""))
	var color := Color(html) if html.is_valid_html_color() else ThemeMGR.get_default_background_color()
	var img := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(color)
	_set_texture(ImageTexture.create_from_image(img), TextureRect.STRETCH_SCALE, CanvasItem.TEXTURE_FILTER_LINEAR)
	_discard_bake()

func _apply_gradient(cfg: Dictionary) -> void:
	var top_html := String(cfg.get("gradient_top", ""))
	var bottom_html := String(cfg.get("gradient_bottom", ""))
	if not top_html.is_valid_html_color() or not bottom_html.is_valid_html_color():
		_apply_default()
		return
	var gradient := Gradient.new()
	gradient.set_color(0, Color(top_html))
	gradient.set_color(1, Color(bottom_html))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 256
	tex.height = 256
	tex.fill_from = Vector2(
		float(cfg.get("gradient_from_x", 0.0)), float(cfg.get("gradient_from_y", 0.0))
	)
	tex.fill_to = Vector2(
		float(cfg.get("gradient_to_x", 0.0)), float(cfg.get("gradient_to_y", 1.0))
	)
	_set_texture(tex, TextureRect.STRETCH_SCALE, CanvasItem.TEXTURE_FILTER_LINEAR)
	_discard_bake()

func _apply_image(cfg: Dictionary) -> void:
	var image_path := String(cfg.get("image_path", ""))
	if image_path.is_empty():
		_apply_default()
		return
	var stretch := String(cfg.get("image_stretch", "cover"))
	var tex := ThemeMGR.get_cached_background_image(image_path)
	if tex:
		_set_texture(tex, _parse_stretch(stretch), CanvasItem.TEXTURE_FILTER_LINEAR)
		_discard_bake()
		return
	# 未命中缓存：先铺默认背景，再由后台线程读盘（避免主线程同步 IO 卡顿）
	_apply_default()
	ThemeMGR.request_background_image(image_path, self, stretch)

func _apply_cover(cfg: Dictionary) -> void:
	var blur := float(cfg.get("cover_blur", DEFAULT_COVER_BLUR))
	var style_name := String(cfg.get("cover_blur_style", DEFAULT_COVER_STYLE))
	var style := cover_blur_style_index(style_name)
	if _cover_texture == null:
		# 没有封面可用：退回默认背景，不要把界面刷成纯色
		_apply_default()
		return
	# 不模糊（强度 0，或显式选 none）：直接铺原图
	if blur <= 0.001 or style == 0:
		_set_texture(_cover_texture, TextureRect.STRETCH_KEEP_ASPECT_COVERED, CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS)
		_discard_bake()
		_ensure_mipmaps(_cover_texture)
		return
	if _can_reuse_bake(blur, style):
		_set_texture(_bake_viewport.get_texture(), TextureRect.STRETCH_KEEP_ASPECT_COVERED, CanvasItem.TEXTURE_FILTER_LINEAR)
		return
	# 烘焙前先铺原图当占位（烘焙完成才换成结果纹理）
	_set_texture(_cover_texture, TextureRect.STRETCH_KEEP_ASPECT_COVERED, CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS)
	_ensure_mipmaps(_cover_texture)
	_bake(blur, style)

# ============ 纹理与材质 ============

## 统一设置纹理。保留 modulate.a：主背景双缓冲靠 modulate.a 做交叉淡入淡出
func _set_texture(tex: Texture2D, stretch: TextureRect.StretchMode, filter: CanvasItem.TextureFilter) -> void:
	texture = tex
	stretch_mode = stretch
	texture_filter = filter
	modulate = Color(1, 1, 1, modulate.a)
	_texture_gen += 1

func _ensure_dim_material() -> ShaderMaterial:
	if _dim_material != null:
		return _dim_material
	var shader := load(COMPOSITE_SHADER)
	if shader == null:
		return null
	_dim_material = ShaderMaterial.new()
	_dim_material.shader = shader
	_dim_material.set_shader_parameter("flash_progress", 0.0)
	material = _dim_material
	return _dim_material

# ============ 封面模糊烘焙 ============

## 异步补 mipmap：先按原图显示（不阻塞当前帧），下一帧再换成带 mipmap 的版本
func _ensure_mipmaps(source: Texture2D) -> void:
	if source == null:
		return
	var image := source.get_image()
	if image == null or image.is_empty() or image.has_mipmaps():
		return
	_generate_mipmaps_deferred(image, _texture_gen)

func _generate_mipmaps_deferred(image: Image, gen: int) -> void:
	await RenderingServer.frame_post_draw
	# 等待期间背景已被换掉（切谱面 / 切主题）就丢弃这次结果
	if gen != _texture_gen or image == null or image.is_empty():
		return
	image.generate_mipmaps()
	texture = ImageTexture.create_from_image(image)

## 是否可复用已烘焙结果：同谱面 + 同模糊强度 + 同算法 + SubViewport 仍有效
func _can_reuse_bake(blur: float, style: int) -> bool:
	if _bake_viewport == null or _baked_key.is_empty():
		return false
	return _baked_key == _cover_key and absf(_baked_blur - blur) < 0.001 and _baked_style == style

## 取带 mipmap 的封面副本。shader 用 textureLod 做大半径降采样，必须依赖 mipmap；
## 原纹理由 FileSystemManager 缓存并可能被别处引用，不能就地 generate_mipmaps。
## 副本按封面 key 缓存，同一谱面反复进页不重复回读。
func _get_mip_source(key: String) -> Texture2D:
	if _cover_texture == null:
		return null
	if _cover_mip_texture != null and _cover_mip_key == key:
		return _cover_mip_texture
	var img := _cover_texture.get_image()
	if img == null or img.is_empty():
		return _cover_texture
	if not img.has_mipmaps():
		img.generate_mipmaps()
	_cover_mip_texture = ImageTexture.create_from_image(img)
	_cover_mip_key = key
	return _cover_mip_texture

func _bake(blur: float, style: int) -> void:
	_discard_bake()
	_bake_free_pending = false
	_bake_id += 1
	var my_id := _bake_id

	var window_size := DisplayServer.window_get_size()
	var bake_size := Vector2i(window_size)
	if bake_size.x > 1920 or bake_size.y > 1080:
		var s := minf(1920.0 / bake_size.x, 1080.0 / bake_size.y)
		bake_size = Vector2i(Vector2(bake_size) * s)
	if bake_size.x <= 0 or bake_size.y <= 0:
		return

	_bake_viewport = SubViewport.new()
	_bake_viewport.size = bake_size
	_bake_viewport.transparent_bg = true
	_bake_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_bake_viewport)

	_bake_rect = TextureRect.new()
	# 只有带 mipmap 的源纹理才能让 shader 的 textureLod 拿到低分辨率层
	_bake_rect.texture = _get_mip_source(_cover_key)
	if _bake_rect.texture == null:
		_bake_rect.texture = _cover_texture
	_bake_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_bake_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bake_rect.position = Vector2.ZERO
	_bake_rect.size = Vector2(bake_size)
	_bake_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bake_viewport.add_child(_bake_rect)

	var mat := ShaderMaterial.new()
	mat.shader = load(COVER_BLUR_SHADER)
	mat.set_shader_parameter("style", style)
	mat.set_shader_parameter("blur_strength", clampf(blur, 0.0, 1.0))
	_bake_rect.material = mat

	await RenderingServer.frame_post_draw

	if my_id != _bake_id or _bake_viewport == null:
		return
	_set_texture(_bake_viewport.get_texture(), TextureRect.STRETCH_KEEP_ASPECT_COVERED, CanvasItem.TEXTURE_FILTER_LINEAR)
	_baked_key = _cover_key
	_baked_blur = blur
	_baked_style = style

func _discard_bake() -> void:
	if _bake_viewport:
		var baked_tex := _bake_viewport.get_texture()
		_bake_viewport.queue_free()
		_bake_viewport = null
		_bake_rect = null
		_bake_id += 1
		# 纹理还指着刚销毁的 ViewportTexture 时立刻换成有效纹理。
		# 死纹理的采样兜底是白色，配上暗化层就是一片灰（退出打歌页时肉眼可见）。
		if texture == baked_tex:
			if _cover_texture != null:
				_set_texture(_cover_texture, TextureRect.STRETCH_KEEP_ASPECT_COVERED, CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS)
				_ensure_mipmaps(_cover_texture)
			elif ThemeMGR:
				_set_texture(ThemeMGR.get_default_background_texture(), TextureRect.STRETCH_SCALE, CanvasItem.TEXTURE_FILTER_LINEAR)
	# SubViewport 释放后 ViewportTexture 失效，不再可复用
	_baked_key = ""
	_baked_blur = -1.0
	_baked_style = -1

# ============ 工具 ============

func _parse_stretch(mode: String) -> TextureRect.StretchMode:
	match mode:
		"scale": return TextureRect.STRETCH_SCALE
		"tile": return TextureRect.STRETCH_TILE
		"fit": return TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		"center": return TextureRect.STRETCH_KEEP_CENTERED
		"keep": return TextureRect.STRETCH_KEEP
	return TextureRect.STRETCH_KEEP_ASPECT_COVERED
