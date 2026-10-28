extends Node2D
class_name NoteBatchDrawer

## Block/Slide/Long 音符批量绘制器
## 用单个 Node2D + _draw() 替代 N 个 TextureRect Control 节点
## 消除 Control 布局 / offset_transform / size 重算开销

# 贴图引用（由 FlowArea.set_note_texture 同步）
var _block_tex: Texture2D = null
var _block_core_tex: Texture2D = null
var _slide_tex: Texture2D = null
var _slide_core_tex: Texture2D = null

# Long 长条贴图（head=long_b 头部 / body=long_f 中部 / tail=long_t 尾部）
var _long_head_tex: Texture2D = null
var _long_head_core_tex: Texture2D = null
var _long_body_tex: Texture2D = null
var _long_body_core_tex: Texture2D = null
var _long_tail_tex: Texture2D = null
var _long_tail_core_tex: Texture2D = null

# 每音符颜色由 FlowArea 在 _spawn_note 时写入 note.cached_color，_draw 直接用，无全局颜色字段

# 光效
var _glow_tex: Texture2D = null       # 程序预烘焙的白色 glow 纹理
var _glow_enabled: bool = false
var _glow_intensity: float = 1.0
var _glow_size: float = 20.0
# 加色混合子层（PlayView.tscn 预挂节点：GlowLayer.gd，z_index=-1 保证在音符之下、背景之上）
# 皮肤预览复用本节点时不挂 GlowLayer，用 get_node_or_null 避免缺节点报错
@onready var _glow_layer: GlowLayer = get_node_or_null("GlowLayer")

# 光效高斯峰值：加色混合逐通道相加，峰值 ≥0.5 时两个相同颜色的光效叠加就达 1.0（白）
# 0.45 保证两个光效叠加不超过 0.9，不白但接近白；调高更亮更易白，调低更压白
const GLOW_PEAK := 0.45

# 音符尺寸
var _note_width: float = 100.0
var _block_half_height: float = 50.0
var _slide_half_height: float = 50.0
# Long 头/尾半高（按贴图宽高比计算）与 body 贴图原始高度（repeat 分条用）
var _long_head_half_height: float = 50.0
var _long_tail_half_height: float = 50.0
var _long_body_tex_height: float = 50.0
# body 分条周期/映射基准所用的参考贴图（base 优先，缺 base 时用 core）。
# body 允许只有 core 没有 base，参考尺寸不能取自透明占位贴图，否则周期与取样区间都会错
var _long_body_ref_tex: Texture2D = null
# body 中部贴图应用方式："repeat"（水平拉伸+垂直重复）或 "stretch"（固定比例映射，不随身体压缩）
var _long_body_mode: String = "repeat"
# stretch 模式的贴图映射方式："screen"（方案 A：屏幕固定映射，按位置裁剪）
# 或 "length"（方案 B：按身体基准长度固定比例映射，随长条移动）
var _long_stretch_mode: String = "length"

# 皮肤预览状态（见 set_long_preview）：命中后 _draw 只画这一条长条，不读实战数据
var _preview_active: bool = false
var _preview_body_rect: Rect2 = Rect2()
var _preview_connect_center: bool = false
var _preview_color: Color = Color.WHITE
var _preview_ref_h: float = 0.0

# 渲染裁剪参数（与 FlowArea._note_cull_margin_* 对齐）
var _cull_margin_top: float = 120.0
var _cull_margin_bottom: float = 180.0
var _viewport_height: float = 0.0

# 活跃音符来源：FlowArea._note_buckets 引用（set_notes_source 注入）
# 结构：type_key(Block/Slide/Long) -> { color -> Array[int] }  桶元素为 seq 索引
# 颜色分桶供 GlowLayer 遍历（同色桶共用一份 modulate）；音符本体绘制改走 _draw_order
var _note_buckets: Dictionary = {}

# 绘制顺序来源：FlowArea._draw_order 引用（set_draw_order_source 注入）
# 结构：type_key -> Array[int]，按 _st_start 升序（先出现=靠下=靠前）
# _draw 逆序遍历它：后画者覆盖先画者。绘制层序 = 类型层序 + 同类型内"先出现者在上"
var _draw_order: Dictionary = {}

# 类型覆盖顺序（先画=在下，后画=在上），由"音符绘制顺序"设置（Appearance/note_draw_order）选择：
# 长条置底（默认）：Long 最底 → Slide → Block 最上，长条不遮挡点块/滑块，不影响游玩
# 长条置顶：Block 最底 → Slide → Long 最上，长条覆盖在其他音符之上
const _DRAW_TYPE_ORDER_LONG_BOTTOM: Array = [
	FlowNote.NoteType.Long,
	FlowNote.NoteType.Slide,
	FlowNote.NoteType.Block,
]
const _DRAW_TYPE_ORDER_LONG_TOP: Array = [
	FlowNote.NoteType.Block,
	FlowNote.NoteType.Slide,
	FlowNote.NoteType.Long,
]
var _draw_type_order: Array = _DRAW_TYPE_ORDER_LONG_BOTTOM

# 平行数组宿主（FlowArea 注入）：_draw 读 flow_area._rt_* 取运行态，无需音符对象
var flow_area: Object = null

# 透明纹理回退（贴图缺失时）
var _transparent_tex: Texture2D = null

# 上色方式：先画 base（固定色结构层），再画 core（纯白 + alpha 蒙版）并 modulate 音符色。
# 实战与皮肤预览共用这套绘制，观感一致；与
# draw_texture_rect(core, rect, false, color) 的 alpha 加权混合等价。
# 注意：不要用 Image.blend_rect_mask 预合成 —— 该 API 只判 mask.a != 0 做二值门整体覆盖，
# 会把 core 的软边与亮度渐变全部涂成纯色（整片色块、轮廓丢失）。


func _ready() -> void:
	_transparent_tex = _create_transparent_texture()
	_bake_glow_texture()
	_setup_glow_layer()


# ========== 公共 API ==========

## 注入活跃音符来源分桶字典（FlowArea._note_buckets，按引用共享）。
## 颜色分桶供 GlowLayer 遍历；音符本体的绘制顺序改由 _draw_order 决定。
func set_notes_source(notes: Dictionary) -> void:
	_note_buckets = notes

## 注入绘制顺序字典（FlowArea._draw_order，按引用共享）。
## 每个类型一个按 _st_start 升序的 seq 索引数组，_draw 逆序遍历以获得正确的覆盖层序。
func set_draw_order_source(order: Dictionary) -> void:
	_draw_order = order

## 设置类型绘制层序：long_on_top=true 时长条置顶，false 时置底（默认）。
## 只影响 _draw 的遍历顺序，_draw_order 数据结构不变，变更后触发重绘即可生效。
func set_draw_type_order(long_on_top: bool) -> void:
	_draw_type_order = _DRAW_TYPE_ORDER_LONG_TOP if long_on_top else _DRAW_TYPE_ORDER_LONG_BOTTOM
	request_redraw()

func clear() -> void:
	# 字典本身由 FlowArea.clear_flow_area 清空（_note_buckets 是同一引用），此处只触发重绘
	queue_redraw()
	if _glow_layer:
		_glow_layer.queue_redraw()

func request_redraw() -> void:
	queue_redraw()
	if _glow_layer:
		_glow_layer.queue_redraw()

func set_textures(block_tex: Texture2D, block_core_tex: Texture2D,
		slide_tex: Texture2D, slide_core_tex: Texture2D) -> void:
	_block_tex = block_tex if block_tex else _transparent_tex
	_block_core_tex = block_core_tex if block_core_tex else _transparent_tex
	_slide_tex = slide_tex if slide_tex else _transparent_tex
	_slide_core_tex = slide_core_tex if slide_core_tex else _transparent_tex
	_recompute_heights()

## 同步 Long 长条贴图（head=long_b 头部 / body=long_f 中部 / tail=long_t 尾部）
func set_long_textures(head_tex: Texture2D, head_core_tex: Texture2D,
		body_tex: Texture2D, body_core_tex: Texture2D,
		tail_tex: Texture2D, tail_core_tex: Texture2D) -> void:
	_long_head_tex = head_tex if head_tex else _transparent_tex
	_long_head_core_tex = head_core_tex if head_core_tex else _transparent_tex
	_long_body_tex = body_tex if body_tex else _transparent_tex
	_long_body_core_tex = body_core_tex if body_core_tex else _transparent_tex
	# 参考贴图按原始入参决定：缺 base 的皮肤（只画 core 的 body）用 core 的尺寸
	_long_body_ref_tex = body_tex if body_tex else body_core_tex
	_long_tail_tex = tail_tex if tail_tex else _transparent_tex
	_long_tail_core_tex = tail_core_tex if tail_core_tex else _transparent_tex
	_recompute_heights()

## 设置 body 中部贴图应用方式（"repeat" / "stretch"）
func set_long_body_mode(mode: String) -> void:
	_long_body_mode = mode

## 设置 stretch 模式的贴图映射方式（"screen" 屏幕固定映射 / "length" 按身体基准长度映射）
func set_long_stretch_mode(mode: String) -> void:
	_long_stretch_mode = mode


# ========== 皮肤预览（NoteSkinAdjust 弹窗） ==========
# 预览不走 _draw_order/_rt_* 的实战数据流，而是直接给一块身体区域，
# 由同一套几何规则与绘制函数产出画面，保证预览与实战的连接/分条观感一致

## 预览状态：body_rect 为本节点局部坐标下的身体区域；ref_h 供 screen 拉伸模式作参考高度
func set_long_preview(body_rect: Rect2, connect_center: bool, color: Color, ref_h: float) -> void:
	_preview_active = true
	_preview_body_rect = body_rect
	_preview_connect_center = connect_center
	_preview_color = color
	_preview_ref_h = ref_h
	queue_redraw()

## 预览各部件矩形（键：body/tail/head），供弹窗摆放光效；坐标与本节点一致
func get_long_preview_rects() -> Dictionary:
	var body := _preview_body_rect
	var tail_half := _long_tail_half_height
	var head_half := _long_head_half_height
	# center 连接：head/tail 中心分别落在 body 的上/下边缘，各向 body 内偏移半高
	var tail_top: float = body.position.y - tail_half if _preview_connect_center else body.position.y - tail_half * 2.0
	var head_top: float = body.position.y + body.size.y - head_half if _preview_connect_center else body.position.y + body.size.y
	return {
		"body": body,
		"tail": Rect2(body.position.x, tail_top, body.size.x, tail_half * 2.0),
		"head": Rect2(body.position.x, head_top, body.size.x, head_half * 2.0),
	}

## Long 头/尾半高（spawn 时由 FlowArea 读取）
func get_long_head_half_height() -> float:
	return _long_head_half_height

func get_long_tail_half_height() -> float:
	return _long_tail_half_height

func set_note_width(wid: float) -> void:
	_note_width = wid
	_recompute_heights()

func set_cull_margins(top: float, bottom: float) -> void:
	_cull_margin_top = top
	_cull_margin_bottom = bottom

func set_viewport_height(h: float) -> void:
	_viewport_height = h

func set_glow_enabled(enabled: bool) -> void:
	_glow_enabled = enabled
	if _glow_layer:
		_glow_layer.visible = enabled

func set_glow_params(intensity: float, size_val: float) -> void:
	var new_intensity = clampf(intensity, 0.0, 2.0)
	var new_size = clampf(size_val, 1.0, 30.0)
	if not is_equal_approx(new_size, _glow_size):
		_glow_size = new_size
		_bake_glow_texture()
	_glow_intensity = new_intensity

func get_half_height(note_type: int) -> float:
	# FlowNote.NoteType: Block=0, Slide=1, Long=2
	if note_type == FlowNote.NoteType.Slide:
		return _slide_half_height
	return _block_half_height

## 所有类型音符中的最大半高（FlowArea 计算 _note_max_size_y 用）
func get_max_half_height() -> float:
	return maxf(maxf(_block_half_height, _slide_half_height), maxf(_long_head_half_height, _long_tail_half_height))


# ========== 内部实现 ==========

## 绘制一个音符部件的两层：base（固定色结构层，原样绘制）→ core（纯白蒙版，modulate 音符色）。
## 必须分两次绘制、不能用 Image.blend_rect_mask 预合成：该 API 只按 mask.a != 0 做二值门整体覆盖，
## 会丢掉 core 的软边与亮度渐变（整片纯色），与预览/实战统一的分层绘制不一致。
func _draw_note_layers(base_tex: Texture2D, core_tex: Texture2D, rect: Rect2, color: Color) -> void:
	# 预览可能在皮肤贴图注入前先触发一次重绘，缺层时跳过而不是把 null 传给绘制接口
	if base_tex:
		draw_texture_rect(base_tex, rect, false)
	if core_tex:
		draw_texture_rect(core_tex, rect, false, color)

func _recompute_heights() -> void:
	_block_half_height = _compute_half_height(_block_tex)
	_slide_half_height = _compute_half_height(_slide_tex)
	_long_head_half_height = _compute_half_height(_long_head_tex)
	_long_tail_half_height = _compute_half_height(_long_tail_tex)
	_long_body_tex_height = _compute_tex_height(_long_body_ref_texture())

## body 分条周期/映射基准贴图：base 缺失时用 core，两者都缺失时退回透明占位贴图
func _long_body_ref_texture() -> Texture2D:
	return _long_body_ref_tex if _long_body_ref_tex else _long_body_tex

func _compute_half_height(tex: Texture2D) -> float:
	if tex == null or tex.get_width() <= 0:
		return _note_width * 0.5
	return _note_width * (float(tex.get_height()) / float(tex.get_width())) * 0.5

func _compute_tex_height(tex: Texture2D) -> float:
	# body 贴图原始高度：repeat 分条重复的单位高度；缺失时退化为 note_width（v_repeat=1）
	if tex == null or tex.get_height() <= 0:
		return _note_width
	return float(tex.get_height())

func _create_transparent_texture(size: int = 64) -> Texture2D:
	var image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(image)

## 程序烘焙白色 glow 纹理
## 高斯径向衰减 exp(-(dist/σ)²)：中心亮、向外平滑衰减、到纹理边缘约 0，无可见圆形边界
## σ 由 _glow_size 映射（1~30 → σ 0.6~1.5，音符半高单位），最大时衰减仍在纹理内结束，不裁边
## 峰值 GLOW_PEAK 直接烤入：保持高斯平滑形状（无平台），加色叠加也不易爆白
func _bake_glow_texture() -> void:
	var size = 128
	var img = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center = size * 0.5
	var note_half = size / 6.0  # note_uv_half = 0.1667 ≈ 1/6（dist 单位：音符半高）
	var sigma = 0.6 + _glow_size * (1.5 - 0.6) / 30.0
	for y in range(size):
		for x in range(size):
			var nx = (x - center) / note_half
			var ny = (y - center) / note_half
			var dist = sqrt(nx * nx + ny * ny)
			var glow = GLOW_PEAK * exp(-dist * dist / (sigma * sigma))
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(glow, 0.0, 1.0)))
	_glow_tex = ImageTexture.create_from_image(img)

## 绑定 tscn 预挂的 GlowLayer 节点（节点结构在 PlayView.tscn 声明：z_index=-1、ADD 混合材质）
## 此处只注入 _drawer 引用（GlowLayer._draw 直接读本节点字段，避免数据同步）并同步可见性
func _setup_glow_layer() -> void:
	if _glow_layer == null:
		return
	_glow_layer._drawer = self
	_glow_layer.visible = _glow_enabled

## 绘制层序（后画者覆盖先画者）：
##   1) 类型层序由 _draw_type_order 决定（"音符绘制顺序"设置：默认长条置底 Long → Slide → Block，
##      或长条置顶 Block → Slide → Long），与音符生成顺序无关。
##   2) 同类型内逆序遍历 _draw_order（按 _st_start 升序存放）→ 先出现的（靠下方）最后画，
##      盖在同类型后出现的（靠上方）音符之上。
## 只跳过已移除音符：Long 被按住时 is_judged=true 但仍需显示，不能按 is_judged 跳过。
## 每音符 2 次绘制：base（固定色结构层）+ core（modulate 音符色）
func _draw() -> void:
	if _preview_active:
		_draw_long_preview()
		return
	if _draw_order.is_empty():
		return
	var view_h = _viewport_height
	var top_limit = -_cull_margin_top
	var bottom_limit = view_h + _cull_margin_bottom
	# 平行数组宿主引用（_draw 每个元素热读，缓存到局部减少动态查找）
	var fa = flow_area
	if fa == null:
		return
	var flags: PackedByteArray = fa._rt_flags
	var rt_cy: PackedFloat32Array = fa._rt_cy
	var rt_x: PackedFloat32Array = fa._rt_x
	var rt_half: PackedFloat32Array = fa._rt_half
	var rt_color: PackedColorArray = fa._rt_color
	var REMOVED: int = fa.F_REMOVED

	for type_key in _draw_type_order:
		var order: Array = _draw_order[type_key]
		var is_long: bool = type_key == FlowNote.NoteType.Long
		var base_tex: Texture2D = _block_tex if type_key == FlowNote.NoteType.Block else _slide_tex
		var core_tex: Texture2D = _block_core_tex if type_key == FlowNote.NoteType.Block else _slide_core_tex
		for i in range(order.size() - 1, -1, -1):
			var note_index: int = order[i]
			if flags[note_index] & REMOVED:
				continue
			# 逐音符取色（不再按颜色桶分组）：绘制顺序由层序规则决定，不能为批处理重排
			var color: Color = rt_color[note_index]
			if is_long:
				# 长条自身层序：body（最底）→ tail → head（最上）
				_draw_long_body(note_index, fa, top_limit, bottom_limit, color)
				_draw_long_tail(note_index, fa, top_limit, bottom_limit, color)
				_draw_long_head(note_index, fa, top_limit, bottom_limit, color)
				continue
			var cy: float = rt_cy[note_index]
			var half_h: float = rt_half[note_index]
			if cy + half_h < top_limit or cy - half_h > bottom_limit:
				continue
			_draw_note_layers(base_tex, core_tex,
				Rect2(rt_x[note_index], cy - half_h, _note_width, half_h * 2.0), color)

## 绘制 Long body（长条连接部分）：
## repeat → 按贴图原始高度分条重复；stretch → 固定比例映射 + 按身体区间裁剪（不随身体压缩/拉伸）。
## 每部分都按 base（固定色）→ core（modulate 音符色）两层绘制。
## note_index 为平行数组 seq 索引，运行态经 fa（FlowArea）读取
func _draw_long_body(note_index: int, fa: Object, top_limit: float, bottom_limit: float, color: Color) -> void:
	var body_top: float = fa._rt_body_top[note_index]
	var body_h: float = fa._rt_body_h[note_index]
	if body_h <= 0.0 or body_top + body_h < top_limit or body_top > bottom_limit:
		return
	var body_x: float = fa._rt_x[note_index]
	if _long_body_mode == "repeat":
		# 拉伸方式对重复模式同样生效，只改变分条的相位锚点（分条周期恒为贴图原始高度）：
		# 屏幕固定 → 分条网格锚定屏幕坐标（图案固定于屏幕，长条滚过其上）
		# 按实际长度 → 分条锚定身体上端（图案随长条整体下移，向下部分被判定线吞掉）
		var phase: float = 0.0
		if _long_stretch_mode == "screen" and _long_body_tex_height > 0.0:
			phase = fposmod(body_top, _long_body_tex_height)
		_draw_long_body_repeat(_long_body_tex, _long_body_core_tex,
			Rect2(body_x, body_top, _note_width, body_h), color, phase)
		return
	_draw_long_body_stretch(note_index, fa, body_x, body_top, body_h, color)

## stretch 模式：固定比例映射 + 按身体区间裁剪（拉伸幅度恒定，不随身体压缩/拉伸）。
## screen（方案 A）→ 贴图按 [0, 屏幕高] 区间固定映射，同一屏幕高度处样式一致；
## length（方案 B）→ 贴图顶部锚定身体上端（尾端）并随长条整体下移，向下越出身体的部分
## （屏幕下方 / 被判定线吞掉）直接裁掉。
## 极端情况（视口/基准长度未就绪）回退整图缩放填充，避免出现空洞
func _draw_long_body_stretch(note_index: int, fa: Object, x: float, body_top: float, body_h: float, color: Color) -> void:
	_draw_long_body_stretch_rect(x, body_top, body_h, fa._rt_body_ref_len[note_index], _viewport_height, color)

## stretch 的公共实现（实战与皮肤预览共用）：
## ref_len = "length" 模式的长条基准长度；ref_h = "screen" 模式的屏幕参考高度
func _draw_long_body_stretch_rect(x: float, body_top: float, body_h: float,
		ref_len: float, ref_h: float, color: Color) -> void:
	# 映射基准取 base（缺 base 时取 core），两层再按同一归一化区间各自取样
	var ref_tex: Texture2D = _long_body_ref_texture()
	var tex_w := float(ref_tex.get_width())
	var tex_h := float(ref_tex.get_height())
	var mapped: Dictionary
	if _long_stretch_mode == "screen":
		if ref_h <= 0.0:
			_draw_note_layers(_long_body_tex, _long_body_core_tex,
				Rect2(x, body_top, _note_width, body_h), color)
			return
		mapped = NoteFallCalculator.compute_screen_span_rect(
			x, _note_width, body_top, body_h, ref_h, tex_w, tex_h)
	else:
		if ref_len <= 0.0:
			_draw_note_layers(_long_body_tex, _long_body_core_tex,
				Rect2(x, body_top, _note_width, body_h), color)
			return
		mapped = NoteFallCalculator.compute_length_span_rect(
			x, _note_width, body_top, body_h, ref_len, tex_w, tex_h)
	if mapped.is_empty():
		return
	var src: Rect2 = mapped["src"]
	var dst: Rect2 = mapped["dst"]
	var v0 := src.position.y / tex_h
	var v1 := (src.position.y + src.size.y) / tex_h
	_draw_long_body_slice(_long_body_tex, dst, v0, v1)
	_draw_long_body_slice(_long_body_core_tex, dst, v0, v1, color)

## 皮肤预览绘制：几何与绘制顺序均与实战一致（body 最底 → tail → head）。
## 预览没有下落时长，stretch+length 取"身体长度 = 基准长度"，等价于恒速下落时贴图整幅铺满
func _draw_long_preview() -> void:
	var rects := get_long_preview_rects()
	var body: Rect2 = rects["body"]
	var tail_rect: Rect2 = rects["tail"]
	var head_rect: Rect2 = rects["head"]
	if body.size.y > 0.0:
		if _long_body_mode == "repeat":
			var phase := 0.0
			if _long_stretch_mode == "screen" and _long_body_tex_height > 0.0:
				phase = fposmod(body.position.y, _long_body_tex_height)
			_draw_long_body_repeat(_long_body_tex, _long_body_core_tex, body, _preview_color, phase)
		else:
			_draw_long_body_stretch_rect(body.position.x, body.position.y, body.size.y,
				body.size.y, _preview_ref_h, _preview_color)
	_draw_note_layers(_long_tail_tex, _long_tail_core_tex, tail_rect, _preview_color)
	_draw_note_layers(_long_head_tex, _long_head_core_tex, head_rect, _preview_color)

## 绘制 Long tail（尾部）
func _draw_long_tail(note_index: int, fa: Object, top_limit: float, bottom_limit: float, color: Color) -> void:
	var tail_cy: float = fa._rt_tail_cy[note_index]
	var tail_half: float = fa._rt_tail_half[note_index]
	if tail_cy + tail_half < top_limit or tail_cy - tail_half > bottom_limit:
		return
	_draw_note_layers(_long_tail_tex, _long_tail_core_tex,
		Rect2(fa._rt_x[note_index], tail_cy - tail_half, _note_width, tail_half * 2.0), color)

## 绘制 Long head（头部，盖在 body 上）
func _draw_long_head(note_index: int, fa: Object, top_limit: float, bottom_limit: float, color: Color) -> void:
	var head_cy: float = fa._rt_head_cy[note_index]
	var head_half: float = fa._rt_head_half[note_index]
	if head_cy + head_half < top_limit or head_cy - head_half > bottom_limit:
		return
	_draw_note_layers(_long_head_tex, _long_head_core_tex,
		Rect2(fa._rt_x[note_index], head_cy - head_half, _note_width, head_half * 2.0), color)

## repeat 模式下分条绘制 body：水平拉伸（0-1），垂直按贴图原始高度逐条重复。
## phase = 身体上端在分条周期内已越过的贴图高度（像素，范围 [0, tex_h)）：
##   0（默认）= 分条锚定身体上端 → 图案随长条整体下移（与 LongBodyRepeat shader v_offset=0 一致）
##   >0       = 分条网格锚定屏幕 → 图案固定于屏幕，长条滚过其上
## 最后一条不足贴图高度时只取该条剩余的贴图部分；base/core 两层逐条分别绘制。
## 取样区间按归一化 UV 表达，base 与 core 各自按自身像素尺寸换算：
## 皮肤允许 body 只提供 core（缺 base），此时不能拿 base 的像素宽高去取样 core
func _draw_long_body_repeat(base_tex: Texture2D, core_tex: Texture2D, rect: Rect2, color: Color, phase: float = 0.0) -> void:
	var tex_h := _long_body_tex_height
	if tex_h <= 0.0:
		_draw_note_layers(base_tex, core_tex, rect, color)
		return
	var top := rect.position.y
	var remain := rect.size.y
	var src_y: float = fposmod(phase, tex_h)
	if tex_h - src_y < 0.01:
		src_y = 0.0
	var guard := 0
	while remain > 0.01:
		var h := minf(tex_h - src_y, remain)
		var dst := Rect2(rect.position.x, top, rect.size.x, h)
		var v0 := src_y / tex_h
		var v1 := (src_y + h) / tex_h
		_draw_long_body_slice(base_tex, dst, v0, v1)
		_draw_long_body_slice(core_tex, dst, v0, v1, color)
		top += h
		remain -= h
		src_y = 0.0
		guard += 1
		if guard > 256:
			break

## 按归一化纵向区间 [v0, v1) 取贴图一段横向整幅铺到 dst。
## 归一化而非像素区间：base/core 画布尺寸不一致时两层仍落在同一段上，不会错位或漏画
func _draw_long_body_slice(tex: Texture2D, dst: Rect2, v0: float, v1: float, color: Color = Color.WHITE) -> void:
	if tex == null:
		return
	var tex_w := float(tex.get_width())
	var tex_h := float(tex.get_height())
	if tex_w <= 0.0 or tex_h <= 0.0 or v1 - v0 <= 0.0:
		return
	draw_texture_rect_region(tex, dst, Rect2(0.0, v0 * tex_h, tex_w, (v1 - v0) * tex_h), color)
