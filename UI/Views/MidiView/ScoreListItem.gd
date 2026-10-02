extends ListItemBase

# 组件宽度缩放适配（手机面板宽 / 桌面面板窄，效果不同）：
# 面板宽度 ≥ SCALE_MAX_WIDTH 时子组件不缩放(1)，≤ SCALE_MIN_WIDTH 时缩到 SCALE_MIN_SCALE，中间线性过渡
const SCALE_MIN_WIDTH := 600.0
const SCALE_MAX_WIDTH := 800.0
const SCALE_MIN_SCALE := 0.8

# 相关节点
@onready var _rank_label: Label = get_node("Rank")
@onready var _score_label: Label = get_node("Score")
@onready var _pp_label: Label = get_node("PP")
@onready var _accuracy_label: Label = get_node("Score/Acc")

@onready var _score_rank_label: Label = get_node("HBox/ScoreRank")
@onready var _avatar_img: TextureRect = get_node("HBox/Avator")
@onready var _player_name_label: Label = get_node("HBox/VBox/Name")

@onready var _perfect_label: Label = get_node("HBox/VBox/Count/perfect")
@onready var _great_label: Label = get_node("HBox/VBox/Count/great")
@onready var _good_label: Label = get_node("HBox/VBox/Count/good")
@onready var _bad_label: Label = get_node("HBox/VBox/Count/bad")
@onready var _miss_label: Label = get_node("HBox/VBox/Count/miss")
@onready var _max_combo_label: Label = get_node("HBox/VBox/Count/maxCombo")

@onready var _scale_comp_list = [
	_pp_label,
	_score_rank_label,
	_avatar_img,
	_player_name_label,
	_perfect_label,
	_great_label,
	_good_label,
	_bad_label,
	_miss_label,
	_max_combo_label
]

# 使用玩家uid查找玩家信息？
var player_uid

func _ready() -> void:
	resized.connect(_update_scale)
	call_deferred("_update_scale")

## 根据当前面板宽度更新各子组件缩放（缩放 pivot 由 tscn 配置，各子节点独立缩放）
func _update_scale() -> void:
	var sc := _compute_scale(size.x)
	for child in _scale_comp_list:
		child.scale = Vector2.ONE * sc

## 线性缩放系数：宽度越窄缩放越小
func _compute_scale(width: float) -> float:
	if width >= SCALE_MAX_WIDTH:
		return 1.0
	if width <= SCALE_MIN_WIDTH:
		return SCALE_MIN_SCALE
	return lerpf(SCALE_MIN_SCALE, 1.0, (width - SCALE_MIN_WIDTH) / (SCALE_MAX_WIDTH - SCALE_MIN_WIDTH))

func setup_score(rank, score, scoreRank, accuracy, pp: float, max_combo: int, perfect_ctn: int, great_ctn: int, good_ctn: int, bad_ctn: int, miss_ctn: int):
	_update_scale()
	_rank_label.text = str(rank)
	_score_label.text = str(score)
	_score_rank_label.text = str(scoreRank)

	_accuracy_label.text = "%.2f%%" % accuracy
	_pp_label.text = "%.2f" % pp

	_max_combo_label.text = str(max_combo)
	_perfect_label.text = str(perfect_ctn)
	_great_label.text = str(great_ctn)
	_good_label.text = str(good_ctn)
	_bad_label.text = str(bad_ctn)
	_miss_label.text = str(miss_ctn)

## 加载玩家头像：avatar_url 为相对路径（如 /avatars/xxx.jpg），空则保持默认
func setup_avatar(avatar_url: String) -> void:
	if avatar_url.is_empty():
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	if _avatar_img == null:
		return
	var full_url := "%s%s" % [NetManager.instance.server_url, avatar_url]
	HttpImageLoader.load(full_url, self, func(tex: Texture2D) -> void:
		if tex and is_instance_valid(_avatar_img):
			_avatar_img.texture = tex
	)

## 设置中途退出（W 评级）状态：整体半透明以区分正常完成记录
func set_withdraw_state(withdraw: bool) -> void:
	modulate.a = 0.4 if withdraw else 1.0

func setup_player_info(uid):
	player_uid = uid
	# 头像，玩家名
	

# 展开该玩家的相关信息
func _on_btn_pressed():
	pass
