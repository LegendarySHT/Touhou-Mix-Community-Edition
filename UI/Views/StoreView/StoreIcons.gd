## 商店 UI 的图标/文字工具。
##
## 图标全部取自项目现有的三张 80px 网格图集（不新增资源），
## AtlasTexture 按 (图集, 区域) 缓存后全局共享——这些资源只读，多个节点引用同一份没有副作用。
##
## 图集索引：
##   1 = icon_set.png（音符/麦克风/搜索/下载/时钟…）
##   2 = icon_set2.png（赞踩/下载云/勾叉/筛选字段/排序…）
##   3 = icon_set3.png（皮肤/音符/均衡器/音源库/媒体控制…）
class_name StoreIcons
extends RefCounted

const SHEET_1 = preload("res://Resources/icon/icon_set.png")
const SHEET_2 = preload("res://Resources/icon/icon_set2.png")
const SHEET_3 = preload("res://Resources/icon/icon_set3.png")

## "sheet|rect" → AtlasTexture
static var _atlas_cache: Dictionary = {}

# ── 通用图集 ──────────────────────────────────────────

static func atlas(sheet: int, x: float, y: float) -> AtlasTexture:
	var key := "%d|%d|%d" % [sheet, int(x), int(y)]
	var cached = _atlas_cache.get(key)
	if cached is AtlasTexture:
		return cached
	var tex := AtlasTexture.new()
	match sheet:
		1: tex.atlas = SHEET_1
		2: tex.atlas = SHEET_2
		_: tex.atlas = SHEET_3
	tex.region = Rect2(x, y, 80, 80)
	_atlas_cache[key] = tex
	return tex

# ── 具名图标（region 均已核对过图集内容） ──────────────

## 歌曲分类：音符
static func song() -> AtlasTexture:
	return atlas(3, 160, 0)

## 皮肤分类：琴键 + 火花
static func skin() -> AtlasTexture:
	return atlas(3, 0, 0)

## 特效分类：均衡器柱
static func effect() -> AtlasTexture:
	return atlas(3, 320, 0)

## 音源分类：唱片库 + 音符
static func soundfont() -> AtlasTexture:
	return atlas(3, 0, 160)

## 下载管理：云下载
static func download_cloud() -> AtlasTexture:
	return atlas(2, 160, 0)

## 搜索
static func search() -> AtlasTexture:
	return atlas(1, 320, 240)

## 下载（托盘箭头）
static func download() -> AtlasTexture:
	return atlas(1, 240, 320)

## 已下载（勾）
static func check() -> AtlasTexture:
	return atlas(2, 0, 80)

## 失败（叉）
static func close() -> AtlasTexture:
	return atlas(2, 80, 80)

## 赞
static func thumb_up() -> AtlasTexture:
	return atlas(2, 0, 0)

## 踩
static func thumb_down() -> AtlasTexture:
	return atlas(2, 80, 0)

## 麦克风（开）
static func mic() -> AtlasTexture:
	return atlas(1, 80, 160)

## 麦克风（关）
static func mic_off() -> AtlasTexture:
	return atlas(1, 80, 240)

## 上传时间排序
static func uploaded() -> AtlasTexture:
	return atlas(2, 240, 320)

## 下载数排序
static func downloads() -> AtlasTexture:
	return atlas(2, 0, 320)

## 游玩数排序
static func plays() -> AtlasTexture:
	return atlas(2, 80, 320)

## 点赞数排序
static func likes() -> AtlasTexture:
	return atlas(2, 160, 320)

## 升序
static func order_asc() -> AtlasTexture:
	return atlas(2, 0, 240)

## 降序
static func order_desc() -> AtlasTexture:
	return atlas(2, 80, 240)

# ── 文本格式化 ─────────────────────────────────────────

## 1300 → 1.3k，1200000 → 1.2m；负数视为“无数据”返回 “—”
static func format_count(value: int) -> String:
	if value < 0:
		return "—"
	if value >= 1000000:
		return "%.1fm" % (float(value) / 1000000.0)
	if value >= 10000:
		return "%.1fw" % (float(value) / 10000.0)
	if value >= 1000:
		return "%.1fk" % (float(value) / 1000.0)
	return str(value)

## 字节数 → 人类可读（0 / 负数返回 “—”）
static func format_size(bytes: int) -> String:
	if bytes <= 0:
		return "—"
	if bytes >= 1073741824:
		return "%.1f GB" % (float(bytes) / 1073741824.0)
	if bytes >= 1048576:
		return "%.1f MB" % (float(bytes) / 1048576.0)
	if bytes >= 1024:
		return "%.0f KB" % (float(bytes) / 1024.0)
	return "%d B" % bytes

## 秒数 → m:ss（超过一小时显示 h:mm:ss）；<=0 返回空串
static func format_duration(seconds: int) -> String:
	if seconds <= 0:
		return ""
	var total := seconds
	var h := int(total / 3600)
	var m := int((total % 3600) / 60)
	var sec := int(total % 60)
	if h > 0:
		return "%d:%02d:%02d" % [h, m, sec]
	return "%d:%02d" % [m, sec]


## 排行榜分数：1234567 → 1,234,567
static func format_score(value: int) -> String:
	var s := str(maxi(value, 0))
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			out = "," + out
		out = s[i] + out
		count += 1
	return out
