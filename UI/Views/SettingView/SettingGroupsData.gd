## 设置项分组静态数据
## 从 SettingList.gd 外移，纯数据无逻辑
##
## 设置项可选标记：
## - "not_implemented": true  → 该项暂未实装，load_settings 时跳过创建 UI（不显示、不保存）
##                              实装后改为 false 或删除该行即可恢复显示
## - "advanced": true         → 该项为高级设置，由 "show_advanced_settings" 开关控制可见性
##                              默认隐藏，开启"显示高级设置项"后显示
class_name SettingGroupsData
extends RefCounted

static func get_setting_groups() -> Array:
	return [
	{
		"name": "常规设置",
		"settings": [
			{
				"id": "album_sort_method",
				"name_en": "Album Sort Method",
				"name_zh": "专辑排序方式",
				"description": "选择专辑列表的默认排序方式",
				"type": "TYPE_OPTION",
				"default_value": "creation_time",
				"options": [
					{"text_en": "By Creation Time", "text_zh": "按创建时间"},
					{"text_en": "By Download Time", "text_zh": "按下载时间"}
				],
				"option_values": ["creation_time", "download_time"]
			},
			{
				"id": "album_sort_direction",
				"name_en": "Album Sort Direction",
				"name_zh": "专辑排序方向",
				"description": "选择专辑列表的正序或倒序排列",
				"type": "TYPE_OPTION",
				"default_value": "asc",
				"options": [
					{"text_en": "Oldest First", "text_zh": "从旧到新"},
					{"text_en": "Newest First", "text_zh": "从新到旧"}
				],
				"option_values": ["asc", "desc"]
			},
			{
				"id": "show_advanced_settings",
				"name_en": "Show Advanced Settings",
				"name_zh": "显示高级设置项",
				"description": "控制是否显示通常不需要调整的高级设置项",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"options": [
					{"text_en": "Off", "text_zh": "关闭"},
					{"text_en": "On", "text_zh": "开启"}
				]
			},
			{
				"id": "display_debug_info",
				"name_en": "Display Debug Info",
				"name_zh": "显示调试信息",
				"description": "在游玩界面实时显示FPS、渲染和内存状态",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"advanced": true,
				"options": [
					{"text_en": "Off", "text_zh": "关闭"},
					{"text_en": "On", "text_zh": "开启"}
				]
			},
			{
			"id": "online_mode",
			"name_en": "Online Mode",
			"name_zh": "线上模式",
			"description": "是否启用登录，谱面下载等联网功能",
			"type": "TYPE_OPTION",
			"default_value": "0",
			"options": [
				{"text_en": "Off", "text_zh": "关闭"},
				{"text_en": "On", "text_zh": "开启"}
			]
		},
		{
			"id": "auto_upload_score",
			"name_en": "Auto Upload Score",
			"name_zh": "自动上传成绩",
			"description": "开启后将自动在结算页面上传成绩，否则需手动上传",
			"type": "TYPE_OPTION",
			"default_value": "1",
			"options": [
				{"text_en": "Off", "text_zh": "关闭"},
				{"text_en": "On", "text_zh": "开启"}
			]
		},
			{
				"id": "language",
				"name_en": "Language",
				"name_zh": "语言",
				"description": "选择游戏界面的语言",
				"type": "TYPE_OPTION",
				"default_value": "1",
				"not_implemented": true,
				"options": [
					{"text_en": "English", "text_zh": "英文"},
					{"text_en": "Chinese", "text_zh": "中文"}
				]
			},
			{
				"id": "server_address",
				"name_en": "Server Address",
				"name_zh": "服务器地址",
				"description": "输入服务器的地址",
				"type": "TYPE_LINE_EDIT",
				"default_value": "thmix.org",
			},
			{
			"id": "reload_builtin_resources",
			"name_en": "Reload Built-in Resources",
			"name_zh": "重置内置资源",
			"description": "点击后，内置的资源将重新加载",
			"type": "TYPE_BUTTON",
			"default_value": null,
			"on_click": "_reload_builtin_resources"
		},
		{
			"id": "storage_location",
			"name_en": "Storage Location",
			"name_zh": "资源存储位置",
			"description": "设置曲包/音源/皮肤/背景图等资源文件以及设置、收藏、日志的保存路径。更改后游戏会迁移现有资源，并在下次启动时生效",
			"type": "TYPE_BUTTON",
			"default_value": null,
			"on_click": "_popup_storage_location_adjust"
		}
		]
	},
	{
		"name": "播放设置",
		"settings": [
			{
				"id": "performing_mode",
				"name_en": "Performing Mode",
				"name_zh": "弹奏模式",
				"description": "关闭后，即使不去点击下落的音符，选择了的音轨也会正常发声",
				"type": "TYPE_OPTION",
				"default_value": "1",
				"options": [
					{"text_en": "Off", "text_zh": "关闭"},
					{"text_en": "On", "text_zh": "开启"}
				]
			},
			{
				"id": "play_ready_animation",
				"name_en": "Play Ready Animation",
				"name_zh": "播放准备动画",
				"description": "关闭后，音乐开始前不会有准备动画",
				"type": "TYPE_OPTION",
				"default_value": "1",
				"options": [
					{"text_en": "Off", "text_zh": "关闭"},
					{"text_en": "On", "text_zh": "开启"}
				]
			},
			{
				"id": "playback_speed_scaling",
				"name_en": "Playback Speed Scaling",
				"name_zh": "播放速度设定",
				"description": "调整音乐的播放倍率，数值越大速度越快",
				"type": "TYPE_LINE_EDIT",
				"default_value": "1.0",
				"not_implemented": true,
				"unit": "x"
			},
			{
				"id": "vibrate_on_touch",
				"name_en": "Vibrate on Touch",
				"name_zh": "触摸震动反馈",
				"description": "选择是否在点击音符时使设备震动",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"options": [
					{"text_en": "Off", "text_zh": "关闭"},
					{"text_en": "On", "text_zh": "开启"}
				]
			},
			{
				"id": "vibration_duration",
				"name_en": "Vibration Duration",
				"name_zh": "震动持续时间",
				"description": "设置点击音符时震动的持续时间，单位：毫秒",
				"type": "TYPE_LINE_EDIT",
				"default_value": "50",
				"unit": "ms"
			},
			{
				"id": "use_system_stopwatch",
				"name_en": "Use System Stopwatch",
				"name_zh": "使用系统时钟",
				"description": "已废弃：判定时钟统一使用音频渲染时钟（单一音频主时钟），不再依赖系统墙钟推算位置",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"advanced": true,
				"not_implemented": true,
				"options": [
					{"text_en": "Off", "text_zh": "关闭"},
					{"text_en": "On", "text_zh": "开启"}
				]
			},
			{
				"id": "audio_playback_delay",
				"name_en": "Audio Playback Delay",
				"name_zh": "音频延迟校准",
				"description": "校准音频输出延迟，使声音到达耳朵的时机与音符判定对齐。普通输出与蓝牙输出分别记录两套延迟，检测到蓝牙时自动使用蓝牙预设",
				"type": "TYPE_BUTTON",
				"default_value": null,
				"on_click": "_popup_delay_adjust"
			},
			{
				"id": "max_polyphony",
				"name_en": "Max Polyphony",
				"name_zh": "最大复音数",
				"description": "设置同时发声的最大音符数，较高的值音质更好但占用更多CPU资源",
				"type": "TYPE_LINE_EDIT",
				"default_value": "96",
				"advanced": true,
				"unit": "音符"
			},
			{
				"id": "default_midi_volume",
				"name_en": "Default MIDI Volume",
				"name_zh": "默认MIDI音量",
				"description": "设置加载新MIDI时的默认MIDI音量，范围0-100 (50%为原始音量, 100%为+6dB增益)",
				"type": "TYPE_LINE_EDIT",
				"default_value": "50",
				"unit": "%"
			},
			{
				"id": "default_vocal_volume",
				"name_en": "Default Vocal Volume",
				"name_zh": "默认人声音量",
				"description": "设置加载新MIDI时的默认人声音量，范围0-100",
				"type": "TYPE_LINE_EDIT",
				"default_value": "50",
				"unit": "%"
			},
			{
				"id": "audio_sync_threshold",
				"name_en": "Audio Sync Threshold",
				"name_zh": "音频不同步阈值",
				"description": "MIDI与人声进度差值超过此阈值时自动对齐",
				"type": "TYPE_LINE_EDIT",
				"default_value": "200",
				"unit": "ms"
			},
			{
				"id": "soundfont_select",
				"name_en": "Sound Font",
				"name_zh": "音源选择",
				"description": "选择MIDI播放时使用的SoundFont音源文件。",
				"type": "TYPE_OPTION",
				"default_value": "GeneralUser-GS.sf2",
				"options": [],
				"dynamic_options": true,
				"options_provider": "_provide_soundfont_options"
			},

		]
	},
	{
		"name": "轨道设置",
		"settings": [
			{
				"id": "lane_count",
				"name_en": "Lane Count",
				"name_zh": "下落轨道数量",
				"description": "设置音符的下落轨道数，数值过高可能会提升出现重叠的音符的概率",
				"type": "TYPE_LINE_EDIT",
				"default_value": "12",
				"unit": "lanes"
			},
			{
				"id": "canvas_horizontal_padding",
				"name_en": "Canvas Horizontal Padding",
				"name_zh": "轨道两侧安全区域宽度",
				"description": "控制屏幕最左/最右两端的留白宽度，值越大轨道整体越向屏幕中间收拢",
				"type": "TYPE_LINE_EDIT",
				"default_value": "100",
				"unit": "px"
			},
			{
				"id": "keyboard_mode_keys",
				"name_en": "Keyboard Mode Settings",
				"name_zh": "键盘模式设置",
				"description": "点击按钮打开窗口，设置键盘模式开关、按键顺序、显示名称、左右间距与交替轨道颜色",
				"type": "TYPE_BUTTON",
				"default_value": null,
				"on_click": "_popup_kb_mode_adjust"
			},
			{
				"id": "flash_alpha",
				"name_en": "Flash Alpha",
				"name_zh": "光柱不透明度",
				"description": "修改光柱的不透明度，有效范围为[0, 1]",
				"type": "TYPE_LINE_EDIT",
				"default_value": "0.8"
			},
			{
				"id": "beam_width_mode",
				"name_en": "Beam Width Mode",
				"name_zh": "轨道光效宽度模式",
				"description": "控制轨道光效的宽度依据：跟随音符宽度会在音符宽度基础上增加边距，跟随轨道宽度会占满整根轨道（无缝铺满）",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"options": [
					{"text_en": "Note Width", "text_zh": "跟随音符宽度"},
					{"text_en": "Lane Width", "text_zh": "跟随轨道宽度"}
				]
			},
			{
				"id": "spark_adjust",
				"name_en": "Judgment Spark Effects",
				"name_zh": "判定特效设定",
				"description": "调整四种判定的按键特效：基础粒子、散射粒子、整体缩放/不透明度、散射粒子缩放",
				"type": "TYPE_BUTTON",
				"default_value": null,
				"on_click": "_popup_spark_adjust"
			}
		]
	},
	{
		"name": "判定设置",
		"settings": [
			{
				"id": "judge_window_ms",
				"name_en": "Judge Valid Zone",
				"name_zh": "判定有效区",
				"description": "筛选可判定音符时的时间范围；选择有限时间则不会判到与当前时间相差超过该值的音符，落到判定线后的音符不受影响",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"options": [
					{"text_en": "Full Vertical", "text_zh": "垂直全幅"},
					{"text_en": "1s", "text_zh": "1s"},
					{"text_en": "500ms", "text_zh": "500ms"},
					{"text_en": "250ms", "text_zh": "250ms"}
				]
			},
			{
				"id": "check_instant_blocks_when_finger_up",
				"name_en": "Check Instant Blocks When Finger Up",
				"name_zh": "抬手时判定滑块",
				"description": "若启用该项，在原地落指并抬指时，处于判定范围内的滑块会进行判定，不影响其他的提前判定滑键逻辑",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"options": [
					{"text_en": "Off", "text_zh": "关闭"},
					{"text_en": "On", "text_zh": "开启"}
				]
			},
			{
				"id": "only_perfect_instant_blocks_before_judge",
				"name_en": "Only Perfect Instant Blocks Before Judge",
				"name_zh": "仅判定完美滑块",
				"description": "若打开此项，在滑块落至完美判定区间的范围前无法被判定，即使主动点击",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"options": [
					{"text_en": "Off", "text_zh": "关闭"},
					{"text_en": "On", "text_zh": "开启"}
				]
			},
			{
				"id": "judge_line_position",
				"name_en": "Judge Line Position",
				"name_zh": "判定线高度",
				"description": "调整判定线距离屏幕底部的距离",
				"type": "TYPE_LINE_EDIT",
				"default_value": "200",
				"unit": "px"
			},
			{
				"id": "judge_line_thickness",
				"name_en": "Judge Line Thickness",
				"name_zh": "判定线宽度",
				"description": "调整判定线厚度，不影响判定，只影响外观",
				"type": "TYPE_LINE_EDIT",
				"default_value": "2",
				"unit": "px"
			},
			{
				"id": "block_judging_width",
				"name_en": "Block Judging Width",
				"name_zh": "音符判定宽度",
				"description": "设置判定宽度占音符宽度的倍数。例如：设置为1.0表示判定宽度等于音符宽度，设置为2.0表示判定宽度为音符宽度的2倍。",
				"type": "TYPE_LINE_EDIT",
				"default_value": "1.0",
				"unit": "倍音符宽度"
			},
			{
				"id": "min_block_spacing",
				"name_en": "Min Block Spacing",
				"name_zh": "最小横向音符间距",
				"description": "控制并排音符间的最小轨道间隔。值为1时，任意两个并排音符的轨道号差必须大于1（至少相隔一个空轨道）。数值太大会导致没有音符下落",
				"type": "TYPE_LINE_EDIT",
				"default_value": "1",
				"unit": "轨道"
			},
			{
				"id": "perfect_time",
				"name_en": "Perfect Time",
				"name_zh": "Perfect判定范围",
				"description": "控制perfect评分的判定时间范围",
				"type": "TYPE_LINE_EDIT",
				"default_value": "0.05",
				"not_implemented": true,
				"unit": "ms"
			},
			{
				"id": "great_time",
				"name_en": "Great Time",
				"name_zh": "Great判定范围",
				"description": "控制great评分的判定时间范围",
				"type": "TYPE_LINE_EDIT",
				"default_value": "0.1",
				"not_implemented": true,
				"unit": "ms"
			},
			{
				"id": "good_time",
				"name_en": "Good Time",
				"name_zh": "Good判定范围",
				"description": "控制good评分的判定时间范围",
				"type": "TYPE_LINE_EDIT",
				"default_value": "0.15",
				"not_implemented": true,
				"unit": "ms"
			},
			{
				"id": "bad_time",
				"name_en": "Bad Time",
				"name_zh": "Bad判定范围",
				"description": "控制bad评分的判定时间范围",
				"type": "TYPE_LINE_EDIT",
				"default_value": "0.2",
				"not_implemented": true,
				"unit": "ms"
			}
		]
	},
	{
		"name": "生成设置",
		"settings": [
			{
				"id": "instant_block_max_time",
				"name_en": "Instant Block Max Time",
				"name_zh": "生成滑块最大时间",
				"description": "控制滑块的生成时间，使长度低于此时间的Note变成滑块",
				"type": "TYPE_LINE_EDIT",
				"default_value": "0.5",
				"unit": "s"
			},
			{
				"id": "short_block_max_time",
				"name_en": "Short Block Max Time",
				"name_zh": "生成短块最大时间",
				"description": "使低于此时间，高于滑块生成时间的音符变为点块",
				"type": "TYPE_LINE_EDIT",
				"default_value": "1.0",
				"unit": "s"
			},
			{
				"id": "max_simultaneous_blocks",
				"name_en": "Max Simultaneous Blocks",
				"name_zh": "最大并排下落音符",
				"description": "控制同时下落的音符的最大数量",
				"type": "TYPE_LINE_EDIT",
				"default_value": "3"
			},
			{
				"id": "min_tap_interval",
				"name_en": "Min Tap Interval",
				"name_zh": "连点最小时间间隔",
				"description": "使一个点块后跟着的与其间隔时间低于此时间的所有点块变成滑块",
				"type": "TYPE_LINE_EDIT",
				"default_value": "0.2",
				"unit": "s"
			},
			{
				"id": "min_touch_cooldown_time",
				"name_en": "Min Touch Cooldown Time",
				"name_zh": "最小点击冷却时间",
				"description": "手指从抬起到任意位置按下的最短时间（会限制上下音符之间的横向距离）",
				"type": "TYPE_LINE_EDIT",
				"default_value": "0.2",
				"unit": "s"
			},
			{
				"id": "max_touch_move_speed",
				"name_en": "Max Touch Move Speed",
				"name_zh": "手指最大移动速度",
				"description": "使各个相邻的音符之间的水平距离在设置的数值所推算出来的距离之间",
				"type": "TYPE_LINE_EDIT",
				"default_value": "500",
				"unit": "px/s"
			},
			{
				"id": "max_block_coalesce_time",
				"name_en": "Note Density Cap",
				"name_zh": "音符生成密度上限",
				"description": "控制每 1 秒内最多生成的按压时刻组数量（0 = 不限）",
				"type": "TYPE_LINE_EDIT",
				"default_value": "8",
				"unit": "组/秒"
			},
			{
				"id": "note_fall_adjust",
				"name_en": "Note Fall Adjust",
				"name_zh": "音符下落设置",
				"description": "音符下落模式、下落时间、过判定线后速度倍率及缓动函数的设置",
				"type": "TYPE_BUTTON",
				"default_value": null,
				"on_click": "_popup_falling_adjust"
			}
		]
	},
	{
		"name": "外观设置",
		"settings": [
			{
				"id": "theme_preset",
				"name_en": "Theme Preset",
				"name_zh": "主题色配置",
				"description": "选择界面主题配色方案",
				"type": "TYPE_OPTION",
				"default_value": "",
				"dynamic_options": true,
				"options_provider": "_provide_theme_preset_options"
			},
			{
				"id": "block_skin_preset",
				"name_en": "Note Skin",
				"name_zh": "音符外观设定",
				"description": "点击按钮打开皮肤选择窗口",
				"type": "TYPE_BUTTON",
				"default_value": null,
				"on_click": "_popup_note_skin_adjust"
			},
			{
				"id": "block_size",
				"name_en": "Block Size",
				"name_zh": "音符尺寸大小",
				"description": "设置可游玩区域容纳的音符数量，数值越大音符越小。例如：设置为6.5表示可游玩区域宽度正好为6.5个音符宽度。",
				"type": "TYPE_LINE_EDIT",
				"default_value": "6.5",
				"unit": "个音符"
			},
			{
				"id": "custom_block_skin_texture_filter_mode",
				"name_en": "Custom Block Skin Texture Filter Mode",
				"name_zh": "皮肤纹理过滤模式",
				"description": "更改对音符皮肤的渲染方式",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"options": [
					{"text_en": "Nearest", "text_zh": "Nearest"},
					{"text_en": "Bilinear", "text_zh": "Bilinear"}
				]
			},
			{
				"id": "note_glow_intensity",
				"name_en": "Note Glow Intensity",
				"name_zh": "音符发光强度",
				"description": "控制音符周围的发光效果强度，[0, 2]",
				"type": "TYPE_LINE_EDIT",
				"default_value": "0.5",
				"range": [0.0, 2.0, 0.1]
			},
			{
				"id": "note_glow_size",
				"name_en": "Note Glow Size",
				"name_zh": "音符发光范围",
				"description": "控制音符发光效果的范围大小，[0, 30]",
				"type": "TYPE_LINE_EDIT",
				"default_value": "5.0",
				"range": [1.0, 12.0, 1.0]
			},
			{
				"id": "randomize_block_color",
				"name_en": "Randomize Block Color",
				"name_zh": "随机音符顏色",
				"description": "开启后，每次进行游戏时音符颜色将会随机设置，仅对非键盘模式有效",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"options": [
					{"text_en": "Off", "text_zh": "关闭"},
					{"text_en": "On", "text_zh": "开启"}
				]
			},
			{
				"id": "sync_color_across_block_type",
				"name_en": "Sync Color Across Block Type",
				"name_zh": "统一音符颜色",
				"description": "仅在随机音符颜色开启时生效：点块、滑块和长条使用同一个随机颜色，光柱特效颜色也同步统一",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"options": [
					{"text_en": "Off", "text_zh": "关闭"},
					{"text_en": "On", "text_zh": "开启"}
				]
			},
			{
				"id": "instant_block_color",
				"name_en": "Instant Block Color",
				"name_zh": "更改滑块颜色",
				"description": "非键盘模式下，未开启随机音符颜色时，修改滑块及其光柱特效颜色",
				"type": "TYPE_COLOR",
				"default_value": "#FF6B6B",
			},
			{
				"id": "short_block_color",
				"name_en": "Short Block Color",
				"name_zh": "更改点块颜色",
				"description": "非键盘模式下，未开启随机音符颜色时，修改点块及其光柱特效颜色",
				"type": "TYPE_COLOR",
				"default_value": "#4ECDC4",
			},
			{
				"id": "long_block_color",
				"name_en": "Long Block Color",
				"name_zh": "更改长条颜色",
				"description": "非键盘模式下，未开启随机音符颜色时，修改长条及其光柱特效颜色",
				"type": "TYPE_COLOR",
				"default_value": "#45B7D1",
			},
			{
				"id": "main_background",
				"name_en": "Main Background",
				"name_zh": "主界面背景",
				"description": "点击修改主界面背景。",
				"type": "TYPE_BUTTON",
				"default_value": null,
				"on_click": "_popup_main_background_adjust"
			},
			{
				"id": "store_background",
				"name_en": "Store Background",
				"name_zh": "商店界面背景",
				"description": "点击修改商店界面背景。",
				"type": "TYPE_BUTTON",
				"default_value": null,
				"on_click": "_popup_store_background_adjust"
			},
			{
				"id": "score_background",
				"name_en": "Score Background",
				"name_zh": "结算界面背景",
				"description": "点击修改结算界面背景。",
				"type": "TYPE_BUTTON",
				"default_value": null,
				"on_click": "_popup_score_background_adjust"
			},
			{
				"id": "track_background",
				"name_en": "Track Background",
				"name_zh": "音轨编辑界面背景",
				"description": "点击修改音轨编辑界面背景。",
				"type": "TYPE_BUTTON",
				"default_value": null,
				"on_click": "_popup_track_background_adjust"
			},
			{
				"id": "midi_background",
				"name_en": "Midi Background",
				"name_zh": "谱面详情界面背景",
				"description": "点击修改谱面详情界面背景。",
				"type": "TYPE_BUTTON",
				"default_value": null,
				"on_click": "_popup_midi_background_adjust"
			},
			{
				"id": "setting_background",
				"name_en": "Setting Background",
				"name_zh": "设置界面背景",
				"description": "点击修改设置界面背景。",
				"type": "TYPE_BUTTON",
				"default_value": null,
				"on_click": "_popup_setting_background_adjust"
			},
			{
				"id": "play_background",
				"name_en": "Play Background",
				"name_zh": "游玩界面背景",
				"description": "点击修改游玩界面背景。支持封面、图片、渐变、纯色四种类型。",
				"type": "TYPE_BUTTON",
				"default_value": null,
				"on_click": "_popup_play_background_adjust"
			},
			{
				"id": "background_image_flash_color",
				"name_en": "Background Image Flash Color",
				"name_zh": "背景闪光颜色",
				"description": "修改打击音符时背景发光的颜色",
				"type": "TYPE_COLOR",
				"edit_alpha": true,
				"default_value": "#FFFFFF00"
			},
			{
				"id": "background_dim_color",
				"name_en": "Background Dim Color",
				"name_zh": "背景遮罩颜色",
				"description": "背景遮罩的颜色，与背景遮罩透明度配合使用来降低背景亮度",
				"type": "TYPE_COLOR",
				"edit_alpha": true,
				"default_value": "#000000FF"
			},
			{
				"id": "generate_short_connect",
				"name_en": "Generate Short Connect",
				"name_zh": "是否连接所有并排的点块",
				"description": "选择是否生成连接线，连接并排下落的点块、滑块和长条",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"not_implemented": true,
				"options": [
					{"text_en": "Off", "text_zh": "关闭"},
					{"text_en": "On", "text_zh": "开启"}
				]
			},
			{
				"id": "generate_instant_connect",
				"name_en": "Generate Instant Connect",
				"name_zh": "是否连接上下相邻的滑块",
				"description": "选择是否生成连接线，连接同一下落轨道内的时间差在设定范围内的数的音符",
				"type": "TYPE_OPTION",
				"default_value": "0",
				"not_implemented": true,
				"options": [
					{"text_en": "Off", "text_zh": "关闭"},
					{"text_en": "On", "text_zh": "开启"}
				]
			},
			{
				"id": "instant_connect_max_time",
				"name_en": "Instant Connect Max Time",
				"name_zh": "被连接音符的最大时间差",
				"description": "设置被连接音符之间的最大时间间隔",
				"type": "TYPE_LINE_EDIT",
				"default_value": "0.5",
				"not_implemented": true,
				"unit": "s"
			}
		]
	}
]
