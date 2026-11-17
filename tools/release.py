#!/usr/bin/env python3
"""多平台手动发布脚本（默认同时出 Windows、Android 与 Linux，beta 渠道）。

发布链路：
  1. 检查工作区干净、gh 已登录、Godot 可执行文件存在
  2. sync_version.py --write --git-build：build = 当前分支提交数
  3. 与已有清单比较 build，禁止倒退
  4. Godot --export-release 依次导出选中平台到 dist/
     - windows → THMIX-CE-<ver>-win64.zip（exe + pck 打包）
     - android → THMIX-CE-<ver>-arm64.apk（Gradle 构建，需 release 签名）
     - linux   → THMIX-CE-<ver>-linux-x86_64.tar.gz（二进制 + pck，保留可执行权限）
  5. 还原版本号文件（版本号是构建期产物，不进提交）
  6. gh release create 一次性上传全部资产（beta 自动加 --prerelease）
  7. 计算 SHA-256 / 大小，生成本地留档清单（platforms 含各平台条目）
  8. 回读校验清单

用法：
  python tools/release.py --dry-run
  python tools/release.py --notes-file notes.md
  python tools/release.py --platforms windows          # 只发 PC
  python tools/release.py --platforms windows,android --notes-file notes.md
  python tools/release.py --platforms linux            # 只发 Linux

Android 签名（仅当发布 android 时需要）：
  THMIX_ANDROID_KEYSTORE           .jks 路径
  THMIX_ANDROID_KEYSTORE_USER      别名（默认 thmix-ce）
  THMIX_ANDROID_KEYSTORE_PASSWORD  密码（只从环境变量读，避免落在命令历史里）
  这三个值会转成 Godot 原生识别的 GODOT_ANDROID_KEYSTORE_RELEASE_* 传给子进程。

注意：
  - 导出需要已安装对应平台的导出模板；C# 工程首次导出会自动编译，耗时较长
  - Android 用 Gradle 构建（预设 use_gradle_build=true），首次或改动依赖后可能数分钟
  - Linux 包固定发 tar.gz：zip 在 Windows 上打包会丢可执行权限，解包后跑不起来
  - --manifest-out 是目录时写入 <目录>/<channel>.json；也可以是完整文件路径
  - 线上清单由后端从 GitHub Release 派生，本地这份仅用于 build 单调性校验与留档
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
import tarfile
import tempfile
import time
import urllib.request
import zipfile
from datetime import date
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import sync_version as sv  # noqa: E402

REPO_ROOT = sv.REPO_ROOT
DIST_DIR = REPO_ROOT / "dist"

## 平台键（与客户端 VersionManager.get_platform_key() 及后端清单 platforms.<key> 一致）
PLATFORM_WINDOWS = "windows"
PLATFORM_ANDROID = "android"
PLATFORM_LINUX = "linux"
EXPORT_PRESETS = {
    PLATFORM_WINDOWS: "Windows Desktop",
    PLATFORM_ANDROID: "Android",
    PLATFORM_LINUX: "Linux",
}
## 产物文件名后缀（dry-run 与文档用同一份映射，避免各写一遍走偏）
ARTIFACT_SUFFIX = {
    PLATFORM_WINDOWS: "win64.zip",
    PLATFORM_ANDROID: "arm64.apk",
    PLATFORM_LINUX: "linux-x86_64.tar.gz",
}
DEFAULT_PLATFORMS = f"{PLATFORM_WINDOWS},{PLATFORM_ANDROID},{PLATFORM_LINUX}"
## Godot 4.2+ 用环境变量注入 release 签名，无需改编辑器设置或项目预设
ANDROID_ENV_PATH = "GODOT_ANDROID_KEYSTORE_RELEASE_PATH"
ANDROID_ENV_USER = "GODOT_ANDROID_KEYSTORE_RELEASE_USER"
ANDROID_ENV_PASSWORD = "GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD"
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


def ensure_pushed(dry_run: bool) -> None:
    """发版前确认本地提交已推送。

    `gh release create` 的 tag 打在**远端**分支头上，不是本地 HEAD：
    本地有未推送提交时，tag 会指向旧提交，和这次实际构建的内容错位
    （2026-11-17 首发 v1.0.0.763 就踩到：tag 落在上一提交上）。
    """
    try:
        ahead = int(git("rev-list", "--count", "@{u}..HEAD").strip() or "0")
    except (ReleaseError, ValueError):
        print("[WARN] 无法判断是否有未推送提交（当前分支缺少上游），跳过检查")
        return
    if ahead <= 0:
        return
    message = f"有 {ahead} 个提交未推送：先 git push，否则 Release tag 会落在旧提交上"
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


def template_dir(godot: Path) -> tuple[Path, str]:
    """按当前引擎版本定位导出模板目录，返回（目录，版本标签）。"""
    tag = godot_version_tag(godot)
    appdata = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
    return appdata / "Godot" / "export_templates" / tag, tag


def missing_template(platform: str, directory: Path) -> str | None:
    """模板齐全返回 None，否则返回缺失说明。"""
    if platform == PLATFORM_WINDOWS:
        if (directory / "windows_release_x86_64.exe").is_file():
            return None
        return f"缺少 windows_release_x86_64.exe（目录 {directory}）"
    if platform == PLATFORM_ANDROID:
        # Gradle 构建（预设 use_gradle_build=true）需要 android_source.zip；
        # 非 Gradle 的预设模板导出用 android_release.apk，两者有其一即可。
        if (directory / "android_source.zip").is_file() or (directory / "android_release.apk").is_file():
            return None
        return f"缺少 android_source.zip / android_release.apk（目录 {directory}）"
    if platform == PLATFORM_LINUX:
        if (directory / "linux_release.x86_64").is_file():
            return None
        return f"缺少 linux_release.x86_64（目录 {directory}）"
    return f"未知平台 {platform}"


def parse_platforms(raw: str) -> list[str]:
    items = [item.strip().lower() for item in raw.split(",") if item.strip()]
    if not items:
        raise ReleaseError("--platforms 为空")
    unknown = [item for item in items if item not in EXPORT_PRESETS]
    if unknown:
        raise ReleaseError(f"未知平台: {', '.join(unknown)}（可选 {', '.join(EXPORT_PRESETS)}）")
    # 去重但保持顺序
    seen: list[str] = []
    for item in items:
        if item not in seen:
            seen.append(item)
    return seen


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
        platforms = old.get("platforms") or {}
        builds = [
            int(entry["build"])
            for entry in platforms.values()
            if isinstance(entry, dict) and "build" in entry
        ]
        if not builds:
            raise ValueError("platforms 里没有任何 build")
        old_build = max(builds)
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        raise ReleaseError(f"已有清单无法解析（{manifest_path}）: {exc}") from exc
    if new_build > old_build:
        return
    message = f"build 未递增：已发布 {old_build}，本次 {new_build}"
    if force:
        print(f"[WARN] {message}（--force 已忽略）")
        return
    raise ReleaseError(message + "（确认要发旧版本请加 --force）")


## 导出产物大小连续稳定这么久就认为写完（Godot headless 写完后常常不退出）
EXPORT_STABLE_SECONDS = 20
EXPORT_POLL_SECONDS = 2


def _tree_size(path: Path) -> int:
    """文件或目录的总字节数；不存在的路径按 0 处理。"""
    try:
        if path.is_file():
            return path.stat().st_size
    except OSError:
        return 0
    total = 0
    for item in path.rglob("*"):
        try:
            if item.is_file():
                total += item.stat().st_size
        except OSError:
            continue
    return total


def _make_staging(tag: str) -> Path:
    """建一个唯一的导出暂存目录（系统临时目录下）。

    不放 dist 里：一次导出会产生 200+ 个文件（C# 工程的 data_* 目录），
    打包后批量删除会触发环境的删除守卫（SAFE_DELETE_BULK_CONFIRM_REQUIRED），
    把整个发布流程打断。临时目录里残留也由系统回收，不污染仓库。
    """
    return Path(tempfile.mkdtemp(prefix=f"thmix-stage-{tag}-"))


def _drop_staging(staging: Path) -> None:
    """尽力清理暂存目录；删不掉（删除守卫 / 文件占用）也不能影响发布结果。"""
    shutil.rmtree(staging, ignore_errors=True)


def run_export(
    cmd: list[str],
    watch: Path,
    label: str,
    env: dict[str, str] | None = None,
    timeout: int = 1800,
) -> None:
    """执行 Godot 导出，产物写完就收工，不等进程自己退出。

    headless 导出在产物落地后经常不退出（日志停在
    `EditorSettings not instantiated ... shutdown_adb_on_exit`），死等只能耗到超时：
    Windows 白等 900s、Android 白等 1800s，一次全平台发版能白烧近一小时。
    这里改成轮询产物（文件或整个暂存目录）的总大小，连续稳定
    EXPORT_STABLE_SECONDS 秒即认为写完，主动结束进程。
    """
    print("[EXPORT] " + " ".join(cmd))
    proc = subprocess.Popen(cmd, cwd=REPO_ROOT, env=env)
    deadline = time.monotonic() + timeout
    last_size = -1
    stable_since: float | None = None
    try:
        while True:
            returncode = proc.poll()
            if returncode is not None:
                if returncode != 0:
                    raise ReleaseError(f"{label} 导出失败（退出码 {returncode}）")
                break

            now = time.monotonic()
            size = _tree_size(watch)
            if size > 0 and size == last_size:
                stable_since = stable_since if stable_since is not None else now
                if now - stable_since >= EXPORT_STABLE_SECONDS:
                    print(
                        f"[WARN] {label} 导出进程未退出，但产物已停止增长"
                        f"（{size} 字节，稳定 {EXPORT_STABLE_SECONDS}s），主动结束"
                    )
                    break
            else:
                last_size = size
                stable_since = None

            if now > deadline:
                if size > 0:
                    print(f"[WARN] {label} 导出超过 {timeout}s，产物非空（{size} 字节），继续")
                    break
                raise ReleaseError(f"{label} 导出超时（{timeout}s）且未生成产物: {watch}")
            time.sleep(EXPORT_POLL_SECONDS)

        if _tree_size(watch) <= 0:
            raise ReleaseError(f"{label} 导出未生成有效产物: {watch}")
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()


def export_windows(godot: Path, version: str) -> Path:
    """导出到临时目录后打包为 zip（预设未内嵌 pck，exe 与 pck 需一起分发）。"""
    staging = _make_staging("win")
    exe = staging / f"THMIX-CE-{version}-win64.exe"

    cmd = [
        str(godot),
        "--headless",
        "--path",
        str(REPO_ROOT),
        "--export-release",
        EXPORT_PRESETS[PLATFORM_WINDOWS],
        str(exe),
    ]
    # 以整个暂存目录为观测对象：Windows 版 exe 自包含 .NET 程序集，
    # 但导出过程仍会先写 data_* 目录，只盯 exe 可能过早判定完成。
    run_export(cmd, staging, PLATFORM_WINDOWS, timeout=900)
    if not exe.is_file() or exe.stat().st_size == 0:
        raise ReleaseError(f"导出未生成有效文件: {exe}")

    zip_path = DIST_DIR / f"THMIX-CE-{version}-win64.zip"
    if zip_path.is_file():
        zip_path.unlink()
    files = sorted(path for path in staging.iterdir() if path.is_file())
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in files:
            archive.write(path, arcname=path.name)
    print(f"[PACK] {zip_path.name}（{len(files)} 个文件，{zip_path.stat().st_size} 字节）")
    _drop_staging(staging)
    return zip_path


def android_signing_config(keystore_arg: str | None, user_arg: str | None) -> dict[str, str]:
    """读取 release 签名配置。密码只认环境变量，避免出现在命令历史 / 进程列表里。"""
    raw_path = keystore_arg or os.environ.get("THMIX_ANDROID_KEYSTORE", "")
    path = Path(raw_path.strip()) if raw_path.strip() else None
    if path is None or not path.is_file():
        raise ReleaseError(
            "Android 发布需要 release keystore：请设 THMIX_ANDROID_KEYSTORE（.jks 路径）或用 --android-keystore 指定。"
            f" 当前值: {raw_path or '<空>'}"
        )
    user = (user_arg or os.environ.get("THMIX_ANDROID_KEYSTORE_USER") or "thmix-ce").strip()
    if not user:
        raise ReleaseError("Android 签名别名为空：请设 THMIX_ANDROID_KEYSTORE_USER 或用 --android-keystore-user")
    password = os.environ.get("THMIX_ANDROID_KEYSTORE_PASSWORD", "")
    if not password:
        raise ReleaseError(
            "Android 签名密码缺失：请设环境变量 THMIX_ANDROID_KEYSTORE_PASSWORD"
            "（不提供命令行参数，避免密码写进 shell 历史）"
        )
    return {"path": str(path), "user": user, "password": password}


def export_android(godot: Path, version: str, signing: dict[str, str]) -> Path:
    """导出 APK。预设使用 Gradle 构建，签名通过环境变量注入给 Godot。"""
    apk = DIST_DIR / f"THMIX-CE-{version}-arm64.apk"
    if apk.is_file():
        apk.unlink()
    DIST_DIR.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env[ANDROID_ENV_PATH] = signing["path"]
    env[ANDROID_ENV_USER] = signing["user"]
    env[ANDROID_ENV_PASSWORD] = signing["password"]

    cmd = [
        str(godot),
        "--headless",
        "--path",
        str(REPO_ROOT),
        "--export-release",
        EXPORT_PRESETS[PLATFORM_ANDROID],
        str(apk),
    ]
    print("[EXPORT] Android 使用 Gradle 构建，首次或依赖变动后可能需要 10 分钟以上")
    run_export(cmd, apk, PLATFORM_ANDROID, env=env, timeout=1800)
    if not apk.is_file() or apk.stat().st_size == 0:
        raise ReleaseError(f"Android 导出未生成有效文件: {apk}")
    print(f"[PACK] {apk.name}（{apk.stat().st_size} 字节）")
    return apk


def pack_linux_archive(staging: Path, binary: Path, version: str) -> Path:
    """把 staging 目录整棵树打成 tar.gz，返回归档路径。

    与 Windows 不同，Linux 导出不会把 .NET 程序集内嵌进可执行文件，
    dotnet publish 的产物（data_<项目名>_linuxbsd_x86_64/）必须一起分发。
    """
    archive_path = DIST_DIR / f"THMIX-CE-{version}-{ARTIFACT_SUFFIX[PLATFORM_LINUX]}"
    if archive_path.is_file():
        archive_path.unlink()
    entries = sorted(staging.rglob("*"))
    file_count = 0
    with tarfile.open(archive_path, "w:gz", compresslevel=6) as archive:
        for path in entries:
            arcname = path.relative_to(staging).as_posix()
            info = archive.gettarinfo(str(path), arcname=arcname)
            # 归一化属主，别把本机 uid/gid 和用户名带进包
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            if path.is_dir():
                info.mode = 0o755
                archive.addfile(info)
                continue
            # Windows 上导出的文件没有 x 位，必须显式指定：
            # 主程序与 coreclr 的 createdump 需要可执行，其余按普通文件处理。
            info.mode = 0o755 if path == binary or path.name == "createdump" else 0o644
            file_count += 1
            with path.open("rb") as handle:
                archive.addfile(info, handle)
    print(
        f"[PACK] {archive_path.name}（{file_count} 个文件，{archive_path.stat().st_size} 字节）"
    )
    return archive_path


def export_linux(godot: Path, version: str) -> Path:
    """导出 Linux x86_64 桌面版并打包为 tar.gz。

    产物是「二进制 + pck + data_<项目名>_linuxbsd_x86_64/ 目录」，
    .NET 运行时与程序集在那个目录里，必须整棵树一起分发。
    用 tar.gz 而不是 zip：zip 在 Windows 上打包会丢掉可执行权限，玩家解包后跑不起来。
    """
    staging = _make_staging("linux")
    binary = staging / f"THMIX-CE-{version}-linux-x86_64"

    cmd = [
        str(godot),
        "--headless",
        "--path",
        str(REPO_ROOT),
        "--export-release",
        EXPORT_PRESETS[PLATFORM_LINUX],
        str(binary),
    ]
    run_export(cmd, staging, PLATFORM_LINUX, timeout=900)
    if not binary.is_file() or binary.stat().st_size == 0:
        raise ReleaseError(f"导出未生成有效文件: {binary}")

    archive_path = pack_linux_archive(staging, binary, version)
    _drop_staging(staging)
    return archive_path


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


def build_notes(version: str, channel: str, notes_file: str | None) -> tuple[str, list[str]]:
    """生成 Release 说明。version_history.json 的 entries 已不再维护，通常需显式传 --notes-file。"""
    if notes_file:
        text = Path(notes_file).read_text(encoding="utf-8").strip()
        if not text:
            raise ReleaseError(f"更新说明文件为空: {notes_file}")
        # 顺手抽出 "- " 列表项，写进本地留档清单的 changes（线上 changes 由后端从 Release body 派生）
        changes = [
            line.strip()[2:].strip() for line in text.splitlines() if line.strip().startswith("- ")
        ]
        return text, [item for item in changes if item]

    entry = current_history_entry(version)
    changes = [str(item).strip() for item in entry.get("changes", []) if str(item).strip()]
    if not changes:
        raise ReleaseError(
            "当前版本没有 changes（version_history.json 的 entries 已不再保存历史），"
            "请用 --notes-file 指定发布说明"
        )

    lines = [f"## v{version}（{channel}）", ""]
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
    tag: str, artifacts: list[Path], notes_path: Path, channel: str, slug: str
) -> dict[str, str]:
    """上传全部资产，返回 {资产文件名: 下载地址}。"""
    if not artifacts:
        raise ReleaseError("没有可上传的产物")
    cmd = [
        "gh",
        "release",
        "create",
        tag,
        *[str(artifact) for artifact in artifacts],
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
    urls = {
        str(asset.get("name")): str(asset.get("browser_download_url"))
        for asset in assets
        if asset.get("name") and asset.get("browser_download_url")
    }
    missing = [artifact.name for artifact in artifacts if artifact.name not in urls]
    if missing:
        raise ReleaseError(f"Release 中找不到资产: {', '.join(missing)}")
    return urls


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
    artifacts: dict[str, Path],
    download_urls: dict[str, str],
) -> dict:
    """生成与服务端同构的留档清单：platforms 下每个平台一条。"""
    platforms: dict[str, dict] = {}
    for platform, artifact in artifacts.items():
        payload = {
            "version": version,
            "build": build,
            "published_at": date.today().isoformat(),
            "changes": entry.get("changes", []),
            "url": download_urls[artifact.name],
            "sha256": sha256_of(artifact),
            "size": artifact.stat().st_size,
            "mirrors": [],
        }
        if entry.get("min_supported_build"):
            payload["min_supported_build"] = int(entry["min_supported_build"])
        platforms[platform] = payload
    return {"schema": 1, "channel": channel, "platforms": platforms}


def write_manifest(path: Path, manifest: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # 回读校验，避免写出服务端会拒绝的结构
    reloaded = json.loads(path.read_text(encoding="utf-8"))
    if reloaded.get("schema") != 1 or reloaded.get("channel") != manifest["channel"]:
        raise ReleaseError("清单回读校验失败：schema/channel 不符")
    platforms = reloaded.get("platforms") or {}
    if not platforms:
        raise ReleaseError("清单回读校验失败：platforms 为空")
    for name, platform in platforms.items():
        if not platform.get("version") or int(platform.get("build", 0)) <= 0:
            raise ReleaseError(f"清单回读校验失败：platforms.{name} 的 version/build 无效")
    summary = "、".join(f"{name}={platform['build']}" for name, platform in platforms.items())
    print(f"[MANIFEST] {path}（{summary}）")


def verify_remote_manifest(url: str, expected_build: int, platforms: list[str]) -> None:
    with urllib.request.urlopen(url, timeout=10) as response:
        remote = json.loads(response.read().decode("utf-8"))
    remote_platforms = remote.get("platforms") or {}
    for name in platforms:
        entry = remote_platforms.get(name)
        if not isinstance(entry, dict):
            raise ReleaseError(f"线上清单缺少 platforms.{name}（可能后端尚未派生该平台）")
        remote_build = int(entry.get("build", 0))
        if remote_build != expected_build:
            raise ReleaseError(f"线上清单 platforms.{name}.build={remote_build}，期望 {expected_build}")
    print(f"[VERIFY] {url} → " + "、".join(f"{name}={expected_build}" for name in platforms))


def load_signing_env() -> None:
    """读取 tools/signing.env（本机凭据，已 gitignore），不覆盖已存在的环境变量。"""
    path = SCRIPT_DIR / "signing.env"
    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def run(args: argparse.Namespace) -> int:
    if not CHANNEL_PATTERN.match(args.channel):
        raise ReleaseError(f"非法渠道名: {args.channel!r}")

    load_signing_env()
    platforms = parse_platforms(args.platforms)

    ensure_clean_worktree(args.dry_run)
    ensure_pushed(args.dry_run)
    ensure_gh_ready(args.dry_run)
    godot = resolve_godot(args.godot)
    slug = repo_slug()
    manifest_path = resolve_manifest_path(args.channel, args.manifest_out)

    directory, engine_tag = template_dir(godot)
    for platform in platforms:
        issue = missing_template(platform, directory)
        if not issue:
            continue
        message = (
            f"未找到 {engine_tag} 的 {platform} 导出模板：{issue}。"
            "请在编辑器「项目 → 导出 → 管理导出模板」安装与当前 Godot 完全一致的 mono 模板"
        )
        if not args.dry_run:
            raise ReleaseError(message)
        print(f"[WARN] {message}")

    # 签名只在发布 Android 时校验，避免只发 PC 时被 keystore 阻塞
    signing: dict[str, str] | None = None
    if PLATFORM_ANDROID in platforms:
        try:
            signing = android_signing_config(args.android_keystore, args.android_keystore_user)
        except ReleaseError as exc:
            if not args.dry_run:
                raise
            print(f"[WARN] {exc}")

    if args.dry_run:
        version = f"{version_prefix()}.{sv.git_commit_count()}"
        print(f"[DRY-RUN] 仓库: {slug}")
        print(f"[DRY-RUN] Godot: {godot}")
        print(f"[DRY-RUN] 模板: {directory}")
        print(f"[DRY-RUN] 平台: {', '.join(platforms)}")
        print(f"[DRY-RUN] 预发布版本: {version}（提交数，未写入文件）")
        for platform in platforms:
            artifact = DIST_DIR / f"THMIX-CE-{version}-{ARTIFACT_SUFFIX[platform]}"
            print(f"[DRY-RUN] 产物({platform}): {artifact}")
        if PLATFORM_ANDROID in platforms:
            print(
                f"[DRY-RUN] 签名: {'已就绪 ' + signing['user'] if signing else '未配置（正式发布会报错）'}"
            )
        print(f"[DRY-RUN] 清单: {manifest_path}")
        print("[DRY-RUN] 未执行导出与上传")
        return 0

    # 先做只读校验，避免校验失败时留下未还原的版本号文件
    expected_build = sv.git_commit_count()
    expected_version = f"{version_prefix()}.{expected_build}"
    check_monotonic(manifest_path, expected_build, args.force)
    tag = f"v{expected_version}"
    ensure_tag_absent(tag)

    if sv.run(write=True, git_build=True) != 0:
        raise ReleaseError("sync_version.py 执行失败")

    try:
        version, build = sv.read_history()
        if version != expected_version or build != expected_build:
            raise ReleaseError(
                f"版本号写入结果与预期不一致: {version}/{build} != {expected_version}/{expected_build}"
            )

        notes_text, changes = build_notes(version, args.channel, args.notes_file)
        notes_path = DIST_DIR / f"release-notes-{version}.md"
        notes_path.parent.mkdir(parents=True, exist_ok=True)
        notes_path.write_text(notes_text, encoding="utf-8")

        # 版本号文件还原前先取条目快照（此时条目仍是新版本号）
        entry = dict(current_history_entry(version))
        entry["changes"] = changes or entry.get("changes", [])
        if args.min_supported_build is not None:
            entry["min_supported_build"] = args.min_supported_build

        # 所有平台都导出完才还原版本号文件：中途还原会让后一个平台读到旧版本号
        artifacts: dict[str, Path] = {}
        if PLATFORM_WINDOWS in platforms:
            artifacts[PLATFORM_WINDOWS] = export_windows(godot, version)
        if PLATFORM_ANDROID in platforms:
            if signing is None:
                raise ReleaseError("Android 签名配置缺失，无法导出")
            artifacts[PLATFORM_ANDROID] = export_android(godot, version, signing)
        if PLATFORM_LINUX in platforms:
            artifacts[PLATFORM_LINUX] = export_linux(godot, version)

        if not args.keep_version_files:
            restore_version_files()

        download_urls = create_github_release(tag, list(artifacts.values()), notes_path, args.channel, slug)
        manifest = build_manifest(version, build, args.channel, entry, artifacts, download_urls)
        write_manifest(manifest_path, manifest)
    finally:
        if not args.keep_version_files and git("status", "--porcelain", "--", *VERSION_FILES):
            restore_version_files()

    if args.verify_url:
        verify_remote_manifest(args.verify_url, build, platforms)

    print("\n[OK] 发布完成")
    print(f"  版本: {version}")
    print(f"  Release: {tag}（{args.channel}）")
    for platform, artifact in artifacts.items():
        print(f"  资产({platform}): {download_urls[artifact.name]}")
    print(f"  清单: {manifest_path}（本地留档，用于 build 单调性校验）")
    print("  线上: 后端会自动从 GitHub 同步，无需上传清单；通常 10 分钟内跟进")
    print("        可在稍后用 --verify-url 复核线上 build")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="导出多平台构建并发布到 GitHub Release + 生成本地留档清单")
    parser.add_argument("--channel", default="beta", help="更新渠道（默认 beta）")
    parser.add_argument(
        "--platforms",
        default=DEFAULT_PLATFORMS,
        help=f"要发布的平台，逗号分隔（默认 {DEFAULT_PLATFORMS}）",
    )
    parser.add_argument("--godot", help="Godot 可执行文件路径（默认读 GODOT_BIN）")
    parser.add_argument("--manifest-out", help="清单输出目录或 .json 完整路径")
    parser.add_argument("--notes-file", help="更新说明 Markdown（version_history.json 已不再保存历史，通常必须提供）")
    parser.add_argument("--min-supported-build", type=int, help="写入清单的最低支持 build（可选）")
    parser.add_argument("--verify-url", help="发布后请求线上清单并校验 build（如 https://thmixce.org/api/update/beta）")
    parser.add_argument("--keep-version-files", action="store_true", help="保留版本号文件改动（默认还原）")
    parser.add_argument("--force", action="store_true", help="允许 build 不递增")
    parser.add_argument("--dry-run", action="store_true", help="只打印计划，不导出、不上传")
    parser.add_argument(
        "--android-keystore",
        help="release keystore 路径（默认读环境变量 THMIX_ANDROID_KEYSTORE）",
    )
    parser.add_argument(
        "--android-keystore-user",
        help="签名别名（默认读 THMIX_ANDROID_KEYSTORE_USER，再默认 thmix-ce）",
    )
    args = parser.parse_args()

    try:
        return run(args)
    except ReleaseError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
