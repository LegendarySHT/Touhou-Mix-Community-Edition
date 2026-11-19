#!/usr/bin/env python3
"""预热 Godot 导入缓存，并在导入真正完成后结束进程。

为什么需要这个：
  本工程的 headless 编辑器在完成导入（或导出）后会卡在关闭阶段，日志停在
  `EditorSettings not instantiated yet when getting setting "export/android/shutdown_adb_on_exit"`
  再也不退出。直接把它当普通命令跑，CI 只能等 step 超时，白烧几十分钟。

做法：
  盯输出，等编辑器布局加载完成（或出现上面那句关闭期日志）就主动结束，
  既不误杀进行中的导入，也不干等。

用法：
  python tools/godot_prepare.py --godot <path/to/godot>
  python tools/godot_prepare.py --godot <path> --timeout-seconds 7200
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import threading
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

## 出现任意一条即表示导入已完成、进入关闭阶段（Godot 不会自己退出）
DONE_MARKERS = (
    "[ DONE ] loading_editor_layout",
    "EditorSettings not instantiated",
)


def _terminate(proc: subprocess.Popen[str]) -> None:
    if proc.poll() is not None:
        return
    if sys.platform.startswith("win"):
        # 控制台包装进程可能还挂着真正的引擎进程，按进程树杀
        subprocess.run(
            ["taskkill", "/F", "/T", "/PID", str(proc.pid)],
            capture_output=True,
            check=False,
        )
    else:
        proc.terminate()
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()


def main() -> int:
    parser = argparse.ArgumentParser(description="预热 Godot 导入缓存")
    parser.add_argument("--godot", required=True, help="Godot 可执行文件路径")
    parser.add_argument("--path", default=REPO_ROOT, help="项目目录（默认仓库根）")
    parser.add_argument("--timeout-seconds", type=int, default=3600, help="整体超时（默认 3600s）")
    args = parser.parse_args()

    cmd = [args.godot, "--headless", "--path", args.path, "--import"]
    print("[PREPARE] " + " ".join(cmd), flush=True)

    started = time.monotonic()
    proc = subprocess.Popen(
        cmd,
        cwd=args.path,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    assert proc.stdout is not None

    finished = threading.Event()
    timed_out = threading.Event()

    def watchdog() -> None:
        if not finished.wait(args.timeout_seconds):
            timed_out.set()
            print(f"[PREPARE] 超时 {args.timeout_seconds}s，结束引擎进程", file=sys.stderr, flush=True)
            _terminate(proc)

    threading.Thread(target=watchdog, daemon=True).start()

    matched = False
    try:
        for line in proc.stdout:
            sys.stdout.write(line)
            if any(marker in line for marker in DONE_MARKERS):
                matched = True
                _terminate(proc)
                break
    finally:
        finished.set()

    elapsed = time.monotonic() - started
    if timed_out.is_set():
        return 1
    if proc.poll() is None:
        _terminate(proc)
    code = proc.returncode or 0
    proc.stdout.close()

    if matched:
        print(f"[PREPARE] 导入完成（{elapsed:.0f}s），已结束引擎进程")
        return 0
    if code != 0:
        print(f"[PREPARE] Godot 退出码 {code}（{elapsed:.0f}s）", file=sys.stderr)
        return code
    print(f"[PREPARE] Godot 自行退出（{elapsed:.0f}s）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
