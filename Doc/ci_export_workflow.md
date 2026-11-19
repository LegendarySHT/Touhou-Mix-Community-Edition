# CI 导出构建（`.github/workflows/export.yml`）

手动触发的影子构建：**只导出、打包、校验，产物走 workflow artifact，不创建 Release、不碰线上。**
本机 `python tools/release.py` 的一条龙发布能力保持不变，两边共用同一套导出与打包代码
（`tools/release.py --export-only`）。

## 触发与输入

Actions → 「导出构建（手动）」→ Run workflow：

| 输入 | 说明 |
| --- | --- |
| `platforms` | 逗号分隔，可写 `windows,linux,android`、`windows`、`Windows , Linux`（空格/大小写/分号都能识别）。拼错的平台名当场报错退出，不会静默跳过 |
| `keep_days` | artifact 保留天数，默认 7 |

`prepare` job 由 `git rev-list --count HEAD` 推出 build 号，版本号写进日志；三个平台 job 并行。

## 与「本机一条龙」的分工

| | CI | 本机 `release.py` |
| --- | --- | --- |
| 导出打包 | `--export-only` | 默认，导出后建 Release |
| 签名 | 一次性影子 keystore（不可发布） | `tools/signing.env` 的真实凭据 |
| 产物去向 | workflow artifact | GitHub Release + 清单 |
| 版本号校验 | 跳过单调性检查 | 校验 build 递增、tag 不存在 |
| 工作区 | 不检查脏/未推送 | `ensure_clean_worktree` / `ensure_pushed` |

真正发版仍然走本机：CI 只回答「这份提交能不能导出成三平台可用的包」。

## 环境准备（`setup-godot` composite action）

- 引擎与模板缓存到 `~/.godot-ci/engine` 与**引擎自己的数据目录**
  （Windows `%APPDATA%\Godot\export_templates`、Linux `~/.local/share/godot/export_templates`）。
  Godot **不读** `GODOT_EXPORT_TEMPLATES`：模板放别处会报
  `No export template found at the expected path`，而脚本侧的自检还会假通过。
- Windows 固定用 `*_console.exe`：GUI 子系统的 exe 在 CI 里 stdout 不接管道，
  导出失败只剩一个退出码，看不到引擎的任何日志。
- 桌面端包必须含 `data_<项目名>_<平台>/`（.NET 程序集，约 105MB）。缺了 Godot 只打一行
  `ERROR: .NET: Assemblies not found`、退出码仍是 0，所以打包前后都有强校验。

## 三个 job 的关键步骤

1. `dotnet build -p:GodotTargetPlatform=<windows|linuxbsd|android>` —— **必须在导入前**。
   干净 checkout 里 `.godot/mono` 为空，C# 未编译会让 `ChartDb`/`MidiCore` 这些 autoload
   起不来，引用 `KeySequenceCore` 的 GDScript 全部 parse error，导出被判 configuration errors。
   本机因为早就 build 过，永远不会暴露这个问题。
2. `tools/godot_prepare.py` —— headless 导入完成后编辑器不退出，脚本盯日志
   （`[ DONE ] loading_editor_layout` / `EditorSettings not instantiated`）主动结束。
3. Android 额外两步：
   - `android/` 整个目录在 `.gitignore` 里（只有本机装过模板），CI 必须从导出模板的
     `android_source.zip` 铺出 `android/build/`，并补 `android/.build_version`
     （缺了报 `no version info for it exists`）与 `android/build/.gdignore`，
     还要 `chmod +x android/build/gradlew`（zip 不保留权限位）。
   - `--install-android-build-template` 在 headless 下**段错误**（退出码 139），不能用。
4. `tools/check_export.py` —— 结构自检：程序集目录、pck 内的
   `song.mid`/`sf2`/`theme.ini`/`config.ini`、原生库、Linux 权限位、Android 的 `assets/` 布局；
   Android 另用 `aapt2 dump permissions` 确认 `android.permission.INTERNET` 存在。
5. `tools/smoke_test.py` —— 解到**空目录**真跑一次 `--headless`，从日志认
   `Config loaded from PCK` 与 `MIDI data loaded successfully`。结构自检证明不了能启动，
   763 那个缺 `data_*` 的包就是「一行 ERROR + 退出码 0」蒙混过去的。

## 当前状态与遗留

- Windows / Android 的启动自检是**硬校验**，全绿。
- **Linux 启动自检是 `continue-on-error`（非阻塞）**：包在 runner 上稳定崩在
  「主题预设已应用」之后（此时 `Config loaded from PCK` 已打出、miniaudio 走 Null 后端
  初始化成功），而同一份代码在 Windows 上能完整跑到 `ALBUM_VIEW`。
  runner 无 GPU（Mesa llvmpipe）也无音频设备，现阶段无法把它与真实缺陷区分开。
  **待办：在真实 Linux 桌面上跑一次 `THMIX-CE-*-linux-x86_64.tar.gz` 判定。**
  解包后同目录执行 `./THMIX-CE-<ver>-linux-x86_64 --headless` 看是否同样段错误。
- 产物只保留 7 天；发布仍走本机。后续若要接 iOS，落点是 macOS runner 上再加一个 job，
  复用同一套 `release.py --export-only`。

## 本地复现 CI 自检

```bash
python tools/smoke_test.py --artifact dist/THMIX-CE-1.0.0.765-linux-x86_64.tar.gz
python tools/smoke_test.py --artifact dist/THMIX-CE-1.0.0.765-win64.zip --timeout 150
# 有 xvfb 的 Linux 上按真实窗口路径跑：
python tools/smoke_test.py --artifact ...tar.gz --headed --wrap "xvfb-run -a "
```

`--keep` 保留解包目录便于排查；失败时若装了 gdb 会自动补一份调用栈。
