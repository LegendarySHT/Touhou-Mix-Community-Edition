## 场景路径注册表（TMX-018）
## 统一收口 Main.tscn 及其懒加载视图的绝对节点路径。
## 修改 Main.tscn / 懒加载视图的节点结构时，只更新本文件即可；
## 业务代码禁止再硬编码 "/root/Main/..." 之类的绝对路径。
class_name PathRegistry

## Main 根节点
const MAIN := "/root/Main"

## skew 容器
const SKEW_C := "/root/Main/Skew/C"
## 静态"选中专辑"头部卡片（SongView 页展示，替代原运行时复制的 SS 节点；隐藏于 AlbumView，转场时显示）
const SELECTED_ALBUM := "/root/Main/Skew/C/SelectedAlbum"

## 静态导航按钮
const LT_BTN := "/root/Main/LTBtn"
const RB_BTN := "/root/Main/RBBtn"

## 常驻 UI
const PLAYER_INFO := "/root/Main/PlayerInfo"
const PLAYER_INFO_TAB_C := "/root/Main/PlayerInfo/InfoPanelBtn/TabC"
const PROFILE_VIEW := "/root/Main/ProfileView"
const CHARACTER := "/root/Main/Chara"

const POPUP_WINDOW_SHADER := "/root/Main/PopupWindowShader"
## 顶部细条进度（后台校验/重扫等"界面仍可操作"的后台任务，无遮罩）
const TASK_PROGRESS := "/root/Main/TaskProgress"
## 通用加载/导入提示（根节点下，ProgressBar 为 ProcessTip 子节点）
const PROCESS_TIP := "/root/Main/ProcessTip"
const PROCESS_PROGRESS := "/root/Main/ProcessTip/ProcessProgress"

## 常驻列表（skew/C 下）
const ALBUM_LIST := "/root/Main/Skew/C/AlbumList"
const SONG_LIST := "/root/Main/Skew/C/SongList"
const SORTED_MIDIS_LIST := "/root/Main/Skew/C/SortedMidisList"
const SHORTCUT_MENU := "/root/Main/Skew/C/ShortCutMenu"
const RANDOM_SELECT_BTN := "/root/Main/Skew/C/RandomSelectBtn"

## 懒加载视图（实例化后存在，读取前请用 get_node_or_null）
const STORE_VIEW := "/root/Main/Store"
const CHARA_VIEW := "/root/Main/CharaView"
const MIDI_VIEW := "/root/Main/Skew/C/MidiView"
const MIDI_LIST := "/root/Main/Skew/C/MidiView/LeftArea/InfoWindow/HBoxC/MidiList"
const TRACK_VIEW := "/root/Main/Skew/C/TrackView"
const SETTING_VIEW := "/root/Main/Skew/C/SettingView"
const PLAY_VIEW := "/root/Main/PlayView"
const SCORE_VIEW := "/root/Main/ScoreView"
const MUSIC_PLAYER_VIEW := "/root/Main/MusicPlayerView"
