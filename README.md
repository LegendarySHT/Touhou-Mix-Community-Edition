# Touhou Mix Community Edition

Touhou Mix Community Edition 是一款使用 Godot 引擎制作的、以 Touhou Project 为主题的音乐游戏。它能将 MIDI 文件转换为可游玩的谱面，并提供了高度的自定义自由度。

本项目是 [Touhou Mix](https://thmix.org)（官网：thmix.org）的社区版本。

> ⚠️ **早期开发警告**  
> 当前游戏开发仍处于早期阶段，可能存在一些影响游玩体验的问题，欢迎反馈。  
> 目前的主要开发精力是将原 Touhou Mix 的玩法和内容进行改进并移植到本项目中，并计划在后期开发更多新玩法和新内容。

## 技术栈

本项目使用了以下开源技术（均已为实现游戏功能进行了部分修改）：

- **[meltysynth](https://github.com/sinshu/meltysynth)** (MIT 协议) — 提供 MIDI 播放功能  
- **[Godot](https://godotengine.org/)** (MIT 协议) — 游戏引擎，用于开发游戏
- **[miniaudio](https://github.com/mackron/miniaudio)** (MIT 协议) — 提供低延迟音频引擎

## 开发环境准备（开发者）

本项目通过 git 子模块引入 `miniaudio.h`（位于 `addons/miniaudio/native/miniaudio/`，对应仓库见 `.gitmodules`），克隆时请带子模块：

```powershell
git clone --recurse-submodules https://github.com/LegendarySHT/Touhou-Mix-Community-Edition
# 或已有 clone 后补拉子模块：
git submodule update --init --recursive
```

> 注意：不要手动下载 `miniaudio.h` 覆盖子模块目录，否则 git 会将其视为子模块被修改。

## 歌曲/资源导入

- **单文件**：把 `.mid` / `.sf2` / 音频文件拖进游戏窗口，或用系统的「打开方式」选择本游戏打开。
  - `.mid`：以文件 MD5 为谱面 hash，自动建立歌曲文件夹（歌曲名取文件名，专辑归入「本地歌曲」）。
  - `.sf2`：复制到音源目录。
  - 音频（`.mp3` / `.wav` / `.ogg` / `.flac`）：文件名（不含扩展名）必须是已有谱面的 MIDI 哈希，会复制为该谱面的人声音频。
- **ZIP 资源包**：拖入或「打开方式」打开，游戏会先解析并显示将导入的歌曲/人声/皮肤/特效/音源/背景数量，确认后按包内结构导入。
  - 有效结构：`Charts/`、`Skins/`、`Particles/`、`Soundfont/`、`BackgroundImage/`、`settings.ini`、`theme.ini` 位于同一层级（外面可以再套普通文件夹）。
  - 只包含一个图片文件夹，或根目录直接是一堆图片时，按皮肤包导入。
  - 包含 `settings.ini` / `theme.ini` 时会覆盖配置，导入完成后需要重启游戏。

## 许可证

本项目采用 **Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License** (CC BY-NC-SA 4.0) 进行许可。

## 贡献

如果你对贡献本项目感兴趣，欢迎加入 Touhou Mix 官方测试群联系开发者：

- QQ 群：**1020610194** 或 **140497416**  
- 联系 Legendary\_SHT 或 Yang\_

