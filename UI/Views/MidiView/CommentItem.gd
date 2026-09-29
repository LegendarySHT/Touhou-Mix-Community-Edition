extends ListItemBase

## 单条评论：展示用户信息，并以服务端目标状态切换点赞。

signal interaction_invalidated(result: Dictionary)

@onready var like_btn: Button = $HBox/VBox/Foot/Like

var _comment_id: int = 0
var _liked_by_me: bool = false
var _can_interact: bool = false
var _busy: bool = false
var _comment_data: Dictionary = {}

func _ready() -> void:
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 应用主题色：评论卡片随主题翻浅/翻深（否则浅色模式下残留写死的深色卡片）
func apply_theme() -> void:
	if not ThemeMGR:
		return
	var sb := get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		sb.bg_color = ThemeMGR._tint_keep_alpha(ThemeMGR.get_color("surface_high"), sb.bg_color.a)
		sb.border_color = ThemeMGR.get_color("border_soft")

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)


func setup_comment(comment: Dictionary, can_interact: bool = false) -> void:
	_comment_data = comment
	_comment_id = int(comment.get("id", 0))
	_liked_by_me = bool(comment.get("likedByMe", false))

	$HBox/VBox/Head/Name.text = str(comment.get("username", "Anonymous"))
	$HBox/VBox/Head/Time.text = _format_created_at(str(comment.get("createdAt", "")))
	$HBox/VBox/Content.text = str(comment.get("content", ""))
	_set_like_count(int(comment.get("likeCount", 0)))
	like_btn.button_pressed = _liked_by_me
	set_interaction_enabled(can_interact)

	var avatar_url = comment.get("avatarUrl")
	setup_avatar(str(avatar_url) if avatar_url != null else "")


func set_interaction_enabled(enabled: bool) -> void:
	_can_interact = enabled
	like_btn.disabled = not _can_interact or _busy or _comment_id <= 0


func _on_like_pressed() -> void:
	if not _can_interact or _busy or _comment_id <= 0 or CommunityManager.instance == null:
		like_btn.button_pressed = _liked_by_me
		return
	var target := not _liked_by_me
	_busy = true
	like_btn.button_pressed = target
	like_btn.disabled = true
	var result: Dictionary = await CommunityManager.instance.set_comment_like(_comment_id, target)
	var data = result.get("data")
	if result.get("ok", false) and not data is Dictionary:
		result = {
			"ok": false,
			"status": int(result.get("status", 0)),
			"data": null,
			"error": "invalid_response",
		}
	if result.get("ok", false) and data is Dictionary:
		_liked_by_me = bool(data.get("likedByMe", false))
		_comment_data["likedByMe"] = _liked_by_me
		_comment_data["likeCount"] = int(data.get("likeCount", 0))
	if not is_inside_tree() or is_queued_for_deletion():
		return
	_busy = false
	if not result.get("ok", false):
		like_btn.button_pressed = _liked_by_me
		_can_interact = false
		set_interaction_enabled(false)
		interaction_invalidated.emit(result)
		return
	if data is Dictionary:
		_set_like_count(int(data.get("likeCount", 0)))
	like_btn.button_pressed = _liked_by_me
	set_interaction_enabled(_can_interact)


func _set_like_count(count: int) -> void:
	var value := str(maxi(count, 0))
	like_btn.text = value
	var shrink := maxi(value.length() - 3, 0) * 2
	like_btn.add_theme_font_size_override("font_size", maxi(20 - shrink, 12))


## ASP.NET Core 返回 UTC ISO-8601；按系统时区显示到分钟。解析失败时保留原文。
func _format_created_at(value: String) -> String:
	if value.is_empty():
		return ""
	var unix_time := int(Time.get_unix_time_from_datetime_string(value))
	if unix_time <= 0:
		return value.replace("T", " ").trim_suffix("Z")
	var zone: Dictionary = Time.get_time_zone_from_system()
	var local_time := unix_time + int(zone.get("bias", 0)) * 60
	var dt: Dictionary = Time.get_datetime_dict_from_unix_time(local_time)
	return "%04d-%02d-%02d %02d:%02d" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0))
	]


## avatarUrl 为服务端相对路径；空值保留场景默认头像。
func setup_avatar(avatar_url: String) -> void:
	if avatar_url.is_empty() or NetManager.instance == null or not NetManager.instance.is_online:
		return
	var img_node := get_node_or_null("HBox/Avator/img")
	if img_node == null:
		return
	var full_url := "%s%s" % [NetManager.instance.server_url, avatar_url]
	HttpImageLoader.load(full_url, self, func(tex: Texture2D) -> void:
		if tex and is_instance_valid(img_node):
			img_node.texture = tex
	)
