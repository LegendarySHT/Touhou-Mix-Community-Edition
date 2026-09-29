extends VBoxContainer
class_name ProfilePage

## 个人信息详情页：Profile / History / Edit 三页切换
## Profile 页显示资料，Edit 页提供修改功能

## 资料更新成功后通知外部刷新（PlayerInfoContent 监听）
signal profile_updated()

## 头像加载完成后的纹理（供 PlayerInfoContent 同步到 MiniInfo/ProfileView）
signal avatar_loaded(texture: Texture2D)

# ========== PageContent（Profile / History / Edit） ==========
@onready var page_content: TabContainer = $PC/PageContent
@onready var navi_profile_btn: Button = $Navi/Btns/Profile
@onready var navi_history_btn: Button = $Navi/Btns/History
@onready var navi_edit_btn: Button = $Navi/Btns/Edit

# ========== History 页面 List 切换 ==========
@onready var history_list: TabContainer = $PC/PageContent/History/List
@onready var recent_play_btn: Button = $PC/PageContent/History/PC/TopBar/TopBtns/RecentPlay
@onready var best_play_btn: Button = $PC/PageContent/History/PC/TopBar/TopBtns/BestPlay
@onready var most_play_btn: Button = $PC/PageContent/History/PC/TopBar/TopBtns/MostPlay

# ========== History 页三个列表的 VBox 容器 ==========
@onready var recent_list_vbox: VBoxContainer = $PC/PageContent/History/List/RecentPlay/VBox
@onready var best_list_vbox: VBoxContainer = $PC/PageContent/History/List/BestPlay/VBox
@onready var most_list_vbox: VBoxContainer = $PC/PageContent/History/List/MostPlay/VBox

# ========== Profile 页显示节点 ==========
@onready var profile_name_label: Label = $PC/PageContent/Profile/Main/Header/HBoxContainer/NameLevelVBox/NameLabel
@onready var profile_pp_label: Label = $PC/PageContent/Profile/Main/Header/HBoxContainer/NameLevelVBox/Level/PPLabel
@onready var profile_bio_label: Label = $PC/PageContent/Profile/Data/VBox/Desc/Label
@onready var profile_avatar_rect: TextureRect = $PC/PageContent/Profile/Main/Header/HBoxContainer/AvatarBig/TextureRect
# ========== Profile 角色展示（Displayer） ==========
@onready var chara_display_img: TextureRect = $PC/PageContent/Profile/Main/PC/Displayer/Border/CharaImg
@onready var bg_display_img: TextureRect = $PC/PageContent/Profile/Main/PC/Displayer/Border/BGImg
@onready var chara_info_name: Label = $PC/PageContent/Profile/Main/PC/Displayer/Info/VBox/Name
@onready var chara_info_author: Label = $PC/PageContent/Profile/Main/PC/Displayer/Info/VBox/Illustrator

# ========== History 页统计显示节点（TopBar/Grid） ==========
@onready var history_pp_label: Label = $PC/PageContent/History/PC/TopBar/PC/InnerMargin/Grid/pp
@onready var history_s_count: Label = $PC/PageContent/History/PC/TopBar/PC/InnerMargin/Grid/SCount
@onready var history_a_count: Label = $PC/PageContent/History/PC/TopBar/PC/InnerMargin/Grid/ACount
@onready var history_b_count: Label = $PC/PageContent/History/PC/TopBar/PC/InnerMargin/Grid/BCount
@onready var history_c_count: Label = $PC/PageContent/History/PC/TopBar/PC/InnerMargin/Grid/CCount
@onready var history_d_count: Label = $PC/PageContent/History/PC/TopBar/PC/InnerMargin/Grid/DCount
@onready var history_f_count: Label = $PC/PageContent/History/PC/TopBar/PC/InnerMargin/Grid/FCount

# ========== Edit 页输入节点 ==========
@onready var nickname_edit: LineEdit = $PC/PageContent/Edit/HBox/ProfileEdit/Nickname/LineEdit
@onready var desc_edit: LineEdit = $PC/PageContent/Edit/HBox/ProfileEdit/Desc/LineEdit
@onready var old_pwd_edit: LineEdit = $PC/PageContent/Edit/HBox/OtherEdit/Password/LineEdit
@onready var new_pwd_edit: LineEdit = $PC/PageContent/Edit/HBox/OtherEdit/NewPassword/LineEdit
@onready var avatar_border: AvatarPreview = $PC/PageContent/Edit/HBox/OtherEdit/AvatorEdit/Border
@onready var avatar_scale_slider: HSlider = $PC/PageContent/Edit/HBox/OtherEdit/AvatorEdit/AdjustBtns/ScaleSlider
@onready var upload_avatar_btn: Button = $PC/PageContent/Edit/HBox/OtherEdit/AvatorEdit/AdjustBtns/UploadBtn
@onready var avatar_save_btn: Button = $PC/PageContent/Edit/HBox/OtherEdit/AvatorEdit/AdjustBtns/SaveBtn
@onready var nickname_confirm_btn: Button = $PC/PageContent/Edit/HBox/ProfileEdit/Nickname/ConfirmBtn
@onready var desc_confirm_btn: Button = $PC/PageContent/Edit/HBox/ProfileEdit/Desc/ConfirmBtn
@onready var pwd_confirm_btn: Button = $PC/PageContent/Edit/HBox/OtherEdit/NewPassword/ConfirmBtn

# ========== 主题色引用节点（每个共享 StyleBox 取一个代表节点） ==========
@onready var _info_panel: PanelContainer = $PC/PageContent/Profile/Main/PC/Displayer/Info
@onready var _header_panel: PanelContainer = $PC/PageContent/Profile/Main/Header
@onready var _play_panel: PanelContainer = $PC/PageContent/Profile/Data/VBox/Play
@onready var _rank_total: PanelContainer = $PC/PageContent/Profile/Data/VBox/Desc/Rank/RankTotal
@onready var _navi_panel: PanelContainer = $Navi
@onready var _history_pc: PanelContainer = $PC/PageContent/History/PC
@onready var _edit_confirm_btn: Button = $PC/PageContent/Edit/HBox/ProfileEdit/Nickname/ConfirmBtn

# PageContent tab 索引
const TAB_PROFILE := 0
const TAB_HISTORY := 1
const TAB_EDIT := 2
# History/List tab 索引
const LIST_RECENT := 0
const LIST_BEST := 1
const LIST_MOST := 2

# 记录列表项场景（preload 避免每次加载）
const RECORD_ITEM_SCENE := preload("res://UI/Components/PlayerInfo/recordListItem.tscn")
# 单页记录数
const RECORD_PAGE_LIMIT := 20

## 操作进行中（防止重复点击）
var _busy: bool = false
## 头像 FileDialog（运行时创建）
var _avatar_file_dialog: FileDialog = null
## 头像图片 HTTP 加载请求（避免重复加载）
var _avatar_load_token: int = 0
## 待保存头像源图（本地选图解码后，保存时裁剪方形区域）
var _pending_avatar: Image = null

# 三个列表的懒加载状态标记
var _recent_loaded: bool = false
var _best_loaded: bool = false
var _most_loaded: bool = false
# 列表加载进行中（每列表独立，防止切换 tab 时互相阻塞导致加载被静默丢弃）
var _recent_loading: bool = false
var _best_loading: bool = false
var _most_loading: bool = false

func _ready() -> void:
	navi_profile_btn.pressed.connect(_on_navi_profile_pressed)
	navi_history_btn.pressed.connect(_on_navi_history_pressed)
	navi_edit_btn.pressed.connect(_on_navi_edit_pressed)
	recent_play_btn.pressed.connect(_on_recent_play_pressed)
	best_play_btn.pressed.connect(_on_best_play_pressed)
	most_play_btn.pressed.connect(_on_most_play_pressed)
	_sync_navi_selection(page_content.current_tab)
	_sync_topbtn_z_index(recent_play_btn)
	# 密码输入框设为密文
	old_pwd_edit.secret = true
	new_pwd_edit.secret = true
	_reset_avatar_adjust()
	# 头像卡（Border 整块卡片框）点击进入 Chara_View：卡片框接收点击，头像图透传
	var card_border := get_node_or_null("PC/PageContent/Profile/Main/PC/Displayer/Border")
	if card_border:
		card_border.gui_input.connect(_on_card_border_gui_input)
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()
	# 角色展示：初始加载当前人物，并监听切换（选中角色后刷新）
	_load_chara_display()
	EvtBus.config_changed.connect(_on_config_changed)
	# FileSystemManager 由 Main._ready 创建（晚于本节点 _ready），故延迟一帧再连扫描完成信号，
	# 保证启动扫描完成后能按最终选中的角色加载一次
	call_deferred("_connect_scan_ready")

func _connect_scan_ready() -> void:
	if FileSystemManager.instance and not FileSystemManager.instance.resources_ready.is_connected(_load_chara_display):
		FileSystemManager.instance.resources_ready.connect(_load_chara_display)

## 角色切换（[Chara] chara_id）时刷新展示
func _on_config_changed(key: String, section: String, _value: Variant) -> void:
	if key == "chara_id" and section == "Chara":
		_load_chara_display()

## 加载当前选中角色的立绘、背景与名字/作者到 Displayer
func _load_chara_display() -> void:
	var key := CharaMGR.get_current_chara_key()
	if key.is_empty():
		return
	var data: Dictionary = CharaMGR.get_chara_data(key)
	var tex := CharaMGR.get_portrait(key, 0)
	if tex:
		chara_display_img.texture = tex
	var bg := CharaMGR.get_background(key)
	if bg:
		bg_display_img.texture = bg
	# 名字与作者
	chara_info_name.text = str(data.get("name", key))
	chara_info_author.text = "by %s" % str(data.get("author", ""))

## 头像卡点击：进入 CHARA_VIEW（标准视图导航，返回键经 UiState 栈回 PROFILE_VIEW）
func _on_card_border_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		UiStatMGR.change_state(UIStateManager.UIState.CHARA_VIEW)

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

# ========== 主题色应用 ==========

func apply_theme() -> void:
	var p: Color = ThemeMGR.get_color("primary")
	var surface: Color = ThemeMGR.get_color("surface")
	var surface_high: Color = ThemeMGR.get_color("surface_high")
	var surface_hover: Color = ThemeMGR.get_color("surface_hover")
	var border: Color = ThemeMGR.get_color("border")
	var accent_border: Color = Color(p.r, p.g, p.b, 0.6)

	# 页面底色为 InfoPanelBtn 的 surface；本页内容面板统一用 surface_high 浮起（简介与 Play 共享同一 StyleBox）
	_set_panel(_info_panel, surface_high, accent_border)   # Info
	_set_panel(_header_panel, surface_high, border)        # Header
	_set_panel(_play_panel, surface_high, border)          # Play
	_set_panel(_rank_total, surface_high, accent_border)   # RankTotal
	# Navi 面板
	_set_panel(_navi_panel, surface, border)               # Navi 底栏与页面底色一致
	# History 顶部面板
	_set_panel_border(_history_pc, border)
	# Navi 按钮（normal/pressed/hover/focus 共享 StyleBox，改 navi_profile_btn 即同步全部）
	# pressed 与页面底色同色（选中项并入内容区），hover_pressed 由 tscn 直接复用 hover
	_set_btn(navi_profile_btn, "normal", surface_high, border)
	_set_btn(navi_profile_btn, "pressed", surface, border)
	_set_btn(navi_profile_btn, "hover", surface_hover, accent_border)
	_set_btn(navi_profile_btn, "focus", surface_high, p)
	# History TopBtns
	_set_btn_border(recent_play_btn, "pressed", p)
	_set_btn_border(recent_play_btn, "hover", p)
	# MostPlay hover 用单独 StyleBox
	_set_btn_border(most_play_btn, "hover", p)
	# Edit 页面 ConfirmBtn / UploadBtn（共享 StyleBox）
	_set_btn(_edit_confirm_btn, "normal", p.darkened(0.1), p)
	_set_btn(_edit_confirm_btn, "pressed", p.darkened(0.3), p)
	_set_btn(_edit_confirm_btn, "hover", p, p)

## 设置面板 bg + border
func _set_panel(node: Control, bg: Color, border: Color) -> void:
	if not node:
		return
	var sb := node.get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		sb.bg_color = bg
		sb.border_color = border

## 仅设置面板 border（保留原 bg）
func _set_panel_border(node: Control, border: Color) -> void:
	if not node:
		return
	var sb := node.get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		sb.border_color = border

## 设置按钮某状态的 bg + border
func _set_btn(btn: Button, state: String, bg: Color, border: Color) -> void:
	if not btn:
		return
	var sb := btn.get_theme_stylebox(state)
	if sb is StyleBoxFlat:
		sb.bg_color = bg
		sb.border_color = border

## 仅设置按钮某状态的 border（保留原 bg 和 border alpha）
func _set_btn_border(btn: Button, state: String, border: Color) -> void:
	if not btn:
		return
	var sb := btn.get_theme_stylebox(state)
	if sb is StyleBoxFlat:
		var a = sb.border_color.a
		sb.border_color = Color(border.r, border.g, border.b, a)

# ========== Navi → PageContent 切换 ==========

func _on_navi_profile_pressed() -> void:
	page_content.current_tab = TAB_PROFILE

func _on_navi_history_pressed() -> void:
	page_content.current_tab = TAB_HISTORY

func _on_navi_edit_pressed() -> void:
	page_content.current_tab = TAB_EDIT

func _sync_navi_selection(tab_idx: int) -> void:
	navi_profile_btn.button_pressed = (tab_idx == TAB_PROFILE)
	navi_history_btn.button_pressed = (tab_idx == TAB_HISTORY)
	navi_edit_btn.button_pressed = (tab_idx == TAB_EDIT)

# ========== History TopBar → List 切换 + z_index ==========

func _on_recent_play_pressed() -> void:
	_switch_history_list(LIST_RECENT, recent_play_btn)
	if not _recent_loaded:
		_load_recent_scores()

func _on_best_play_pressed() -> void:
	_switch_history_list(LIST_BEST, best_play_btn)
	if not _best_loaded:
		_load_best_scores()

func _on_most_play_pressed() -> void:
	_switch_history_list(LIST_MOST, most_play_btn)
	if not _most_loaded:
		_load_most_played()

## 切换 History/List 的 tab，并把激活按钮 z_index 抬到 1，其余压回 0
## 避免相邻按钮 stylebox 超边界部分被遮挡
func _switch_history_list(tab_idx: int, active_btn: Button) -> void:
	if tab_idx < history_list.get_tab_count():
		history_list.current_tab = tab_idx
	_sync_topbtn_z_index(active_btn)

func _sync_topbtn_z_index(active_btn: Button) -> void:
	recent_play_btn.z_index = 1 if recent_play_btn == active_btn else 0
	best_play_btn.z_index = 1 if best_play_btn == active_btn else 0
	most_play_btn.z_index = 1 if most_play_btn == active_btn else 0

# ========== 资料显示（由 PlayerInfoContent 调用） ==========

## 从 PlayerInfoContent 传入玩家数据，更新 Profile 页显示
func update_display(data: Dictionary) -> void:
	var display_name_raw = data.get("display_name", "")
	var display_name := str(display_name_raw) if display_name_raw != null else ""
	if display_name.is_empty() or display_name == "<null>":
		var name_raw = data.get("name", "Anonymous Player")
		display_name = str(name_raw) if name_raw != null else "Anonymous Player"
	profile_name_label.text = display_name
	profile_pp_label.text = "%.2f pp" % float(data.get("pp", 0.0))
	var bio_raw = data.get("bio", "")
	var bio := str(bio_raw) if bio_raw != null else ""
	profile_bio_label.text = bio if not bio.is_empty() and bio != "<null>" else "还没有填写简介..."
	# 同步 History 页统计：总 pp + 各评级数量
	history_pp_label.text = "%.2f pp" % float(data.get("pp", 0.0))
	var grades = data.get("grades", {})
	if grades == null:
		grades = {}
	history_s_count.text = str(int(grades.get("S", 0)))
	history_a_count.text = str(int(grades.get("A", 0)))
	history_b_count.text = str(int(grades.get("B", 0)))
	history_c_count.text = str(int(grades.get("C", 0)))
	history_d_count.text = str(int(grades.get("D", 0)))
	history_f_count.text = str(int(grades.get("F", 0)))
	# 同步 Edit 页输入框为当前值
	nickname_edit.text = display_name
	desc_edit.text = bio
	# 加载头像
	var avatar_url = data.get("avatar_url", "")
	if avatar_url == null:
		avatar_url = ""
	_load_avatar_async(str(avatar_url))

## 异步加载头像（从服务端 URL），同时更新 Profile 页和 Edit 页预览
func _load_avatar_async(avatar_url: String) -> void:
	if avatar_url.is_empty():
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	_avatar_load_token += 1
	var my_token := _avatar_load_token
	var full_url := "%s%s" % [NetManager.instance.server_url, avatar_url]
	var http := HTTPRequest.new()
	add_child(http)
	var req_err := http.request(full_url, PackedStringArray(), HTTPClient.METHOD_GET, "")
	if req_err != OK:
		GLogger.warning("Avatar request failed to start: err=%d url=%s" % [req_err, full_url], "ProfilePage")
		http.queue_free()
		return
	var resp = await http.request_completed
	if my_token != _avatar_load_token:
		http.queue_free()
		return
	var result_code = resp[0]
	var response_code = resp[1]
	var response_body = resp[3]
	http.queue_free()
	if result_code != HTTPRequest.RESULT_SUCCESS:
		GLogger.warning("Avatar download failed: result=%d url=%s" % [result_code, full_url], "ProfilePage")
		return
	if response_code != 200:
		GLogger.warning("Avatar HTTP %d: url=%s" % [response_code, full_url], "ProfilePage")
		return
	if not response_body is PackedByteArray or response_body.size() == 0:
		GLogger.warning("Avatar response body empty: url=%s" % full_url, "ProfilePage")
		return
	var image := Image.new()
	var err := OK
	# 根据扩展名选择解码器，避免无关解码器报错
	var ext := full_url.get_extension().to_lower()
	if ext == "jpg" or ext == "jpeg":
		err = image.load_jpg_from_buffer(response_body)
	elif ext == "png":
		err = image.load_png_from_buffer(response_body)
	else:
		# 未知扩展名：尝试两种格式
		err = image.load_png_from_buffer(response_body)
		if err != OK:
			err = image.load_jpg_from_buffer(response_body)
	if err != OK:
		GLogger.warning("Avatar image decode failed (not PNG/JPG): url=%s" % full_url, "ProfilePage")
		return
	var tex := ImageTexture.create_from_image(image)
	profile_avatar_rect.texture = tex
	avatar_border.set_display_texture(tex)
	avatar_loaded.emit(tex)
	GLogger.info("Avatar loaded: %s" % full_url, "ProfilePage")

# ========== Edit 页面：资料修改 ==========

## 保存昵称
func _on_save_nickname_btn_pressed() -> void:
	if _busy:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	var new_name := nickname_edit.text.strip_edges()
	if new_name.is_empty():
		return
	_busy = true
	nickname_confirm_btn.disabled = true
	var result: Dictionary = await AuthManager.instance.update_profile(new_name, null)
	_busy = false
	nickname_confirm_btn.disabled = false
	if result.get("ok", false):
		GLogger.info("Nickname updated: %s" % new_name, "ProfilePage")
		profile_updated.emit()
	else:
		GLogger.warning("Nickname update failed: %s" % str(result.get("error", "")), "ProfilePage")

## 保存简介
func _on_save_desc_btn_pressed() -> void:
	if _busy:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	var new_bio := desc_edit.text.strip_edges()
	_busy = true
	desc_confirm_btn.disabled = true
	var result: Dictionary = await AuthManager.instance.update_profile(null, new_bio)
	_busy = false
	desc_confirm_btn.disabled = false
	if result.get("ok", false):
		GLogger.info("Bio updated", "ProfilePage")
		profile_updated.emit()
	else:
		GLogger.warning("Bio update failed: %s" % str(result.get("error", "")), "ProfilePage")

## 修改密码
func _on_save_pwd_btn_pressed() -> void:
	if _busy:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	var old_pwd := old_pwd_edit.text
	var new_pwd := new_pwd_edit.text
	if old_pwd.is_empty() or new_pwd.is_empty():
		return
	if new_pwd.length() < 6:
		new_pwd_edit.text = ""
		return
	_busy = true
	pwd_confirm_btn.disabled = true
	var result: Dictionary = await AuthManager.instance.change_password(old_pwd, new_pwd)
	_busy = false
	pwd_confirm_btn.disabled = false
	if result.get("ok", false):
		GLogger.info("Password changed", "ProfilePage")
		old_pwd_edit.text = ""
		new_pwd_edit.text = ""
	else:
		GLogger.warning("Password change failed: %s" % str(result.get("error", "")), "ProfilePage")
		old_pwd_edit.text = ""

## 上传头像：弹出 FileDialog 选择图片
func _on_upload_avatar_btn_pressed() -> void:
	if _busy:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	if _avatar_file_dialog == null:
		_avatar_file_dialog = FileDialog.new()
		_avatar_file_dialog.use_native_dialog = true
		_avatar_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_avatar_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_avatar_file_dialog.filters = PackedStringArray(["*.png ; PNG Image", "*.jpg ; JPEG Image", "*.jpeg ; JPEG Image"])
		_avatar_file_dialog.title = "选择头像图片"
		add_child(_avatar_file_dialog)
		_avatar_file_dialog.file_selected.connect(_on_avatar_file_selected)
	_avatar_file_dialog.popup_centered_clamped(Vector2i(800, 600))

## 保存头像：裁剪预览方形区域 → PNG 编码 → 上传
func _on_save_avatar_btn_pressed() -> void:
	if _busy:
		return
	if _pending_avatar == null:
		GLogger.info("No avatar selected to save", "ProfilePage")
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	# 由预览偏移/缩放反推方形裁剪区（源图像素坐标），缩放以左上角为锚点
	var img := _pending_avatar
	var s := avatar_scale_slider.value
	if s <= 0.0:
		return
	var view := avatar_border.get_box_size()
	var off := avatar_border.offset
	# STRETCH_KEEP + 左上角锚：off 即缩放后图片左上角，源图像素 q=(p-off)/s，
	# 屏幕 [0, view] 对应源图区域 = -off/s + (view/s)
	var crop_rect := Rect2(-off / s, view / s)
	crop_rect = crop_rect.intersection(Rect2(0, 0, img.get_width(), img.get_height()))
	if crop_rect.size.x < 1 or crop_rect.size.y < 1:
		GLogger.warning("Avatar crop region empty", "ProfilePage")
		return
	var square := img.get_region(Rect2i(crop_rect))
	# 限制输出最长边 <= 512，避免上传超大图
	var max_side := maxi(square.get_width(), square.get_height())
	if max_side > 512:
		var ratio := 512.0 / max_side
		square.resize(maxi(1, int(square.get_width() * ratio)), maxi(1, int(square.get_height() * ratio)))
	var png := square.save_png_to_buffer()
	if png.is_empty():
		GLogger.warning("Avatar PNG encode failed", "ProfilePage")
		return
	_busy = true
	avatar_save_btn.disabled = true
	var image_base64 := Marshalls.raw_to_base64(png)
	var result: Dictionary = await AuthManager.instance.upload_avatar(image_base64, "image/png")
	_busy = false
	avatar_save_btn.disabled = false
	if result.get("ok", false):
		GLogger.info("Avatar uploaded", "ProfilePage")
		# 直接从上传响应中提取 avatarUrl 并立即加载头像
		if result.data is Dictionary:
			var av = result.data.get("avatarUrl", "")
			var av_url := str(av) if av != null else ""
			if not av_url.is_empty():
				_load_avatar_async(av_url)
		profile_updated.emit()
		# 保存成功：复位预览变换并隐藏调整控件（回到「仅显示当前头像」）
		_reset_avatar_adjust()
	else:
		GLogger.warning("Avatar upload failed: %s" % str(result.get("error", "")), "ProfilePage")

## FileDialog 选择图片后：解码载入预览（保存时再裁剪上传）
func _on_avatar_file_selected(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() == 0:
		return
	# 源图过大时直接拒绝（解码占用内存）
	if bytes.size() > 8 * 1024 * 1024:
		GLogger.warning("Avatar too large (>%d bytes), skipping" % (8 * 1024 * 1024), "ProfilePage")
		return
	var img := Image.new()
	var ext := path.get_extension().to_lower()
	var err := OK
	if ext == "jpg" or ext == "jpeg":
		err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			err = img.load_png_from_buffer(bytes)
	else:
		err = img.load_png_from_buffer(bytes)
		if err != OK:
			err = img.load_jpg_from_buffer(bytes)
	if err != OK or img.get_width() <= 0 or img.get_height() <= 0:
		GLogger.warning("Avatar image decode failed (not PNG/JPG): %s" % path, "ProfilePage")
		return
	# 过长边降到 2048 内，避免预览/记忆体浪费
	var max_side := maxi(img.get_width(), img.get_height())
	if max_side > 2048:
		var ratio := 2048.0 / max_side
		img.resize(maxi(1, int(img.get_width() * ratio)), maxi(1, int(img.get_height() * ratio)))
	_show_avatar_preview(img)
	GLogger.info("Avatar loaded for preview: %s" % path, "ProfilePage")

## 载入源图到预览：交给 Border 自绘（可平移/缩放）
func _show_avatar_preview(img: Image) -> void:
	_pending_avatar = img
	avatar_border.set_source_image(img)
	avatar_scale_slider.value = 1.0
	avatar_scale_slider.visible = true

## 缩放滑条：更新缩放并保持位置边界
func _on_avatar_scale_changed(value: float) -> void:
	if _pending_avatar == null:
		return
	avatar_border.set_zoom(value)

## 回到「仅显示当前头像」状态：清除待调整图、隐藏滑条
## 拖拽/缩放/裁剪状态由 Border 内部持有，退出详情页时清空即可恢复显示当前头像
func _reset_avatar_adjust() -> void:
	_pending_avatar = null
	avatar_border.clear_preview()
	avatar_scale_slider.value = 1.0
	avatar_scale_slider.visible = false

# ========== History 页成绩列表加载 ==========

## 加载最近游玩记录
func _load_recent_scores() -> void:
	if _recent_loading:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	_recent_loading = true
	var result: Dictionary = await AuthManager.instance.get_recent_scores(RECORD_PAGE_LIMIT, 0)
	_recent_loading = false
	if not is_instance_valid(self):
		return
	if not result.get("ok", false) or not result.data is Dictionary:
		GLogger.warning("Failed to load recent scores: %s" % str(result.get("error", "")), "ProfilePage")
		return
	_populate_records(recent_list_vbox, result.data.get("records", []), RecordListItem.RecordMode.RECENT)
	_recent_loaded = true

## 加载最佳记录（按 MIDI 去重）
func _load_best_scores() -> void:
	if _best_loading:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	_best_loading = true
	var result: Dictionary = await AuthManager.instance.get_best_scores(RECORD_PAGE_LIMIT, 0)
	_best_loading = false
	if not is_instance_valid(self):
		return
	if not result.get("ok", false) or not result.data is Dictionary:
		GLogger.warning("Failed to load best scores: %s" % str(result.get("error", "")), "ProfilePage")
		return
	_populate_records(best_list_vbox, result.data.get("records", []), RecordListItem.RecordMode.BEST)
	_best_loaded = true

## 加载最多游玩记录
func _load_most_played() -> void:
	if _most_loading:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	_most_loading = true
	var result: Dictionary = await AuthManager.instance.get_most_played(RECORD_PAGE_LIMIT, 0)
	_most_loading = false
	if not is_instance_valid(self):
		return
	if not result.get("ok", false) or not result.data is Dictionary:
		GLogger.warning("Failed to load most played: %s" % str(result.get("error", "")), "ProfilePage")
		return
	_populate_records(most_list_vbox, result.data.get("records", []), RecordListItem.RecordMode.MOST)
	_most_loaded = true

## 清空 VBox 并填充记录项
func _populate_records(vbox: VBoxContainer, records: Array, mode: int) -> void:
	for child in vbox.get_children():
		child.queue_free()
	for record in records:
		var item := RECORD_ITEM_SCENE.instantiate() as RecordListItem
		vbox.add_child(item)
		item.setup_record(record, mode)

## 刷新所有历史列表（成绩上传后调用）：清空已加载标记并重新加载当前 Tab
func refresh_history_lists() -> void:
	_recent_loaded = false
	_best_loaded = false
	_most_loaded = false
	# 重新加载当前可见的 Tab
	match history_list.current_tab:
		LIST_RECENT:
			_load_recent_scores()
		LIST_BEST:
			_load_best_scores()
		LIST_MOST:
			_load_most_played()

## 清空所有历史列表（退出登录时调用）
func clear_history_lists() -> void:
	for child in recent_list_vbox.get_children():
		child.queue_free()
	for child in best_list_vbox.get_children():
		child.queue_free()
	for child in most_list_vbox.get_children():
		child.queue_free()
	_recent_loaded = false
	_best_loaded = false
	_most_loaded = false
