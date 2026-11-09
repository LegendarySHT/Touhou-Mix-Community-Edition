extends VBoxContainer

## 新脚本一律 preload 后按常量调用，不依赖 .godot/global_script_class_cache.cfg
const OnlineCache := preload("res://Core/OnlineContentCache.gd")
const UploadRefreshGate := preload("res://UI/Views/MidiView/UploadRefreshGate.gd")

## 当前 MIDI 的评价与评论区。公开内容在线可读；写操作由服务端按非 W 成绩授权。

const DEFAULT_INPUT_HINT: String = "发表评论..."
const MAX_COMMENT_LENGTH: int = 500

@onready var comments_list: BaseScrollList = $Comments
@onready var input: LineEdit = $Bottom/LineEdit
@onready var send_btn: Button = $Bottom/Button
@onready var like_btn: Button = $Top/Like
@onready var dislike_btn: Button = $Top/Dislike

var _current_midi: MidiData = null
var _request_version: int = 0
var _comments_data: Array[Dictionary] = []
var _can_interact: bool = false
var _my_reaction: String = ""
var _reaction_busy: bool = false
var _comment_busy: bool = false
var _was_online_ready: bool = false
var _retry_on_online_heartbeat: bool = false
## 缓存评论正文是否已上屏：在线请求失败时据此保留缓存，不清空列表
var _cache_rendered_comments: bool = false


func _ready() -> void:
	EvtBus.online_state_changed.connect(_on_online_state_changed)
	EvtBus.auth_changed.connect(_on_auth_changed)
	EvtBus.score_uploaded.connect(_on_score_uploaded)
	EvtBus.score_upload_failed.connect(_on_score_upload_failed)
	input.placeholder_text = DEFAULT_INPUT_HINT
	input.max_length = MAX_COMMENT_LENGTH
	_was_online_ready = _is_online_ready()
	_set_interaction_enabled(false)
	_set_counts(0, 0)


## 由 MidiView 在 MIDI 选中变化或重新进入视图时调用。
func load_comments(midi: MidiData) -> void:
	_current_midi = midi
	_request_version += 1
	var version := _request_version
	_comments_data.clear()
	comments_list.clear_items()
	_reaction_busy = false
	_comment_busy = false
	_retry_on_online_heartbeat = false
	_my_reaction = ""
	_cache_rendered_comments = false
	_set_reaction_visual("")
	_set_interaction_enabled(false)
	input.placeholder_text = DEFAULT_INPUT_HINT
	input.tooltip_text = ""

	if midi == null or midi.file_hash.is_empty():
		_set_counts(0, 0)
		return

	_show_cached_counts(midi.file_hash)

	# ① SWR 的 stale 部分：先渲染缓存的评论正文，不等网络。
	# 线上模式关闭且二级开关为 0（默认）时不展示，保持原有表现。
	var offline_mode := NetManager.instance != null \
		and NetManager.instance.connect_state == NetManager.ConnectState.OFFLINE_MODE
	if OnlineCache.is_enabled() \
			and (not offline_mode or OnlineCache.show_when_offline()):
		_load_cached_comments(midi.file_hash)

	if not _is_online_ready() or CommunityManager.instance == null:
		return

	_request_summary(midi.file_hash, version)
	_request_comments(midi.file_hash, version)


## 读取并渲染缓存评论。likedByMe 是账号态，缓存渲染时一律按未点赞处理，
## 等在线汇总/评论响应给出权威值，避免切账号后按钮显示错误。
func _load_cached_comments(midi_hash: String) -> bool:
	var entry := OnlineCache.read("charts", midi_hash + "|comments50")
	if entry.is_empty():
		return false
	var payload: Variant = OnlineCache.payload_of(entry, null)
	if not payload is Array:
		return false
	var cached: Array = payload
	_comments_data.clear()
	for value in cached:
		if value is Dictionary:
			var raw: Dictionary = value
			var comment := raw.duplicate(true)
			comment["likedByMe"] = false
			_comments_data.append(comment)
	_render_comments()
	_cache_rendered_comments = true
	return true


func _request_summary(midi_hash: String, version: int) -> void:
	var result: Dictionary = await CommunityManager.instance.get_summary(midi_hash)
	if not _is_current_request(midi_hash, version):
		return
	if not result.get("ok", false):
		_set_interaction_enabled(false)
		if int(result.get("status", 0)) == 404:
			_set_counts(0, 0)
			_request_version += 1
		else:
			_schedule_online_retry(result)
		return
	var data = result.get("data")
	if not data is Dictionary:
		_set_interaction_enabled(false)
		_schedule_online_retry(result)
		return
	_set_counts(int(data.get("likeCount", 0)), int(data.get("dislikeCount", 0)))
	var reaction = data.get("myReaction")
	_my_reaction = str(reaction) if reaction != null else ""
	_set_reaction_visual(_my_reaction)
	_set_interaction_enabled(bool(data.get("canInteract", false)))


func _request_comments(midi_hash: String, version: int) -> void:
	var result: Dictionary = await CommunityManager.instance.get_comments(midi_hash)
	if not _is_current_request(midi_hash, version):
		return
	if not result.get("ok", false):
		# 404 是权威空结果（谱面未收录），可以清空；网络/5xx 失败则保留已上屏的缓存
		if _cache_rendered_comments and int(result.get("status", 0)) != 404:
			_schedule_online_retry(result)
			return
		comments_list.clear_items()
		_comments_data.clear()
		_cache_rendered_comments = false
		input.tooltip_text = ""
		if int(result.get("status", 0)) == 404:
			_set_counts(0, 0)
			_set_interaction_enabled(false)
			_request_version += 1
		else:
			_schedule_online_retry(result)
		return
	var data = result.get("data")
	if not data is Dictionary:
		_schedule_online_retry(result)
		return
	var comments = data.get("comments", [])
	if not comments is Array:
		return
	OnlineCache.write("charts", midi_hash + "|comments50", comments)
	_cache_rendered_comments = false
	input.tooltip_text = ""
	_comments_data.clear()
	for value in comments:
		if value is Dictionary:
			_comments_data.append(value)
	_render_comments()


func _render_comments() -> void:
	comments_list.clear_items()
	for i in range(_comments_data.size()):
		var comment := _comments_data[i]
		var item_id := str(comment.get("id", i))
		var node := comments_list.create_and_add_item(item_id, "comment")
		if node != null:
			if node.has_signal("interaction_invalidated"):
				node.connect("interaction_invalidated", _on_comment_interaction_invalidated)
			node.setup_comment(comment, _can_interact)


func _on_send_pressed(_text: String = "") -> void:
	if not _can_interact or _comment_busy or _current_midi == null:
		return
	var content := input.text.strip_edges()
	if content.is_empty():
		_set_input_status("评论内容不能为空")
		return
	if content.length() > MAX_COMMENT_LENGTH:
		_set_input_status("评论不能超过 %d 字" % MAX_COMMENT_LENGTH)
		return
	_submit_comment(content)


func _submit_comment(content: String) -> void:
	_comment_busy = true
	_update_controls()
	var version := _request_version
	var midi_hash := _current_midi.file_hash
	var result: Dictionary = await CommunityManager.instance.create_comment(midi_hash, content)
	if not _is_current_request(midi_hash, version):
		return
	_comment_busy = false
	if not result.get("ok", false):
		_handle_write_failure(result)
		_update_controls()
		return
	var data = result.get("data")
	if data is Dictionary:
		_comments_data.push_front(data)
		input.clear()
		input.placeholder_text = DEFAULT_INPUT_HINT
		input.tooltip_text = ""
		_render_comments()
	else:
		_handle_write_failure({
			"ok": false,
			"status": int(result.get("status", 0)),
			"data": null,
			"error": "invalid_response",
		})
	_update_controls()


func _on_like_pressed() -> void:
	var target := "" if _my_reaction == "like" else "like"
	_submit_reaction(target)


func _on_dislike_pressed() -> void:
	var target := "" if _my_reaction == "dislike" else "dislike"
	_submit_reaction(target)


func _submit_reaction(target: String) -> void:
	if not _can_interact or _reaction_busy or _current_midi == null:
		_set_reaction_visual(_my_reaction)
		return
	var previous := _my_reaction
	_reaction_busy = true
	_set_reaction_visual(target)
	_update_controls()
	var version := _request_version
	var midi_hash := _current_midi.file_hash
	var body_value: Variant = null
	if not target.is_empty():
		body_value = target
	var result: Dictionary = await CommunityManager.instance.set_reaction(midi_hash, body_value)
	if not _is_current_request(midi_hash, version):
		return
	_reaction_busy = false
	if not result.get("ok", false):
		_set_reaction_visual(previous)
		_handle_write_failure(result)
		_update_controls()
		return
	var data = result.get("data")
	if data is Dictionary:
		_set_counts(int(data.get("likeCount", 0)), int(data.get("dislikeCount", 0)))
		var reaction = data.get("myReaction")
		_my_reaction = str(reaction) if reaction != null else ""
		_set_reaction_visual(_my_reaction)
		_set_interaction_enabled(bool(data.get("canInteract", false)))
	else:
		_set_reaction_visual(previous)
		_handle_write_failure({
			"ok": false,
			"status": int(result.get("status", 0)),
			"data": null,
			"error": "invalid_response",
		})
	_update_controls()


func _on_online_state_changed(state: int, _latency_ms: int) -> void:
	var online_now := state == NetManager.ConnectState.ONLINE \
		and NetManager.instance != null and NetManager.instance.is_online
	var became_online := online_now and not _was_online_ready
	var became_unavailable := not online_now and _was_online_ready
	_was_online_ready = online_now
	if _current_midi == null:
		return
	if online_now and (became_online or _retry_on_online_heartbeat):
		_retry_on_online_heartbeat = false
		load_comments(_current_midi)
	elif became_unavailable:
		_request_version += 1
		_my_reaction = ""
		_set_reaction_visual("")
		_set_interaction_enabled(false)
		_show_cached_counts(_current_midi.file_hash)
		# 掉线时回落到缓存评论，而不是留一片空白；开关关闭时走原清空逻辑
		if not _load_cached_comments(_current_midi.file_hash):
			_comments_data.clear()
			comments_list.clear_items()
			_cache_rendered_comments = false


func _on_auth_changed(_user: Variant) -> void:
	if _current_midi == null:
		return
	if _is_online_ready():
		load_comments(_current_midi)
	else:
		_my_reaction = ""
		_set_reaction_visual("")
		_set_interaction_enabled(false)


## W 上传也会发出 score_uploaded；是否解锁始终以服务端 canInteract 为准。
func _on_score_uploaded(midi_hash: String) -> void:
	_refresh_after_upload(midi_hash)


## 上传结束但未写入时同样补刷：中途退出回页时若成绩还在上传，
## MidiView 会推迟评论刷新到这里（否则会回页刷一次 + 上传完成再刷一次）。
func _on_score_upload_failed(midi_hash: String) -> void:
	_refresh_after_upload(midi_hash)


## 只在「本页正是当前视图」时刷新（判定见 UploadRefreshGate）：不在 MIDI_VIEW 时
## 下次进入的刷新会拿到最新数据，这里再拉一次只会白打一轮 summary + 评论请求。
func _refresh_after_upload(midi_hash: String) -> void:
	if _current_midi == null:
		return
	if not UploadRefreshGate.should_refresh(_current_midi.file_hash, midi_hash,
			UiStatMGR.current_state, _is_online_ready()):
		return
	load_comments(_current_midi)


func _set_interaction_enabled(enabled: bool) -> void:
	_can_interact = enabled and _is_online_ready()
	_update_controls()
	for item in comments_list.list_items:
		if item != null and item.has_method("set_interaction_enabled"):
			item.set_interaction_enabled(_can_interact)


func _update_controls() -> void:
	like_btn.disabled = not _can_interact or _reaction_busy
	dislike_btn.disabled = not _can_interact or _reaction_busy
	send_btn.disabled = not _can_interact or _comment_busy
	input.editable = _can_interact and not _comment_busy


func _set_reaction_visual(reaction: String) -> void:
	like_btn.button_pressed = reaction == "like"
	dislike_btn.button_pressed = reaction == "dislike"


func _show_cached_counts(midi_hash: String) -> void:
	var cached: Dictionary = {}
	if CommunityManager.instance != null:
		cached = CommunityManager.instance.get_cached_counts(midi_hash)
	_set_counts(
		int(cached.get("like_count", 0)),
		int(cached.get("dislike_count", 0))
	)


func _set_counts(like_count: int, dislike_count: int) -> void:
	_set_button_count(like_btn, maxi(like_count, 0), 25)
	_set_button_count(dislike_btn, maxi(dislike_count, 0), 24)


func _set_button_count(button: Button, count: int, base_size: int) -> void:
	var value := str(count)
	button.text = value
	var shrink := maxi(value.length() - 5, 0) * 2
	button.add_theme_font_size_override("font_size", maxi(base_size - shrink, 14))


func _handle_write_failure(result: Dictionary) -> void:
	var status := int(result.get("status", 0))
	var error := str(result.get("error", ""))
	var response_data = result.get("data")
	var api_error := str(response_data.get("error", "")) if response_data is Dictionary else ""
	if status == 401 or error in ["not_logged_in", "token_expired"]:
		_set_input_status("请先登录账号")
		_set_interaction_enabled(false)
	elif status == 403:
		_set_input_status("请先完成该谱面并成功上传非 W 成绩")
		_set_interaction_enabled(false)
	elif status == 404 and api_error == "comment_not_found":
		_set_input_status("该评论已不存在，请刷新后重试")
		_set_interaction_enabled(false)
	elif status == 404:
		_set_input_status("服务端未收录该谱面")
		_set_counts(0, 0)
		_set_interaction_enabled(false)
	elif status == 400:
		_set_input_status("提交内容无效")
	else:
		_set_input_status("在线操作失败，请稍后重试")
		_set_interaction_enabled(false)
		if _current_midi != null:
			_show_cached_counts(_current_midi.file_hash)
		_schedule_online_retry(result)


func _set_input_status(message: String) -> void:
	input.placeholder_text = message
	input.tooltip_text = message


func _on_comment_interaction_invalidated(result: Dictionary) -> void:
	_handle_write_failure(result)


## 请求层失败时等待下一次在线心跳补刷；正常的 4xx 由用户状态变化触发刷新。
func _schedule_online_retry(result: Dictionary) -> void:
	var status := int(result.get("status", 0))
	if status == 0 or status >= 500 or (status >= 200 and status < 300):
		_retry_on_online_heartbeat = true


func _is_current_request(midi_hash: String, version: int) -> bool:
	return is_inside_tree() and version == _request_version \
		and _current_midi != null and _current_midi.file_hash == midi_hash


func _is_online_ready() -> bool:
	return NetManager.instance != null \
		and NetManager.instance.connect_state == NetManager.ConnectState.ONLINE \
		and NetManager.instance.is_online
