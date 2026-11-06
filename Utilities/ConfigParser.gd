## 配置值解析工具类（纯静态）
## 用于将配置字符串转换为相应的数据类型
class_name ConfigParser

## 键码名称到 KeyCode 的映射表
const KEY_NAME_MAP: Dictionary = {
	# 数字键
	"0": Key.KEY_0, "1": Key.KEY_1, "2": Key.KEY_2, "3": Key.KEY_3, "4": Key.KEY_4,
	"5": Key.KEY_5, "6": Key.KEY_6, "7": Key.KEY_7, "8": Key.KEY_8, "9": Key.KEY_9,
	
	# 字母键（支持大小写）
	"A": Key.KEY_A, "a": Key.KEY_A,
	"B": Key.KEY_B, "b": Key.KEY_B,
	"C": Key.KEY_C, "c": Key.KEY_C,
	"D": Key.KEY_D, "d": Key.KEY_D,
	"E": Key.KEY_E, "e": Key.KEY_E,
	"F": Key.KEY_F, "f": Key.KEY_F,
	"G": Key.KEY_G, "g": Key.KEY_G,
	"H": Key.KEY_H, "h": Key.KEY_H,
	"I": Key.KEY_I, "i": Key.KEY_I,
	"J": Key.KEY_J, "j": Key.KEY_J,
	"K": Key.KEY_K, "k": Key.KEY_K,
	"L": Key.KEY_L, "l": Key.KEY_L,
	"M": Key.KEY_M, "m": Key.KEY_M,
	"N": Key.KEY_N, "n": Key.KEY_N,
	"O": Key.KEY_O, "o": Key.KEY_O,
	"P": Key.KEY_P, "p": Key.KEY_P,
	"Q": Key.KEY_Q, "q": Key.KEY_Q,
	"R": Key.KEY_R, "r": Key.KEY_R,
	"S": Key.KEY_S, "s": Key.KEY_S,
	"T": Key.KEY_T, "t": Key.KEY_T,
	"U": Key.KEY_U, "u": Key.KEY_U,
	"V": Key.KEY_V, "v": Key.KEY_V,
	"W": Key.KEY_W, "w": Key.KEY_W,
	"X": Key.KEY_X, "x": Key.KEY_X,
	"Y": Key.KEY_Y, "y": Key.KEY_Y,
	"Z": Key.KEY_Z, "z": Key.KEY_Z,
	
	# 特殊键
	";": Key.KEY_SEMICOLON,
	":": Key.KEY_SEMICOLON,
	",": Key.KEY_COMMA,
	"<": Key.KEY_COMMA,
	".": Key.KEY_PERIOD,
	">": Key.KEY_PERIOD,
	"/": Key.KEY_SLASH,
	"?": Key.KEY_SLASH,
	"\\": Key.KEY_BACKSLASH,
	"|": Key.KEY_BACKSLASH,
	"[": Key.KEY_BRACKETLEFT,
	"{": Key.KEY_BRACKETLEFT,
	"]": Key.KEY_BRACKETRIGHT,
	"}": Key.KEY_BRACKETRIGHT,
	"-": Key.KEY_MINUS,
	"_": Key.KEY_MINUS,
	"=": Key.KEY_EQUAL,
	"+": Key.KEY_EQUAL,
	" ": Key.KEY_SPACE,
}

## 键位绑定 token
## 一个槽位「绑了什么」统一用一个整数表示，键盘键、MIDI 音符、鼠标键、手柄按钮、
## 手柄摇杆轴共用同一套编码，因此键位表与按下状态表都只需要一个整数作键
##   - 低 25 位：键值。Godot 的 KeyCode 只占低 25 位（KEY_CODE_MASK = (1 << 25) - 1）
##   - 高位：输入来源，避免不同类型的编号相撞
enum BindingKind { KEY, MIDI, MOUSE, JOY_BUTTON, JOY_AXIS }

## 未绑定的槽位（0 同时等于 KEY_NONE，两者天然一致）
const BINDING_NONE: int = 0
const BINDING_TAG_SHIFT: int = 25
const BINDING_VALUE_MASK: int = (1 << 25) - 1

## 摇杆轴的触发阈值：绝对值超过即视为按下
const JOY_AXIS_THRESHOLD := 0.5

## 配置串里的前缀标记
## 与键盘键名不冲突：只有「前缀 + 纯数字」才算对应来源，裸 "M" 仍是字母键
const MIDI_TOKEN_PREFIX := "M"          # M60 → MIDI 音符 60（音名 C4）
const MOUSE_TOKEN_PREFIX := "MB"        # MB2 → 鼠标右键（数字为 MouseButton 枚举值）
const JOY_BUTTON_TOKEN_PREFIX := "JB"   # JB0 → 手柄按钮 0（A / 南键）
const JOY_AXIS_TOKEN_PREFIX := "JA"     # JA0+ / JA0- → 摇杆 0 号轴的正 / 负方向

## 音名表（升号记法），用于 MIDI 音符的默认显示名
const MIDI_NOTE_NAMES: Array[String] = [
	"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"
]

## 鼠标键的默认显示名；左键保留给界面点击，不作为键位
const MOUSE_BUTTON_NAMES: Dictionary = {
	MOUSE_BUTTON_RIGHT: "右键",
	MOUSE_BUTTON_MIDDLE: "中键",
	MOUSE_BUTTON_WHEEL_UP: "滚上",
	MOUSE_BUTTON_WHEEL_DOWN: "滚下",
	MOUSE_BUTTON_WHEEL_LEFT: "滚左",
	MOUSE_BUTTON_WHEEL_RIGHT: "滚右",
}

## 手柄按钮的默认显示名（未列出的按钮回退为 JB<编号>）
const JOY_BUTTON_NAMES: Dictionary = {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "Back", JOY_BUTTON_GUIDE: "Guide", JOY_BUTTON_START: "Start",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_DPAD_UP: "↑", JOY_BUTTON_DPAD_DOWN: "↓",
	JOY_BUTTON_DPAD_LEFT: "←", JOY_BUTTON_DPAD_RIGHT: "→",
}

## 摇杆轴的默认显示名，键为 axis * 2 + 方向位（0 正向 / 1 负向）
## Y 轴向下为正，所以正向显示为 ↓
const JOY_AXIS_NAMES: Dictionary = {
	0: "L→", 1: "L←", 2: "L↓", 3: "L↑",
	4: "R→", 5: "R←", 6: "R↓", 7: "R↑",
	8: "LT", 9: "LT-", 10: "RT", 11: "RT-",
}

# ===== token 构造与拆解 =====

static func make_midi_token(note: int) -> int:
	return (BindingKind.MIDI << BINDING_TAG_SHIFT) | (note & BINDING_VALUE_MASK)

static func make_mouse_token(button: int) -> int:
	return (BindingKind.MOUSE << BINDING_TAG_SHIFT) | (button & BINDING_VALUE_MASK)

static func make_joy_button_token(button: int) -> int:
	return (BindingKind.JOY_BUTTON << BINDING_TAG_SHIFT) | (button & BINDING_VALUE_MASK)

## 摇杆轴编码为 axis * 2 + 方向位（正向 0 / 负向 1），正负两个方向算两个独立键位
static func make_joy_axis_token(axis: int, positive: bool) -> int:
	var code := axis * 2 + (0 if positive else 1)
	return (BindingKind.JOY_AXIS << BINDING_TAG_SHIFT) | (code & BINDING_VALUE_MASK)

## token 的输入来源（BindingKind）
static func binding_kind(token: int) -> int:
	return (token >> BINDING_TAG_SHIFT) & 0xF

## token 的键值：键盘为 keycode，MIDI 为音符号，鼠标/手柄为枚举值，摇杆为 axis * 2 + 方向位
static func binding_value(token: int) -> int:
	return token & BINDING_VALUE_MASK

# ===== 输入事件 ↔ token =====

## 输入事件对应的绑定 token；0 表示该事件不作为键位
## 同一个物理输入在按下与抬起时返回相同 token，按下与否由 binding_event_pressed 判断
static func binding_token_from_event(event: InputEvent) -> int:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		# 少数输入法/远程桌面环境下 keycode 为空，用物理键码兜底
		return key_event.keycode if key_event.keycode != 0 else key_event.physical_keycode
	if event is InputEventMIDI:
		var midi_event := event as InputEventMIDI
		# 只关心音符的按下与抬起，其它 MIDI 消息（控制器、音色切换等）不可绑定
		if midi_event.message == MIDI_MESSAGE_NOTE_ON \
				or midi_event.message == MIDI_MESSAGE_NOTE_OFF:
			return make_midi_token(midi_event.pitch)
		return BINDING_NONE
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		# 左键留给界面点击：绑成键位会吞掉按钮、拖拽等操作的点击
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			return BINDING_NONE
		return make_mouse_token(mouse_event.button_index)
	if event is InputEventJoypadButton:
		return make_joy_button_token((event as InputEventJoypadButton).button_index)
	if event is InputEventJoypadMotion:
		var motion_event := event as InputEventJoypadMotion
		# 轴是持续量：停在阈值内表示没按，此时没有绑定身份
		var amount := absf(motion_event.axis_value)
		if amount < JOY_AXIS_THRESHOLD:
			return BINDING_NONE
		return make_joy_axis_token(motion_event.axis, motion_event.axis_value > 0.0)
	return BINDING_NONE

## 事件表示按下还是抬起；MIDI 的 Note On 力度 0 按规范等同 Note Off
static func binding_event_pressed(event: InputEvent) -> bool:
	if event is InputEventKey:
		return (event as InputEventKey).pressed
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).pressed
	if event is InputEventJoypadButton:
		return (event as InputEventJoypadButton).pressed
	if event is InputEventJoypadMotion:
		return absf((event as InputEventJoypadMotion).axis_value) >= JOY_AXIS_THRESHOLD
	if event is InputEventMIDI:
		var midi_event := event as InputEventMIDI
		if midi_event.message == MIDI_MESSAGE_NOTE_ON:
			return midi_event.velocity > 0
		return false
	return false

# ===== 解析与还原 =====

## 解析轨道绑定串，逐槽位返回绑定 token
## 支持格式（逗号分隔，每项一个轨道）：
##   - "A,S,D,F,J,K,L,;"  （字母与符号，写法同 OS.get_keycode_string）
##   - "M60,M62,M64"      （MIDI 音符号，60 = C4）
##   - "MB2,MB3"          （鼠标右键 / 中键）
##   - "JB0,JB1"          （手柄按钮编号）
##   - "JA0+,JA0-"        （摇杆轴的正 / 负方向）
## 无法解析的槽位被跳过；整串都解析失败时回落到默认键位
static func parse_lane_bindings(binding_string: String) -> Array[int]:
	if binding_string.is_empty():
		GLogger.warning("Lane binding string is empty, using default", "ConfigParser")
		return _build_default_bindings()

	var tokens: Array[int] = []
	for part in binding_string.split(","):
		var text := part.strip_edges()
		if text.is_empty():
			continue
		var token := parse_binding_token(text)
		if token == BINDING_NONE:
			GLogger.warning("Cannot parse lane binding: '%s'" % text, "ConfigParser")
			continue
		tokens.append(token)

	if tokens.is_empty():
		GLogger.warning(
			"Failed to parse any lane binding from '%s', using default" % binding_string,
			"ConfigParser"
		)
		return _build_default_bindings()

	return tokens

## 单个绑定转回配置串（写入方向）
static func binding_to_token_string(token: int) -> String:
	if token == BINDING_NONE:
		return ""
	match binding_kind(token):
		BindingKind.MIDI:
			return MIDI_TOKEN_PREFIX + str(binding_value(token))
		BindingKind.MOUSE:
			return MOUSE_TOKEN_PREFIX + str(binding_value(token))
		BindingKind.JOY_BUTTON:
			return JOY_BUTTON_TOKEN_PREFIX + str(binding_value(token))
		BindingKind.JOY_AXIS:
			var code := binding_value(token)
			@warning_ignore("integer_division")
			return JOY_AXIS_TOKEN_PREFIX + str(code / 2) + ("+" if code % 2 == 0 else "-")
	return OS.get_keycode_string(binding_value(token))

## 绑定的默认显示名（键位标签与「当前按键」共用）
static func binding_to_display_name(token: int) -> String:
	if token == BINDING_NONE:
		return ""
	match binding_kind(token):
		BindingKind.MIDI:
			return midi_note_to_name(binding_value(token))
		BindingKind.MOUSE:
			var button := binding_value(token)
			return MOUSE_BUTTON_NAMES.get(button, "鼠标%d" % button)
		BindingKind.JOY_BUTTON:
			var button := binding_value(token)
			return JOY_BUTTON_NAMES.get(button, "JB%d" % button)
		BindingKind.JOY_AXIS:
			var code := binding_value(token)
			var dir := "+" if code % 2 == 0 else "-"
			@warning_ignore("integer_division")
			return JOY_AXIS_NAMES.get(code, "轴%d%s" % [code / 2, dir])
	return OS.get_keycode_string(token)

## 解析单个配置标记；无法识别返回 BINDING_NONE
static func parse_binding_token(text: String) -> int:
	var token := text.strip_edges()
	if token.is_empty():
		return BINDING_NONE

	if token.begins_with(MIDI_TOKEN_PREFIX):
		var note_text := token.substr(1)
		if note_text.is_valid_int():
			var note := note_text.to_int()
			return make_midi_token(note) if note >= 0 and note <= 127 else BINDING_NONE

	if token.begins_with(MOUSE_TOKEN_PREFIX):
		var button_text := token.substr(MOUSE_TOKEN_PREFIX.length())
		if button_text.is_valid_int():
			return make_mouse_token(button_text.to_int())
		return BINDING_NONE

	if token.begins_with(JOY_BUTTON_TOKEN_PREFIX):
		var button_text := token.substr(JOY_BUTTON_TOKEN_PREFIX.length())
		if button_text.is_valid_int():
			return make_joy_button_token(button_text.to_int())
		return BINDING_NONE

	if token.begins_with(JOY_AXIS_TOKEN_PREFIX):
		var body := token.substr(JOY_AXIS_TOKEN_PREFIX.length())
		var has_dir := body.ends_with("+") or body.ends_with("-")
		if body.length() >= 2 and has_dir:
			var axis_text := body.substr(0, body.length() - 1)
			if axis_text.is_valid_int():
				return make_joy_axis_token(axis_text.to_int(), body.ends_with("+"))
		return BINDING_NONE

	return _parse_key_token(token)

## MIDI 音符号转音名（60 → "C4"）
static func midi_note_to_name(note: int) -> String:
	if note < 0 or note > 127:
		return ""
	@warning_ignore("integer_division")
	return MIDI_NOTE_NAMES[note % 12] + str(note / 12 - 1)

## 解析单个键盘标记，失败返回 KEY_NONE
static func _parse_key_token(token: String) -> Key:
	# 直接查表
	if token in KEY_NAME_MAP:
		return KEY_NAME_MAP[token]

	# 去掉 "KEY_" 前缀后查表
	var without_prefix := token
	if token.begins_with("KEY_"):
		without_prefix = token.substr(4)
	if without_prefix in KEY_NAME_MAP:
		return KEY_NAME_MAP[without_prefix]

	# 兜底：OS.find_keycode_from_string（支持 "Space"/"Semicolon"/"Comma" 等 get_keycode_string 输出）
	return OS.find_keycode_from_string(token)

## 默认键位（全键盘）
static func _build_default_bindings() -> Array[int]:
	var tokens: Array[int] = []
	for key in _get_default_keyboard_keys():
		tokens.append(int(key))
	return tokens

## 获取默认键位配置
static func _get_default_keyboard_keys() -> Array[Key]:
	return [
		Key.KEY_A, Key.KEY_S, Key.KEY_D, Key.KEY_F,
		Key.KEY_J, Key.KEY_K, Key.KEY_L, Key.KEY_SEMICOLON
	]

## 将逗号分隔的显示名字符串解析为数组
## 与 keys 数组对齐：若长度不一致按 key_count 补齐/截断
## 空字符串或缺失段一律返回空字符串（=使用按键默认名）
static func parse_keyboard_display_names(names_string: String, key_count: int) -> Array[String]:
	var names: Array[String] = []
	if names_string.is_empty():
		for i in key_count:
			names.append("")
		return names
	var parts := names_string.split(",", true)
	for i in key_count:
		names.append(parts[i].strip_edges() if i < parts.size() else "")
	return names
