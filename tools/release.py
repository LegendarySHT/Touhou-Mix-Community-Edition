#!/usr/bin/env python3
"""Windows 手动发布脚本（beta 渠道）。

发布链路：
  1. 检查工作区干净、gh 已登录、Godot 可执行文件存在
  2. sync_version.py --write --git-build：build = 当前分支提交数
  3. 与已有清单比较 build，禁止倒退
  4. Godot --export-release 导出 Windows exe 到 dist/
  5. 还原版本号文件（版本号是构建期产物，不进提交）
  6. gh release create（beta 自动加 --prerelease）并取回资产下载地址
  7. 计算 SHA-256 / 大小，生成 beta.json 写到 --manifest-out
  8. 回读校验清单

用法：
  python tools/release.py --dry-run
  python tools/release.py --manifest-out "D:/Touhou Mix Dev/ThmixData/updates"
  python tools/release.py --notes-file notes.md --min-supported-build 700

注意：
  - 导出需要已安装 Windows 导出模板；C# 工程首次导出会自动编译，耗时较长
  - --manifest-out 是目录时写入 <目录>/<channel>.json；也可以是完整文件路径
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from datetime import date
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import sync_version as sv  # noqa: E402

REPO_ROOT = sv.REPO_ROOT
DIST_DIR = REPO_ROOT / "dist"
EXPORT_PRESET = "Windows Desktop"
DEFAULT_GODOT = Path(
    r"D:\Software\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
)
VERSION_FILES = [
    "project.godot",
    "export_presets.cfg",
    str(sv.HISTORY_PATH.relative_to(REPO_ROOT)).replace("\\", "/"),
]
CHANNEL_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")


class ReleaseError(RuntimeError):
    pass


def git(*args: str) -> str:
    try:
        return subprocess.check_output(
            ["git", *args], cwd=REPO_ROOT, text=True, stderr=subprocess.PIPE
        ).strip()
    except FileNotFoundError as exc:
        raise ReleaseError("找不到 git 命令") from exc
    except subprocess.CalledProcessError as exc:
        raise ReleaseError(f"git {' '.join(args)} 失败: {exc.stderr.strip()}") from exc


def ensure_clean_worktree(dry_run: bool) -> None:
    status = git("status", "--porcelain")
    if not status:
        return
    if dry_run:
        print("[WARN] 工作区不干净（dry-run 继续；正式发布会被拒绝）：\n" + status)
        return
    raise ReleaseError("工作区不干净，请先提交或 stash：\n" + status)


def ensure_gh_ready(dry_run: bool) -> None:
    try:
        proc = subprocess.run(
            ["gh", "auth", "status"], cwd=REPO_ROOT, capture_output=True, text=True
        )
    except FileNotFoundError as exc:
        raise ReleaseError("找不到 gh 命令，请先安装 GitHub CLI") from exc
    if proc.returncode == 0:
        return
    message = "gh 未登录，请先执行 gh auth login（或设置 GH_TOKEN）"
    if dry_run:
        print(f"[WARN] {message}")
        return
    raise ReleaseError(message)


def repo_slug() -> str:
    url = git("remote", "get-url", "origin")
    match = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$", url)
    if not match:
        raise ReleaseError(f"无法从 origin 解析 GitHub 仓库名: {url}")
    return f"{match.group(1)}/{match.group(2)}"


def resolve_godot(arg: str | None) -> Path:
    candidate = Path(arg or os.environ.get("GODOT_BIN", DEFAULT_GODOT))
    if not candidate.is_file():
        raise ReleaseError(f"找不到 Godot 可执行文件: {candidate}（可用 --godot 或 GODOT_BIN 指定）")
    return candidate


def godot_version_tag(godot: Path) -> str:
    try:
        output = subprocess.check_output([str(godot), "--version"], text=True, stderr=subprocess.STDOUT)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ReleaseError(f"读取 Godot 版本失败: {exc}") from exc
    tag = output.strip().splitlines()[0].strip() if output.strip() else ""
    if not tag:
        raise ReleaseError("Godot --version 返回为空")
    # 形如 4.7.2.stable.mono.official.ed1daf0bf → 模板目录用 4.7.2.stable.mono
    parts = tag.split(".")
    if len(parts) > 4 and parts[4] == "mono":
        tag = ".".join(parts[:5])
    elif len(parts) > 3:
        tag = ".".join(parts[:4])
    return tag


def windows_template(godot: Path) -> tuple[Path, str]:
    """按当前引擎版本查找 Windows 导出模板，返回（模板目录，期望的版本标签）。"""
    tag = godot_version_tag(godot)
    appdata = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
    expected = appdata / "Godot" / "export_templates" / tag
    if (expected / "windows_release_x86_64.exe").is_file():
        return expected, tag
    return expected, tag


def version_prefix() -> str:
    version, _ = sv.read_history()
    parts = version.split(".")
    if len(parts) != 4:
        raise ReleaseError(f"需要 4 段版本号（如 1.0.0.645），当前为 {version!r}")
    return ".".join(parts[:3])


def resolve_manifest_path(channel: str, raw: str | None) -> Path:
    if raw:
        path = Path(raw)
        if path.suffix.lower() == ".json":
            return path
        return path / f"{channel}.json"
    return DIST_DIR / "updates" / f"{channel}.json"


def check_monotonic(manifest_path: Path, new_build: int, force: bool) -> None:
    if not manifest_path.is_file():
        return
    try:
        old = json.loads(manifest_path.read_text(encoding="utf-8"))
        old_build = int(old["platforms"]["windows"]["build"])
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        raise ReleaseError(f"已有清单无法解析（{manifest_path}）: {exc}") from exc
    if new_build > old_build:
        return
    message = f"build 未递增：已发布 {old_build}，本次 {new_build}"
    if force:
        print(f"[WARN] {message}（--force 已忽略）")
        return
    raise ReleaseError(message + "（确认要发旧版本请加 --force）")


def export_windows(godot: Path, version: str) -> Path:
    """导出到临时目录后打包为 zip（预设未内嵌 pck，exe 与 pck 需一起分发）。"""
    staging = DIST_DIR / f"stage-{version}"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    exe = staging / f"THMIX-CE-{version}-win64.exe"

    cmd = [
        str(godot),
        "--headless",
        "--path",
        str(REPO_ROOT),
        "--export-release",
        EXPORT_PRESET,
        str(exe),
    ]
    print("[EXPORT] " + " ".join(cmd))
    proc = subprocess.run(cmd, cwd=REPO_ROOT)
    if proc.returncode != 0:
        raise ReleaseError(f"Godot 导出失败（退出码 {proc.returncode}）")
    if not exe.is_file() or exe.stat().st_size == 0:
        raise ReleaseError(f"导出未生成有效文件: {exe}")

    zip_path = DIST_DIR / f"THMIX-CE-{version}-win64.zip"
    if zip_path.is_file():
        zip_path.unlink()
    files = sorted(path for path in staging.iterdir() if path.is_file())
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in files:
            archive.write(path, arcname=path.name)
    shutil.rmtree(staging)
    print(f"[PACK] {zip_path.name}（{len(files)} 个文件，{zip_path.stat().st_size} 字节）")
    return zip_path


def restore_version_files() -> None:
    subprocess.run(
        ["git", "restore", "--source=HEAD", "--", *VERSION_FILES],
        cwd=REPO_ROOT,
        check=False,
    )
    print("[RESTORE] 已还原版本号文件，保持工作区干净")


def current_history_entry(version: str) -> dict:
    data = json.loads(sv.HISTORY_PATH.read_text(encoding="utf-8"))
    entries = data.get("entries") or []
    for entry in entries:
        if isinstance(entry, dict) and str(entry.get("version", "")).strip() == version:
            return entry
    return entries[0] if entries and isinstance(entries[0], dict) else {}


def build_notes(version: str, notes_file: str | None) -> tuple[str, list[str]]:
    if notes_file:
        text = Path(notes_file).read_text(encoding="utf-8").strip()
        if not text:
            raise ReleaseError(f"更新说明文件为空: {notes_file}")
        return text, []

    entry = current_history_entry(version)
    title = str(entry.get("title", "")).strip()
    changes = [str(item).strip() for item in entry.get("changes", []) if str(item).strip()]
    if not title and not changes:
        raise ReleaseError("version_history.json 中没有更新说明，请用 --notes-file 指定")

    lines = [f"## {title}" if title else f"## v{version}", ""]
    lines += [f"- {item}" for item in changes]
    return "\n".join(lines).strip() + "\n", changes


def ensure_tag_absent(tag: str) -> None:
    proc = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0:
        raise ReleaseError(f"标签已存在: {tag}")


def create_github_release(
    tag: str, artifact: Path, notes_path: Path, channel: str, slug: str
) -> str:
    cmd = [
        "gh",
        "release",
        "create",
        tag,
        str(artifact),
        "--title",
        tag,
        "--notes-file",
        str(notes_path),
    ]
    if channel != "stable":
        cmd.append("--prerelease")
    print("[GH] " + " ".join(cmd))
    proc = subprocess.run(cmd, cwd=REPO_ROOT)
    if proc.returncode != 0:
        raise ReleaseError(f"gh release create 失败（退出码 {proc.returncode}）")

    payload = subprocess.check_output(
        ["gh", "api", f"repos/{slug}/releases/tags/{tag}"], cwd=REPO_ROOT, text=True
    )
    assets = json.loads(payload).get("assets") or []
    for asset in assets:
        if asset.get("name") == artifact.name:
            return str(asset["browser_download_url"])
    raise ReleaseError(f"Release 中找不到资产 {artifact.name}")


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(
    version: str,
    build: int,
    channel: str,
    entry: dict,
    artifact: Path,
    download_url: str,
) -> dict:
    payload = {
        "version": version,
        "build": build,
        "published_at": date.today().isoformat(),
        "changes": entry.get("changes", []),
        "url": download_url,
        "sha256": sha256_of(artifact),
        "size": artifact.stat().st_size,
        "mirrors": [],
    }
    if entry.get("min_supported_build"):
        payload["min_supported_build"] = int(entry["min_supported_build"])
    return {"schema": 1, "channel": channel, "platforms": {"windows": payload}}


def write_manifest(path: Path, manifest: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # 回读校验，避免写出服务端会拒绝的结构
    reloaded = json.loads(path.read_text(encoding="utf-8"))
    platform = reloaded["platforms"]["windows"]
    if reloaded.get("schema") != 1 or reloaded.get("channel") != manifest["channel"]:
        raise ReleaseError("清单回读校验失败：schema/channel 不符")
    if not platform.get("version") or int(platform.get("build", 0)) <= 0:
        raise ReleaseError("清单回读校验失败：version/build 无效")
    print(f"[MANIFEST] {path}（build={platform['build']}）")


def verify_remote_manifest(url: str, expected_build: int) -> None:
    with urllib.request.urlopen(url, timeout=10) as response:
        remote = json.loads(response.read().decode("utf-8"))
    remote_build = int(remote["platforms"]["windows"]["build"])
    if remote_build != expected_build:
        raise ReleaseError(f"线上清单 build={remote_build}，期望 {expected_build}")
    print(f"[VERIFY] {url} → build={remote_build}")


def run(args: argparse.Namespace) -> int:
    if not CHANNEL_PATTERN.match(args.channel):
        raise ReleaseError(f"非法渠道名: {args.channel!r}")

    ensure_clean_worktree(args.dry_run)
    ensure_gh_ready(args.dry_run)
    godot = resolve_godot(args.godot)
    slug = repo_slug()
    manifest_path = resolve_manifest_path(args.channel, args.manifest_out)

    template, engine_tag = windows_template(godot)
    template_ok = (template / "windows_release_x86_64.exe").is_file()
    if not template_ok:
        message = (
            f"未找到 {engine_tag} 的 Windows 导出模板（缺失 {template}）。"
            "请在编辑器「项目 → 导出 → 管理导出模板」安装与当前 Godot 完全一致的 mono 模板"
        )
        if not args.dry_run:
            raise ReleaseError(message)
        print(f"[WARN] {message}")

    if args.dry_run:
        version = f"{version_prefix()}.{sv.git_commit_count()}"
        print(f"[DRY-RUN] 仓库: {slug}")
        print(f"[DRY-RUN] Godot: {godot}")
        print(f"[DRY-RUN] 模板: {template if template_ok else '未安装'}")
        print(f"[DRY-RUN] 预发布版本: {version}（提交数，未写入文件）")
        print(f"[DRY-RUN] 产物: {DIST_DIR / f'THMIX-CE-{version}-win64.zip'}")
        print(f"[DRY-RUN] 清单: {manifest_path}")
        print("[DRY-RUN] 未执行导出与上传")
        return 0

    # 写入提交数版本号；失败时文件未改，无需还原
    if sv.run(write=True, git_build=True) != 0:
        raise ReleaseError("sync_version.py 执行失败")
    version, build = sv.read_history()
    if build != sv.git_commit_count():
        raise ReleaseError(f"build={build} 与 git 提交数={sv.git_commit_count()} 不一致")

    check_monotonic(manifest_path, build, args.force)

    tag = f"v{version}"
    ensure_tag_absent(tag)

    notes_text, changes = build_notes(version, args.notes_file)
    notes_path = DIST_DIR / f"release-notes-{version}.md"
    notes_path.parent.mkdir(parents=True, exist_ok=True)
    notes_path.write_text(notes_text, encoding="utf-8")

    # 版本号文件还原前先取条目快照（此时条目仍是新版本号）
    entry = dict(current_history_entry(version))
    entry["changes"] = changes or entry.get("changes", [])
    if args.min_supported_build is not None:
        entry["min_supported_build"] = args.min_supported_build

    try:
        artifact = export_windows(godot, version)
        if not args.keep_version_files:
            restore_version_files()

        download_url = create_github_release(tag, artifact, notes_path, args.channel, slug)
        manifest = build_manifest(version, build, args.channel, entry, artifact, download_url)
        write_manifest(manifest_path, manifest)
    finally:
        if not args.keep_version_files and git("status", "--porcelain", "--", *VERSION_FILES):
            restore_version_files()

    if args.verify_url:
        verify_remote_manifest(args.verify_url, build)

    print("\n[OK] 发布完成")
    print(f"  版本: {version}")
    print(f"  Release: {tag}（{args.channel}）")
    print(f"  资产: {download_url}")
    print(f"  清单: {manifest_path}")
    print("  部署: 把清单放到后端 数据根目录/updates/ 后即可被客户端读取")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="导出 Windows 构建并发布到 GitHub Release + 生成更新清单")
    parser.add_argument("--channel", default="beta", help="更新渠道（默认 beta）")
    parser.add_argument("--godot", help="Godot 可执行文件路径（默认读 GODOT_BIN）")
    parser.add_argument("--manifest-out", help="清单输出目录或 .json 完整路径")
    parser.add_argument("--notes-file", help="更新说明 Markdown；默认取 version_history.json 的 title/changes")
    parser.add_argument("--min-supported-build", type=int, help="写入清单的最低支持 build（可选）")
    parser.add_argument("--verify-url", help="发布后请求线上清单并校验 build（如 https://thmixce.org/api/update/beta）")
    parser.add_argument("--keep-version-files", action="store_true", help="保留版本号文件改动（默认还原）")
    parser.add_argument("--force", action="store_true", help="允许 build 不递增")
    parser.add_argument("--dry-run", action="store_true", help="只打印计划，不导出、不上传")
    args = parser.parse_args()

    try:
        return run(args)
    except ReleaseError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
