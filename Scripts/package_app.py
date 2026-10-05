#!/usr/bin/env python3
import plistlib
from pathlib import Path
import re
import shutil
import sys

root = Path(__file__).resolve().parent.parent
version = (root / "VERSION").read_text().strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    sys.exit("VERSION must contain a numeric major.minor.patch version")
configuration = sys.argv[1]
app = root / "dist" / "泊舟.app"
if app.exists():
    shutil.rmtree(app)
macos = app / "Contents" / "MacOS"
resources = app / "Contents" / "Resources"
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
for executable in ("Bozhou", "BozhouAskPass"):
    shutil.copy2(root / ".build" / configuration / executable, macos / executable)
shutil.copy2(root / "Resources" / "Bozhou.icns", resources / "Bozhou.icns")
for bundle in ("Bozhou_SwiftTerm.bundle", "Bozhou_BozhouCore.bundle"):
    shutil.copytree(root / ".build" / configuration / bundle, resources / bundle)
for document in ("THIRD_PARTY_NOTICES.md", "LICENSE"):
    shutil.copy2(root / document, resources / document)
shutil.copy2(root / "Vendor" / "SwiftTerm" / "LICENSE", resources / "SwiftTerm-LICENSE.txt")
shutil.copy2(root / "Vendor" / "bash-preexec" / "LICENSE.md", resources / "bash-preexec-LICENSE.md")
info = {
    "CFBundleIdentifier": "dev.bozhou.ssh",
    "CFBundleName": "泊舟",
    "CFBundleDisplayName": "泊舟",
    "CFBundleExecutable": "Bozhou",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": version,
    "CFBundleIconFile": "Bozhou",
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleLocalizations": ["zh_CN", "zh-Hans"],
    "LSMinimumSystemVersion": "14.0",
    "LSApplicationCategoryType": "public.app-category.developer-tools",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "NSHumanReadableCopyright": "Copyright © 2026 泊舟。SwiftTerm is licensed under MIT.",
}
with (app / "Contents" / "Info.plist").open("wb") as stream:
    plistlib.dump(info, stream, sort_keys=False)
