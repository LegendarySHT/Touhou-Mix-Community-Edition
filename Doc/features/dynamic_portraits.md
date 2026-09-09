# 动态立绘与成绩反应

> 核对日期：2026-09-07

## 实现边界

`UI/Components/DynamicPortrait.gd` 使用细分网格、RGB 运动权重与独立眼睑补片，实现呼吸、轻摆、发梢/裙摆运动和眨眼。翅膀不进行独立局部变形，只随整张立绘整体移动，以避免边缘顶点和中心区域不同步造成的撕裂。它是保留原画的轻量 2D 动画，**不是 Live2D Cubism 模型**，不依赖 Cubism SDK，也不包含自动骨骼绑定、任意视角转头或口型同步。

人物选择继续使用 `CharaView` 与 `[Chara] chara_id`。新增内置莉莉白不覆盖用户当前选择；在人物页选择后，Album、Song、SortedMidi 的主界面人物和 ScoreView 会使用该角色。

## 兼容原有资源协议

- 保留 `chara.json` 的 `general`、`info`、`rating`、`dialog`，以及 `CharaMGR.get_portrait(key, emotion)` 静态纹理接口。
- 表情 `0` 表示基础图；表情 `1..N` 从表情图集左上角开始按行排列。`rating` 始终是评级到整数表情编号的映射，不改成反应对象。
- `motion` 和 `score_reactions` 都是可选字段。旧人物不必修改 JSON，仍可显示静态表情与轻微浮动；列表和头像消费者不需要实例化动态组件。
- 扩展数据在扫描 worker 中规范化，独立扫描和 `FileSystemManager` 直接合并索引的路径一致。缺少或损坏的扩展不影响有效的静态立绘。
- 未知 motion 版本、缺少权重图或权重图尺寸不匹配时退回静态；眼睑图尺寸不匹配仅禁用眨眼。不要把这些回退当作资源验证通过。

## 素材要求与 motion v1

基础图与表情图集仍由原协议合成。另准备两种可选 PNG：

| 素材 | 规格 |
| --- | --- |
| 运动权重图 | 与基础图等尺寸、同坐标的 RGB 图片。黑色不施加局部位移，红通道保留作构图标记但当前不驱动独立翅膀变形，绿通道对应发梢，蓝通道对应裙摆；不要把权重图作为可见图层或添加透明遮罩。 |
| 眼睑补片 | 与基础图等尺寸、同坐标的 RGBA 图片，仅闭眼所需区域不透明；仅用于明确兼容的表情，避免闭眼时覆盖不匹配的眉毛、脸红或眼泪。 |

以下字段放在 `chara.json` 根对象的 `motion` 中；图片路径相对于当前人物目录，禁止绝对路径和 `..`：

```json
{
  "version": 1,
  "weight_image": "motion.png",
  "head_pivot": [0.28, 0.4],
  "breath": 2.2,
  "sway": 2.5,
  "wing": 14.0,
  "wing_rotation": 4.5,
  "wing_pivots": [[0.47, 0.23], [0.36, 0.16]],
  "hair": 4.0,
  "skirt": 5.0,
  "speed": 1.0,
  "float": 5.0,
  "blink": {
    "image": "blink.png",
    "emotions": [0, 1, 7],
    "interval": [3.0, 5.8],
    "duration": 0.18
  }
}
```

| 参数 | 单位与约束 |
| --- | --- |
| `head_pivot` | 原图 UV 坐标，默认 `[0.28, 0.4]`；x 限于 0..1，y 限于 0.05..0.95。新人物需按头部位置调整。 |
| `breath` | 原图像素，范围 0..12。 |
| `sway` | 头部轻摆角度，范围 0..15 度。 |
| `wing` / `wing_rotation` / `wing_pivots` | 保留在资源协议中供后续无撕裂的独立翅膀渲染器使用；当前渲染器不对翅膀做局部变形。 |
| `hair` / `skirt` | 原图像素，分别限制在 0..20 / 0..20。 |
| `float` | 内层整体浮动，原图像素，范围 0..20。 |
| `speed` | 速度倍率，范围 0.2..3；基础循环周期为 `5 / speed` 秒。 |
| `blink.interval` | 随机等待区间，单位秒，各值 1..30，最大值不小于最小值。 |
| `blink.duration` | 一次闭合、保持、睁开的总时长，单位秒，范围 0.08..0.6。 |
| `blink.emotions` | 可使用该眼睑补片的整数表情编号；空数组不眨眼。不要包含超出实际素材的编号。 |

数值需要 JSON 数字而不是字符串。主体运动采用 26 × 40 格网格；翅膀使用同尺寸独立图层并整片平移，因此不会因边缘和中心落在不同权重顶点而变形。不同构图的角色可重做权重和头部支点；任意额外运动通道或骨骼属于后续渲染器扩展，不能仅通过新增未支持的 JSON 键实现。

## 按成绩配置反应

根对象的 `score_reactions` 将评级映射到命名预设；未知评级使用 `default`。表情仍独立由 `rating` 决定。

```json
{
  "default": "encourage",
  "ratings": {"Ω": "celebrate", "SSS": "celebrate", "F": "encourage"},
  "presets": {
    "celebrate": {
      "motion_scale": 1.4, "bounce": 18.0, "tilt": -3.0,
      "effect": "petals", "count": 20, "message": "太棒了！"
    },
    "encourage": {
      "motion_scale": 0.55, "bounce": 2.0, "tilt": 2.0,
      "effect": "none", "count": 0, "message": "我们再一起试试吧。"
    }
  }
}
```

- `motion_scale`：循环运动幅度倍率，0..2；不替代 `bounce` 和 `tilt`。
- `bounce`：入场反应的上跳距离，原图像素，0..40；`tilt`：倾斜角度，-8..8 度。
- `effect`：目前支持 `petals`、`sparkles`、`none`；`count` 最多 32，颜色由 `ThemeMGR` 提供。
- `message`：最多 160 字符；实际显示空间有限，推荐一句短文案并实测最小窗口。
- 完整评级包括 `Ω, SSS, SS, S, A+, A, A-, B+, B, B-, C+, C, C-, D+, D, D-, F`。莉莉白示例完整覆盖 17 级，按五档使用庆祝、花瓣、星光或轻柔鼓励；新增人物不要遗漏带 `+/-` 的评级。

## 宿主与组件职责

```gdscript
var portrait := DynamicPortrait.new()
add_child(portrait)
portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
portrait.show_character(chara_key, 0)
portrait.set_active(true)
```

| API | 行为 |
| --- | --- |
| `show_character(key, emotion = 0)` | 清理旧人物状态，载入新人物、表情与独立材质。 |
| `set_emotion(emotion)` | 换表情并复位眨眼；保留当前人物。 |
| `show_result(key, rank)` | 根据一次确定的评级选择表情、动作、特效和短消息。 |
| `set_active(active)` | 显式控制动画，默认关闭。停止时清理所有内部 Tween 并复位姿态。 |

使用 `CharaMGR.get_motion_config(key)`、`get_score_reaction(key, rank)` 获取规范化配置的深复制，不直接修改 Manager 索引。`get_chara_texture(key, image_name)` 缓存扩展纹理，统一缓存清理入口同时清理它们；材质和动画状态不共享。

- 外层 `TextureButton` / `TextureRect` 保留布局、主界面命中检测和页面入退场；设置其 `self_modulate.a = 0` 隐藏自身绘图，不要设置 `modulate.a = 0` 隐藏动态子层。
- 内层组件的所有 Tween 使用 `AniMGR.create_managed_tween` 和实例唯一 ID；宿主不再叠加旧的人物浮动循环。
- 主界面人物仅在 Album、Song、SortedMidi 页面显示；Store 页面不显示人物。退场仅移出屏幕，不一定 `hide()`，所以 `CharaInteract` 按 UIState 显式暂停。选角详情和 ScoreView 在入场完成后激活，离开、切角、隐藏和释放时停止。
- ScoreView 使用最终评级快照，异步入场通过 generation 检查取消过期协程，不在延时回调中重新查询全局分数。
- `message_top_ratio` 默认 0.84；ScoreView 设为 0.43，给下方成绩面板让出空间。布局变化后应重新做视觉检查。
- 人物扫描由 `FileSystemManager.resources_ready` 完成；主初始化还可等待 `EvtBus.data_loaded_complete`。不要在 `_ready()` 假设人物资源已就绪。

## 添加下一个人物

1. 在 `Resources/Charas/<新目录>/` 添加基础图、表情图集和 `chara.json`，保留原画作者与许可说明。
2. 保证同一组表情位置完全对齐；只有脸部变化时可以裁出共同差分区域。用叠回基础图的方式验证所有表情，而不只验证第一张。
3. 根据新构图制作等尺寸的权重与眼睑 PNG，调整 `head_pivot` 和动作幅度；配置真实存在的表情编号。
4. 添加 `motion.version = 1`、完整 `rating` 和可选 `score_reactions`；同类效果不需要修改主界面或 ScoreView，也不应按角色 ID 写分支。
5. Godot 导入资源后重新启动或等待人物扫描完成，从人物选择页启用；保留现有选择配置，不默认替用户换角。
6. 验证表情缓存首次/命中、损坏动态资源回退、多实例材质独立、切角和快速进退，以及新旧人物在 Album、Song、SortedMidi、详情、ScoreView 的表现；确认 Store 页面不显示人物。

莉莉白的可重跑加工工具为 `Tools/Art/prepare_lily_white.py`，依赖 Pillow。传入用户提供的源目录即可重建四张 PNG，**不修改源图，也不覆盖手工维护的 `chara.json`**。其闭眼遮罩和运动分区仅适用于本套莉莉白构图，不是通用自动拆图工具。

## 本次验证边界

2026-09-07 在本机 Godot 4.7.1 Mono 下完成 125 项 headless 协议/缓存/生命周期检查和 25 项真实 GPU 页面检查，并通过 300 帧游戏启动验证。临时回归脚本、日志及截图位于 `temp/lily_*`，按项目规范不入库。

真实页面检查包含眨眼、Album、选角预览、五档成绩反应、连续进退与旧天子兼容；Store 页面仅确认不显示人物。Store 的后端在本次环境不可达，未替代在线商品交互和 Android/iOS 真机性能验证。退出时已有的 `CoverLoader.gd` 线程清理警告不属于动态立绘改动。
