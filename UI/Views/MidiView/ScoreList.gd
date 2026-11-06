extends BaseScrollList

class_name ScoreList

## 排行榜单次加载条数
const LOAD_LIMIT := 50

## 当前关联的 MIDI（用于刷新）
var _current_midi: MidiData = null

## 加载中标记
var _loading: bool = false

## 请求版本号：快速切换 MIDI 时丢弃过期响应
var _request_version: int = 0

## FailMessage 显示前的标签页索引（隐藏时恢复，见 _hide_message）
var _fail_prev_tab: int = -1

## 待显示的提示信息：排行榜标签页未激活时先缓存，切回时经 FailMessage 展示
var _pending_message: String = ""

## 「在线模式已开启但尚未连上服务器」的等待标记
## 连接成功后据此自动刷新排行榜
var _waiting_online: bool = false

## 当前 MIDI 是否已经得到过一次有效的在线排行榜响应。
## 空排行榜也是有效响应，不能再被后续连接状态提示覆盖。
var _has_loaded_online_result: bool = false

## Top 汇总行（OptionPanel/OptTabs/RankPanel/Total）是 ScoreList 的兄弟节点。
## 用相对路径取，不必给场景节点加 unique_name_in_owner。
@onready var _stats_label: Label = get_node_or_null("../Total") as Label

## 汇总行降级文案：拿不到在线数据时显示一句提示，绝不回落占位假数字。
const _STATS_LOADING: String = "在线统计加载中..."
const _STATS_OFFLINE: String = "离线模式，暂无在线统计"
const _STATS_CONNECTING: String = "正在连接在线服务..."
const _STATS_UNAVAILABLE: String = "在线统计暂不可用"
const _STATS_EMPTY: String = "暂无在线成绩统计"

func _ready() -> void:
	super._ready()
	EvtBus.online_state_changed.connect(_on_online_state_changed)
	EvtBus.score_uploaded.connect(_on_score_uploaded)
	if _stats_label == null:
		GLogger.warning("RankPanel/Total not found, online stats line disabled", "ScoreList")

## 可见性变化：排行榜标签页切回时把缓存的消息经 FailMessage 展示
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree() \
			and not _pending_message.is_empty():
		_apply_message()

## 连接状态变化：区分在线模式关闭、连接中、连接失败，并在连接成功后补刷。
## 不依赖 ScoreList 是否当前显示：排行榜页可能是 TabContainer 的非当前页，
## 但仍应在进入 MidiView 后及时拿到已经建立的连接结果。
func _on_online_state_changed(state: int, _latency_ms: int) -> void:
	if _current_midi == null:
		return

	match state:
		NetManager.ConnectState.OFFLINE_MODE:
			# 在线模式被关闭时切回本地最佳成绩。
			load_scores(_current_midi)
		NetManager.ConnectState.CONNECTING:
			if _has_loaded_online_result:
				return
			_waiting_online = true
			_set_stats_message(_STATS_CONNECTING)
			_show_message("正在连接在线服务...")
		NetManager.ConnectState.FAILED:
			if _has_loaded_online_result:
				return
			_waiting_online = true
			_set_stats_message(_STATS_UNAVAILABLE)
			_show_message("无法连接到在线服务器，请检查网络设置")
		NetManager.ConnectState.ONLINE:
			if _waiting_online:
				load_scores(_current_midi)

## 成绩上传完成后刷新当前 MIDI，覆盖用户快速返回 MidiView 时的竞态。
func _on_score_uploaded(midi_hash: String) -> void:
	if _current_midi == null or _current_midi.file_hash != midi_hash:
		return
	if NetManager.instance == null or NetManager.instance.connect_state != NetManager.ConnectState.ONLINE:
		return
	load_scores(_current_midi)

## 加载排行榜数据 + 顶部汇总行（汇总行取 /api/scores/stats 的全服聚合统计）
## midi: 要查询的 MidiData（使用 file_hash 作为 key）
func load_scores(midi: MidiData) -> void:
	_current_midi = midi
	_request_version += 1
	var request_version := _request_version
	_hide_message()
	clear_items()
	_loading = false
	_waiting_online = false
	_has_loaded_online_result = false
	# 每次刷新先清掉上一首谱面的统计，避免过期数值残留
	_set_stats_message(_STATS_LOADING)

	if NetManager.instance == null:
		_set_stats_message(_STATS_UNAVAILABLE)
		_show_message("在线服务未就绪")
		return

	# 在线模式关闭：显示本地最佳成绩（离线排行榜），无论服务器是否可达
	if NetManager.instance.connect_state == NetManager.ConnectState.OFFLINE_MODE:
		_set_stats_message(_STATS_OFFLINE)
		_show_local_best(midi)
		return

	# 在线模式开启但尚未建立连接：按连接阶段显示具体状态，不伪装成未开启。
	if NetManager.instance.connect_state == NetManager.ConnectState.CONNECTING:
		_waiting_online = true
		_set_stats_message(_STATS_CONNECTING)
		_show_message("正在连接在线服务...")
		return
	if NetManager.instance.connect_state == NetManager.ConnectState.FAILED:
		_waiting_online = true
		_set_stats_message(_STATS_UNAVAILABLE)
		_show_message("无法连接到在线服务器，请检查网络设置")
		return
	if not NetManager.instance.is_online:
		_waiting_online = true
		_set_stats_message(_STATS_UNAVAILABLE)
		_show_message("在线服务连接已失效，正在重试...")
		return

	if midi == null or midi.file_hash.is_empty():
		_set_stats_message(_STATS_UNAVAILABLE)
		_show_message("无法获取 MIDI 信息")
		return

	if ScoreManager.instance == null:
		_set_stats_message(_STATS_UNAVAILABLE)
		_show_message("成绩服务未就绪")
		return

	_loading = true
	_show_message("加载中...")

	var result = await ScoreManager.instance.get_leaderboard(midi.file_hash, LOAD_LIMIT, 0)
	if request_version != _request_version:
		return  # 已有更新的请求，丢弃过期响应
	_loading = false

	if not result.get("ok", false):
		_set_stats_message(_STATS_UNAVAILABLE)
		_show_message("加载失败")
		return

	var data = result.get("data")
	if data == null or not data is Dictionary:
		_set_stats_message(_STATS_UNAVAILABLE)
		_show_message("数据格式错误")
		return

	var scores = data.get("scores", [])
	_has_loaded_online_result = true
	if scores.is_empty():
		_set_stats_message(_STATS_EMPTY)
		_show_message("暂无成绩记录")
		return

	_hide_message()
	clear_items()
	for i in range(scores.size()):
		var s = scores[i]
		var node = create_and_add_item(str(s.get("id", i)), "score")
		var rank_pos := i + 1  # 排名从 1 开始
		var accuracy_pct := float(s.get("accuracy", 0.0)) * 100.0
		var rank_str := str(s.get("rank", "F"))
		node.setup_score(
			rank_pos,
			int(s.get("totalScore", 0)),
			rank_str,
			accuracy_pct,
			float(s.get("pp", 0.0)),
			int(s.get("maxCombo", 0)),
			int(s.get("perfectCount", 0)),
			int(s.get("greatCount", 0)),
			int(s.get("goodCount", 0)),
			int(s.get("badCount", 0)),
			int(s.get("missCount", 0))
		)
		# W 评级（中途退出）：整体半透明
		node.set_withdraw_state(rank_str == "W")
		# 填充玩家名
		var username = s.get("username")
		var name_label = node.get_node_or_null("Name")
		if name_label:
			name_label.text = username if username != null and not str(username).is_empty() else "Anonymous"
		# 加载玩家头像（服务端返回 avatarUrl，可能为 null）
		var avatar_url = s.get("avatarUrl")
		var avatar_url_str := str(avatar_url) if avatar_url != null else ""
		node.setup_avatar(avatar_url_str)

	# 列表渲染完后再取全服聚合统计：只在确实有在线成绩时才请求，
	# 与列表共用 request_version，切谱面时丢弃过期响应。
	await _load_stats(midi.file_hash, request_version)

## 拉取 /api/scores/stats 并刷新 RankPanel/Total 汇总行。
## 字段口径：totalPlays = 全服非 W（中途退出）游玩次数，avgScore/avgPp/avgAccuracy 为均值；
## avgAccuracy 是 0~1 的比率，与 ScoreListItem / PlayerInfoContent 一致，×100 后显示百分比。
func _load_stats(midi_hash: String, request_version: int) -> void:
	if ScoreManager.instance == null:
		_set_stats_message(_STATS_UNAVAILABLE)
		return
	var result: Dictionary = await ScoreManager.instance.get_stats(midi_hash)
	if request_version != _request_version:
		return  # 切谱面了，丢弃过期统计
	if not result.get("ok", false):
		# 404：服务端该谱面还没有任何非 W 成绩
		if int(result.get("status", 0)) == 404:
			_set_stats_message(_STATS_EMPTY)
		else:
			_set_stats_message(_STATS_UNAVAILABLE)
		return
	var data: Variant = result.get("data")
	if data == null or not data is Dictionary:
		_set_stats_message(_STATS_UNAVAILABLE)
		return
	var s: Dictionary = data
	var line := "游玩次数 %d | 平均成绩 %.0f | 平均PP %.2f | 平均准度 %.2f%%" % [
		int(s.get("totalPlays", 0)),
		float(s.get("avgScore", 0.0)),
		float(s.get("avgPp", 0.0)),
		float(s.get("avgAccuracy", 0.0)) * 100.0,
	]
	_set_stats_message(line)

## 只改汇总行文案（Label 缺失时静默跳过，不影响排行榜本身）
func _set_stats_message(msg: String) -> void:
	if _stats_label != null:
		_stats_label.text = msg

## 显示本地最佳成绩（单条，离线排行榜）
## 未登录/在线模式关闭时使用，仅展示本机每首 pp 最高的记录
func _show_local_best(midi: MidiData) -> void:
	if midi == null or midi.file_hash.is_empty():
		_show_message("无法获取 MIDI 信息")
		return
	if ScoreManager.instance == null:
		_show_message("成绩服务未就绪")
		return
	var local := ScoreManager.instance.get_local_best(midi.file_hash)
	if local.is_empty():
		_show_message("暂无本地成绩")
		return
	_hide_message()
	clear_items()
	var node := create_and_add_item("local_best", "score")
	# 本地最佳固定排名第 1
	node.setup_score(
			1,
			int(local.get("totalScore", 0)),
			str(local.get("rank", "F")),
			float(local.get("accuracy", 0.0)) * 100.0,
			float(local.get("pp", 0.0)),
			int(local.get("maxCombo", 0)),
			int(local.get("perfectCount", 0)),
		int(local.get("greatCount", 0)),
		int(local.get("goodCount", 0)),
		int(local.get("badCount", 0)),
		int(local.get("missCount", 0))
	)
	var name_label := node.get_node_or_null("Name")
	if name_label:
		name_label.text = "Offline Score"
	# 本地成绩无头像，保持默认头像占位

## 显示提示信息（经 TabView 下 FailMessage 节点，作为独立页展示）
## 排行榜标签页未激活时仅缓存，切回时再展示，避免抢占其它标签页
func _show_message(msg: String) -> void:
	clear_items()
	_pending_message = msg
	if is_visible_in_tree():
		_apply_message()
	else:
		# FailMessage 当前仍由本列表占用（可见）时，ScoreList 不可见也要立即更新文案。
		var fail := get_node_or_null("../../FailMessage") as Label
		if fail != null and fail.visible:
			_apply_message()

## 把待显示消息写入 FailMessage（显示时 TabContainer 会切到该页）
func _apply_message() -> void:
	var fail := get_node_or_null("../../FailMessage") as Label
	if fail == null:
		return
	if not fail.visible:
		var tab_view := get_parent().get_parent()
		if tab_view is TabContainer:
			_fail_prev_tab = tab_view.current_tab
	fail.text = _pending_message
	fail.visible = true

## 隐藏 FailMessage 并恢复到显示前的标签页。
## FailMessage 可使 ScoreList 暂时不可见，因此不能用 is_visible_in_tree() 作为前置条件。
## _fail_prev_tab 只会在本列表显示消息时设置，可避免干预其它标签页的提示。
func _hide_message() -> void:
	_pending_message = ""
	if _fail_prev_tab < 0:
		return  # FailMessage 非本列表显示，不干预
	var fail := get_node_or_null("../../FailMessage") as Label
	if fail == null or not fail.visible:
		_fail_prev_tab = -1
		return
	fail.visible = false
	var tab_view := get_parent().get_parent()
	if tab_view is TabContainer:
		tab_view.current_tab = _fail_prev_tab
	_fail_prev_tab = -1
