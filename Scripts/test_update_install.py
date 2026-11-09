#!/usr/bin/env python3
"""Exercise real SwiftUI update dismissal, app quit and production helper."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import tempfile
import time


def run(*arguments):
    subprocess.run(arguments, check=True, capture_output=True)


def make_app(app, binary, version):
    macos = app / "Contents/MacOS"
    macos.mkdir(parents=True)
    shutil.copy2(binary, macos / "Bozhou")
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({
            "CFBundleIdentifier": "dev.bozhou.ssh",
            "CFBundleExecutable": "Bozhou",
            "CFBundleName": "Bozhou Update Probe",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "NSPrincipalClass": "NSApplication",
            "LSUIElement": True,
        }, stream)


def version(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream)["CFBundleShortVersionString"]


def exercise(binary_directory, mode, language):
    # All installations and generated fixture data live outside the repository.
    with tempfile.TemporaryDirectory(prefix="bozhou-update-install-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        marker = root / "candidate-launched"
        source = root / "candidate.c"
        source.write_text(
            '#include <stdio.h>\nint main(void) { FILE *f = fopen('
            + json.dumps(str(marker)) + ', "w"); if (!f) return 1; '
            + 'fputs("candidate launched", f); fclose(f); return 0; }\n'
        )
        candidate_binary = root / "candidate"
        run("/usr/bin/xcrun", "clang", "-arch", "arm64", str(source), "-o", str(candidate_binary))
        candidate = root / "candidate-payload/泊舟.app"
        make_app(candidate, candidate_binary, "1.3.1")
        run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(candidate))
        archive = root / "Bozhou-1.3.1-macOS-arm64.zip"
        run("/usr/bin/ditto", "-c", "-k", "--keepParent", str(candidate), str(archive))
        sums = root / "SHA256SUMS"
        sums.write_text(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")
        base = "https://github.com/sancppp/Bozhou/releases/download/release/v1.3.1/"
        (root / "release.json").write_text(json.dumps({
            "tag_name": "release/v1.3.1", "draft": False, "prerelease": False,
            "body": "Isolated signed update fixture",
            "html_url": "https://github.com/sancppp/Bozhou/releases/tag/release/v1.3.1",
            "assets": [
                {"name": p.name, "browser_download_url": base + p.name, "size": p.stat().st_size}
                for p in (archive, sums)
            ],
        }))
        target = root / "泊舟.app"
        make_app(target, binary_directory / "NativeUpdateInstallProbe", "1.3.0")
        macos = target / "Contents/MacOS"
        shutil.copy2(binary_directory / "BozhouUpdater", macos / "BozhouUpdater")
        resources = target / "Contents/Resources"
        resources.mkdir()
        shutil.copytree(binary_directory / "Bozhou_BozhouCore.bundle", resources / "Bozhou_BozhouCore.bundle")
        run("/usr/bin/codesign", "--force", "--sign", "-", str(macos / "BozhouUpdater"))
        run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(target))
        data = root / "data"
        environment = {
            **os.environ, "BOZHOU_DATA_DIR": str(data),
            "BOZHOU_UPDATE_PROBE_ROOT": str(root), "BOZHOU_UPDATE_PROBE_MODE": mode,
            "TMPDIR": str(root),
        }
        # AppModel creates an English workspace; the probe also validates Chinese copy.
        if language == "zh-Hans":
            environment["BOZHOU_UPDATE_PROBE_LANGUAGE"] = language
        process = subprocess.Popen([str(macos / "Bozhou")], env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=45)
            print(stdout, end="")
            assert process.returncode == 0, stderr
            if mode in ("cancel", "blocked"):
                assert version(target) == "1.3.0" and not marker.exists()
                assert not list(root.glob("泊舟.app.backup-*"))
                assert not list(root.glob(".bozhou-update-*"))
            else:
                deadline = time.monotonic() + 20
                while (not marker.exists() or list(root.glob(".bozhou-update-*"))) and time.monotonic() < deadline:
                    time.sleep(0.05)
                assert marker.read_text() == "candidate launched", "Replacement did not launch"
                assert version(target) == "1.3.1"
                assert (root / "parent-terminated").read_text() == f"quitRequests={2 if mode == 'reject' else 1},sheets=0"
                backups = list(root.glob("泊舟.app.backup-*"))
                assert len(backups) == 1 and version(backups[0]) == "1.3.0"
                assert not list(root.glob(".bozhou-update-*"))
                run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(target))
            print(f"PASS {mode}/{language}: isolated target, backup and launch state")
        finally:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            if process.poll() is None:
                process.communicate(timeout=5)


if __name__ == "__main__":
    binaries = Path(sys.argv[1]).resolve()
    for scenario, language in (("success", "en"), ("reject", "en"), ("cancel", "en"),
                               ("blocked", "en"), ("success", "zh-Hans")):
        exercise(binaries, scenario, language)
