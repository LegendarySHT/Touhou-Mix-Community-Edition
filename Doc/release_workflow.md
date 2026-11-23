# 发布流程（当前）

> 一句话：**在 GitHub 上点一次「发布（手动）」**，三平台并行导出 → 攒进草稿 Release →
> 逐个回读校验 → 转正。本机 `tools/release.py` 降级为应急通道。

## 前提（一次性配置）

Android 真签名需要 4 个**仓库级** secret：Settings → Secrets and variables → Actions →
Secrets → New repository secret。2026-11-23 已配好：

| secret | 值 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | release keystore 的 base64 |
| `ANDROID_KEYSTORE_USER` | `thmix-ce` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEYSTORE_SHA256` | 证书 SHA-256（小写、无冒号，64 位） |

缺 `ANDROID_KEYSTORE_SHA256` 时发布**直接失败**，不会回落到测试签名——Android 升级要求同签名。
取值与写入命令见 `Doc/ci_export_workflow.md` §6。

## 常规发布（CI）

1. 改 `Doc/release-notes/next.md`（手写，格式见下），提交并 push 到 `main`
2. Actions →「发布（手动）」→ Run workflow，`mode` 选 `release`
3. 等 6~8 分钟：导出 6 分钟 + 发布 2 分钟
4. 玩家侧最迟 10 分钟后收到更新（后端每 600s 从 GitHub Releases 派生清单）

版本号不需要手改：`build = git rev-list --count HEAD`，版本号前三段取自
`Resources/Config/version_history.json` 的 `current`。所以**每多一个提交，build 就 +1**，
发布前也不要再改版本号文件（`release.py` 会在导出后 `git restore` 还原，CI 里同样不提交）。

### 发布说明的格式

```markdown
## 一句话概括

- 玩家能看懂的改动
- 修了什么
```

- 首行 `## 标题` → 客户端「关于」页的版本标题（版本号与「（beta）」会被自动剥掉）
- `- ` / `* ` 开头的行 → 更新内容，**最多取 20 条**
- `<!-- ... -->` 里的内容后端会跳过，可以写内部备注

## 应急发布（本机）

GitHub 故障、或需要绕开 CI 排队时：

```powershell
$env:PYTHONUTF8="1"
python tools/release.py --notes-file Doc/release-notes/next.md
```

前提：工作区干净、提交已推送、`gh auth status` 正常、本机 Godot 4.7.2 mono + 导出模板齐备、
`tools/signing.env` 里有 Android 签名凭据。

本机这条通道**不更新** `dist/updates/beta.json` 之外任何线上状态，但 build 单调性判据
同时看本地留档与线上清单（`--online-url`，默认 `https://thmixce.org/api/update/beta`），
所以和 CI 不会撞号。

## 两条通道的硬约束（都不可绕过）

| 约束 | 原因 |
| --- | --- |
| 顺序必须是「提交 → push → 发布」 | tag 打在远端分支头，本地有未推送提交时 tag 会落歪 |
| 只能从 `main` 发 | 转正（`mode=release`）时强制；tag 指向哪个提交是不可逆的事实。唯一例外：`mode=draft-only` + 勾「允许分支试跑」，草稿不建 tag、对线上不可见 |
| 同一 build 不能重发 | 换资产会改 sha256，已下载的客户端校验对不上；只能 bump build |
| Android 必须用 release keystore | 升级要求同签名，换了 key 全体用户必须卸载重装 |
| 发布后不能改资产 | 同上：sha256 变了但 build 没变，等于发了个坏更新 |

## 出了事怎么办

| 情况 | 处理 |
| --- | --- |
| 草稿没转正就发现问题 | 什么都不用做：重跑会删掉旧草稿重建；或直接在 GitHub 上删草稿，线上没变化 |
| 转正后发现有问题 | `gh release edit <tag> --draft=true` 改回草稿，10 分钟内后端回退到上一版 |
| 已经有人升级到坏版本 | **只能发 build 更大的修复版**（客户端不会降级） |
| 一个平台漏发了 | 补提交 → 重发一版（不能只替换单个资产） |
| 想先看成品再决定 | 触发时 `mode` 选 `draft-only`，在 GitHub 上确认后点 Publish |

## 相关文档

- `Doc/ci_export_workflow.md`：工作流内部细节、secrets 配置、iOS/macOS 占位、本地复现自检
