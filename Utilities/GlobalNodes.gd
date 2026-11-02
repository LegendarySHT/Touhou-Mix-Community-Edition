## 全局节点表
##
## 统一收口常驻 UI 节点的节点引用（不再保存 `/root/Main/...` 绝对路径）。
## 注册方：
##   - Main：Main 直属常驻节点（_enter_tree 内注册，早于子节点 _ready）
##   - UIStateManager：懒加载视图首次实例化后注册
##   - MidiView / PlayerInfoPanel：各自场景内部需要跨场景访问的子节点
##
## 未加载/未注册的节点对应字段为 null，读取方按需判空。
## 节点结构改名时只需改注册处，不再需要遍历业务代码里的路径字符串。
class_name GlobalNodes

## 主场景根节点
static var main: Control
## 斜向容器 Skew 下的 Control（视图挂载区）
static var skew_c: Control

# ========== Main 直属常驻节点 ==========

## 静态"选中专辑"头部卡片（SongView 页展示）
static var selected_album: AlbumListItem
## 快捷菜单侧栏
static var shortcut_menu: Shortcut_Menu
## 玩家信息面板
static var player_info: PlayerInfoPanel
## 玩家信息面板内的页签容器（ScoreView 读取）
static var player_info_tabs: TabContainer
## 左下 / 右下角导航按钮
static var lt_btn: LT_Btn
static var rb_btn: RB_Btn
## 右下角人物立绘容器
static var character: Control
## 随机选专辑按钮
static var random_select_btn: Button

## 后台任务 / 提示 UI
static var popup_window_shader: ColorRect
static var task_progress: ProgressBar
static var process_tip: Label
static var process_progress: ProgressBar

# ========== 常驻列表 ==========

static var album_view: AlbumView
static var song_view: SongView
static var sorted_view: SortedMidiView
## MidiView 内部的谱面列表
static var midi_list: MidiList

# ========== 懒加载视图（首次进入对应状态时注册） ==========

static var midi_view: MidiView
## TrackView 的场景根（列表逻辑在其 PageContent 的 TrackView 里）
static var track_view: TrackViewRoot
static var setting_view: SettingView
static var play_view: PlayView
static var score_view: ScoreView
static var store_view: StoreView
static var chara_view: CharaView
static var profile_view: ProfileView
static var music_player_view: MusicPlayerView
