extends ViewBase

## CharaListItem 场景（用于动态构建角色列表）
const CHARA_ITEM_SCENE := preload("res://UI/Views/CharaView/CharaListItem.tscn")

## 详情里立绘的浮动振幅（px）与周期（s）
const FLOAT_AMPLITUDE := 10.0
const FLOAT_DURATION := 1.5


## 当前详情展示的角色 key（空表示未展示）
var _detail_key: String = ""
var _floating_tween: Tween = null
var _bg_pan_tween: Tween = null
## 背景可视窗口高度（与 Panel 高度一致，用于计算移动范围）
const PAN_HINT_HEIGHT := 400.0

func _on_view_ready() -> void:
	_build_chara_list()

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）：
## 只重着色「跟随主题」的 UI 元素（标题下划线、选择按钮），角色立绘与文字保持原方案。
func apply_theme() -> void:
	if not ThemeMGR:
		return
	# 标题下划线 → 强调色
	var tsb = %CharaViewTitle.get_theme_stylebox("normal")
	if tsb is StyleBoxFlat:
		tsb.border_color = ThemeMGR.get_color("primary_light")
	# 选择按钮：实心强调色填充，禁用态用凹陷面
	var p := ThemeMGR.get_color("primary")
	for state in ["normal", "pressed", "hover"]:
		if not ThemeMGR.has_local_stylebox(%SelectBtn, state):
			continue
		var sb = %SelectBtn.get_theme_stylebox(state)
		if sb is StyleBoxFlat:
			sb.bg_color = ThemeMGR._tint_keep_alpha(p, sb.bg_color.a)
	if ThemeMGR.has_local_stylebox(%SelectBtn, "disabled"):
		var dsb = %SelectBtn.get_theme_stylebox("disabled")
		if dsb is StyleBoxFlat:
			dsb.bg_color = ThemeMGR._tint_keep_alpha(ThemeMGR.get_color("surface_low"), dsb.bg_color.a)

## 构建角色列表（清空占位项，按 CharaMGR 扫描结果重新生成）
func _build_chara_list() -> void:
	for child in %CharaListRow.get_children():
		child.queue_free()

	var keys := CharaMGR.get_chara_list()
	if keys.is_empty():
		# 扫描可能尚未合并完成，等待扫描结束后重建
		if FileSystemManager.instance and not FileSystemManager.instance.resources_ready.is_connected(_build_chara_list):
			FileSystemManager.instance.resources_ready.connect(_build_chara_list, CONNECT_ONE_SHOT)
		return

	for key in keys:
		var item = CHARA_ITEM_SCENE.instantiate()
		%CharaListRow.add_child(item)
		item.setup_chara(key, CharaMGR.get_chara_data(key))
		item.chara_activated.connect(_open_chara_detail)

############################ 专属入场/退场（由 AnimationManager 调用） ############################

## 入场：CharaList 左滑淡入，Title 下滑淡入
func _play_enter() -> Tween:
	_teardown_detail()
	visible = true
	modulate.a = 1.0
	offset_transform_position = Vector2.ZERO
	AniMGR.animate_fade_slide_in(%CharaList, Vector2(300, 0), 0.35, "CharaListIn")
	AniMGR.animate_fade_slide_in(%CharaViewTitle, Vector2(0, -%CharaViewTitle.size.y), 0.35, "TitleIn")
	return null

## 向右滑出
func _play_exit() -> Tween:
	_stop_floating()
	_teardown_detail()
	var tween := AniMGR.animate_offset_to(self, Vector2(get_viewport().get_visible_rect().size.x, 0), 0.3, "Chara_View_out")
	if tween and tween.is_valid():
		tween.finished.connect(func() -> void:
			if is_instance_valid(self):
				visible = false
		)
	return tween

func _on_chara_detail_close() -> void:
	_close_chara_detail()


func _on_chara_select() -> void:
	if _detail_key.is_empty():
		return
	_select_chara(_detail_key)

############################ CharaDetail 展示 ############################

## 弹出 CharaDetail（并行入场动画）
func _open_chara_detail(chara_key: String) -> void:
	_detail_key = chara_key
	var data := CharaMGR.get_chara_data(chara_key)
	%CharaImg.texture = CharaMGR.get_portrait(chara_key, 0)
	%CharaName.text = str(data.get("name", chara_key))
	%CharaAuthor.text = "立绘 %s" % str(data.get("author", ""))
	%CharaDescription.text = str(data.get("description", ""))
	# 加载角色背景（未配置时保留原默认图）
	var bg := CharaMGR.get_background(chara_key)
	if bg:
		%CharaBGImg.texture = bg

	# 已选中的角色将 SelectBtn 置灰
	var is_current := chara_key == CharaMGR.get_current_chara_key()
	%SelectBtn.disabled = is_current
	%SelectBtn.text = "已选中" if is_current else "选择"

	# 复位各元素状态（保证重复打开时从正确起点播放）
	_stop_floating()
	%CharaInfoBtn.visible = true
	%CharaInfoBtn.modulate.a = 1.0
	_set_back_btn_visible(false)
	_start_bg_pan()
	%CharaInfoPanel.offset_transform_scale = Vector2.ONE
	%CharaName.offset_transform_position = Vector2.ZERO
	%CharaName.offset_transform_scale = Vector2.ONE
	%CharaDescription.offset_transform_position = Vector2.ZERO
	%CharaDescription.offset_transform_scale = Vector2.ONE
	%RightShader.offset_transform_position = Vector2.ZERO
	%CharaAuthor.offset_transform_position = Vector2.ZERO
	%SelectBtn.offset_transform_position = Vector2.ZERO
	%CharaImg.offset_transform_position = Vector2.ZERO
	%CharaImg.offset_transform_scale = Vector2.ONE

	# 并行入场
	AniMGR.animate_fade_scale_in(%CharaInfoPanel, Vector2.ONE * 1.1, 0.35, "detail_panel_in")
	AniMGR.animate_fade_slide_in(%CharaName, Vector2(-100, 0), 0.3, "detail_name_in")
	AniMGR.animate_fade_slide_in(%CharaDescription, Vector2(-100, 0), 0.3, "detail_desc_in")
	AniMGR.animate_fade_slide_in(%RightShader, Vector2(%RightShader.size.x, 0), 0.3, "detail_rshader_in")
	AniMGR.animate_fade_slide_in(%CharaAuthor, Vector2(%CharaAuthor.size.x, 0), 0.3, "detail_illu_in")
	AniMGR.animate_fade_slide_in(%SelectBtn, Vector2(%SelectBtn.size.x, 0), 0.3, "detail_btn_in")
	var chara_in := AniMGR.animate_fade_slide_scale_in(%CharaImg, Vector2(0, %CharaImg.size.y), Vector2.ONE * 1.01, 0.35, "detail_chara_in")
	# 立绘入场完成后开始上下浮动
	chara_in.finished.connect(_start_floating, CONNECT_ONE_SHOT)

## 关闭 CharaDetail（并行退场动画，结束后隐藏整个详情）
func _close_chara_detail() -> void:
	if not %CharaInfoBtn.visible:
		return
	_stop_floating()
	_stop_bg_pan()
	# Chara 与 Panel 轻微缩小淡出；其余做入场反向（滑回原位反方向）
	AniMGR.animate_fade_scale_out(%CharaInfoPanel, Vector2.ONE * 0.96, 0.25, "detail_panel_out")
	AniMGR.animate_fade_scale_out(%CharaImg, Vector2.ONE * 0.96, 0.25, "detail_chara_out")
	AniMGR.animate_fade_scale_out(%CharaName, Vector2.ONE * 0.96, 0.25, "detail_name_out")
	AniMGR.animate_fade_scale_out(%CharaDescription, Vector2.ONE * 0.96, 0.25, "detail_desc_out")
	AniMGR.animate_fade_slide_out(%RightShader, Vector2(%RightShader.size.x, 0), 0.25, "detail_rshader_out")
	AniMGR.animate_fade_slide_out(%CharaAuthor, Vector2(%CharaAuthor.size.x, 0), 0.25, "detail_illu_out")
	AniMGR.animate_fade_slide_out(%SelectBtn, Vector2(%SelectBtn.size.x, 0), 0.25, "detail_btn_out")
	AniMGR.delay_call(_hide_detail, 0.3, "detail_hide")

func _hide_detail() -> void:
	%CharaInfoBtn.visible = false
	_set_back_btn_visible(true)

## 选中角色：写入配置持久化并把 SelectBtn 置灰
func _select_chara(chara_key: String) -> void:
	if ConfigManager.instance:
		ConfigManager.instance.set_value_and_notify("chara_id", chara_key)
		ConfigManager.instance.save_config(ConfigManager.instance.USER_CONFIG_PATH)
	%SelectBtn.disabled = true
	%SelectBtn.text = "已选中"
	GLogger.info("Chara selected: %s" % chara_key, "CharaView")

## 立绘上下浮动循环动画
func _start_floating() -> void:
	if not %CharaInfoBtn.visible or %CharaImg.texture == null:
		return
	_stop_floating()
	%CharaImg.offset_transform_position = Vector2.ZERO
	_floating_tween = AniMGR.animate_floating(%CharaImg, FLOAT_AMPLITUDE, FLOAT_DURATION, "detail_chara_float")

func _stop_floating() -> void:
	if _floating_tween and _floating_tween.is_valid():
		_floating_tween.kill()
		_floating_tween = null
	%CharaImg.offset_transform_position = Vector2.ZERO

## 背景上下来回缓慢移动（ratio 0..1-400/高，一个来回约 20s）
func _start_bg_pan() -> void:
	_stop_bg_pan()
	if %CharaBGImg.size.y <= 0:
		return
	var max_ratio = PAN_HINT_HEIGHT / %CharaBGImg.size.y - 1.0
	%CharaBGImg.offset_transform_enabled = true
	%CharaBGImg.offset_transform_position_ratio = Vector2.ZERO
	_bg_pan_tween = create_tween()
	_bg_pan_tween.set_loops()
	_bg_pan_tween.set_trans(Tween.TRANS_SINE)
	_bg_pan_tween.set_ease(Tween.EASE_IN_OUT)
	_bg_pan_tween.tween_property(%CharaBGImg, "offset_transform_position_ratio:y", max_ratio, 25.0)
	_bg_pan_tween.tween_property(%CharaBGImg, "offset_transform_position_ratio:y", 0.0, 25.0)

func _stop_bg_pan() -> void:
	if _bg_pan_tween and _bg_pan_tween.is_valid():
		_bg_pan_tween.kill()
		_bg_pan_tween = null
	%CharaBGImg.offset_transform_position_ratio = Vector2.ZERO

## 立即撤下详情并复位（进入/退出视图时调用，避免残留动画）
func _teardown_detail() -> void:
	_stop_floating()
	_stop_bg_pan()
	%CharaInfoBtn.visible = false
	_set_back_btn_visible(true)
	%CharaInfoPanel.offset_transform_scale = Vector2.ONE
	%CharaImg.offset_transform_scale = Vector2.ONE

## 弹窗展示期间临时隐藏右下角返回按钮（恢复时置回）
func _set_back_btn_visible(shown: bool) -> void:
	if RB_Btn.instance:
		RB_Btn.instance.visible = shown
