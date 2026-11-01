#!/usr/bin/env python3
"""Exercise the packaged updater with signed, isolated apps and a real parent process."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "dist" / "泊舟.app" / "Contents"


def run(*args):
    subprocess.run(args, check=True, capture_output=True)


def version(app):
    with (app / "Contents" / "Info.plist").open("rb") as stream:
        return plistlib.load(stream)["CFBundleShortVersionString"]


def main():
    with tempfile.TemporaryDirectory(prefix="update-helper-", dir=ROOT / ".runtime" / "tmp") as temporary:
        root = Path(temporary)
        marker = root / "launched"
        source = root / "fixture.c"
        source.write_text(
            '#include <stdio.h>\nint main(void) { FILE *f = fopen('
            + json.dumps(str(marker))
            + ', "w"); if (!f) return 1; fputs("candidate launched", f); fclose(f); return 0; }\n'
        )
        binary = root / "fixture"
        run("/usr/bin/xcrun", "clang", "-arch", "arm64", str(source), "-o", str(binary))

        def make_app(app, number):
            macos = app / "Contents" / "MacOS"
            macos.mkdir(parents=True)
            shutil.copy2(binary, macos / "Bozhou")
            with (app / "Contents" / "Info.plist").open("wb") as stream:
                plistlib.dump({
                    "CFBundleIdentifier": "dev.bozhou.ssh",
                    "CFBundleExecutable": "Bozhou",
                    "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": number,
                    "LSUIElement": True,
                }, stream)
            run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app))

        target = root / "泊舟.app"
        staging = root / ".bozhou-update-fixture"
        staging.mkdir(mode=0o700)
        make_app(target, "1.1.1")
        make_app(staging / "泊舟.app", "1.1.2")
        shutil.copy2(PACKAGE / "MacOS" / "BozhouUpdater", staging / "BozhouUpdater")
        shutil.copytree(PACKAGE / "Resources" / "Bozhou_BozhouCore.bundle",
                        staging / "Bozhou_BozhouCore.bundle")
        # This owned process remains alive until stdin closes.
        parent = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"],
                                  stdin=subprocess.PIPE)
        helper = subprocess.Popen([str(staging / "BozhouUpdater"), str(parent.pid),
                                   str(target), "1.1.2", "en"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(0.4)
            assert helper.poll() is None, "Updater exited before its parent"
            assert version(target) == "1.1.1" and not marker.exists(), "Replaced a running app"
            parent.stdin.close()
            parent.wait(timeout=5)
            stdout, stderr = helper.communicate(timeout=30)
            assert helper.returncode == 0, (stdout + stderr).decode(errors="replace")
            assert version(target) == "1.1.2"
            previous = list(root.glob("泊舟.app.backup-*"))
            assert len(previous) == 1 and version(previous[0]) == "1.1.1"
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(target))
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            assert marker.read_text() == "candidate launched", "New app did not run"
            assert not staging.exists(), "Staging directory was not removed"
        finally:
            for process in (parent, helper):
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
        print("PASS packaged updater: waits for quit, replaces, retains backup, launches and cleans staging")


if __name__ == "__main__":
    main()
