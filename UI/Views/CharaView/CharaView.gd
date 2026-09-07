extends Control

## CharaListItem 场景（用于动态构建角色列表）
const CHARA_ITEM_SCENE := preload("res://UI/Views/CharaView/CharaListItem.tscn")

@onready var _hbox: HBoxContainer = $CharaList/HBox
@onready var _chara_list: ScrollContainer = $CharaList
@onready var _title: Label = $Title
@onready var _detail: TextureButton = $CharaDetail
@onready var _detail_panel: Panel = $CharaDetail/Panel
@onready var _detail_bg: TextureRect = $CharaDetail/Panel/BG
@onready var _detail_right_shader: TextureRect = $CharaDetail/RightShader
@onready var _detail_desc: Label = $CharaDetail/Desc
@onready var _detail_name: Label = $CharaDetail/Name
@onready var _detail_illustrator: Label = $CharaDetail/Illustrator
@onready var _detail_select_btn: Button = $CharaDetail/SelectBtn
@onready var _detail_chara: TextureRect = $CharaDetail/Chara

## 当前详情展示的角色 key（空表示未展示）
var _detail_key: String = ""
var _portrait: DynamicPortrait
var _default_background: Texture2D
## 背景可视窗口高度（与 Panel 高度一致，用于计算移动范围）
const PAN_HINT_HEIGHT := 400.0

func _ready() -> void:
	_default_background = _detail_bg.texture
	_portrait = DynamicPortrait.new()
	_detail_chara.add_child(_portrait)
	_portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detail_chara.self_modulate.a = 0.0
	_build_chara_list()

func _exit_tree() -> void:
	_stop_detail_tweens()
	_stop_bg_pan()
	_stop_portrait()
	AniMGR.stop_tween("Chara_View_out")
	AniMGR.stop_tween("CharaListIn")
	AniMGR.stop_tween("TitleIn")

## 构建角色列表（清空占位项，按 CharaMGR 扫描结果重新生成）
func _build_chara_list() -> void:
	for child in _hbox.get_children():
		child.queue_free()

	var keys := CharaMGR.get_chara_list()
	if keys.is_empty():
		# 扫描可能尚未合并完成，等待扫描结束后重建
		if FileSystemManager.instance and not FileSystemManager.instance.resources_ready.is_connected(_build_chara_list):
			FileSystemManager.instance.resources_ready.connect(_build_chara_list, CONNECT_ONE_SHOT)
		return

	for key in keys:
		var item = CHARA_ITEM_SCENE.instantiate()
		_hbox.add_child(item)
		item.setup_chara(key, CharaMGR.get_chara_data(key))
		item.chara_activated.connect(_open_chara_detail)

############################ 专属入场/退场（由 AnimationManager 调用） ############################

## 入场：CharaList 左滑淡入，Title 下滑淡入
func play_enter() -> void:
	AniMGR.stop_tween("Chara_View_out")
	_teardown_detail()
	visible = true
	modulate.a = 1.0
	offset_transform_position = Vector2.ZERO
	AniMGR.animate_fade_slide_in(_chara_list, Vector2(300, 0), 0.35, "CharaListIn")
	AniMGR.animate_fade_slide_in(_title, Vector2(0, -_title.size.y), 0.35, "TitleIn")

## 向右滑出
func play_exit() -> void:
	_teardown_detail()
	var tween := AniMGR.animate_offset_to(self, Vector2(get_viewport().get_visible_rect().size.x, 0), 0.3, "Chara_View_out")
	tween.finished.connect(func() -> void:
		visible = false
	)

func _on_chara_detail_close() -> void:
	_close_chara_detail()


func _on_chara_select() -> void:
	if _detail_key.is_empty():
		return
	_select_chara(_detail_key)

############################ CharaDetail 展示 ############################

## 弹出 CharaDetail（并行入场动画）
func _open_chara_detail(chara_key: String) -> void:
	_teardown_detail()
	_detail_key = chara_key
	var data := CharaMGR.get_chara_data(chara_key)
	_detail_chara.texture = CharaMGR.get_portrait(chara_key, 0)
	_portrait.show_character(chara_key)
	_detail_name.text = str(data.get("name", chara_key))
	_detail_illustrator.text = "插图 %s" % str(data.get("author", ""))
	_detail_desc.text = str(data.get("description", ""))
	# 加载角色背景（未配置时保留原默认图）
	var bg := CharaMGR.get_background(chara_key)
	_detail_bg.texture = bg if bg != null else _default_background

	# 已选中的角色将 SelectBtn 置灰
	var is_current := chara_key == CharaMGR.get_current_chara_key()
	_detail_select_btn.disabled = is_current
	_detail_select_btn.text = "已选中" if is_current else "选择"

	# 复位各元素状态（保证重复打开时从正确起点播放）
	_detail.visible = true
	_detail.modulate.a = 1.0
	_set_back_btn_visible(false)
	_start_bg_pan()
	_detail_panel.offset_transform_scale = Vector2.ONE
	_detail_name.offset_transform_position = Vector2.ZERO
	_detail_name.offset_transform_scale = Vector2.ONE
	_detail_desc.offset_transform_position = Vector2.ZERO
	_detail_desc.offset_transform_scale = Vector2.ONE
	_detail_right_shader.offset_transform_position = Vector2.ZERO
	_detail_illustrator.offset_transform_position = Vector2.ZERO
	_detail_select_btn.offset_transform_position = Vector2.ZERO
	_detail_chara.offset_transform_position = Vector2.ZERO
	_detail_chara.offset_transform_scale = Vector2.ONE

	# 并行入场
	AniMGR.animate_fade_scale_in(_detail_panel, Vector2.ONE * 1.1, 0.35, "detail_panel_in")
	AniMGR.animate_fade_slide_in(_detail_name, Vector2(-100, 0), 0.3, "detail_name_in")
	AniMGR.animate_fade_slide_in(_detail_desc, Vector2(-100, 0), 0.3, "detail_desc_in")
	AniMGR.animate_fade_slide_in(_detail_right_shader, Vector2(_detail_right_shader.size.x, 0), 0.3, "detail_rshader_in")
	AniMGR.animate_fade_slide_in(_detail_illustrator, Vector2(_detail_illustrator.size.x, 0), 0.3, "detail_illu_in")
	AniMGR.animate_fade_slide_in(_detail_select_btn, Vector2(_detail_select_btn.size.x, 0), 0.3, "detail_btn_in")
	var chara_in := AniMGR.animate_fade_slide_scale_in(_detail_chara, Vector2(0, _detail_chara.size.y), Vector2.ONE * 1.01, 0.35, "detail_chara_in")
	chara_in.finished.connect(_start_portrait, CONNECT_ONE_SHOT)

## 关闭 CharaDetail（并行退场动画，结束后隐藏整个详情）
func _close_chara_detail() -> void:
	if not _detail.visible:
		return
	_stop_detail_tweens()
	_stop_portrait()
	_stop_bg_pan()
	# Chara 与 Panel 轻微缩小淡出；其余做入场反向（滑回原位反方向）
	AniMGR.animate_fade_scale_out(_detail_panel, Vector2.ONE * 0.96, 0.25, "detail_panel_out")
	AniMGR.animate_fade_scale_out(_detail_chara, Vector2.ONE * 0.96, 0.25, "detail_chara_out")
	AniMGR.animate_fade_scale_out(_detail_name, Vector2.ONE * 0.96, 0.25, "detail_name_out")
	AniMGR.animate_fade_scale_out(_detail_desc, Vector2.ONE * 0.96, 0.25, "detail_desc_out")
	AniMGR.animate_fade_slide_out(_detail_right_shader, Vector2(_detail_right_shader.size.x, 0), 0.25, "detail_rshader_out")
	AniMGR.animate_fade_slide_out(_detail_illustrator, Vector2(_detail_illustrator.size.x, 0), 0.25, "detail_illu_out")
	AniMGR.animate_fade_slide_out(_detail_select_btn, Vector2(_detail_select_btn.size.x, 0), 0.25, "detail_btn_out")
	AniMGR.delay_call(_hide_detail, 0.3, "detail_hide")

func _hide_detail() -> void:
	_stop_portrait()
	_detail.visible = false
	_set_back_btn_visible(true)

## 选中角色：写入配置持久化并把 SelectBtn 置灰
func _select_chara(chara_key: String) -> void:
	if ConfigManager.instance:
		ConfigManager.instance.set_value_and_notify("Chara", "chara_id", chara_key)
		ConfigManager.instance.save_config(ConfigManager.instance.USER_CONFIG_PATH)
	_detail_select_btn.disabled = true
	_detail_select_btn.text = "已选中"
	GLogger.info("Chara selected: %s" % chara_key, "CharaView")

func _start_portrait() -> void:
	_portrait.set_active(_detail.visible and UiStatMGR.current_state == UIStateManager.UIState.CHARA_VIEW)

func _stop_portrait() -> void:
	if is_instance_valid(_portrait):
		_portrait.set_active(false)

func _stop_detail_tweens() -> void:
	AniMGR.stop_tween("detail_hide")
	for part in ["panel", "chara", "name", "desc", "rshader", "illu", "btn"]:
		AniMGR.stop_tween("detail_%s_in" % part)
		AniMGR.stop_tween("detail_%s_out" % part)

## 背景上下来回缓慢移动（ratio 0..1-400/高，一个来回约 20s）
func _start_bg_pan() -> void:
	_stop_bg_pan()
	if _detail_bg.size.y <= 0:
		return
	var max_ratio := PAN_HINT_HEIGHT / _detail_bg.size.y - 1.0
	_detail_bg.offset_transform_enabled = true
	_detail_bg.offset_transform_position_ratio = Vector2.ZERO
	var _bg_pan_tween := AniMGR.create_managed_tween(self, "chara_view_%s_bg" % get_instance_id())
	_bg_pan_tween.set_loops()
	_bg_pan_tween.set_trans(Tween.TRANS_SINE)
	_bg_pan_tween.set_ease(Tween.EASE_IN_OUT)
	_bg_pan_tween.tween_property(_detail_bg, "offset_transform_position_ratio:y", max_ratio, 25.0)
	_bg_pan_tween.tween_property(_detail_bg, "offset_transform_position_ratio:y", 0.0, 25.0)

func _stop_bg_pan() -> void:
	AniMGR.stop_tween("chara_view_%s_bg" % get_instance_id())
	_detail_bg.offset_transform_position_ratio = Vector2.ZERO

## 立即撤下详情并复位（进入/退出视图时调用，避免残留动画）
func _teardown_detail() -> void:
	_stop_detail_tweens()
	_stop_portrait()
	_stop_bg_pan()
	_detail.visible = false
	_set_back_btn_visible(true)
	_detail_panel.offset_transform_scale = Vector2.ONE
	_detail_chara.offset_transform_scale = Vector2.ONE

## 弹窗展示期间临时隐藏右下角返回按钮（恢复时置回）
func _set_back_btn_visible(shown: bool) -> void:
	if RB_Btn.instance:
		RB_Btn.instance.visible = shown
