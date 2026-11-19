#!/usr/bin/env python3
"""校验导出产物的结构完整性。

只读产物、不启动游戏，专门拦住那些「能打出来、能上传、玩家一打开就废」的问题：

  - Windows/Linux 缺 `data_<项目名>_<平台>_<架构>/` 程序集目录 → 报 .NET assemblies not found
  - pck 里没有谱面 / 音色库 / 主题配置 → include_filter 漏配，游戏能起但没内容
  - miniaudio 原生库没随包 → 不崩，但 MIDI 全程静音
  - Linux 主程序或 .so 丢了可执行位 → 解包后跑不起来

用法：
  python tools/check_export.py --platform linux --version 1.0.0.770
  python tools/check_export.py --platform windows --version 1.0.0.770 --artifacts-dir dist
"""

from __future__ import annotations

import argparse
import sys
import tarfile
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DIST_DIR = REPO_ROOT / "dist"

ARTIFACT_SUFFIX = {
    "windows": "win64.zip",
    "android": "arm64.apk",
    "linux": "linux-x86_64.tar.gz",
}
## pck 里必须出现的资源（任意一条缺失都说明导出过滤条件漏了）
PCK_MARKERS = [
    (b"song.mid", "谱面 MIDI"),
    (b".sf2", "音色库"),
    (b"theme.ini", "主题配置"),
]
## 程序集目录里必须存在的文件（缺了运行时就起不来）
ASSEMBLY_MARKERS = {
    "windows": ["GodotSharp.dll", "hostfxr.dll"],
    "linux": ["GodotSharp.dll", "libcoreclr.so"],
}
NATIVE_LIB = {
    "windows": "addons/miniaudio/libs/windows/miniaudio_bridge.dll",
    "linux": "addons/miniaudio/libs/linux/libminiaudio_bridge.so",
}


def _check_pck(errors: list[str], platform: str, data: bytes) -> None:
    for marker, label in PCK_MARKERS:
        if marker not in data:
            errors.append(f"{platform}: pck 内缺少{label}（{marker.decode()}），导出过滤条件可能漏配")


def _assembly_dir(names: list[str], platform: str) -> str | None:
    suffix = "_windows_x86_64" if platform == "windows" else "_linuxbsd_x86_64"
    for name in names:
        head = name.split("/", 1)[0]
        if head.startswith("data_") and head.endswith(suffix):
            return head
    return None


def check_windows(path: Path, version: str, errors: list[str]) -> list[str]:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        exe = f"THMIX-CE-{version}-win64.exe"
        if exe not in names:
            errors.append(f"windows: 缺少主程序 {exe}")

        pcks = [n for n in names if n.endswith(".pck") and "/" not in n]
        if len(pcks) != 1:
            errors.append(f"windows: 顶层应恰有一个 .pck，实际 {len(pcks)} 个")
        else:
            _check_pck(errors, "windows", archive.read(pcks[0]))

        directory = _assembly_dir(names, "windows")
        if directory is None:
            errors.append(
                "windows: 缺少 .NET 程序集目录 data_*_windows_x86_64/"
                "（运行时必然报 .NET assemblies not found）"
            )
        else:
            inner = {n.rsplit("/", 1)[-1] for n in names if n.startswith(directory + "/")}
            for marker in ASSEMBLY_MARKERS["windows"]:
                if marker not in inner:
                    errors.append(f"windows: {directory}/ 里缺 {marker}")

        if NATIVE_LIB["windows"] not in names:
            errors.append(f"windows: 缺少原生库 {NATIVE_LIB['windows']}（MIDI 会静音）")
    return names


def check_linux(path: Path, version: str, errors: list[str]) -> list[str]:
    with tarfile.open(path) as archive:
        members = {m.name: m for m in archive.getmembers()}
        names = list(members)

        binary = f"THMIX-CE-{version}-linux-x86_64"
        member = members.get(binary)
        if member is None:
            errors.append(f"linux: 缺少主程序 {binary}")
        elif not member.mode & 0o111:
            errors.append(f"linux: 主程序没有可执行位（mode={oct(member.mode)}）")

        pcks = [n for n in names if n.endswith(".pck") and "/" not in n]
        if len(pcks) != 1:
            errors.append(f"linux: 顶层应恰有一个 .pck，实际 {len(pcks)} 个")
        else:
            handle = archive.extractfile(pcks[0])
            _check_pck(errors, "linux", handle.read() if handle else b"")

        directory = _assembly_dir(names, "linux")
        if directory is None:
            errors.append(
                "linux: 缺少 .NET 程序集目录 data_*_linuxbsd_x86_64/"
                "（mono 导出不内嵌程序集，缺了跑不起来）"
            )
        else:
            inner = {n.rsplit("/", 1)[-1] for n in names if n.startswith(directory + "/")}
            for marker in ASSEMBLY_MARKERS["linux"]:
                if marker not in inner:
                    errors.append(f"linux: {directory}/ 里缺 {marker}")

        native = members.get(NATIVE_LIB["linux"])
        if native is None:
            errors.append(f"linux: 缺少原生库 {NATIVE_LIB['linux']}（MIDI 会静音）")
        elif not native.mode & 0o111:
            errors.append(f"linux: {NATIVE_LIB['linux']} 没有可执行位（dlopen 会失败）")
    return names


def check_android(path: Path, version: str, errors: list[str]) -> list[str]:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if "AndroidManifest.xml" not in names:
            errors.append("android: 缺少 AndroidManifest.xml")

        for lib in ("lib/arm64-v8a/libgodot_android.so", "lib/arm64-v8a/libminiaudio_bridge.so"):
            if lib not in names:
                errors.append(f"android: 缺少 {lib}" + ("（MIDI 会静音）" if "miniaudio" in lib else ""))

        # 程序集在 assets/.godot/mono/publish/<abi>/ 下
        if not any(
            n.startswith("assets/.godot/mono/publish/") and n.endswith("GodotSharp.dll")
            for n in names
        ):
            errors.append("android: assets/.godot/mono/publish/ 下找不到 GodotSharp.dll")

        # Gradle 构建（预设 use_gradle_build=true）把 res:// 直接铺进 assets/，没有 pck；
        # 非 Gradle 模板导出才有 pck。两种布局都要能校验。
        pcks = [n for n in names if n.endswith(".pck")]
        if pcks:
            _check_pck(errors, "android", archive.read(pcks[0]))
        else:
            if "assets/Resources/Config/theme.ini" not in names:
                errors.append("android: assets/Resources/Config/theme.ini 缺失（主题配置没导出）")
            if not any(n.startswith("assets/Resources/Soundfont/") and n.endswith(".sf2") for n in names):
                errors.append("android: assets/Resources/Soundfont/ 下没有 .sf2（音色库没导出）")
            if not any(n.startswith("assets/Resources/Charts/") and n.endswith("song.mid") for n in names):
                errors.append("android: assets/Resources/Charts/ 下没有 song.mid（谱面没导出）")
    return names


CHECKERS = {
    "windows": check_windows,
    "linux": check_linux,
    "android": check_android,
}


def main() -> int:
    parser = argparse.ArgumentParser(description="校验导出产物结构")
    parser.add_argument("--platform", required=True, choices=sorted(CHECKERS))
    parser.add_argument("--version", required=True, help="完整版本号，如 1.0.0.770")
    parser.add_argument("--artifacts-dir", default=str(DIST_DIR), help="产物所在目录（默认 dist/）")
    args = parser.parse_args()

    artifact = Path(args.artifacts_dir) / f"THMIX-CE-{args.version}-{ARTIFACT_SUFFIX[args.platform]}"
    if not artifact.is_file():
        print(f"[FAIL] {args.platform}: 产物不存在 {artifact}", file=sys.stderr)
        return 1

    errors: list[str] = []
    try:
        names = CHECKERS[args.platform](artifact, args.version, errors)
    except (OSError, zipfile.BadZipFile, tarfile.TarError) as exc:
        print(f"[FAIL] {args.platform}: 无法读取 {artifact.name}: {exc}", file=sys.stderr)
        return 1

    if errors:
        for message in errors:
            print(f"[FAIL] {message}", file=sys.stderr)
        return 1

    print(f"[OK] {args.platform}: {artifact.name}（{artifact.stat().st_size:,} 字节，{len(names)} 个条目）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
