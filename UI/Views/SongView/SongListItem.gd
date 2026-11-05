## 歌曲列表项组件
## 继承自 CoverListItemBase，显示歌曲信息（含封面视差）
class_name SongListItem
extends CoverListItemBase

## 引用节点（需要根据实际场景结构调整）
@onready var song_name_label: Label = $HBoxC/C/SongName
@onready var midi_count_label: Label = %SongCount
@onready var cover: TextureRect = $HBoxC/C/Cover

@onready var animation_manager: AnimationManager = AniMGR

## 歌曲轻量投影数据（ChartDB.GetSongItemsByAlbum 返回的字典）
var item_dict: Dictionary = {}

## 谱面计数圆形标签的背景色（列表容器按主题写入）
## 场景内联 StyleBox 跨实例共享，写任意一个列表项即同步全部歌曲列表项
var midi_count_accent: Color = Color.WHITE:
	set(value):
		midi_count_accent = value
		if midi_count_label == null:
			return
		midi_count_label.get_theme_stylebox("normal").bg_color = value

signal _init_fin

func _ready() -> void:
	# SongListItem 不使用视差滚动（封面静态显示）
	_parallax_enabled = false
	# 给基类 cover_texture 赋值，启用封面加载/释放机制
	cover_texture = $HBoxC/C/Cover
	await _init_fin

	var name_str: String =" %s" % String(item_dict.get("name", "")) if item_dict.get("name", "") else "Unknown"
	# track 兼容 int/float（旧 JSON 可能被存为 1.0，roundi 确保 0.6→1、1.0→1 一致）
	var track_raw = item_dict.get("track", 0)
	var track_val: int = track_raw if typeof(track_raw) == TYPE_INT else int(roundf(float(track_raw)))
	if track_val != 0:
		name_str = "%02d:%s" % [track_val, name_str]
	song_name_label.set_scroll_text(name_str)
	midi_count_label.text = "%d" % item_dict.get("midi_count", 0)

	# 直接开始加载封面（不等列表构建完毕）
	# 命中 WeakRef 缓存时零开销同步应用；未命中则入 CoverLoader 异步队列，不阻塞主线程
	# 列表的 trigger_cover_chain 仍处理"释放后重载"场景（状态切换回视图时）与 path 暂不可用的重试
	start_cover_load()

## 从歌曲轻量投影字典初始化显示（DB 返回，无完整 SongData）
func setup_with_dict(parent: SongView, d: Dictionary, index: int, bg: ButtonGroup) -> void:
	item_dict = d
	item_id = String(d.get("id", ""))
	item_type = "song"
	item_index = index

	button = self
	button.button_group = bg

	enable_selected_animation(button, parent)

	_init_fin.emit()

## 重写基类钩子：封面 texture 设置完成后应用 item_index 静态错位
## 不同歌曲项显示封面图的不同区域，避免所有歌曲显示同一部分
func _on_cover_texture_set() -> void:
	_apply_static_cover_offset(0)

## 应用基于 item_index 的静态错位
## 若布局未稳定（size 为 0），延迟到下一帧重试，最多 10 次后放弃（避免异常布局下无限重试）
func _apply_static_cover_offset(retry: int = 0) -> void:
	if not is_instance_valid(self) or not cover or not cover.texture:
		return
	if cover.size.y <= 0 or self.size.y <= 0:
		if retry < 10:
			# 布局未稳定，下一帧重试（不阻塞 start_cover_load 的 emit 传播）
			call_deferred("_apply_static_cover_offset", retry + 1)
		return
	var cover_h: int = int(max(cover.size.y - self.size.y, 1))
	cover.offset_transform_position.y = -(floori(self.size.y * item_index) % cover_h)

## 重写基类虚函数：返回歌曲封面 Texture2D
## 选择该歌曲下首个 MIDI 的封面，找不到由 FileSystemManager 返回默认封面
func _get_cover_texture() -> Texture2D:
	if item_dict.is_empty():
		return null
	var fs_mgr := FileSystemManager.instance
	if not fs_mgr:
		return null
	return fs_mgr.load_cover_with_cache(fs_mgr.default_cover_if_missing(ChartDB.GetSongCoverPath(String(item_dict.get("id", "")))))

## 重写基类虚函数：返回封面文件路径（主线程调用，供异步加载器使用）
## 路径查询在主线程完成，后台线程只负责读盘
func _resolve_cover_path() -> String:
	if item_dict.is_empty():
		return ""
	var fs_mgr := FileSystemManager.instance
	if not fs_mgr:
		return ""
	var real := fs_mgr.default_cover_if_missing(ChartDB.GetSongCoverPath(String(item_dict.get("id", ""))))
	# 同一 coverHash 的封面内容一致，复用首个解析路径作为缓存键，同 hash 歌曲共享一份 Texture
	return fs_mgr.canonicalize_cover_key(real, String(item_dict.get("coverHash", "")))
