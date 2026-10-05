#!/usr/bin/env python3
"""Supervise the project-owned fixture and bound integration test duration."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
marker = ROOT / ".runtime/integration/fixture.json"
marker.parent.mkdir(parents=True, exist_ok=True)
marker.unlink(missing_ok=True)
with (ROOT / ".runtime/logs/fixture.log").open("w") as fixture_log:
    fixture = subprocess.Popen(
        [sys.executable, "Scripts/ssh_fixture.py"], cwd=ROOT,
        stdout=fixture_log, stderr=subprocess.STDOUT,
    )
    try:
        deadline = time.monotonic() + 10
        while not marker.exists():
            if fixture.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("本地 SSH fixture 启动失败，请查看 .runtime/logs/fixture.log")
            time.sleep(0.1)
        data = json.loads(marker.read_text())
        print("本地隔离测试端口：" + ", ".join(map(str, data["ports"])), flush=True)
        result = subprocess.run(
            [str(ROOT / ".build/debug/BozhouCoreTests"), "--integration"],
            cwd=ROOT, timeout=120, capture_output=True, text=True,
            env={**os.environ, "SHELL": "/bin/bash"},
        )
        text = result.stdout + result.stderr
        (ROOT / ".runtime/logs/all-tests.log").write_text(text)
        print(text, end="")
        sys.exit(result.returncode)
    finally:
        fixture.terminate()
        try:
            fixture.wait(timeout=5)
        except subprocess.TimeoutExpired:
            fixture.kill()
            fixture.wait()
