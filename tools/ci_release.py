#!/usr/bin/env python3
"""GitHub Actions 上的发布编排：发布前校验 → 建草稿 → 上传 → 回读校验 → 转正。

为什么不能直接复用 tools/release.py 的发布段：
  本机那条链路依赖「本地 dist/updates/*.json 留档清单 + 本地 git 状态」，
  搬到 CI 后会**静默失效**——`check_monotonic()` 在清单不存在时直接 return，
  于是 CI 里既没有 build 单调性保护，也没有 tag 冲突保护（只剩 gh 的裸报错）。
  本脚本把 CI 侧的判据全部换成远端事实：线上清单的 build、GitHub 上的 tag/release。

为什么用草稿 Release 收口：
  后端 `UpdateManifestBuilder.Build()` 第一件事就是 `if (release.Draft) continue;`
  ——草稿对玩家完全不可见。所以可以在草稿里攒齐三平台资产、逐个回读校验，
  全部通过后才 `--draft=false` 转正；中途任何一步失败，线上清单一个字节都不变。

用法：
  # 发布前校验（在 prepare job 里、任何导出之前跑）
  python tools/ci_release.py preflight --notes-file Doc/release-notes/next.md

  # 建草稿 + 上传 + 回读校验 + 转正（在 publish job 里、产物下载完之后跑）
  python tools/ci_release.py publish --tag v1.0.0.776 --version 1.0.0.776 \\
      --build 776 --notes-file Doc/release-notes/next.md \\
      --target-sha "$(git rev-parse HEAD)" --assets dist/*.zip dist/*.apk dist/*.tar.gz

  # 转正后等线上清单跟进（后端 600s 定时刷新，非阻塞）
  python tools/ci_release.py wait-online --version 1.0.0.776 --build 776 --timeout 900

退出码：0 通过；1 校验失败/操作失败；2 参数错误。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import sync_version as sv  # noqa: E402

REPO_ROOT = sv.REPO_ROOT
CSPROJ_PATH = REPO_ROOT / "Touhou Mix Community Edition.csproj"
EXPORT_PRESETS_PATH = REPO_ROOT / "export_presets.cfg"
VERSION_MANAGER_PATH = REPO_ROOT / "Core" / "VersionManager.gd"

## 线上清单地址（后端从 GitHub Release 派生；CI 只读，不写）
ONLINE_MANIFEST_URL = "https://thmixce.org/api/update/beta"
## 云防火墙按 UA 拦非浏览器请求（CF 1010），脚本必须自带浏览器 UA
BROWSER_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
## 发布说明模板标记：文件还在模板状态时必须拦住，否则会把占位文案发出去
TEMPLATE_MARKER = "<!-- 待填写 -->"
## 资产文件名 → 平台键（与 release.py / 后端 FindPlatformAsset 的命名约定一致）
ARTIFACT_SUFFIX = {
    "windows": "win64.zip",
    "android": "arm64.apk",
    "linux": "linux-x86_64.tar.gz",
}
TAG_PATTERN = re.compile(r"^v?(\d+(?:\.\d+){1,3})$")
## 上传后回读资产的重试：GitHub 的资产是异步落库的，刚上传完立刻读可能还是空
ASSET_READBACK_ATTEMPTS = 6
ASSET_READBACK_DELAY = 5


class CiReleaseError(RuntimeError):
    pass


## 子进程输出统一按 UTF-8 解码：`text=True` 默认用 locale（Windows 上是 GBK），
## 而 git/gh 的输出里常有 UTF-8 中文，不指定就会抛 UnicodeDecodeError。
TEXT_KW = {"text": True, "encoding": "utf-8", "errors": "replace"}


# ============================================================ 基础工具


def git(*args: str) -> str:
    try:
        return subprocess.check_output(
            ["git", *args], cwd=REPO_ROOT, stderr=subprocess.PIPE, **TEXT_KW
        ).strip()
    except FileNotFoundError as exc:
        raise CiReleaseError("找不到 git 命令") from exc
    except subprocess.CalledProcessError as exc:
        raise CiReleaseError(f"git {' '.join(args)} 失败: {exc.stderr.strip()}") from exc


def gh(*args: str, capture: bool = True) -> str:
    """调用 gh CLI；capture=False 时直接继承 stdout/stderr（上传进度直接打到日志里）。"""
    cmd = ["gh", *args]
    try:
        if capture:
            return subprocess.check_output(
                cmd, cwd=REPO_ROOT, stderr=subprocess.PIPE, **TEXT_KW
            ).strip()
    except FileNotFoundError as exc:
        raise CiReleaseError("找不到 gh 命令（CI 里需要 GH_TOKEN 环境变量）") from exc
    except subprocess.CalledProcessError as exc:
        raise CiReleaseError(f"gh {' '.join(args)} 失败: {exc.stderr.strip()}") from exc

    proc = subprocess.run(cmd, cwd=REPO_ROOT)
    if proc.returncode != 0:
        raise CiReleaseError(f"gh {' '.join(args)} 失败（退出码 {proc.returncode}）")
    return ""


def repo_slug() -> str:
    """owner/repo。优先用 CI 注入的 GITHUB_REPOSITORY。

    不走 git remote：checkout v4 的 origin 可能带凭据前缀或走 credential helper，
    而 GITHUB_REPOSITORY 是 GitHub 直接给的权威值。
    """
    env = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if env.count("/") == 1:
        return env
    url = git("remote", "get-url", "origin")
    match = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$", url)
    if not match:
        raise CiReleaseError(f"无法从 origin 解析 GitHub 仓库名: {url}")
    return f"{match.group(1)}/{match.group(2)}"


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_outputs(values: dict[str, str]) -> None:
    """同时写 GITHUB_OUTPUT（CI）和标准输出（本地调试可见）。"""
    for key, value in values.items():
        print(f"[OUTPUT] {key}={value}")
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        for key, value in values.items():
            handle.write(f"{key}={value}\n")


def write_summary(lines: list[str]) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        for line in lines:
            print(line)
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def http_json(url: str, timeout: int = 15) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": BROWSER_UA})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def split_platforms(raw: str) -> list[str]:
    """把 "windows, android" 归一成 ["windows", "android"]。

    workflow 里传进来的是一整串（`--platforms windows,android,linux`），
    直接用字符串迭代会变成逐字符比较，所以每个入口都要先过这里。
    """
    known = ["windows", "android", "linux"]
    items = [item.strip().lower() for item in raw.replace(";", ",").split(",") if item.strip()]
    unknown = [item for item in items if item not in known]
    if unknown:
        raise CiReleaseError(f"未知平台 {', '.join(unknown)}（可选 {', '.join(known)}）")
    if not items:
        raise CiReleaseError("平台列表为空")
    return [item for item in known if item in items]


# ============================================================ 发布说明


def load_notes(path_text: str) -> tuple[Path, str]:
    path = Path(path_text)
    if not path.is_absolute():
        path = REPO_ROOT / path
    if not path.is_file():
        raise CiReleaseError(
            f"发布说明文件不存在: {path}。请在仓库里手写本次说明（建议 Doc/release-notes/next.md），"
            "提交推送后再触发发布"
        )
    # utf-8-sig：编辑器/PowerShell 写出的文件常带 BOM，BOM 会被原样传给 gh，
    # 结果 Release body 首行变成 "\ufeff## 标题"，后端 ExtractTitle 只认行首 '#'
    # ⇒ 标题静默丢失。在这里剥掉，别指望写文件的人记得。
    text = path.read_text(encoding="utf-8-sig").strip()
    if not text:
        raise CiReleaseError(f"发布说明文件为空: {path}")
    if TEMPLATE_MARKER in text:
        raise CiReleaseError(
            f"发布说明仍是模板（含 {TEMPLATE_MARKER}）: {path}。请写入本次真实更新内容后再发布"
        )
    return path, text


def check_notes_shape(text: str, allow_empty_changes: bool) -> tuple[list[str], list[str]]:
    """校验说明的机器可读部分，返回（错误, 警告）。

    后端从 Release body 里抽两类信息，写错不会报错、只会在客户端「关于」页看得出来：
      - 首行 `## 标题`       → 版本标题（标题里的版本号与渠道标注会被剥掉）
      - `- ` / `* ` 开头的行 → changes 列表（最多 20 条，`<!--` 开头会被跳过）
    """
    errors: list[str] = []
    warnings: list[str] = []
    lines = text.splitlines()
    bullets = [
        line.strip()[2:].strip()
        for line in lines
        if line.strip().startswith("- ") or line.strip().startswith("* ")
    ]
    bullets = [item for item in bullets if item and not item.startswith("<!--")]
    if not bullets and not allow_empty_changes:
        errors.append(
            "发布说明里没有 `- ` 开头的条目：客户端「关于」页的更新内容会是空的。"
            "请补条目，或确认无用户可见变更时写一条说明（加 --allow-empty-changes 跳过本检查）"
        )
    heading = next((line for line in lines if line.strip()), "")
    if not heading.startswith("#"):
        warnings.append("发布说明首行不是 `## 标题`：版本历史里会只显示版本号，没有标题")
    if len(bullets) > 20:
        warnings.append(f"条目 {len(bullets)} 条，后端只取前 20 条")
    return errors, warnings


# ============================================================ build 单调性


def online_builds(url: str) -> dict[str, int]:
    payload = http_json(url)
    platforms = payload.get("platforms") or {}
    builds: dict[str, int] = {}
    for name, entry in platforms.items():
        if isinstance(entry, dict):
            try:
                builds[name] = int(entry.get("build", 0))
            except (TypeError, ValueError):
                continue
    return builds


def release_builds_from_gh(slug: str) -> dict[str, int]:
    """从 GitHub 上的 Release tag 反推既有 build（线上清单不可用时的兜底判据）。

    只统计**已发布**的 Release：草稿对玩家不可见，把草稿的 build 当基准会让
    「上次没转正的草稿」永久抬高单调性门槛，把下一次合法发布挡住。
    """
    payload = gh(
        "release", "list", "--repo", slug, "--limit", "100", "--json", "tagName,isDraft"
    )
    builds: dict[str, int] = {}
    for item in json.loads(payload or "[]"):
        if item.get("isDraft"):
            continue
        tag = str(item.get("tagName") or "")
        match = TAG_PATTERN.match(tag)
        if not match:
            continue
        try:
            build = int(match.group(1).split(".")[-1])
        except ValueError:
            continue
        if build > 0:
            builds[f"tag {tag}"] = build
    return builds


def find_release(slug: str, tag: str) -> dict | None:
    """按 tag 找一个 Release，**草稿也算**。

    为什么不用 `/releases/tags/{tag}`：草稿在 GitHub 上还没有 tag，这个端点对草稿是 404
    （cli/cli#6198）。于是「上次发布失败留下了草稿」这种最需要妥善处理的场景，
    恰好会被判成「不存在」→ 紧接着 `gh release create` 撞 tag 冲突，现场很难看懂。
    列表端点在带 push 权限的令牌下会把草稿一起返回，所以以它为准。
    """
    listing = json.loads(gh("api", f"repos/{slug}/releases?per_page=100"))
    for item in listing:
        if str(item.get("tag_name") or "") == tag:
            return item
    return None


def reload_release(slug: str, release: dict) -> dict:
    """按 **release id** 重新读取（草稿也能读到，且能拿到资产的 digest/size）。"""
    release_id = release.get("id")
    if not release_id:
        raise CiReleaseError(f"Release {release.get('tag_name')} 缺少 id，无法回读")
    return json.loads(gh("api", f"repos/{slug}/releases/{release_id}"))


def tag_commit(slug: str, tag: str) -> str | None:
    """远端 tag 指向的提交；tag 不存在时返回 None。

    注意：**草稿 Release 不会创建 tag**，GitHub 要等转正时才建。所以「有草稿」不代表
    「有 tag」，判断草稿指向哪个提交要看 release 对象的 target_commitish。
    """
    try:
        payload = gh("api", f"repos/{slug}/git/ref/tags/{tag}")
    except CiReleaseError as exc:
        if "404" in str(exc) or "Not Found" in str(exc):
            return None
        raise
    ref = json.loads(payload)
    obj = ref.get("object") or {}
    if obj.get("type") == "tag":
        # 附注标签要再解一层才拿到提交
        annotated = json.loads(gh("api", f"repos/{slug}/git/tags/{obj.get('sha')}"))
        return str((annotated.get("object") or {}).get("sha") or "")
    return str(obj.get("sha") or "")


def release_target(release: dict) -> str:
    """草稿/正式 Release 记录的构建提交（target_commitish，可能是分支名）。"""
    return str(release.get("target_commitish") or "")


# ============================================================ preflight


def cmd_preflight(args: argparse.Namespace) -> int:
    slug = args.repo or repo_slug()
    platforms = split_platforms(args.platforms)

    # 1) 浅克隆会让 build（= 提交总数）偏小，必须当场拦住
    if git("rev-parse", "--is-shallow-repository") == "true":
        raise CiReleaseError("工作区是浅克隆，git rev-list --count HEAD 会偏小；请用 fetch-depth: 0")

    # 2) build / version / tag 三者由同一个提交数派生，不接受任何外部输入
    build = sv.git_commit_count()
    version, _ = sv.read_history()
    parts = version.split(".")
    if len(parts) != 4:
        raise CiReleaseError(f"version_history.json 的 current 需要 4 段（如 1.0.0.775），当前 {version!r}")
    version = ".".join(parts[:3] + [str(build)])
    tag = f"v{version}"

    # 3) 来源分支校验：正式的发布构建必须正好是远端 main 的那个提交。
    #
    #    例外只有一种：**mode=draft-only + --allow-branch**（试跑）。
    #    草稿 Release 对玩家不可见、也不会创建 tag，因此从分支试跑是安全的；
    #    一旦允许转正（mode=release），分支来源必须硬拒——tag 打在哪个提交上是
    #    不可逆的事实，而分支随时可能被 rebase/force-push。
    ref = os.environ.get("GITHUB_REF", "")
    is_main = ref in ("", "refs/heads/main")
    head = git("rev-parse", "HEAD")
    if not is_main:
        if args.mode != "draft-only" or not args.allow_branch:
            raise CiReleaseError(
                f"发布只能从 main 触发（当前 {ref}）。"
                "分支试跑必须同时选择 mode=draft-only 并勾选「允许分支试跑」"
            )
        branch = ref.split("refs/heads/", 1)[-1]
        try:
            origin_branch = git("rev-parse", f"origin/{branch}")
        except CiReleaseError:
            origin_branch = ""
        if not origin_branch:
            raise CiReleaseError(
                f"远端没有 origin/{branch}。试跑前先 git push -u origin {branch}"
            )
        if head != origin_branch:
            raise CiReleaseError(
                f"HEAD（{head[:7]}）与 origin/{branch}（{origin_branch[:7]}）不一致，"
                "先把这次改动推上去，否则跑的是旧代码"
            )
        print(f"[WARN] 试跑模式：来源分支 {branch}（草稿不会转正，线上不可见）")
    else:
        try:
            origin_main = git("rev-parse", "origin/main")
        except CiReleaseError:
            origin_main = ""
        if origin_main and head != origin_main:
            raise CiReleaseError(
                "HEAD 与 origin/main 不一致（本地分支/未推送提交/旧 checkout 都可能）。"
                "发布构建必须正好是远端 main 的那个提交，否则 tag 与实际内容错位"
            )

    # 4) csproj 的 Godot SDK 版本必须与 workflow 下载的引擎版本一致
    if args.godot_version:
        csproj = CSPROJ_PATH.read_text(encoding="utf-8", errors="replace")
        match = re.search(r'Godot\.NET\.Sdk/([\d.]+)', csproj)
        if not match:
            raise CiReleaseError(f"csproj 里找不到 Godot.NET.Sdk 版本: {CSPROJ_PATH.name}")
        if match.group(1) != args.godot_version:
            raise CiReleaseError(
                f"版本不一致：csproj 的 Godot.NET.Sdk/{match.group(1)}，"
                f"workflow 的 GODOT_VERSION={args.godot_version}。两者必须相同，否则导出必失败"
            )

    # 5) 发布说明：手写，且必须能被后端抽成 changes
    notes_path, notes_text = load_notes(args.notes_file)
    errors, warnings = check_notes_shape(notes_text, args.allow_empty_changes)
    for message in warnings:
        print(f"[WARN] {message}")
    if errors:
        raise CiReleaseError("\n".join(errors))

    # 6) build 单调性：以线上清单为准，gh 兜底；两边都拿不到就失败（不猜）
    known: dict[str, int] = {}
    source = ""
    try:
        known = online_builds(args.online_url)
        source = args.online_url
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        print(f"[WARN] 线上清单不可用（{exc}），改用 GitHub Release 兜底")
        known = release_builds_from_gh(slug)
        source = "GitHub releases"
    if not known:
        raise CiReleaseError("既有 build 无法判定（线上清单与 GitHub Release 都取不到），拒绝发布")
    latest_known = max(known.values())
    if build <= latest_known:
        message = f"build 未递增：{source} 上已有 {latest_known}，本次 {build}"
        if not args.force:
            raise CiReleaseError(message + "（确认要覆盖请加 --force）")
        print(f"[WARN] {message}（--force 已忽略）")
    missing_platforms = [p for p in platforms if p not in known]
    if missing_platforms:
        print(f"[INFO] 线上清单暂缺平台 {', '.join(missing_platforms)}（本次会补上）")

    # 7) tag / release 冲突：已发布的同号版本绝不允许重发
    release = find_release(slug, tag)
    if release is not None:
        if not release.get("draft"):
            raise CiReleaseError(
                f"{tag} 已经发布过（build {build}）。同一 build 不能重发："
                "资产一换 sha256 就变，已下载的客户端会对不上；请新增提交让 build 递增"
            )
        # 草稿是上一次没跑完留下的：publish 会把它删掉重建，所以这里只提示不拦。
        # 唯一值得注意的是它记的提交与本次不同——那说明「同一个 build 号对应了不同内容」，
        # 属于不该发生的事（build 就是提交数），必须让人看一眼。
        target = release_target(release)
        if target and len(target) == 40 and target != head:
            raise CiReleaseError(
                f"草稿 {tag} 记录的提交是 {target[:7]}，本次构建提交是 {head[:7]}。"
                "同一个 build 号对应两份不同内容，说明提交历史被改写过（amend/rebase/force push）。"
                "请先删掉这个草稿再重跑：gh api --method DELETE "
                f"repos/{slug}/releases/{release.get('id')}"
            )
        print(f"[INFO] 已存在同号草稿 {tag}，publish 时会删掉重建（草稿对线上不可见）")
    else:
        stray = tag_commit(slug, tag)
        if stray is not None:
            raise CiReleaseError(
                f"远端已有 tag {tag}（指向 {stray[:7]}）但没有对应 Release。"
                "先删掉这个 tag 再发布：git push origin :refs/tags/" + tag
            )

    write_outputs(
        {
            "version": version,
            "build": str(build),
            "tag": tag,
            "commit": head,
            "notes_file": str(notes_path.relative_to(REPO_ROOT)).replace("\\", "/")
            if notes_path.is_relative_to(REPO_ROOT)
            else str(notes_path),
            "platforms": ",".join(platforms),
        }
    )
    write_summary(
        [
            "## 发布前校验通过",
            "",
            f"- 版本：`{version}`（build `{build}`，来自提交数）",
            f"- 标签：`{tag}` → `{head[:7]}`",
            f"- 平台：{', '.join(platforms)}",
            f"- 线上最高 build：`{latest_known}`（来源：{source}）",
            f"- 发布说明：`{notes_path.name}`（{len(notes_text.splitlines())} 行）",
        ]
    )
    print(f"[OK] preflight: {tag}（build {build}）可发布，线上当前 {latest_known}")
    return 0


# ============================================================ publish


def cmd_publish(args: argparse.Namespace) -> int:
    slug = args.repo or repo_slug()

    if not TAG_PATTERN.match(args.tag):
        raise CiReleaseError(f"非法 tag: {args.tag!r}")
    if args.tag.lstrip("v").split(".")[-1] != str(args.build):
        raise CiReleaseError(
            f"tag {args.tag} 的末段与 --build {args.build} 不一致（build 必须等于版本号末段）"
        )
    notes_path, _ = load_notes(args.notes_file)

    assets: list[Path] = []
    platforms_found: dict[str, str] = {}
    expected_prefix = f"THMIX-CE-{args.version}-"
    for raw in args.assets:
        path = Path(raw)
        if not path.is_file():
            raise CiReleaseError(f"资产不存在: {path}")
        if not path.name.startswith(expected_prefix):
            # 后端靠「扩展名 + 文件名含 win/linux」挑资产，名字不对会挑错甚至挑空
            raise CiReleaseError(f"资产命名不符合约定，应以 {expected_prefix} 开头: {path.name}")
        suffix = path.name[len(expected_prefix):]
        platform = next((name for name, tail in ARTIFACT_SUFFIX.items() if tail == suffix), None)
        if platform is None:
            raise CiReleaseError(
                f"资产 {path.name} 的后缀不在约定内（{' / '.join(ARTIFACT_SUFFIX.values())}）。"
                "名字不符时后端挑不到包，玩家会收不到这个平台的更新"
            )
        if platform in platforms_found:
            raise CiReleaseError(f"同一平台出现两个资产: {platform}")
        platforms_found[platform] = path.name
        assets.append(path)
    if not assets:
        raise CiReleaseError("没有可上传的资产")
    print(f"[ASSET] 平台覆盖: {', '.join(sorted(platforms_found))}")

    digests = {path.name: sha256_of(path) for path in assets}
    for name, digest in digests.items():
        print(f"[ASSET] {name}  {digest}")

    # 目标提交必须是构建提交
    release = find_release(slug, args.tag)
    if release is not None and not release.get("draft"):
        raise CiReleaseError(f"{args.tag} 已经是正式 Release，不允许再改资产")

    if release is None:
        # 还没有 Release：若远端已有同号 tag，说明它指向未知内容
        # （tag 一旦发布就是不可逆的事实，不能悄悄复用）
        previous = tag_commit(slug, args.tag)
        if previous is not None and previous != args.target_sha:
            raise CiReleaseError(
                f"tag {args.tag} 已指向 {previous[:7]}，与 --target-sha {args.target_sha[:7]} 不一致"
            )
    else:
        # 已经有一份草稿：**删掉重建**，而不是往里补资产。
        # 草稿里的资产可能是上次中途失败的半成品；而 `gh release upload` 对刚建的草稿
        # 还有复制延迟问题（cli/cli#6198）。草稿对外不可见，删了重建最省心。
        # 删除必须用 release id：`gh release delete <tag>` 走 /releases/tags/，
        # 而草稿在 GitHub 上还没有 tag，按 tag 删会报 release not found。
        release_id = release.get("id")
        if not release_id:
            raise CiReleaseError(f"草稿 {args.tag} 缺少 id，无法删除重建")
        print(f"[INFO] 删除已存在的草稿 {args.tag}（id={release_id}）后重建；草稿对线上不可见")
        gh("api", "--method", "DELETE", f"repos/{slug}/releases/{release_id}")
        release = None

    # 资产**放在 create 同一次调用里**，不随后单独 upload。
    # 原因（cli/cli#6198）：草稿刚建好时 GraphQL 与 REST 之间有短暂复制延迟，
    # 紧接着 `gh release upload <tag>` 会报 release not found；而 create 自带的上传
    # 走刚创建的对象本身，不受这个延迟影响。
    cmd = [
        "release",
        "create",
        args.tag,
        *[str(p) for p in assets],
        "--repo",
        slug,
        "--draft",
        # 渠道固定 beta：stable 入口刻意不开放（第一个正式版语义重得多）
        "--prerelease",
        "--title",
        args.tag,
        "--target",
        args.target_sha,
        "--notes-file",
        str(notes_path),
    ]
    print("[GH] " + " ".join(cmd))
    gh(*cmd)
    release = find_release(slug, args.tag)
    if release is None:
        raise CiReleaseError(f"创建草稿后读不到 {args.tag}（gh 报了成功但列表里没有）")

    # 回读校验：不信任 gh 的退出码，逐个比对名字/大小/摘要。
    # 用 release id 而不是 tag：草稿在 /releases/tags/ 上是 404。
    # 上传是异步落库的，刚上传完立刻读可能还是空的 ⇒ 带重试。
    payload = reload_release(slug, release)
    for attempt in range(1, ASSET_READBACK_ATTEMPTS + 1):
        remote_assets = {str(a.get("name")): a for a in (payload.get("assets") or [])}
        if all(path.name in remote_assets for path in assets):
            break
        if attempt == ASSET_READBACK_ATTEMPTS:
            break
        print(f"[WAIT] 资产尚未全部可见（第 {attempt} 次），{ASSET_READBACK_DELAY}s 后重读")
        time.sleep(ASSET_READBACK_DELAY)
        payload = reload_release(slug, release)
    remote_assets = {str(a.get("name")): a for a in (payload.get("assets") or [])}

    problems: list[str] = []
    for path in assets:
        remote = remote_assets.get(path.name)
        if remote is None:
            problems.append(f"{path.name}: Release 里找不到这个资产")
            continue
        size = int(remote.get("size") or 0)
        local_size = path.stat().st_size
        if size != local_size:
            problems.append(f"{path.name}: 大小不一致（远端 {size}，本地 {local_size}）")
        digest = str(remote.get("digest") or "")
        if digest:
            remote_sha = digest.split(":", 1)[-1].lower()
            if remote_sha != digests[path.name]:
                problems.append(f"{path.name}: sha256 不一致（远端 {remote_sha[:12]}…）")
        else:
            print(f"[WARN] {path.name}: GitHub 未返回 digest，只校验了大小")
    if problems:
        raise CiReleaseError(
            "资产回读校验失败（Release 保持草稿，线上未受影响）：\n  " + "\n  ".join(problems)
        )
    print(f"[OK] {len(assets)} 个资产回读校验通过")

    summary = [
        f"## {'草稿已就绪' if args.keep_draft else '已发布'} `{args.tag}`",
        "",
        "| 资产 | 大小 | sha256 |",
        "| --- | --- | --- |",
    ]
    for path in assets:
        summary.append(f"| `{path.name}` | {path.stat().st_size:,} | `{digests[path.name][:16]}…` |")

    if args.keep_draft:
        summary.append("")
        summary.append("草稿对线上不可见；确认无误后在 GitHub 上手动 Publish，或重跑并勾选发布。")
        write_summary(summary)
        print("[OK] 保留草稿（--keep-draft）")
        return 0

    print("[GH] 转正：草稿 → 正式 Release（线上清单下一次刷新即生效）")
    gh("release", "edit", args.tag, "--repo", slug, "--draft=false", "--prerelease")

    # 转正后 tag 才真正存在，这里可以按 tag 读，但用 id 读更稳（不依赖 tag 已建好）
    final = reload_release(slug, release)
    if final.get("draft"):
        raise CiReleaseError("转正后回读仍是草稿，请到 GitHub 上确认")
    summary.append("")
    summary.append(f"线上地址：{final.get('html_url')}")
    write_summary(summary)
    write_outputs({"release_url": str(final.get("html_url") or "")})
    print(f"[OK] 已发布 {args.tag}：{final.get('html_url')}")
    return 0


# ============================================================ wait-online


def cmd_wait_online(args: argparse.Namespace) -> int:
    deadline = time.monotonic() + args.timeout
    # --platforms 传的是 "windows,android" 这样一串；不切分的话 `name in args.platforms`
    # 永远为假，stuck 恒为空，第一次轮询就会误报「已经上线」。
    wanted = split_platforms(args.platforms) if args.platforms else []
    last_error = ""
    while True:
        try:
            builds = online_builds(args.url)
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            builds = {}
            last_error = str(exc)
        if builds:
            stuck = {
                name: value
                for name, value in builds.items()
                if value < args.build and (not wanted or name in wanted)
            }
            if not stuck:
                print(f"[OK] 线上清单已跟进：{', '.join(f'{k}={v}' for k, v in sorted(builds.items()))}")
                write_summary(
                    [
                        "## 线上清单已跟进",
                        "",
                        *[f"- `{k}`: build `{v}`" for k, v in sorted(builds.items())],
                    ]
                )
                return 0
            print(f"[WAIT] 线上仍是 {stuck}，期望 build {args.build}")
        else:
            print(f"[WAIT] 暂时读不到线上清单（{last_error or '空 platforms'}）")
        if time.monotonic() >= deadline:
            print(
                f"[WARN] 等待 {args.timeout}s 仍未见 build {args.build} 上线；"
                "后端每 600s 刷新一次，稍后可用同一命令复查"
            )
            return 1
        time.sleep(args.interval)


# ============================================================ apple-check


def cmd_apple_check(args: argparse.Namespace) -> int:
    """iOS / macOS 占位 job 的前置条件核对。

    占位 job 的职责只有两条：证明 macOS runner 能装好 Godot mono + 模板，
    以及把「真做导出还缺什么」列清楚。一旦仓库里真的出现 iOS/macOS 预设，
    这个 job 就必须改成真正的导出步骤——所以它在这里**故意失败**当绊线。
    """
    presets = EXPORT_PRESETS_PATH.read_text(encoding="utf-8", errors="replace")
    release_py = (SCRIPT_DIR / "release.py").read_text(encoding="utf-8", errors="replace")
    version_manager = VERSION_MANAGER_PATH.read_text(encoding="utf-8", errors="replace")

    checks = [
        (
            "export_presets.cfg 有 iOS 预设",
            bool(re.search(r'platform="iOS"', presets)),
            'preset 的 platform="iOS"（目前只有 Android / Windows Desktop / Linux）',
        ),
        (
            "export_presets.cfg 有 macOS 预设",
            bool(re.search(r'platform="macOS"', presets)),
            'preset 的 platform="macOS"',
        ),
        (
            "release.py 支持 macos/ios 导出",
            '"macos"' in release_py and '"ios"' in release_py,
            "tools/release.py 的 EXPORT_PRESETS / ARTIFACT_SUFFIX 增加 ios、macos 条目",
        ),
        (
            "客户端平台键已就绪",
            '"ios"' in version_manager and '"macos"' in version_manager,
            "Core/VersionManager.gd 的 get_platform_key()（已有，无需改动）",
        ),
        (
            "check_export.py 能校验 apple 产物",
            "macos" in (SCRIPT_DIR / "check_export.py").read_text(encoding="utf-8", errors="replace"),
            "tools/check_export.py 增加 ios/macos 的结构校验",
        ),
    ]

    todo = [check for check in checks if not check[1]]
    summary = ["## iOS / macOS 占位 job", ""]
    if args.godot:
        summary.append(f"引擎：`{args.godot}`（macOS runner 安装成功）")
        summary.append("")
    summary.append("| 前置条件 | 状态 |")
    summary.append("| --- | --- |")
    for label, ok, _ in checks:
        # 只用 ASCII 标记：Windows 控制台是 GBK，emoji 会直接抛 UnicodeEncodeError
        summary.append(f"| {label} | {'已就绪' if ok else '缺失'} |")
    if todo:
        summary.append("")
        summary.append("待办：")
        summary.extend(f"- {item[2]}" for item in todo)
        summary.append("")
        summary.append(
            "另需后端 `UpdateManifestBuilder` 增加 `ios` / `macos` 平台键，否则包做出来也发不下去。"
        )
        write_summary(summary)
        print(f"[PLACEHOLDER] 还缺 {len(todo)} 项前置条件，占位 job 未做导出（符合预期）")
        return 0

    # 前置条件齐了：这个 job 不能再假装通过
    write_summary(summary)
    raise CiReleaseError(
        "iOS/macOS 的前置条件已齐备，占位 job 必须改成真正的导出步骤"
        "（tools/release.py --export-only --platforms macos）后再保留该 job"
    )


# ============================================================ CLI


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="CI 侧发布编排（草稿 Release 收口）")
    sub = parser.add_subparsers(dest="command", required=True)

    pre = sub.add_parser("preflight", help="发布前校验（导出之前跑）")
    pre.add_argument("--notes-file", required=True, help="发布说明文件（仓库内路径）")
    pre.add_argument("--platforms", default="windows,android,linux", help="本次要出的平台")
    pre.add_argument("--channel", default="beta", help="更新渠道（CI 固定 beta）")
    pre.add_argument("--godot-version", help="期望的 Godot 版本（与 csproj 的 Godot.NET.Sdk 比对）")
    pre.add_argument("--online-url", default=ONLINE_MANIFEST_URL, help="线上清单地址（build 单调性判据）")
    pre.add_argument("--repo", help="owner/repo（默认从 origin 解析）")
    pre.add_argument("--mode", default="release", choices=["release", "draft-only"],
                     help="发布模式；非 draft-only 时分支来源一律拒绝")
    pre.add_argument("--allow-branch", action="store_true",
                     help="允许从非 main 分支试跑（仅在 mode=draft-only 下生效）")
    pre.add_argument("--allow-empty-changes", action="store_true", help="允许说明里没有 `- ` 条目")
    pre.add_argument("--force", action="store_true", help="允许 build 不递增")
    pre.set_defaults(func=cmd_preflight)

    pub = sub.add_parser("publish", help="建草稿 → 上传 → 回读校验 → 转正")
    pub.add_argument("--tag", required=True)
    pub.add_argument("--version", required=True)
    pub.add_argument("--build", type=int, required=True)
    pub.add_argument("--notes-file", required=True)
    pub.add_argument("--target-sha", required=True, help="本次构建提交（tag 必须钉在这里）")
    pub.add_argument("--assets", nargs="+", required=True)
    pub.add_argument("--repo")
    pub.add_argument("--keep-draft", action="store_true", help="只留草稿，不转正")
    pub.set_defaults(func=cmd_publish)

    wait = sub.add_parser("wait-online", help="等线上清单跟进（非阻塞提示）")
    wait.add_argument("--build", type=int, required=True)
    wait.add_argument("--url", default=ONLINE_MANIFEST_URL)
    wait.add_argument("--platforms", default="", help="只关心这些平台，逗号分隔（默认全部）")
    wait.add_argument("--timeout", type=int, default=900)
    wait.add_argument("--interval", type=int, default=30)
    wait.set_defaults(func=cmd_wait_online)

    apple = sub.add_parser("apple-check", help="iOS/macOS 占位 job 的前置条件核对")
    apple.add_argument("--godot", help="已安装的引擎路径（仅用于日志）")
    apple.set_defaults(func=cmd_apple_check)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        return args.func(args)
    except CiReleaseError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
