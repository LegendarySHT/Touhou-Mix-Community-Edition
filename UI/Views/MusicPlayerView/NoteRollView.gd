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
## 窗口漂移超过 CACHE_STEP_MS 才重扫；重扫只遍历窗口内音符（起点二分定位），
## 开销不随全曲音符数增长。
## _draw 照 TrackView NoteDrawNode 的套路：音符矩形建时算定（尺寸固定，每帧只写
## position.y/size.y），亮度渐变按 16 档预乘进 LUT——每帧循环内零 Variant 分配。

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
## 亮度渐变分档：接近发声点的渐亮量化成档位预乘进颜色表，_draw 循环内不构造 Color
const BRIGHT_STEPS := 16
## 渐亮区间（毫秒）与最暗档，复刻原 bright = clampf(1 - lead/500, 0.28, 1) 曲线
const BRIGHT_SPAN_MS := 500.0
const BRIGHT_MIN := 0.28

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
## 绘制列表（窗口内音符）。元素为预缓存的 NoteItem：矩形尺寸建时算定，
## y 每帧由当前播放头现算（这是滚动平滑的关键）
var _notes: Array[NoteItem] = []
## NoteItem 回收池：重扫每 120ms 一次，复用对象避免分配churn
var _pool: Array[NoteItem] = []
## 轨道色 × 亮度档位预乘表：_color_lut[track][level]，level 0 = 全亮
var _color_lut: Array = []
## 上次重扫时的播放头位置
var _cache_pos_ms: float = -1.0
var _cache_size: Vector2 = Vector2.ZERO
## 全曲最大音符时长（tick），窗口起点回溯量（见 _rebuild_note_list）
var _max_dur_ticks: float = 0.0

## 单个窗口音符的绘制状态（同 TrackView.NoteState：静态字段建时算定，每帧只写矩形 y）
class NoteItem:
	extends RefCounted
	var rect := Rect2()   # x / size.x 建时算定；position.y / size.y 每帧由 _draw 更新
	var s_k := 0.0        # start_ms × k（k = h/VIEW_SPAN_MS），y_head = y_off − s_k
	var e_k := 0.0        # 有效 end_ms（含 MIN_DURATION 下限）× k
	var s_ms := 0.0       # 起始时刻（算亮度档位用）
	var lut: Array[Color] = []   # 本音符轨道的亮度分档颜色行

func _ready() -> void:
	_build_color_lut()
	set_process(true)

## 预乘亮度表：f(level) = clampf(1 − level/STEPS, BRIGHT_MIN, 1)
func _build_color_lut() -> void:
	if not _color_lut.is_empty():
		return
	for c in TRACK_COLORS:
		var row: Array[Color] = []
		row.resize(BRIGHT_STEPS + 1)
		for lv in BRIGHT_STEPS + 1:
			var f := 1.0 if lv == 0 else maxf(BRIGHT_MIN, 1.0 - lv / float(BRIGHT_STEPS))
			row[lv] = Color(c.r, c.g, c.b, c.a * f)
		_color_lut.append(row)

func _process(_delta: float) -> void:
	var mgr := PlaybackDisplay.instance
	if mgr == null or not is_visible_in_tree():
		return
	var pos := mgr.get_realtime_position_ms()
	# 暂停且播放头没动（无 seek）时不重绘
	if pos == _pos_ms and not mgr.is_playing:
		return
	_pos_ms = pos
	queue_redraw()

func bind(data: MidiData) -> void:
	_soa = data.notes_soa if data != null else null
	_max_dur_ticks = float(_soa.max_duration_ticks()) if _soa != null else 0.0
	_cache_pos_ms = -1.0
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
	# 每帧常量提到循环外：y_head/y_tail 各只需一次减法（s_k/e_k 已预乘 k），
	# 矩形与颜色全部复用缓存对象，循环内零 Variant 分配
	var k := maxf(1.0, h) / VIEW_SPAN_MS
	var y_off := h + _pos_ms * k
	var bright_inv := BRIGHT_STEPS / BRIGHT_SPAN_MS
	for n: NoteItem in _notes:
		var y_head := y_off - n.s_k
		# 仅当整体在视野外才剔除；部分越界时裁剪绘制，
		# 这样音符才能从画面上缘滑入、下缘滑出，而不是整块凭空冒出
		if y_head < 0.0:
			continue
		var y_tail := y_off - n.e_k
		if y_tail > h:
			continue
		var top := y_tail if y_tail > 0.0 else 0.0
		var nh := (y_head if y_head < h else h) - top
		if nh < MIN_NOTE_H:
			nh = MIN_NOTE_H
		# 亮度只看「离发声点还有多久」：未来音符越接近越亮，一旦到达发声点
		# （头部越过下边缘）就保持最亮不再变暗——长音符完全流出前不会又暗下去
		var lv := int((n.s_ms - _pos_ms) * bright_inv)
		if lv < 0:
			lv = 0
		elif lv > BRIGHT_STEPS:
			lv = BRIGHT_STEPS
		n.rect.position.y = top
		n.rect.size.y = nh
		draw_rect(n.rect, n.lut[lv], true)

## 发声点 = 控件下边缘：音符头部（起始时间）到达此处即开始离开节点，此时发声
func head_y() -> float:
	return size.y

func ms_per_px() -> float:
	return VIEW_SPAN_MS / maxf(1.0, head_y())

## 重建可视窗口（含余量）内的音符列表：矩形静态字段预缓存进 NoteItem。
## 只遍历窗口内音符——_start_ticks 升序，先二分定位窗口起点（起点回溯一个最大时长，
## 避免漏掉"起始在窗口前、尾部仍落在窗口内"的长音符），再顺序扫到窗口末尾提前退出。
## 原先是从头遍历全曲（22w 音符）并且每音符两次 tick→ms 二分，每 120ms 一次，是卡顿主因。
## NoteItem 从池里取，旧窗口元素全部回收复用。
func _rebuild_note_list(w: float, h: float) -> void:
	_pool.append_array(_notes)
	_notes.clear()
	_cache_pos_ms = _pos_ms
	_cache_size = size
	if _soa == null:
		return
	if _color_lut.is_empty():
		_build_color_lut()
	var n_rows := PITCH_HIGH - PITCH_LOW
	var row_h := w / float(n_rows)
	if row_h <= 0.0:
		return
	var note_w := maxf(2.0, row_h - COL_GAP)
	var k := maxf(1.0, h) / VIEW_SPAN_MS
	var hi := _pos_ms + VIEW_SPAN_MS + CACHE_MARGIN_MS
	var lo := _pos_ms - (h - head_y()) * ms_per_px() - CACHE_MARGIN_MS
	var lo_tick := _soa.ms_to_tick(lo)
	# 起点二分要再回溯一个最大时长，否则会漏掉"起始在窗口前、尾部仍在窗口内"的长音符
	var scan_tick := lo_tick - _max_dur_ticks
	var hi_tick := _soa.ms_to_tick(hi)
	var n := _soa.size()
	var idx0 := _soa.first_index_from_start_tick(scan_tick)
	for i in range(idx0, n):
		var s_tick := _soa.start_tick(i)
		if s_tick > hi_tick:
			break                      # 升序：后面的只会更晚
		if _soa.end_tick(i) < lo_tick:
			continue
		var pitch := _soa.pitch(i)
		if pitch < PITCH_LOW or pitch > PITCH_HIGH:
			continue
		# 音高越高越靠左列（横向即"琴键"）
		var x := (n_rows - 1 - (pitch - PITCH_LOW)) * row_h
		var ti: int = _soa.track(i)
		var s_ms := _soa.start_tick_ms(i)
		var it: NoteItem = _pool.pop_back() if not _pool.is_empty() else NoteItem.new()
		it.rect.position.x = x
		it.rect.size.x = note_w
		it.s_ms = s_ms
		it.s_k = s_ms * k
		it.e_k = maxf(_soa.end_tick_ms(i), s_ms + MIN_DURATION_MS) * k
		it.lut = _color_lut[ti % _color_lut.size()]
		_notes.append(it)
