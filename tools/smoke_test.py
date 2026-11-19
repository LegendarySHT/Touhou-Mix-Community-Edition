#!/usr/bin/env python3
"""把导出的包解到空目录跑一次 headless，确认它真的能起来。

为什么需要这个：
  结构自检只能证明「文件在」，证明不了「能启动」。历史上两个坑都躲过了结构检查：
    - 桌面端漏打包 data_*（.NET 程序集）目录，exe 一开就报 assemblies not found，
      而 Godot 只往 stdout 打一行 ERROR、退出码仍是 0；
    - include_filter 空着导致 pck 里没有谱面 / 音色库 / 配置，界面能进但一玩就空。
  所以必须解包到空目录、实际跑，并从日志里认三个标记。

用法：
  python tools/smoke_test.py --artifact dist/THMIX-CE-1.0.0.765-linux-x86_64.tar.gz
  python tools/smoke_test.py --artifact dist/THMIX-CE-1.0.0.765-win64.zip --timeout 150
"""

from __future__ import annotations

import argparse
import os
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile
from pathlib import Path

## 必须出现的关键行：配置来自 pck、数据加载完成。
## 不用 [ChartDB] opened —— 只在首次建库时打，走缓存就不会出现。
REQUIRED_MARKERS = (
    "Config loaded from PCK",
    "MIDI data loaded successfully",
)
## 出现才算正常，缺了通常是原生库没进包；只告警，避免无声卡环境误判
OPTIONAL_MARKERS = (
    "[MiniaudioNative] Loaded native library",
    "[ChartDB] opened",
)


def pick_binary(root: Path) -> Path:
    """在解包目录里找主程序。"""
    candidates: list[Path] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        name = path.name
        if name.endswith("-win64.exe") and "console" not in name:
            candidates.append(path)
        elif name.endswith("-linux-x86_64"):
            candidates.append(path)
    if not candidates:
        raise SystemExit(f"解包目录里找不到主程序：{root}")
    # 深度浅的优先（真主程序在包根，别挑到 data_* 里的辅助程序）
    candidates.sort(key=lambda p: (len(p.relative_to(root).parts), str(p)))
    return candidates[0]


def unpack(artifact: Path, dest: Path) -> None:
    if zipfile.is_zipfile(artifact):
        with zipfile.ZipFile(artifact) as archive:
            archive.extractall(dest)
        return
    if tarfile.is_tarfile(artifact):
        with tarfile.open(artifact) as archive:
            archive.extractall(dest)
        return
    raise SystemExit(f"既不是 zip 也不是 tar：{artifact}")


def kill_tree(proc: subprocess.Popen[bytes]) -> None:
    if proc.poll() is not None:
        return
    if sys.platform.startswith("win"):
        subprocess.run(
            ["taskkill", "/F", "/T", "/PID", str(proc.pid)], capture_output=True, check=False
        )
    else:
        proc.terminate()
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)


def run_headless(
    binary: Path, timeout: int, extra: list[str], wrap: list[str], headed: bool
) -> tuple[str, int]:
    binary.chmod(binary.stat().st_mode | 0o755)
    # 输出走临时文件而不是管道：communicate() 超时后管道会被内部关闭，
    # 再去 read() 就是 "read of closed file"，而恰恰超时（游戏不退出）才是常态。
    fd, name = tempfile.mkstemp(prefix="thmix-smoke-", suffix=".log")
    os.close(fd)
    log_path = Path(name)
    # headed 时不加 --headless，配合 xvfb 走玩家的真实启动路径：
    # Godot 在 headless 下 DisplayServer 为空，某些渲染/主题代码会段错误，
    # 这种崩溃只存在于无头环境，不该拿来判定「包坏了」。
    cmd = wrap + [str(binary)] + ([] if headed else ["--headless"]) + extra
    print("[SMOKE] 命令：" + " ".join(cmd))
    started = time.monotonic()
    with open(log_path, "wb") as log_file:
        proc = subprocess.Popen(
            cmd,
            cwd=binary.parent,
            stdout=log_file,
            stderr=subprocess.STDOUT,
        )
        try:
            code = proc.wait(timeout=timeout) or 0
        except subprocess.TimeoutExpired:
            kill_tree(proc)
            code = -1
    elapsed = time.monotonic() - started
    text = log_path.read_text(encoding="utf-8", errors="replace")
    log_path.unlink(missing_ok=True)
    print(f"[SMOKE] 运行 {elapsed:.0f}s，退出码 {code}，日志 {len(text.splitlines())} 行")
    return text, code


def gdb_backtrace(binary: Path, timeout: int = 180) -> None:
    """段错误只留一个 -11，没有栈就无从下手；有 gdb 时补一份。"""
    if sys.platform != "linux" or shutil.which("gdb") is None:
        return
    print("[SMOKE] 崩溃退出，尝试用 gdb 抓调用栈：")
    try:
        result = subprocess.run(
            ["gdb", "-batch", "-ex", "run", "-ex", "bt 25", "--args", str(binary), "--headless"],
            cwd=binary.parent,
            capture_output=True,
            timeout=timeout,
        )
        print((result.stdout + result.stderr).decode("utf-8", errors="replace"))
    except subprocess.TimeoutExpired:
        print("[SMOKE] gdb 超时", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description="解包并 headless 启动自检")
    parser.add_argument("--artifact", required=True, help="dist/ 下的 zip 或 tar.gz")
    parser.add_argument("--timeout", type=int, default=120, help="启动观察上限（默认 120s）")
    parser.add_argument("--keep", action="store_true", help="保留解包目录便于排查")
    parser.add_argument(
        "--extra-args",
        default="",
        help="追加给程序的参数，如 '--audio-driver Dummy'（CI 无声卡时避开音频设备）",
    )
    parser.add_argument(
        "--wrap",
        default="",
        help="包装命令，如 'dbus-run-session --'（CI 无 session bus 时给 MPRIS 一个）",
    )
    parser.add_argument(
        "--headed",
        action="store_true",
        help="不加 --headless，配合 xvfb 走真实窗口启动路径",
    )
    args = parser.parse_args()

    artifact = Path(args.artifact).resolve()
    if not artifact.is_file():
        print(f"[SMOKE] 找不到产物：{artifact}", file=sys.stderr)
        return 1

    workdir = Path(tempfile.mkdtemp(prefix="thmix-smoke-"))
    try:
        unpack(artifact, workdir)
        binary = pick_binary(workdir)
        print(f"[SMOKE] 主程序：{binary.relative_to(workdir)}")
        text, code = run_headless(
            binary, args.timeout, shlex.split(args.extra_args), shlex.split(args.wrap), args.headed
        )

        missing = [m for m in REQUIRED_MARKERS if m not in text]
        absent = [m for m in OPTIONAL_MARKERS if m not in text]
        if missing:
            print("[SMOKE] 缺少关键日志：" + "、".join(missing))
            # headed 那一轮不抓栈：同一次崩溃抓两遍太慢，留给最后一次判定
            if code != 0 and not args.headed:
                gdb_backtrace(binary)
            print("\n".join(text.splitlines()[-60:]))
            return 1
        for marker in absent:
            print(f"[SMOKE] 警告：未看到 {marker!r}")
        print("[SMOKE] 通过：" + "、".join(REQUIRED_MARKERS))
        return 0
    finally:
        if args.keep:
            print(f"[SMOKE] 解包目录保留在 {workdir}")
        else:
            # ignore_errors：包里有几百个文件，批量删除会撞环境的删除守卫
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
