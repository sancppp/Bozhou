#!/usr/bin/env python3
"""Check the distributable's version, resource boundary, executables and signatures."""
from pathlib import Path
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parent.parent
app = root / "dist" / "泊舟.app"
with (app / "Contents" / "Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info["CFBundleShortVersionString"] == (root / "VERSION").read_text().strip()
assert info["CFBundleIdentifier"] == "dev.bozhou.ssh"
resources = app / "Contents" / "Resources"
expected = {
    "Bozhou.icns", "Bozhou_SwiftTerm.bundle", "Bozhou_BozhouCore.bundle",
    "README.md", "THIRD_PARTY_NOTICES.md", "LICENSE", "CONTRIBUTING.md", "SECURITY.md",
    "SwiftTerm-LICENSE.txt", "bash-preexec-LICENSE.md",
}
assert {p.name for p in resources.iterdir()} == expected, "Unexpected or missing packaged resources"
for document in resources.glob("*.md"):
    for target in re.findall(r"\]\(([^)]+)\)", document.read_text()):
        if not target.startswith(("https:", "http:", "#")):
            assert (resources / target.split("#")[0]).is_file(), f"Broken help link: {document.name} -> {target}"
for executable in ("Bozhou", "BozhouAskPass"):
    subprocess.run(["codesign", "--verify", "--strict", str(app / "Contents" / "MacOS" / executable)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print("PASS package version, resource allowlist, help links, helper and app signatures")
