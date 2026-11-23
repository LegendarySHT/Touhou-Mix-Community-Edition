# CI 发布与导出

GitHub Actions 上的一条流水线，拆成三个文件：

| 文件 | 作用 |
| --- | --- |
| `_export-platforms.yml` | **可复用**：`workflow_call`，三平台导出 + 结构自检 + 启动自检 + 上传 artifact |
| `export.yml` | **影子构建**（手动）：只出 artifact，不碰线上，Android 用一次性测试签名 |
| `release.yml` | **正式发布**（手动）：导出 → 攒进草稿 Release → 回读校验 → 转正 |

平台细节只写在 `_export-platforms.yml` 一份里，两个入口不各写一遍。

## 一、正式发布怎么做

### 1. 写发布说明（必做，手写）

编辑 `Doc/release-notes/next.md`，提交并推到 `main`：

```markdown
## 草稿箱与稳定性修复

- 新增草稿箱，支持上传、查看、下载草稿
- 修复个人资料页打开时的节点错误
```

格式由后端 `UpdateManifestBuilder` 决定，写错不会报错、只会在客户端「关于」页看得出来：

| 元素 | 作用 | 约束 |
| --- | --- | --- |
| 首行 `## 标题` | 版本历史里的标题 | 后端会剥掉其中的版本号与「（beta）」标注；缺了只显示版本号 |
| `- ` / `* ` 开头的行 | `changes` 列表 | **最多取 20 条**；`<!--` 开头的行会被跳过（可写机器可读元信息） |
| 其余文字 | 不进入客户端 | 只作为 Release 正文 |

发布校验会拦住三种情况：文件仍是模板（含 `<!-- 待填写 -->`）、文件为空、没有任何 `- ` 条目。
确认本次没有用户可见变更时，可在触发时勾选「允许空更新说明」。

> 发布完成后记得把 `next.md` 改回模板内容再提交，否则下一次会误发旧内容。

### 2. 触发

Actions → 「发布（手动）」→ Run workflow：

| 输入 | 说明 |
| --- | --- |
| `platforms` | 逗号分隔，默认三个平台全出 |
| `notes_file` | 发布说明路径，默认 `Doc/release-notes/next.md` |
| `mode` | `release` = 校验通过后转正；`draft-only` = 只留草稿，人工在 GitHub 上 Publish |
| `allow_empty_changes` | 允许说明里没有 `- ` 条目 |
| `force` | 允许 build 不递增（危险，见下） |

### 3. 流水线做了什么

```
preflight（只读，~1 分钟）
  ├ 浅克隆拦截：build = 提交数，fetch-depth 必须 0
  ├ 只允许 refs/heads/main，且 HEAD == origin/main
  ├ csproj 的 Godot.NET.Sdk 版本 == workflow 的 GODOT_VERSION
  ├ 发布说明存在、非模板、能被抽成 changes
  ├ build 单调性：线上清单 vs 本次 build（gh 兜底）
  └ tag/release 冲突：同号已发布过 → 直接失败
export（三平台并行，~6 分钟）
  └ 复用 _export-platforms.yml，android_signing=release
publish（~2 分钟）
  ├ 建 **草稿** Release（--target 钉死构建提交，--prerelease，**资产在同一次 create 调用里**）
  ├ 按 release id 回读：逐个比对资产名 / 大小 / sha256（GitHub 的 digest），带重试
  └ gh release edit --draft=false   ← 唯一对外可见的时刻
wait-online（非阻塞）
  └ 轮询线上清单，最多 15 分钟，把结果写进 run summary
```

### 4. 为什么用草稿 Release

后端 `UpdateManifestBuilder.Build()` 第一件事是 `if (release.Draft) continue;`
——**草稿对玩家完全不可见**。所以可以在草稿里攒齐资产、逐个回读校验，全绿了才转正：

- 任何一步失败，线上清单一个字节都不变，不用手动清理半成品；
- 回滚有正经手段：`gh release edit v1.0.0.777 --draft=true` 把它改回草稿，
  后端下次刷新（≤10 分钟）就回退到上一版。

⚠️ 这只挡「还没更新的人」。已经升到坏版本的客户端，`VersionManager._evaluate_manifest`
只认 `latest_build > local_build`，**不会降级**——真要救必须发一个 build 更大的修复版。

### 5. 三个已踩过的 GitHub API 坑（改这段代码前务必读）

这三条都是「本地怎么测都过、到 GitHub 上才炸」的类型：

| 坑 | 现象 | 现在的做法 |
| --- | --- | --- |
| 草稿在 `/releases/tags/{tag}` 上是 404 | 以为草稿不存在 → 重复 create 撞 tag 冲突 | 一律用 `/releases?per_page=100` 列表找（带 push 权限能看到草稿），回读用 `/releases/{id}` |
| `gh release create --draft` 后立刻 `gh release upload` 报 `release not found`（[cli/cli#6198](https://github.com/cli/cli/issues/6198)） | 草稿刚建时 GraphQL 与 REST 有复制延迟 | **资产放在 create 同一次调用里**，不随后单独 upload |
| `gh release delete <tag>` 对草稿同样 404 | 重跑时删不掉旧草稿 | 用 `gh api --method DELETE repos/{slug}/releases/{id}` |

因此「重跑」的语义是：**发现同号草稿就删掉重建**，而不是往里补资产——
上次失败留下的资产可能是半成品，而草稿对外不可见，删了没有任何代价。

### 6. 需要的 secrets

发布走**仓库级** secret（Settings → Secrets and variables → Actions → Secrets →
New repository secret），未启用人工审批，触发即跑。2026-11-23 已配好这 4 个：

| secret | 用途 | 怎么取 |
| --- | --- | --- |
| `ANDROID_KEYSTORE_BASE64` | release keystore 的 base64 | `base64 -w0 thmix-release.jks`；PowerShell：`[Convert]::ToBase64String([IO.File]::ReadAllBytes("...jks"))` |
| `ANDROID_KEYSTORE_USER` | 签名别名 | 本机 `tools/signing.env` 的 `THMIX_ANDROID_KEYSTORE_USER`（当前 `thmix-ce`） |
| `ANDROID_KEYSTORE_PASSWORD` | 签名密码 | 同上 |
| `ANDROID_KEYSTORE_SHA256` | 证书指纹，用于**校验签名身份** | `keytool -list -v -keystore <jks> -alias thmix-ce \| grep SHA256` |

用 `gh` 写入（keystore 与密码走 stdin，不进命令行历史）：

```bash
gh secret set ANDROID_KEYSTORE_BASE64 < keystore.b64
gh secret set ANDROID_KEYSTORE_USER --body thmix-ce
gh secret set ANDROID_KEYSTORE_PASSWORD < password.txt
gh secret set ANDROID_KEYSTORE_SHA256 --body <小写无冒号的完整 SHA-256>
gh secret list   # 确认 4 个都在（只显示名字与更新时间，读不到值）
```

**`ANDROID_KEYSTORE_SHA256` 不是可选项**：结构自检完全不看签名，拿测试 key 打出来的包能一路绿到发布。
Android 升级要求同签名，一旦把测试签名的包发出去，所有用户必须卸载重装。
缺这个 secret 时 `android_signing=release` 会直接失败，不会回落到测试签名。

指纹的大小写与冒号**两侧都归一**（小写、去冒号、去空白），但**长度必须 64**——
CI 会显式检查，防「提取被截断、两边恰好相等」的假通过（`sed 's/.*: *//'` 是贪婪匹配，
遇到 `4C:00:F0:…` 这种带冒号输入会把指纹截成末尾 2 个字符，实测确认过）。

影子构建（`export.yml`）不需要任何 secret，用 `keytool` 现生成一次性密钥。

### 7. 与本机 `release.py` 的分工

**CI 主、本机应急。**

| | CI `release.yml` | 本机 `release.py` |
| --- | --- | --- |
| 用途 | 常规发布 | GitHub 故障 / 需要秒级热修 |
| 签名 | secret 里的 release keystore + 指纹校验 | `tools/signing.env` |
| build 判据 | 线上清单（gh 兜底） | 本地留档 **+ 线上清单**（`--online-url`，默认开） |
| 发布收口 | 草稿 → 校验 → 转正 | 直接 `gh release create` |
| 版本号文件 | 不提交（`git restore` 还原） | 同左 |

两条通道的 build 判据现在都收敛到线上清单，撞号会当场失败，不会各发各的。

## 二、影子构建（`export.yml`）

只导出、打包、校验，产物走 workflow artifact（默认 7 天）；**不建 Release、不碰线上**。
Android 用一次性测试签名，包不可发布。用途：在没装 Godot 的机器上验证发布链路。

## 三、环境准备（`setup-godot` composite action）

- 引擎与模板缓存到 `~/.godot-ci/engine` 与**引擎自己的数据目录**
  （Windows `%APPDATA%\Godot\export_templates`、Linux `~/.local/share/godot/export_templates`、
  macOS `~/Library/Application Support/Godot/export_templates`）。
  Godot **不读** `GODOT_EXPORT_TEMPLATES`：模板放别处会报
  `No export template found at the expected path`，而脚本侧的自检还会假通过。
- Windows 固定用 `*_console.exe`：GUI 子系统的 exe 在 CI 里 stdout 不接管道，
  导出失败只剩一个退出码，看不到引擎的任何日志。
- 桌面端包必须含 `data_<项目名>_<平台>/`（.NET 程序集，约 105MB）。缺了 Godot 只打一行
  `ERROR: .NET: Assemblies not found`、退出码仍是 0，所以打包前后都有强校验。

## 四、三个导出 job 的关键步骤

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

## 五、iOS / macOS 占位 job

`_export-platforms.yml` 里有一个 `apple-placeholder` job（macos runner，**按 10 倍计费，
默认关闭**，勾 `include_apple` 才跑）。它只做两件事：

1. 证明 macOS runner 能装好 Godot mono 引擎与导出模板（`setup-godot` 已支持 `platform: macos`）；
2. 用 `python3 tools/ci_release.py apple-check` 列出**真做导出还缺什么**。

当前缺的四项（每次跑都会打印）：

| 缺什么 | 怎么补 |
| --- | --- |
| `export_presets.cfg` 的 iOS 预设 | 编辑器里加 preset，`platform="iOS"` |
| `export_presets.cfg` 的 macOS 预设 | 同上，`platform="macOS"` |
| `tools/release.py` 支持 ios/macos | `EXPORT_PRESETS` / `ARTIFACT_SUFFIX` 增加条目（导出逻辑基本同 Linux） |
| `tools/check_export.py` 校验 apple 产物 | 参照 `check_linux` 写分支 |

另外还需后端 `UpdateManifestBuilder` 增加 `ios` / `macos` 平台键，否则包做出来也发不下去。
客户端侧已就绪：`VersionManager.get_platform_key()` 早就返回 `ios` / `macos`。

**绊线设计**：一旦上述前置条件齐备，`apple-check` 会**主动失败**，提醒把这个 job 改成真正的
导出步骤（`release.py --export-only --platforms macos`），而不是继续假装通过。

## 六、当前状态与遗留

- Windows / Android 的启动自检是**硬校验**，全绿。
- **Linux 启动自检是 `continue-on-error`（非阻塞）**：包在 runner 上稳定崩在
  「主题预设已应用」之后（此时 `Config loaded from PCK` 已打出、miniaudio 走 Null 后端
  初始化成功），而同一份代码在 Windows 上能完整跑到 `ALBUM_VIEW`。
  runner 无 GPU（Mesa llvmpipe）也无音频设备，现阶段无法把它与真实缺陷区分开。
  **待办：在真实 Linux 桌面上跑一次 `THMIX-CE-*-linux-x86_64.tar.gz` 判定。**
  解包后同目录执行 `./THMIX-CE-<ver>-linux-x86_64 --headless` 看是否同样段错误。
- CI 不暴露 `stable` 渠道：所有 Release 都带 `--prerelease`，`/api/update/stable` 尚未启用。
- 后端每 600s 从 GitHub Releases 派生一次清单，**没有手动刷新接口**，
  所以发布后最快要等 10 分钟才线上可见（`wait-online` 只是把这个过程记录下来）。

## 七、本地复现 CI 自检

```bash
# 发布前校验（不联网写任何东西，只读线上清单与 gh）
PYTHONUTF8=1 python3 tools/ci_release.py preflight --notes-file Doc/release-notes/next.md --godot-version 4.7.2

# 结构自检 / 启动自检
python3 tools/check_export.py --platform linux --version 1.0.0.777
python3 tools/smoke_test.py --artifact dist/THMIX-CE-1.0.0.777-linux-x86_64.tar.gz
python3 tools/smoke_test.py --artifact dist/THMIX-CE-1.0.0.777-win64.zip --timeout 150
# 有 xvfb 的 Linux 上按真实窗口路径跑：
python3 tools/smoke_test.py --artifact ...tar.gz --headed --wrap "xvfb-run -a "
```

`--keep` 保留解包目录便于排查；失败时若装了 gdb 会自动补一份调用栈。

工作流文件改完可以在本地用 actionlint 静态检查（CI 里没有这一步）：

```bash
actionlint -shellcheck shellcheck -pyflakes "python -m pyflakes"
```
