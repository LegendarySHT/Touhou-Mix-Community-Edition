## 精灵图序列帧粒子批绘器
## 替代旧的逐粒子实例化 + 对象池：全部粒子由单个 Node2D 统一维护，
## _process() 推进动画状态，_draw() 一次批量绘制所有粒子
## 供 PlayView 判定特效与 ParticleAdjust 预览共用
## 一次特效 = 基础粒子层（可选）+ 发射器/散射粒子层（可选），两层各自独立推进帧
## （两层来自不同粒子包时 fps/帧数/网格可能不同，不再强制同网格）
extends Control

class_name ParticleBatchDrawer

## 循环粒子的最大播放时长（秒）：loop=true 的层也必须终结，
## 否则粒子长期残留、越积越多
const _MAX_LOOP_PLAY_SEC := 5.0

# ===== 单层运行时状态（轻量 RefCounted，非节点） =====
## 一层 = 一张精灵图 + 该包自己的网格/帧率/播放推进状态
## base 层与 emitter 层各自持有独立 Layer，独立推进帧
class Layer:
	var texture: Texture2D
	## 贴图 RID（spawn 时缓存，_draw 免每帧 get_rid()）
	var tex_id: int = 0
	## 是否为发射器层（绘制按角色分桶：基础层桶在下、发射器层桶在上）
	var is_emitter: bool = false
	## 粒子位置快照（spawn 时写入；粒子播发后位置不变，绘制桶直接取用，
	## 避免 Layer→粒子反向引用造成 RefCounted 循环引用泄漏）
	var pos: Vector2 = Vector2.ZERO
	## 粒子整体不透明度快照（0-1，spawn 时写入；尾段淡出由 _layer_color 实时计算，不改此值）
	var alpha: float = 1.0
	## 显示边长一半（spawn 预计算，_draw 免逐帧换算）
	var half_size: float = 0.0
	## 该层本次播放的旋转角（弧度；spawn 时按包内 rotation 规格采样一次，整段动画固定）
	var rotation: float = 0.0
	## 贴图中单帧的像素边长（粒子包 [general] size）
	var source_size: float = 256.0
	var cols: int = 1      # 网格列数
	var rows: int = 1      # 网格行数
	var frame_count: int = 1
	var fps: float = 30.0
	var loop: bool = false
	var fade_out: bool = true
	# ===== 播放状态 =====
	var frame: int = 0
	var frame_time: float = 0.0
	## 单帧时长（1.0 / fps）预计算：_advance_layer 热路径免每帧除法
	var frame_dur: float = 0.0
	# ===== 绘制缓存 =====
	## 上一帧绘制时的 frame 与对应源矩形（frame 未变时复用，免每帧重算除法取模）
	var cached_frame: int = -1
	var cached_region: Rect2 = Rect2()

# ===== 单粒子运行时状态（轻量 RefCounted，非节点） =====
class ActiveParticle:
	## 粒子包含的绘制层（基础层在前，发射器层在后）
	## 位置/不透明度不再存于此：spawn 时已快照进各 Layer（绘制桶直接取用），
	## 此处只保留播放推进所需状态
	var layers: Array = []
	## 累计播放时长（循环粒子的硬上限计时）
	var play_time: float = 0.0

## 活跃粒子列表（spawn 追加，播完由 _process 移除）
var _active: Array = []

## 绘制分桶：tex_id → Array[Layer]，spawn 时按层纹理入桶。
## 绘制按桶遍历 → 同纹理层天然连续 → 引擎实例化合批，零每帧排序。
## 基础/发射器层各自分桶，绘制时先基础桶序再发射器桶序，保证基础在下、散射在上
var _base_buckets: Dictionary = {}
var _emitter_buckets: Dictionary = {}


func _ready() -> void:
	# 默认禁用 _process：spawn 在首个粒子入队时 set_process(true)，
	# 避免空 ParticleBatchDrawer 实例（如已关闭的 ParticleAdjust 预览）每帧空跑
	set_process(false)


# ========== 公共 API ==========

## 生成一个特效粒子（基础层 + 发射器层叠加绘制在同一位置）
## base_pack_key: 基础粒子包键（空 = 无基础层）
## emitter_pack_key: 发射器/散射粒子包键（空 = 无发射器层）
## pos: 粒子位置（本节点局部坐标）
## scale_mult: 整体缩放倍率（1.0 = 使用包声明原始尺寸，作用于基础层与发射器层）
## alpha: 整体不透明度（0-1，作用于所有层；调用方已换算好，内部不再除 100）
## emitter_scale_mult: 发射器层额外缩放倍率（在整体基础上，默认 1.5）
func spawn(base_pack_key: String, emitter_pack_key: String, pos: Vector2,
		scale_mult: float = 1.0, alpha: float = 1.0, emitter_scale_mult: float = 1.5) -> void:
	var p := ActiveParticle.new()
	var final_alpha := clampf(alpha, 0.0, 1.0)

	# 基础层（整体缩放作用于其上）
	if not base_pack_key.is_empty():
		_add_role_layer(p, base_pack_key, false, scale_mult, pos, final_alpha)
	# 发射器层（整体缩放 × 发射器缩放作用于其上）
	if not emitter_pack_key.is_empty():
		_add_role_layer(p, emitter_pack_key, true, scale_mult * emitter_scale_mult, pos, final_alpha)

	if p.layers.is_empty():
		return
	if _active.is_empty():
		set_process(true)
	_active.append(p)
	queue_redraw()


## 按角色为粒子追加一层（用 ParticleMGR 预烘焙模板：随机选一张精灵图 + 采样旋转角）
## 层创建后按 tex_id 写入对应角色分桶；pos/alpha 快照到层（绘制桶直接取用，避免循环引用）
func _add_role_layer(p: ActiveParticle, pack_key: String, is_emitter: bool, scale_mult: float,
		pos: Vector2, alpha: float) -> void:
	var tpl := ParticleMGR.get_layer_template(pack_key,
		ParticleMGR.ROLE_EMITTER if is_emitter else ParticleMGR.ROLE_BASE)
	if tpl.is_empty():
		return
	var textures: Array = tpl.get("textures", [])
	if textures.is_empty():
		return
	var tex: Texture2D = textures[randi() % textures.size()]
	var source_size: float = float(tpl.get("size", 0))
	if source_size <= 0.0:
		return

	var layer := Layer.new()
	layer.texture = tex
	layer.tex_id = int(tex.get_rid().get_id())
	layer.is_emitter = is_emitter
	layer.pos = pos
	layer.alpha = alpha
	layer.source_size = source_size
	layer.half_size = source_size * scale_mult * 0.5
	# 每层独立随机旋转角（spawn 时抽一次，整段动画固定该角；包未声明 rotation 规格 → 0）
	layer.rotation = _sample_rotation(tpl.get("rotation_spec", null))
	layer.fps = float(tpl.get("fps", 30.0))
	# 预计算单帧时长：fps<=0 时退化为 INF（与原 1.0/fps 行为一致，frame_time 永远 < INF，层不推进）
	layer.frame_dur = 1.0 / layer.fps if layer.fps > 0.0 else INF
	layer.loop = bool(tpl.get("loop", false))
	layer.fade_out = bool(tpl.get("fade_out", true))
	layer.cols = int(tpl.get("cols", 1))
	layer.rows = int(tpl.get("rows", 1))
	layer.frame_count = int(tpl.get("frame_count", 1))
	p.layers.append(layer)

	# 按层纹理入对应角色分桶（同一 tex_id 桶内全部同纹理，绘制时连续 → 合批）
	var buckets: Dictionary = _emitter_buckets if is_emitter else _base_buckets
	if not buckets.has(layer.tex_id):
		buckets[layer.tex_id] = []
	buckets[layer.tex_id].append(layer)


## 从旋转规格中采样一次该层的旋转角度（返回弧度）
## spec 为 ParticleMGR._parse_rotation 的产物：null→0；{mode:"fixed"}→固定角；
## {mode:"range"}→连续范围随机；{mode:"set"}→离散集随机；未知→0
func _sample_rotation(spec) -> float:
	if spec == null or not (spec is Dictionary):
		return 0.0
	match spec.get("mode", ""):
		"fixed":
			return deg_to_rad(float(spec.get("value", 0.0)))
		"range":
			return deg_to_rad(randf_range(float(spec.get("min", 0.0)), float(spec.get("max", 0.0))))
		"set":
			var values: Array = spec.get("values", [])
			if values.is_empty():
				return 0.0
			return deg_to_rad(float(values[randi() % values.size()]))
	return 0.0


## 清空全部粒子（游戏结束/清场时调用）
## 注意：即使 _active 已空也必须 queue_redraw——粒子播完由 _process 自清时不重绘，
## 旧绘制命令仍被引擎逐帧重放（_draw 只在 queue_redraw 后替换命令列表），画面会残留最后一帧。
## 空列表重绘一次 _draw 即擦除残留，防止退出/清场后残影卡住
func clear() -> void:
	_active.clear()
	_base_buckets.clear()
	_emitter_buckets.clear()
	set_process(false)
	queue_redraw()


# ========== 帧驱动 ==========

func _process(delta: float) -> void:
	if _active.is_empty():
		return
	var i := _active.size() - 1
	while i >= 0:
		if _advance(_active[i], delta):
			_remove_particle_buckets(_active[i])
			_active.remove_at(i)
		i -= 1
	if _active.is_empty():
		set_process(false)
		# 最后一批粒子播完：立即重绘一次擦除残留帧（否则旧绘制命令持续重放，卡住残影）
		queue_redraw()
	else:
		queue_redraw()


## 粒子播完移除：把其每层从对应分桶删除（否则残留在桶里会被持续绘制）
func _remove_particle_buckets(p: ActiveParticle) -> void:
	for layer in p.layers:
		var buckets: Dictionary = _emitter_buckets if layer.is_emitter else _base_buckets
		var arr: Variant = buckets.get(layer.tex_id)
		if arr is Array:
			arr.erase(layer)


## 推进单个粒子一帧，返回是否已播放结束（需移除）
## 所有层（非循环）都播完即结束；含循环层时受 _MAX_LOOP_PLAY_SEC 硬上限约束
func _advance(p: ActiveParticle, delta: float) -> bool:
	p.play_time += delta
	if p.play_time >= _MAX_LOOP_PLAY_SEC:
		return true
	var finished := 0
	for layer in p.layers:
		if _advance_layer(layer, delta):
			finished += 1
	return finished >= p.layers.size()


## 推进单个绘制层一帧，返回该层是否已播放结束
func _advance_layer(layer: Layer, delta: float) -> bool:
	var frame_dur := layer.frame_dur
	layer.frame_time += delta
	while layer.frame_time >= frame_dur:
		layer.frame_time -= frame_dur
		layer.frame += 1
		if layer.frame >= layer.frame_count:
			if layer.loop:
				layer.frame = 0
			else:
				return true
	return false


# ========== 批量绘制 ==========

func _draw() -> void:
	if _active.is_empty():
		return
	# 按分桶遍历绘制：先全部基础层桶（下方），再全部发射器层桶（上方）。
	# 桶内同 tex_id 同纹理 → 引擎实例化合批，零每帧排序；
	# 不同包/不同精灵图 → 各自独立桶，天然分开绘制。
	# 跨粒子顺序 = 桶序（spawn 插入序），粒子为半透明叠加，先后无可察觉差异
	for arr in _base_buckets.values():
		for layer in arr:
			_draw_layer(layer)
	for arr in _emitter_buckets.values():
		for layer in arr:
			_draw_layer(layer)


## 绘制单个层（位置/不透明度取自层快照；无旋转直绘免 transform，有旋转走 transform 画后恢复）
## 内联 _layer_region / _layer_color 热路径（每帧每层两次函数调用 → 直接展开）
func _draw_layer(layer: Layer) -> void:
	var hs := layer.half_size
	var pos := layer.pos

	# 内联 _layer_region：frame 未变时复用缓存，避免每帧重算除法取模 + 构造 Rect2
	if layer.cached_frame != layer.frame:
		layer.cached_frame = layer.frame
		var col := layer.frame % layer.cols
		@warning_ignore("integer_division")
		var row := layer.frame / layer.cols
		layer.cached_region = Rect2(col * layer.source_size, row * layer.source_size, layer.source_size, layer.source_size)
	var region := layer.cached_region

	# 内联 _layer_color：尾部淡出（最后 40% 线性降到 0），整体 alpha 乘入
	var a := layer.alpha
	if layer.fade_out and not layer.loop:
		var progress := (layer.frame + layer.frame_time * layer.fps) / float(layer.frame_count)
		if progress > 0.6:
			a *= 1.0 - (progress - 0.6) * 2.5
			if a < 0.0:
				a = 0.0
			elif a > 1.0:
				a = 1.0
	var tint_color := Color(1.0, 1.0, 1.0, a)

	if layer.rotation == 0.0:
		draw_texture_rect_region(layer.texture, Rect2(pos.x - hs, pos.y - hs, hs * 2.0, hs * 2.0), region, tint_color)
	else:
		draw_set_transform(pos, layer.rotation, Vector2.ONE)
		draw_texture_rect_region(layer.texture, Rect2(-hs, -hs, hs * 2.0, hs * 2.0), region, tint_color)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
