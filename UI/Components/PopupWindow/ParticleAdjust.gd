extends HBoxContainer

class_name ParticleAdjust

@onready var _particle_preview: Panel = $ParticlePreview
@onready var _title_label: Label = $VBoxC/Title
@onready var _basic_particle_btn: OptionButton = $VBoxC/Options/BasicParticle
@onready var _emitter_btn: OptionButton = $VBoxC/Options/ParticleEmitter
@onready var _total_scale_edit: LineEdit = $VBoxC/Options/TotalScale/LineEdit
@onready var _total_alpha_edit: LineEdit = $VBoxC/Options/TotalAlpha/LineEdit
@onready var _emitter_scale_edit: LineEdit = $VBoxC/Options/EmitterScale/LineEdit
## 四种判定类型的切换按钮（与 _judge_type 一一对应）
@onready var _judge_btns: Array[Button] = [
	$VBoxC/JudgeSwitch/Perfect,
	$VBoxC/JudgeSwitch/Great,
	$VBoxC/JudgeSwitch/Good,
	$VBoxC/JudgeSwitch/Bad,
]

# ===== 粒子设置页 =====
## 支持的判定类型（与配置键 {j}_spark_* 及 FlowArea spark 判定名一一对应）
const JUDGE_TYPES: Array[String] = ["Perfect", "Great", "Good", "Bad"]
## 粒子 preset 选项（索引 0=None，之后动态从 ParticleMGR 读取粒子包）
## 下拉项即粒子包完整名字（如 "BoxBurst [内置]"）；配置按名字读写而非索引，避免新增包时索引错位
## 每个下拉只列出声明了对应角色精灵图的粒子包：有 [base] 才进基础下拉，有 [emitter] 才进散射下拉
var _base_presets: Array[String] = ["None"]
var _emitter_presets: Array[String] = ["None"]
## 粒子预览场景（精灵图序列帧批绘节点）
var _particle_scene: PackedScene = preload("res://UI/Views/PlayView/particle_player.tscn")
## 常驻批绘节点（预览粒子全部由单个 Node2D 统一绘制）
var _particle_drawer: Node2D = null
## 预览循环定时器
var _particle_preview_timer: Timer = null
## 粒子预览自动播放间隔（秒）
const _PARTICLE_PREVIEW_INTERVAL: float = 1.8
## 数值输入防抖定时器（连续输入时只保存 + 预览一次，避免逐字符写盘/重复实例化）
var _value_debounce_timer: Timer = null
const _VALUE_DEBOUNCE_SEC := 0.4

## 当前正在编辑的判定类型（Perfect / Great / Good / Bad）
## 由 PopupWindow.show_particle_adjust 传入，决定读写哪个 spark 配置字段
var _judge_type: String = "Perfect"

func _ready() -> void:
	_basic_particle_btn.item_selected.connect(_on_preset_changed)
	_emitter_btn.item_selected.connect(_on_preset_changed)
	_total_scale_edit.text_changed.connect(_on_value_changed)
	_total_alpha_edit.text_changed.connect(_on_value_changed)
	_emitter_scale_edit.text_changed.connect(_on_value_changed)
	# 判定类型切换按钮（同一 ButtonGroup，点击后切到对应判定类型）
	for i in JUDGE_TYPES.size():
		_judge_btns[i].pressed.connect(_on_judge_pressed.bind(JUDGE_TYPES[i]))
	# 常驻单个批绘节点，预览粒子由它统一绘制
	_particle_drawer = _particle_scene.instantiate()
	_particle_preview.add_child(_particle_drawer)
	_init_particle_preview()
	_init_value_debounce()

## 初始化数值防抖定时器（one-shot，连续输入只触发一次保存 + 预览）
func _init_value_debounce() -> void:
	_value_debounce_timer = Timer.new()
	_value_debounce_timer.one_shot = true
	_value_debounce_timer.wait_time = _VALUE_DEBOUNCE_SEC
	_value_debounce_timer.timeout.connect(_apply_values_debounced)
	add_child(_value_debounce_timer)

## 初始化粒子预览循环定时器（粒子由常驻批绘节点统一绘制，定时触发 spawn）
func _init_particle_preview() -> void:
	_particle_preview_timer = Timer.new()
	_particle_preview_timer.wait_time = _PARTICLE_PREVIEW_INTERVAL
	_particle_preview_timer.timeout.connect(_play_preview_particle)
	add_child(_particle_preview_timer)

## 由 PopupWindow.show_particle_adjust 调用：填充选项 + 选中当前配置值
## judge_type: 初始选中的判定类型（Perfect / Great / Good / Bad），弹窗内可随时切换
func init_adjust(judge_type: String = "Perfect") -> void:
	_judge_type = judge_type
	_title_label.text = "%s 特效设定" % judge_type
	# 刷新粒子样式选项（动态从 ParticleMGR 读取，支持外部导入的粒子包）
	_refresh_presets()
	_update_switch_buttons()
	_load_current_values()

## 切换判定类型：先保存当前判定类型的设置，再载入目标判定类型并预览一次
func _on_judge_pressed(judge_type: String) -> void:
	if _judge_type == judge_type:
		return
	_save_current()
	_judge_type = judge_type
	_update_switch_buttons()
	_load_current_values()
	_play_preview_particle()

## 更新切换按钮的选中态与窗口标题（与 _judge_type 一致）
func _update_switch_buttons() -> void:
	for i in JUDGE_TYPES.size():
		_judge_btns[i].button_pressed = (JUDGE_TYPES[i] == _judge_type)
	_title_label.text = "%s 特效设定" % _judge_type

## 从配置读取当前判定类型的数值填充到控件（临时断开信号避免回环）
func _load_current_values() -> void:
	var jl := _judge_type.to_lower()
	# 基础粒子 preset（配置存粒子包名字，找不到回退 None=索引0）
	var preset_name: String = ConfigManager.instance.get_string("Lane", jl + "_spark_preset", "")
	_basic_particle_btn.selected = _preset_index_of(preset_name, _base_presets)
	# 散射粒子 preset
	var emitter_name: String = ConfigManager.instance.get_string("Lane", jl + "_spark_emitter", "")
	_emitter_btn.selected = _preset_index_of(emitter_name, _emitter_presets)
	# 三个数值（临时断开信号避免回环）
	_total_scale_edit.text_changed.disconnect(_on_value_changed)
	_total_scale_edit.text = str(ConfigManager.instance.get_int("Lane", jl + "_spark_scaling", 100))
	_total_scale_edit.text_changed.connect(_on_value_changed)
	_total_alpha_edit.text_changed.disconnect(_on_value_changed)
	_total_alpha_edit.text = str(ConfigManager.instance.get_int("Lane", jl + "_spark_alpha", 100))
	_total_alpha_edit.text_changed.connect(_on_value_changed)
	_emitter_scale_edit.text_changed.disconnect(_on_value_changed)
	_emitter_scale_edit.text = str(ConfigManager.instance.get_int("Lane", jl + "_spark_emitter_scaling", 150))
	_emitter_scale_edit.text_changed.connect(_on_value_changed)

## 刷新粒子包选项列表（索引 0=None，1 起按 ParticleMGR 扫描顺序）
## 基础下拉只列声明了 [base] 的包，散射下拉只列声明了 [emitter] 的包；
## 两种角色都声明的包（复合包）会同时出现在两个下拉
func _refresh_presets() -> void:
	_base_presets = ["None"]
	_emitter_presets = ["None"]
	for pack_key in ParticleMGR.get_particle_list_for_role(ParticleMGR.ROLE_BASE):
		_base_presets.append(pack_key)
	for pack_key in ParticleMGR.get_particle_list_for_role(ParticleMGR.ROLE_EMITTER):
		_emitter_presets.append(pack_key)
	_fill_btn(_basic_particle_btn, _base_presets)
	_fill_btn(_emitter_btn, _emitter_presets)

## 用指定选项列表填充一个 OptionButton
func _fill_btn(btn: OptionButton, list: Array) -> void:
	btn.clear()
	for pack_name in list:
		btn.add_item(pack_name)

## 读取百分比数值输入（非法回退默认值）
func _read_pct(edit: LineEdit, default: int) -> int:
	var text := edit.text
	return int(text) if text.is_valid_int() else default

## 配置中存的是粒子包名字（如 "Diamond-Rainbow [内置]"），转成对应角色下拉的索引；找不到 → 0(None)
func _preset_index_of(preset_name: String, list: Array) -> int:
	if preset_name.is_empty():
		return 0
	var idx := list.find(preset_name)
	return idx if idx >= 0 else 0

## 播放一次预览粒子（在 ParticlePreview 中心，使用当前选中的预设与数值）
## 由常驻批绘节点直接 spawn，粒子内部 _process/_draw 统一推进绘制
func _play_preview_particle() -> void:
	if not is_visible_in_tree():
		return
	# base 与 emitter 都为 None 时不播放
	var base_idx: int = _basic_particle_btn.selected
	var emitter_idx: int = _emitter_btn.selected
	if base_idx == 0 and emitter_idx == 0:
		return
	var base_key: String = _base_presets[base_idx] if base_idx > 0 else ""
	var emitter_key: String = _emitter_presets[emitter_idx] if emitter_idx > 0 else ""
	# 数值预换算为倍率/不透明度再传 spawn（spawn 内部不再除 100）
	var scale_mult := float(_read_pct(_total_scale_edit, 100)) / 100.0
	var alpha := clampf(float(_read_pct(_total_alpha_edit, 100)) / 100.0, 0.0, 1.0)
	var emitter_scale_mult := float(_read_pct(_emitter_scale_edit, 150)) / 100.0
	# 单节点批绘：直接 spawn，粒子由内部 _process/_draw 统一推进绘制
	# Node2D 在 Control 下的 position 以左上角为原点，Panel size=500x500 → 中心 250,250
	_particle_drawer.spawn(base_key, emitter_key, _particle_preview.size / 2.0,
		scale_mult, alpha, emitter_scale_mult)

## 启动粒子预览循环
func start_preview() -> void:
	if _particle_preview_timer:
		_particle_preview_timer.start()
	# 立即播放一次
	_play_preview_particle()

## 停止粒子预览循环
## 同时清空残留粒子：弹窗关闭后无需继续推进/绘制预览粒子，避免空跑 _process 直到自然衰减
func stop_preview() -> void:
	if _particle_preview_timer and not _particle_preview_timer.is_stopped():
		_particle_preview_timer.stop()
	if _particle_drawer:
		_particle_drawer.clear()

## 将当前所有控件值写入对应判定类型的配置字段（set_value_and_notify 即时应用 + 热更新）
func _save_current() -> void:
	var jl := _judge_type.to_lower()
	ConfigManager.instance.set_value_and_notify("Lane", jl + "_spark_preset", _base_presets[_basic_particle_btn.selected])
	ConfigManager.instance.set_value_and_notify("Lane", jl + "_spark_emitter", _emitter_presets[_emitter_btn.selected])
	ConfigManager.instance.set_value_and_notify("Lane", jl + "_spark_scaling", _read_pct(_total_scale_edit, 100))
	ConfigManager.instance.set_value_and_notify("Lane", jl + "_spark_alpha", _read_pct(_total_alpha_edit, 100))
	ConfigManager.instance.set_value_and_notify("Lane", jl + "_spark_emitter_scaling", _read_pct(_emitter_scale_edit, 150))

## 切换基础/散射粒子下拉：即时保存到对应判定类型的配置字段并播放一次预览
func _on_preset_changed(_index: int) -> void:
	_save_current()
	_play_preview_particle()

## 数值输入修改：重启防抖定时器，停顿后统一保存 + 播放预览
func _on_value_changed(_new_text: String) -> void:
	_value_debounce_timer.start()

## 防抖触发：将当前数值保存到对应判定类型的配置字段并播放一次预览
func _apply_values_debounced() -> void:
	_save_current()
	# 弹窗已关闭时不再重复播放预览（配置保存本身无副作用）
	if is_visible_in_tree():
		_play_preview_particle()

## 返回当前全部四种判定类型的粒子设置（供 PopupWindow.show_particle_adjust 返回）
## 结构：{"by_judge": {"Perfect": {...}, "Great": {...}, ...}}
## 读取前先强制保存当前判定类型（其控件值可能仍处于防抖计时中未落库）；
## 其它判定类型在切换离开时已通过 _on_judge_pressed → _save_current 落库
func get_result() -> Dictionary:
	_save_current()
	var by_judge: Dictionary = {}
	for judge in JUDGE_TYPES:
		var jl := judge.to_lower()
		by_judge[judge] = {
			"preset": ConfigManager.instance.get_string("Lane", jl + "_spark_preset", ""),
			"emitter": ConfigManager.instance.get_string("Lane", jl + "_spark_emitter", ""),
			"scaling": ConfigManager.instance.get_int("Lane", jl + "_spark_scaling", 100),
			"alpha": ConfigManager.instance.get_int("Lane", jl + "_spark_alpha", 100),
			"emitter_scaling": ConfigManager.instance.get_int("Lane", jl + "_spark_emitter_scaling", 150),
		}
	return {"by_judge": by_judge}
