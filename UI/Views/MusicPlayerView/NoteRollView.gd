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
## 平滑滚动：缓存里只存音符的【时间】，y 坐标每帧由当前播放头现算——
## 早期版本缓存的是算好的像素坐标且每 40ms 才重建一次，两次重建之间整批不动、
## 更新时整批跳一格，视觉上音符是"凭空冒出来"的而不是滑入。
## 为控制每帧开销，缓存的可见窗口比实际视窗两端各多留 CACHE_MARGIN_MS，
## 窗口漂移超过 CACHE_STEP_MS 才重扫（大谱面 22w 音符不能每帧全扫）。

## 视窗时长：从下边缘（发声点）往上能看到的时间跨度。越大音符越小（同屏提前量越多）
const VIEW_SPAN_MS := 1400.0
## 单个音符的最小可见高度（像素）
const MIN_NOTE_H := 3.0
## 时长下限（毫秒）：极短/零长音符也要有一小段可见高度
const MIN_DURATION_MS := 40.0
## 音高显示范围（一格一个半音）
const PITCH_LOW := 21
const PITCH_HIGH := 108
## 缓存窗口相对视窗的两侧余量：新音符必须提前进入缓存，否则会延迟冒头
const CACHE_MARGIN_MS := 200.0
## 播放头漂移超过此值才重扫全量音符
const CACHE_STEP_MS := 120.0
## 列间距
const COL_GAP := 2.0

## 轨道配色表（照 TrackView/midiTrack.gd 的 colors_set，视觉一致）
const TRACK_COLORS := [
	Color("#FF5C6C"), Color("#FF5CA8"), Color("#FF8C42"), Color("#FFC24B"),
	Color("#A8E05F"), Color("#3ED88C"), Color("#2AD4C4"), Color("#35C8E8"),
	Color("#5B8CFF"), Color("#6C6CFF"), Color("#A06BFF"), Color("#E05CFF"),
	Color("#FF6B9D"),
]

var _soa: NoteSoa = null
## 播放头位置（毫秒），_process 里随播放推进
var _pos_ms: float = 0.0
## 绘制列表：[x, s_ms, e_ms, color, note_w]。bind 时构建——只存时间不存像素，
## y 每帧由当前播放头现算（这是滚动平滑的关键）
var _notes: Array = []
## 上次重扫时的播放头位置
var _cache_pos_ms: float = -1.0
var _cache_size: Vector2 = Vector2.ZERO

func _ready() -> void:
	set_process(true)

func bind(data: MidiData) -> void:
	_soa = data.notes_soa if data != null else null
	_cache_pos_ms = -1.0
	queue_redraw()

func _process(_delta: float) -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr == null:
		return
	_pos_ms = mgr.get_realtime_position_ms()
	queue_redraw()

func _draw() -> void:
	if _soa == null or _soa.size() == 0:
		return
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return

	# 窗口漂移超阈值或尺寸变化时重扫（缓存只存时间，重扫不频繁）
	if _cache_pos_ms < 0.0 or absf(_pos_ms - _cache_pos_ms) > CACHE_STEP_MS \
			or _cache_size != size:
		_rebuild_note_list(w, h)
	for e in _notes:
		var s_ms: float = e[1]
		var e_ms: float = e[2]
		# y 每帧由当前播放头现算 → 逐帧平滑滑动。
		# 音符两端各算一个 y：结束时间（尾端）在上、起始时间（首端）在下，
		# 矩形 = [尾端, 首端]，高度直接由时长换算 → 长音符画长条。
		var k := 1.0 / ms_per_px()
		var y_head := head_y() - (s_ms - _pos_ms) * k
		var y_tail := head_y() - (maxf(e_ms, s_ms + MIN_DURATION_MS) - _pos_ms) * k
		# 仅当整体在视野外才剔除；部分越界时裁剪绘制，
		# 这样音符才能从画面上缘滑入、下缘滑出，而不是整块凭空冒出
		if y_head < 0.0 or y_tail > h:
			continue
		var top := maxf(y_tail, 0.0)
		var bot := minf(y_head, h)
		var nh := maxf(bot - top, MIN_NOTE_H)
		# 亮度只看「离发声点还有多久」：未来音符越接近越亮，一旦到达发声点
		# （头部越过下边缘）就保持最亮不再变暗——长音符完全流出前不会又暗下去
		var lead: float = s_ms - _pos_ms
		var bright: float = 1.0 if lead <= 0.0 else clampf(1.0 - lead / 500.0, 0.28, 1.0)
		var col: Color = e[3]
		draw_rect(Rect2(e[0], top, e[4], nh),
			Color(col.r, col.g, col.b, col.a * bright), true)

## 发声点 = 控件下边缘：音符头部（起始时间）到达此处即开始离开节点，此时发声
func head_y() -> float:
	return size.y

func ms_per_px() -> float:
	return VIEW_SPAN_MS / maxf(1.0, head_y())

## 重扫全量音符，缓存可视窗口（含余量）内的音符：x / 时间 / 颜色。
func _rebuild_note_list(w: float, h: float) -> void:
	_notes.clear()
	_cache_pos_ms = _pos_ms
	_cache_size = size
	if _soa == null:
		return
	var n_rows := PITCH_HIGH - PITCH_LOW
	var row_h := w / float(n_rows)
	if row_h <= 0.0:
		return
	var note_w := maxf(2.0, row_h - COL_GAP)
	var hi := _pos_ms + VIEW_SPAN_MS + CACHE_MARGIN_MS
	var lo := _pos_ms - (h - head_y()) * ms_per_px() - CACHE_MARGIN_MS
	var n := _soa.size()
	for i in n:
		var pitch := _soa.pitch(i)
		if pitch < PITCH_LOW or pitch > PITCH_HIGH:
			continue
		var s_ms := _soa.start_tick_ms(i)
		if s_ms > hi:
			continue
		if _soa.end_tick_ms(i) < lo:
			continue
		# 音高越高越靠左列（横向即"琴键"）
		var x := (n_rows - 1 - (pitch - PITCH_LOW)) * row_h
		var ti: int = _soa.track(i)
		var col: Color = TRACK_COLORS[ti % TRACK_COLORS.size()]
		_notes.append([x, s_ms, _soa.end_tick_ms(i), col, note_w])
