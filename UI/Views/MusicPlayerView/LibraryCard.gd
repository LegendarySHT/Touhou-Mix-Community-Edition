extends PanelContainer
## 曲库网格中的单首歌曲卡片：左封面 / 中信息 / 右上中下三个操作按钮

const COVER_ITEM_PREFIX := "music_player_card_"

## 数据索引（排序结果数组下标），供页面做节点池窗口对齐
var item_index: int = -1
var data_index: int = -1

var _cover_version: int = 0

@onready var _cover: TextureRect = $HBox/Cover
@onready var _album: Label = $HBox/Info/Album
@onready var _song: Label = $HBox/Info/Song
@onready var _artist: Label = $HBox/Info/Artist
@onready var _midi_name: Label = $HBox/Info/MidiName
@onready var _midi_author: Label = $HBox/Info/MidiAuthor
@onready var _next_btn: Button = $HBox/Btns/NextBtn
@onready var _add_btn: Button = $HBox/Btns/AddBtn
@onready var _fav_btn: Button = $HBox/Btns/FavBtn

## 回传轻量投影（Dictionary）
signal play_next_requested(item: Dictionary)
signal add_to_playlist_requested(item: Dictionary)
signal add_to_favorite_requested(item: Dictionary)

## 当前绑定的轻量投影
var item: Dictionary = {}

## 节点是否已 _ready。未 ready 时 @onready 变量为 null，setup_with 里的赋值会静默失败，
## 表现为卡片全是空值。数据先存着，ready 后补刷一次（机制同 SortedMidiListItem._has_ready）
var _has_ready: bool = false

func _ready() -> void:
	_has_ready = true
	_next_btn.pressed.connect(func(): play_next_requested.emit(item))
	_add_btn.pressed.connect(func(): add_to_playlist_requested.emit(item))
	_fav_btn.pressed.connect(_on_fav_pressed)
	# 进树时若已有数据（节点池先 instantiate 再 add_child 后立刻 setup_with），补刷一次
	if not item.is_empty():
		_apply_item()

## item 是 ChartDB.GetSortedMidiListItems 的轻量投影（见 ChartDb.ListItemDict）
## animate_in：数据刷新后首次绑定该槽时播入场动画（滚动补位不播，同 SortedMidiListItem）
func setup_with(p_item: Dictionary, idx: int, animate_in: bool = false) -> void:
	if animate_in:
		modulate.a = 0.0
		AniMGR.animate_fade_in(self, 0.22, "libcard_%d" % get_instance_id())
	item = p_item
	item_index = idx
	data_index = idx
	if not _has_ready:
		return   # 节点还没进树，等 _ready 里补刷
	_apply_item()

func _ready_apply() -> void:
	_apply_item()

## 把 item 的内容刷到界面。文本必须走 set_scroll_text（节点池换绑后才会重算滚动）；
## 五个字段全部取自 ChartDb.ListItemDict 投影（绑定零 DB 查询），映射同 PlayView
func _apply_item() -> void:
	var album := String(item.get("album_name", ""))
	var song := String(item.get("song_name", ""))
	var author := String(item.get("author_name", ""))
	_album.set_scroll_text(album if not album.is_empty() else String(item.get("artist_name", "")))
	_song.set_scroll_text(song if not song.is_empty() else String(item.get("name", "")))
	_artist.set_scroll_text(author if not author.is_empty() else "Unknown")
	_midi_name.set_scroll_text(String(item.get("name", "")))
	_midi_author.set_scroll_text(String(item.get("artist_name", "")))
	_cover.texture = null
	var cover_path := _cover_path_of(item)
	if cover_path.is_empty():
		_cover_version = 0
		return
	_cover_version += 1
	# 用过期的判定用本卡自己的版本号：CoverLoader 的版本是「每 item 各自计数、投递后清零」，
	# 与本卡单调递增的计数会错位（尤其封面路径为空把它重置为 0 之后），拿它的版本比对会永久不显示
	var ver := _cover_version
	CoverLoader.request_load(COVER_ITEM_PREFIX + str(get_instance_id()), cover_path,
		func(_p: String, tex: Texture2D, _v: int): if ver == _cover_version: _cover.texture = tex)

## 封面：投影已带 file_hash / coverHash，直接走 FileSystemManager 的按 id 取图
func _cover_path_of(midi_item: Dictionary) -> String:
	var fs_mgr := FileSystemManager.instance
	if fs_mgr == null:
		return ""
	return fs_mgr.get_cover_path_by_ids(String(midi_item.get("file_hash", "")),
		String(midi_item.get("id", "")))

func _exit_tree() -> void:
	CoverLoader.cancel(COVER_ITEM_PREFIX + str(get_instance_id()))

## 后台内存回收用（见 Core/MemoryGC.gd）：放掉封面纹理引用，并作废在途请求。
## 递增版本号使在途回调失效——否则回调回来还会再把刚刚释放的纹理装回去。
## 下次进曲库时由 LibraryLayer.release_cover_state() → _reconcile_library_pool(true)
## 全量重绑，届时会重新走 _apply_item 重新加载。
func release_cover_state() -> void:
	_cover_version += 1
	CoverLoader.cancel(COVER_ITEM_PREFIX + str(get_instance_id()))
	if _cover != null and is_instance_valid(_cover):
		_cover.texture = null

func _on_fav_pressed() -> void:
	add_to_favorite_requested.emit(item)
