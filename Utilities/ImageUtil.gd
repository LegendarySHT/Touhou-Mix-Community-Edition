## 图片辅助工具
## 提供不依赖扩展名匹配的稳健文件加载，以及外部图片（封面/头像）的显存优化
class_name ImageUtil
extends RefCounted

## 按文件内容加载图片：先按扩展名快速加载，失败时按文件头回退重试常见格式
## 解决扩展名与实际格式不符（如 PNG 内容被命名成 .jpg）导致解码失败的问题
## 线程安全（Image.load_from_file / load_*_from_buffer 均为纯解码操作）
static func load_image_file(path: String) -> Image:
	if path.is_empty():
		return null
	# SVG 不是位图：按扩展名直接栅格化，不依赖 Image.load_from_file 的格式分发
	if path.get_extension().to_lower() == "svg":
		return _load_svg_file(path)
	var img := Image.load_from_file(path)
	if img and img.get_width() > 0 and img.get_height() > 0:
		return img
	# 扩展名未命中正确解码器时，读取字节按内容重试
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	return decode_image_buffer(bytes)

## 读取 SVG 文本并栅格化为位图（用户皮肤等外部素材的矢量贴图入口）
static func _load_svg_file(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	return decode_image_buffer(bytes)

## 按文件签名选择唯一解码器；用错误解码器探测会触发 Godot 引擎错误日志
## 线程安全（纯解码操作）
static func decode_image_buffer(bytes: PackedByteArray) -> Image:
	if bytes.is_empty():
		return null
	var image := Image.new()
	var decode_error := ERR_FILE_UNRECOGNIZED
	if _has_png_signature(bytes):
		decode_error = image.load_png_from_buffer(bytes)
	elif _has_jpeg_signature(bytes):
		decode_error = image.load_jpg_from_buffer(bytes)
	elif _has_webp_signature(bytes):
		decode_error = image.load_webp_from_buffer(bytes)
	elif _has_svg_signature(bytes):
		decode_error = image.load_svg_from_buffer(bytes)
	if decode_error != OK:
		return null
	return image

## SVG 是文本 XML：只检查文件头是否含 <svg 根节点，避免整文件转字符串
static func _has_svg_signature(bytes: PackedByteArray) -> bool:
	var head := bytes.slice(0, mini(bytes.size(), 1024)).get_string_from_utf8()
	return head.find("<svg") != -1

## 是否已探测过显示格式（后台线程只看结果，不做探测）
static var _probed := false
## 显示纹理的目标格式；-1 表示不转换（拿不到 RenderingDevice 时保持原格式）
static var _display_format: int = -1

## 探测 GPU 可采样的 16 位格式（仅主线程调用）
## 部分移动 GPU 的 B5G6R5 缺少采样特性，直接用它建纹理会得到空 RID、封面白屏；
## 因此按 RGB565 → RGBA4444 → RGBA8 的顺序选择实际可用的格式。
static func _probe_display_format() -> int:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		# 兼容渲染器没有 RenderingDevice，无法探测；保持解码后的原格式即可显示
		return -1
	# usage 与 ImageTexture 创建时保持一致，探测结果才与引擎校验相符
	var usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	if rd.texture_is_format_supported_for_usage(RenderingDevice.DATA_FORMAT_B5G6R5_UNORM_PACK16, usage):
		return Image.FORMAT_RGB565
	if rd.texture_is_format_supported_for_usage(RenderingDevice.DATA_FORMAT_B4G4R4A4_UNORM_PACK16, usage):
		return Image.FORMAT_RGBA4444
	return Image.FORMAT_RGBA8

## 取显示纹理格式：主线程首次调用时探测并缓存，后台线程只读缓存
static func get_display_format() -> int:
	if not _probed and Thread.is_main_thread():
		_display_format = _probe_display_format()
		_probed = true
	return _display_format

## 外部图片的显存优化（纯 CPU 操作，可在后台线程调用）：
## 导出模板只保留块压缩解码器，没有 ETC2/ASTC/S3TC 编码器，运行时无法生成压缩纹理；
## 封面和头像不需要透明通道，转成 GPU 可用的 16 位格式，显存约为 RGBA8 的 1/2。
## 不改变图片尺寸，避免缩放造成失真。
## 注：Godot 中 FORMAT_RGB565 的格式名沿用 "RGBA5551"，实际存储的是 16 位 RGB565。
static func prepare_display_image(image: Image) -> Image:
	if image == null or image.is_empty() or image.is_compressed():
		return image
	var format := get_display_format()
	if format == -1:
		return image
	if image.get_format() != format:
		image.convert(format)
	return image

## 加载文件并做显存优化（线程安全，供 CoverLoader 后台线程使用）
static func load_display_image(path: String) -> Image:
	return prepare_display_image(load_image_file(path))

## 创建显示用纹理（主线程）
static func create_display_texture(image: Image) -> Texture2D:
	if image == null or image.is_empty():
		return null
	var prepared := prepare_display_image(image)
	if prepared == null or prepared.is_empty():
		return null
	return ImageTexture.create_from_image(prepared)

## 路径 → 显示纹理（同步加载；大文件或主线程敏感场景请走 CoverLoader）
static func load_display_texture(path: String) -> Texture2D:
	return create_display_texture(load_image_file(path))

static func _has_png_signature(bytes: PackedByteArray) -> bool:
	return bytes.size() >= 8 \
		and bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47 \
		and bytes[4] == 0x0D and bytes[5] == 0x0A and bytes[6] == 0x1A and bytes[7] == 0x0A

static func _has_jpeg_signature(bytes: PackedByteArray) -> bool:
	return bytes.size() >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF

static func _has_webp_signature(bytes: PackedByteArray) -> bool:
	return bytes.size() >= 12 \
		and bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x46 \
		and bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50
