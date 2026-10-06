#!/usr/bin/env python3
"""Check the distributable's version, resource boundary, executables and signatures."""
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parent.parent
app = root / "dist" / "泊舟.app"
with (app / "Contents" / "Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info["CFBundleShortVersionString"] == (root / "VERSION").read_text().strip()
assert info["CFBundleIdentifier"] == "dev.bozhou.ssh"
assert info["CFBundleDevelopmentRegion"] == "en"
assert info["CFBundleLocalizations"] == ["en", "zh-Hans"]
assert info["CFBundleDisplayName"] == "Bozhou"
resources = app / "Contents" / "Resources"
expected = {
    "Bozhou.icns", "Bozhou_SwiftTerm.bundle", "Bozhou_BozhouCore.bundle",
    "THIRD_PARTY_NOTICES.md", "LICENSE", "SwiftTerm-LICENSE.txt", "bash-preexec-LICENSE.md",
}
assert {p.name for p in resources.iterdir()} == expected, "Unexpected or missing packaged resources"
for language in ("en", "zh-hans"):
    catalog = resources / "Bozhou_BozhouCore.bundle" / f"{language}.lproj" / "Localizable.strings"
    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(catalog)],
                            check=True, capture_output=True, text=True)
    import json
    values = json.loads(result.stdout)
    assert values["Settings"] == ("Settings" if language == "en" else "设置")
    assert values["SSH Authentication"] == ("SSH Authentication" if language == "en" else "SSH 身份验证")
    assert len(values) > 400
for executable in ("Bozhou", "BozhouAskPass"):
    subprocess.run(["codesign", "--verify", "--strict", str(app / "Contents" / "MacOS" / executable)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print("PASS package version, English default, bilingual resources, licenses, helper and app signatures")
