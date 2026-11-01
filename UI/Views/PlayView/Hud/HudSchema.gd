class_name HudSchema
extends RefCounted

## 可自定义 HUD 组件注册表 + 默认布局。
## 组件脚本按 id 动态 load，避免场景/资源里散落一堆 ext_resource；
## 新增一种组件只需在这里加一行 + 写一个 HudComponent 子类。

const BASE_DIR := "res://UI/Views/PlayView/Hud/components/"

## 顺序即编辑器「添加组件」下拉里的顺序
static func entries() -> Array:
	return [
		{"id": "combo", "name": "Combo 计数", "script": BASE_DIR + "ComboComponent.gd"},
		{"id": "score", "name": "分数", "script": BASE_DIR + "ScoreComponent.gd"},
		{"id": "score_add", "name": "本次得分", "script": BASE_DIR + "ScoreAddComponent.gd"},
		{"id": "score_pending", "name": "未计入分数", "script": BASE_DIR + "ScorePendingComponent.gd"},
		{"id": "accuracy", "name": "准确度", "script": BASE_DIR + "AccuracyComponent.gd"},
		{"id": "pp", "name": "PP", "script": BASE_DIR + "PPComponent.gd"},
		{"id": "judge", "name": "判定指示", "script": BASE_DIR + "JudgeComponent.gd"},
		{"id": "offset_early", "name": "正偏移指示", "script": BASE_DIR + "OffsetComponent.gd"},
		{"id": "offset_late", "name": "负偏移指示", "script": BASE_DIR + "OffsetComponent.gd"},
		{"id": "pause", "name": "暂停按钮", "script": BASE_DIR + "PauseComponent.gd"},
		{"id": "album", "name": "专辑名", "script": BASE_DIR + "InfoComponent.gd"},
		{"id": "song", "name": "歌曲名", "script": BASE_DIR + "InfoComponent.gd"},
		{"id": "midi_name", "name": "MIDI 名", "script": BASE_DIR + "InfoComponent.gd"},
		{"id": "difficulty", "name": "当前难度", "script": BASE_DIR + "InfoComponent.gd"},
		{"id": "text", "name": "自定义文本", "script": BASE_DIR + "CustomTextComponent.gd"},
	]


static func entry(id: String) -> Dictionary:
	for e in entries():
		if String(e["id"]) == id:
			return e
	return {}


static func script_of(id: String) -> String:
	return String(entry(id).get("script", ""))


static func name_of(id: String) -> String:
	return String(entry(id).get("name", id))


static func exists(id: String) -> bool:
	return not entry(id).is_empty()


## 新建组件的初始布局值（锚点居中、无偏移、缩放 1）
static func new_component_data(id: String) -> Dictionary:
	return {
		"id": id,
		"variant": 0,
		"anchor": [0.5, 0.5],
		"offset": [0.0, 0.0],
		"scale": 1.0,
		"visible": true,
		"params": {},
	}


## 默认布局：与旧版固定 HUD 的位置基本一致（几个位置按手机圆角/观感微调过）
static func default_layout() -> Array:
	return [
		{"id": "pause", "variant": 0, "anchor": [0.0, 0.0], "offset": [0.0, 0.0],
			"scale": 1.0, "visible": true, "params": {}},
		{"id": "combo", "variant": 0, "anchor": [0.5, 0.0], "offset": [0.0, 30.0],
			"scale": 1.0, "visible": true,
			"params": {"font_size": 48, "text_size": 42, "anim": 1}},
		{"id": "score", "variant": 0, "anchor": [1.0, 0.0], "offset": [-20.0, 12.0],
			"scale": 1.0, "visible": true, "params": {"font_size": 72}},
		{"id": "score_add", "variant": 0, "anchor": [1.0, 0.0], "offset": [-20.0, 112.0],
			"scale": 1.0, "visible": true, "params": {"font_size": 48}},
		{"id": "score_pending", "variant": 0, "anchor": [1.0, 0.0], "offset": [-20.0, 174.0],
			"scale": 1.0, "visible": false, "params": {"font_size": 36}},
		{"id": "accuracy", "variant": 0, "anchor": [1.0, 1.0], "offset": [-30.0, -10.0],
			"scale": 1.0, "visible": true, "params": {"font_size": 64}},
		{"id": "pp", "variant": 0, "anchor": [0.0, 1.0], "offset": [30.0, -10.0],
			"scale": 1.0, "visible": true, "params": {"font_size": 64}},
		{"id": "judge", "variant": 0, "anchor": [0.5, 0.5], "offset": [0.0, 0.0],
			"scale": 1.0, "visible": true, "params": {"font_size": 72}},
		{"id": "offset_early", "variant": 0, "anchor": [0.5, 0.5], "offset": [0.0, -64.0],
			"scale": 1.0, "visible": true, "params": {"font_size": 32}},
		{"id": "offset_late", "variant": 0, "anchor": [0.5, 0.5], "offset": [0.0, 64.0],
			"scale": 1.0, "visible": true, "params": {"font_size": 32}},
	]


## 编辑器的锚点预设：3×3 归一化锚点
static func anchor_presets() -> Array:
	return [
		{"label": "↖", "anchor": Vector2(0.0, 0.0)},
		{"label": "↑", "anchor": Vector2(0.5, 0.0)},
		{"label": "↗", "anchor": Vector2(1.0, 0.0)},
		{"label": "←", "anchor": Vector2(0.0, 0.5)},
		{"label": "◎", "anchor": Vector2(0.5, 0.5)},
		{"label": "→", "anchor": Vector2(1.0, 0.5)},
		{"label": "↙", "anchor": Vector2(0.0, 1.0)},
		{"label": "↓", "anchor": Vector2(0.5, 1.0)},
		{"label": "↘", "anchor": Vector2(1.0, 1.0)},
	]
