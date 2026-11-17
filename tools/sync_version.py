#!/usr/bin/env python3
"""版本号单一来源同步脚本。

唯一事实来源是 Resources/Config/version_history.json：
  - current      → 展示用版本号（如 1.0.0.645），末段即构建号
  - entries      → 已不再维护（版本历史改由服务端从 GitHub Releases 派生）；
                   为空时构建号直接取 current 的第 4 段，若仍有条目则优先取条目里的 build

本脚本把版本号写入（或校验）以下派生位置，避免手工改漏：
  - project.godot                 application/config/version
  - export_presets.cfg            version/code（Android versionCode）、version/name（Android versionName）
  - export_presets.cfg            application/file_version / application/product_version（Windows 资源版本）

用法：
  python tools/sync_version.py --check    只校验，不一致时退出码 1（发布前必跑）
  python tools/sync_version.py --write    写入全部派生位置

  # 构建号 = 当前分支提交总数（发布前、所有改动已提交后执行）
  python tools/sync_version.py --write --git-build
  python tools/sync_version.py --check --git-build

--git-build 说明：
  取 `git rev-list --count HEAD` 作为 build（即 version 最后一段），
  并把结果回写 version_history.json 后再同步其余派生位置。
  不要在提交前运行（此时提交数还不包含本次提交，构建号会小 1）；
  正确时机是发布构建前、工作区已提交后。

退出码：0 一致/已写入；1 校验失败或文件缺失；2 参数错误。
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HISTORY_PATH = REPO_ROOT / "Resources" / "Config" / "version_history.json"
PROJECT_GODOT_PATH = REPO_ROOT / "project.godot"
EXPORT_PRESETS_PATH = REPO_ROOT / "export_presets.cfg"

VERSION_PATTERN = re.compile(r"^\d+(\.\d+){1,3}$")


class SyncError(RuntimeError):
    pass


def read_history() -> tuple[str, int]:
    """从 version_history.json 读取 (version, build)。"""
    if not HISTORY_PATH.is_file():
        raise SyncError(f"找不到版本历史文件: {HISTORY_PATH}")

    try:
        data = json.loads(HISTORY_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SyncError(f"解析版本历史失败: {exc}") from exc

    version = str(data.get("current", "")).strip()
    if not VERSION_PATTERN.match(version):
        raise SyncError(f"current 不是合法版本号（1~4 段数字）: {version!r}")

    entries = data.get("entries") or []
    if not isinstance(entries, list):
        raise SyncError("entries 必须是数组")

    build = None
    for entry in entries:
        if isinstance(entry, dict) and str(entry.get("version", "")).strip() == version:
            build = entry.get("build")
            break
    if build is None and entries and isinstance(entries[0], dict):
        build = entries[0].get("build")
    if build is None:
        # 历史条目已不再维护（entries 为空），构建号就是版本号第 4 段
        parts = version.split(".")
        if len(parts) == 4 and parts[3].isdigit():
            build = int(parts[3])
    if build is None:
        raise SyncError(
            f"版本 {version} 取不到构建号：entries 为空时版本号必须是 4 段（如 1.0.0.645）"
        )
    try:
        build_int = int(build)
    except (TypeError, ValueError) as exc:
        raise SyncError(f"build 必须是整数: {build!r}") from exc
    if build_int <= 0:
        raise SyncError(f"build 必须为正整数（Android versionCode 要求）: {build_int}")

    return version, build_int


def git_commit_count() -> int:
    """当前分支的提交总数（HEAD 可达的全部提交，含合并提交）。"""
    try:
        output = subprocess.check_output(
            ["git", "rev-list", "--count", "HEAD"],
            cwd=REPO_ROOT,
            text=True,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        raise SyncError("找不到 git 命令，无法使用 --git-build") from exc
    except subprocess.CalledProcessError as exc:
        raise SyncError(f"读取 git 提交数失败: {exc.stderr.strip()}") from exc

    try:
        count = int(output.strip())
    except ValueError as exc:
        raise SyncError(f"git 提交数不是整数: {output!r}") from exc
    if count <= 0:
        raise SyncError(f"git 提交数必须为正整数: {count}")
    return count


def rewrite_history_build(version: str, count: int) -> str:
    """把 build 写入 version_history.json（current 与对应条目的最后一段）。

    返回写入后的新版本号。要求原版本号为 4 段，前 3 段保持不变。
    """
    parts = version.split(".")
    if len(parts) != 4:
        raise SyncError(f"--git-build 需要 4 段版本号（如 1.0.0.645），当前为 {version!r}")

    new_version = ".".join(parts[:3] + [str(count)])
    try:
        data = json.loads(HISTORY_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SyncError(f"解析版本历史失败: {exc}") from exc

    data["current"] = new_version
    entries = data.get("entries") or []
    for entry in entries:
        if isinstance(entry, dict) and str(entry.get("version", "")).strip() == version:
            entry["version"] = new_version
            entry["build"] = count
    # entries 为空是当前默认状态（版本历史改由服务端从 GitHub Releases 派生），
    # 构建号只体现在 current 的末段，无需回写条目。
    data["entries"] = entries

    HISTORY_PATH.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"[GIT] build {count} 已写入 {HISTORY_PATH.name} → {new_version}")
    return new_version


def windows_version(version: str) -> str:
    """Windows 资源版本必须是 4 段数字，不足补 0。"""
    parts = version.split(".")
    parts += ["0"] * (4 - len(parts))
    return ".".join(parts[:4])


def replace_setting(text: str, key: str, new_value: str) -> tuple[str, int]:
    """按 `key = value` 形式整行替换，保留缩进；返回 (新文本, 命中次数)。"""
    pattern = re.compile(rf"^(\s*{re.escape(key)}\s*=\s*)(.*)$", re.MULTILINE)
    return pattern.subn(lambda m: m.group(1) + new_value, text)


def collect_targets(version: str, build: int) -> list[tuple[Path, list[tuple[str, str]]]]:
    """返回 [(文件路径, [(键名, 期望值), ...]), ...]；期望值已带引号/为原始整数。"""
    quoted = f'"{version}"'
    win_quoted = f'"{windows_version(version)}"'
    return [
        (PROJECT_GODOT_PATH, [("config/version", quoted)]),
        (
            EXPORT_PRESETS_PATH,
            [
                ("version/code", str(build)),
                ("version/name", quoted),
                ("application/file_version", win_quoted),
                ("application/product_version", win_quoted),
            ],
        ),
    ]


def run(write: bool, git_build: bool = False) -> int:
    try:
        version, build = read_history()
        if git_build:
            count = git_commit_count()
            if count != build:
                if not write:
                    print(
                        f"[MISMATCH] version_history.json build={build}，git 提交数={count}",
                        file=sys.stderr,
                    )
                    print("运行 python tools/sync_version.py --write --git-build 同步", file=sys.stderr)
                    return 1
                rewrite_history_build(version, count)
                version, build = read_history()
    except SyncError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    print(f"版本来源: {HISTORY_PATH.relative_to(REPO_ROOT)} → version={version}, build={build}")

    mismatches: list[str] = []
    changes: list[tuple[Path, str, str, str]] = []

    for path, settings in collect_targets(version, build):
        if not path.is_file():
            print(f"[ERROR] 找不到文件: {path}", file=sys.stderr)
            return 1
        original = path.read_text(encoding="utf-8")
        updated = original
        for key, expected in settings:
            updated, count = replace_setting(updated, key, expected)
            if count == 0:
                print(f"[ERROR] {path.name} 中找不到键 {key}", file=sys.stderr)
                return 1
            current_match = re.search(
                rf"^\s*{re.escape(key)}\s*=\s*(.*)$", original, re.MULTILINE
            )
            current = current_match.group(1).strip() if current_match else ""
            if current != expected:
                mismatches.append(f"{path.name}: {key} = {current} → 期望 {expected}")
                changes.append((path, key, current, expected))
        if write and updated != original:
            path.write_text(updated, encoding="utf-8")

    if not mismatches:
        print("[OK] 版本号派生位置全部一致")
        return 0

    if write:
        print(f"[OK] 已写入 {len(changes)} 处版本号：")
        for path, key, old, new in changes:
            print(f"  - {path.name}: {key} {old} → {new}")
        return 0

    print("[MISMATCH] 版本号派生位置与 version_history.json 不一致：", file=sys.stderr)
    for item in mismatches:
        print(f"  - {item}", file=sys.stderr)
    print("运行 python tools/sync_version.py --write 修复", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="同步 version_history.json 的版本号到工程文件")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--check", action="store_true", help="只校验（默认行为）")
    group.add_argument("--write", action="store_true", help="写入派生位置")
    parser.add_argument(
        "--git-build",
        action="store_true",
        help="build 取当前分支提交总数（git rev-list --count HEAD）",
    )
    args = parser.parse_args()
    return run(write=args.write, git_build=args.git_build)


if __name__ == "__main__":
    sys.exit(main())
