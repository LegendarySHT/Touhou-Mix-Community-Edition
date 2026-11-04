extends Control
## 钢琴卷帘式音符可视化
##
## 数据源是 MidiData.notes_soa（6 个并行紧凑数组），不是实时频谱——miniaudio 的
## 数据回调不回读音频给 Godot，频谱/波形做不出来（需改 C 层加 FFT，代价过高）。
##
## 画法：横轴 = 音高（一格一个半音，同音高的音符天然对齐成一列），纵轴 = 时间。
## 未来的音符从顶部滑入，越接近下边缘越亮，尾部从下边缘流出。
## 发声时刻 = 音符开始离开节点（头部到达下边缘）的时刻，不再画播放线。
## 颜色按音符所属 track 取 TrackView 同款配色表。
##
## 绘制：x/宽度是静态实例变换，y/高度/亮度由 canvas_item shader 按播放头现算。
## 音符写入 MultiMesh 的圆形槽，每帧只更新两个 uniform 并追加「本帧新进入窗口」
## 的音符；seek/循环跳变/bind/resize 时才清槽重填。窗口外的旧槽由 shader 退化
## 顶点自动剔除，不需要逐帧清理。

## 视窗时长：从下边缘（发声点）往上能看到的时间跨度。越大音符越小（同屏提前量越多）
const VIEW_SPAN_MS := 1400.0
## 单个音符的最小可见高度（像素）
const MIN_NOTE_H := 3.0
## 时长下限（毫秒）：极短/零长音符也要有一小段可见高度
const MIN_DURATION_MS := 40.0
## 音高显示范围（一格一个半音）
const PITCH_LOW := 21
const PITCH_HIGH := 108
## 列间距
const COL_GAP := 2.0
## 亮度渐变分档（shader 内按同一公式量化）
const BRIGHT_STEPS := 16
## 渐亮区间（毫秒）与最暗档
const BRIGHT_SPAN_MS := 500.0
const BRIGHT_MIN := 0.28

## 圆形槽容量：2.1s 窗口内极端谱面约 1500-2000 条，8192 留有余量
const SLOT_CAP := 8192
## 提前量（毫秒）：音符可见前先写入槽，覆盖两次追加之间的时间
const ENTER_MARGIN_MS := 700.0
## 回溯窗口下限/上限（毫秒）：seek/bind 时向后补「起始在播放头之前」的长音符
const LOOKBACK_MIN_MS := 3000.0
const LOOKBACK_MAX_MS := 15000.0
## 向后回溯最多走多少条 SOA 索引（避免超长音符 + 极密谱面下扫全曲）
const BACKWALK_STEPS := 4096
## 单个实例 buffer 的 float 数：8 变换 + 4 颜色 + 4 自定义数据
const SLOT_STRIDE := 16
## 固定外包盒的边距（像素）：盖住最小高度在底边的溢出与浮点误差
const AABB_MARGIN := 8.0

## 轨道配色表（照 TrackView/midiTrack.gd 的 colors_set，视觉一致）
const TRACK_COLORS := [
	Color("#FF5C6C"), Color("#FF5CA8"), Color("#FF8C42"), Color("#FFC24B"),
	Color("#A8E05F"), Color("#3ED88C"), Color("#2AD4C4"), Color("#35C8E8"),
	Color("#5B8CFF"), Color("#6C6CFF"), Color("#A06BFF"), Color("#E05CFF"),
	Color("#FF6B9D"),
]

const NOTE_ROLL_SHADER: Shader = preload("res://UI/Views/MusicPlayerView/NoteRoll.gdshader")

var _soa: NoteSoa = null
## 当前 MIDI 数据（回溯上限用其最大音符时长与 BPM 时间线）
var _midi: MidiData = null
## 播放头位置（毫秒），_process 里随播放推进
var _pos_ms: float = 0.0
## 下一个写入的圆形槽
var _slot: int = 0
## 已写入的槽数量（实例可见前缀长度）
var _used: int = 0
## soa 中下一个待追加索引（按 start 升序，只增）
var _cursor: int = 0
## 上一帧播放头（判定 seek / 循环跳变）
var _last_pos_ms: float = -1.0
## 回溯窗口上限（毫秒）：最大音符时长 × 最慢 BPM 换算后 clamp
var _max_dur_ms: float = 10000.0
## 布局缓存：单列宽与音符宽（resize 时重算）
var _row_h: float = 0.0
var _note_w: float = 2.0
## 全 0 槽 buffer：复位时整块写回，零矩阵不产生像素
var _zero_buffer: PackedFloat32Array = PackedFloat32Array()

var _mm: MultiMesh
var _mmi: MultiMeshInstance2D
var _mat: ShaderMaterial

func _ready() -> void:
	_mm = MultiMesh.new()
	# flags 必须先于 instance_count 设好：按最终 stride 分配底层 buffer
	_mm.transform_format = MultiMesh.TRANSFORM_2D
	_mm.use_colors = true
	_mm.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_mm.mesh = quad
	_mm.instance_count = SLOT_CAP
	_update_custom_aabb()
	_zero_buffer.resize(SLOT_CAP * SLOT_STRIDE)
	_mm.set_buffer(_zero_buffer)
	_mm.visible_instance_count = 0

	_mmi = MultiMeshInstance2D.new()
	_mmi.multimesh = _mm
	_mmi.texture = _make_white_texture()
	_mat = ShaderMaterial.new()
	_mat.shader = NOTE_ROLL_SHADER
	_apply_static_shader_params()
	_mmi.material = _mat
	_mmi.visible = false
	add_child(_mmi)

	_update_layout_metrics()
	_update_max_dur_ms()
	resized.connect(_on_resized)
	_on_resized()
	set_process(true)

## 固定外包盒（实例空间 = 节点局部坐标）：x 是列布局、y 是 shader 现算的像素 y。
## 指定后引擎不再按可见实例逐个重算 AABB，也不再每帧发 AABB 变更通知。
func _update_custom_aabb() -> void:
	if _mm == null:
		return
	var w := maxf(size.x, 1.0) + AABB_MARGIN * 2.0
	var h := maxf(size.y, 1.0) + AABB_MARGIN * 2.0
	_mm.custom_aabb = AABB(Vector3(-AABB_MARGIN, -AABB_MARGIN, 0.0), Vector3(w, h, 0.0))

## 1×1 白贴图：shader 自己采样 TEXTURE，缺省贴图语义不够明确
func _make_white_texture() -> ImageTexture:
	var img := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)

func _process(_delta: float) -> void:
	var mgr := PlaybackDisplay.instance
	if mgr == null or not is_visible_in_tree():
		return
	var pos := mgr.get_realtime_position_ms()
	# 暂停且播放头没动（无 seek）时画面冻结，不更新 uniform
	if pos == _pos_ms and not mgr.is_playing:
		return
	if size.x <= 0.0 or size.y <= 0.0:
		return
	_pos_ms = pos

	if pos < _last_pos_ms or pos > _last_pos_ms + 3000.0:
		_refill(pos)          # seek / 循环跳回：清槽重填窗口
	else:
		_append_until(pos)    # 只追加本帧新进入窗口的音符
		_last_pos_ms = pos

	_mat.set_shader_parameter("u_pos_ms", pos)
	_mat.set_shader_parameter("u_view_h", size.y)

## 发声点 = 控件下边缘：音符头部（起始时间）到达此处即开始离开节点，此时发声
func head_y() -> float:
	return size.y

func ms_per_px() -> float:
	return VIEW_SPAN_MS / maxf(1.0, head_y())

func bind(data: MidiData) -> void:
	_midi = data
	_soa = data.notes_soa if data != null else null
	_update_max_dur_ms()
	_slot = 0
	_used = 0
	_cursor = 0
	_last_pos_ms = -1.0
	_clear_slots()
	if _soa != null and _soa.size() > 0:
		var pos := _pos_ms if _pos_ms >= 0.0 else 0.0
		_refill(pos)
	_sync_mmi_visibility()

## 回溯上限：全曲最大音符时长按最慢 BPM 换成毫秒（最慢 = 每 tick 毫秒数最大）
func _update_max_dur_ms() -> void:
	var dur_ms := 10000.0
	if _midi != null and _midi.max_note_duration_ticks > 0.0:
		var min_bpm := _min_bpm(_midi.bpm_timeline)
		var timebase := _midi.midi_timebase
		if timebase <= 0:
			timebase = 480
		if min_bpm > 0.0:
			var min_ms_per_tick := 60000.0 / min_bpm / float(timebase)
			dur_ms = _midi.max_note_duration_ticks * min_ms_per_tick * 1.5
	_max_dur_ms = clampf(dur_ms, LOOKBACK_MIN_MS, LOOKBACK_MAX_MS)

## BPM 时间线里的最小 BPM（0 = 时间线为空/无有效项）
func _min_bpm(timeline: Array) -> float:
	var min_bpm := 0.0
	for e in timeline:
		if not (e is Dictionary):
			continue
		var bpm := float(e.get("bpm", 0.0))
		if bpm > 0.0 and (min_bpm <= 0.0 or bpm < min_bpm):
			min_bpm = bpm
	return min_bpm

## 重算列宽与音符宽（横向几何只随控件宽度变化）
func _update_layout_metrics() -> void:
	var n_rows := PITCH_HIGH - PITCH_LOW
	if size.x > 0.0:
		_row_h = size.x / float(n_rows)
	else:
		_row_h = 0.0
	_note_w = maxf(2.0, _row_h - COL_GAP)

func _on_resized() -> void:
	_update_max_dur_ms()
	var pos := _last_pos_ms
	if pos < 0.0:
		pos = _pos_ms if _pos_ms >= 0.0 else 0.0
	_refill(pos)
	_sync_mmi_visibility()

## 清空全部槽：全 0 buffer 是零矩阵，实例退化到不产生像素
func _clear_slots() -> void:
	_mm.set_buffer(_zero_buffer)
	_mm.visible_instance_count = 0

## 可见实例只取前缀 0.._used-1（写入按槽序递增）
func _sync_visible_count() -> void:
	_mm.visible_instance_count = _used

## 尺寸非法时不绘制（宽或高为 0 时没有可见区域）
func _sync_mmi_visibility() -> void:
	if _mmi == null:
		return
	_mmi.visible = size.x > 0.0 and size.y > 0.0

## 把 GDScript 侧常量写进 shader uniform，保持与 shader 默认值同源
func _apply_static_shader_params() -> void:
	_mat.set_shader_parameter("u_span_ms", VIEW_SPAN_MS)
	_mat.set_shader_parameter("u_min_note_h", MIN_NOTE_H)
	_mat.set_shader_parameter("u_bright_steps", float(BRIGHT_STEPS))
	_mat.set_shader_parameter("u_bright_span", BRIGHT_SPAN_MS)
	_mat.set_shader_parameter("u_bright_min", BRIGHT_MIN)

func _apply_uniforms(pos_ms: float) -> void:
	_mat.set_shader_parameter("u_pos_ms", pos_ms)
	_mat.set_shader_parameter("u_view_h", size.y)

## 清槽并重建当前窗口：向后收长音符，再向前补满（含提前量）。
## 只在 seek / 循环跳变 / bind / resize 时调用；播放中走 _append_until 增量追加。
func _refill(pos_ms: float) -> void:
	# 重算列宽：bind 可能早于首次 resized 信号（此时缓存还是初始值）
	_update_layout_metrics()
	_update_custom_aabb()
	_slot = 0
	_used = 0
	_cursor = 0
	_clear_slots()
	_last_pos_ms = pos_ms
	if _soa != null and _soa.size() > 0 and size.x > 0.0 and size.y > 0.0:
		var first := _soa.first_index_from_start_tick(_soa.ms_to_tick(pos_ms))
		# 向后：起始在播放头之前、尾部仍落在窗口内的长音符
		var back := first - 1
		var steps := 0
		var low_ms := pos_ms - _max_dur_ms
		while back >= 0 and steps < BACKWALK_STEPS:
			if _soa.start_tick_ms(back) < low_ms:
				break
			if _soa.end_tick_ms(back) > pos_ms:
				_write_note(back)
			back -= 1
			steps += 1
		# 向前：从第一个 start >= 播放头的位置补满窗口
		_cursor = first
		_append_until(pos_ms)
	_apply_uniforms(pos_ms)

## 追加 start 时刻进入「播放头 + 视窗 + 提前量」的音符；只推进游标，不回扫
func _append_until(pos_ms: float) -> void:
	if _soa == null:
		return
	var limit_ms := pos_ms + VIEW_SPAN_MS + ENTER_MARGIN_MS
	var n := _soa.size()
	while _cursor < n:
		if _soa.start_tick_ms(_cursor) >= limit_ms:
			break
		_write_note(_cursor)
		_cursor += 1
	_sync_visible_count()

## 写入一个音符到圆形槽：x/宽度进实例变换，时间进自定义数据，y/高度/亮度由 shader 算
func _write_note(idx: int) -> void:
	if _soa == null or _row_h <= 0.0:
		return
	var pitch := _soa.pitch(idx)
	if pitch < PITCH_LOW or pitch > PITCH_HIGH:
		return
	var s_ms := _soa.start_tick_ms(idx)
	var e_ms := _soa.end_tick_ms(idx)
	var n_rows := PITCH_HIGH - PITCH_LOW
	# 音高越高越靠左列（横向即"琴键"）
	var x := float(n_rows - 1 - (pitch - PITCH_LOW)) * _row_h
	var ti := _soa.track(idx)
	var col: Color = TRACK_COLORS[ti % TRACK_COLORS.size()]
	# QuadMesh 1x1 以原点为中心：x 轴缩放 = 音符宽，origin.x = 左边缘 + 半宽
	_mm.set_instance_transform_2d(_slot, Transform2D(
		Vector2(_note_w, 0.0), Vector2(0.0, 1.0), Vector2(x + _note_w * 0.5, 0.0)))
	_mm.set_instance_color(_slot, Color(col.r, col.g, col.b, 1.0))
	_mm.set_instance_custom_data(_slot, Color(s_ms, maxf(e_ms, s_ms + MIN_DURATION_MS), 0.0, 0.0))
	_slot = (_slot + 1) % SLOT_CAP
	if _used < SLOT_CAP:
		_used += 1
