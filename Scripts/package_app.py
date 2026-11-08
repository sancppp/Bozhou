#!/usr/bin/env python3
import plistlib
import os
from pathlib import Path
import re
import shutil
import sys

root = Path(__file__).resolve().parent.parent
version = (root / "VERSION").read_text().strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    sys.exit("VERSION must contain a numeric major.minor.patch version")
configuration = sys.argv[1]
app = Path(os.environ.get("BOZHOU_APP_OUTPUT", str(root / "dist" / "泊舟.app"))).expanduser().absolute()
if app.exists():
    shutil.rmtree(app)
macos = app / "Contents" / "MacOS"
resources = app / "Contents" / "Resources"
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
for executable in ("Bozhou", "BozhouAskPass", "BozhouUpdater"):
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
    "CFBundleName": "Bozhou",
    "CFBundleDisplayName": "Bozhou",
    "CFBundleExecutable": "Bozhou",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": version,
    "CFBundleIconFile": "Bozhou",
    "CFBundleDevelopmentRegion": "en",
    "CFBundleLocalizations": ["en", "zh-Hans"],
    "LSMinimumSystemVersion": "14.0",
    "LSApplicationCategoryType": "public.app-category.developer-tools",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "NSHumanReadableCopyright": "Copyright © 2026 Bozhou. SwiftTerm is licensed under MIT.",
    "UTExportedTypeDeclarations": [{
        "UTTypeIdentifier": "dev.bozhou.backup",
        "UTTypeDescription": "Bozhou Backup",
        "UTTypeConformsTo": ["public.data"],
        "UTTypeTagSpecification": {"public.filename-extension": ["bozhoubackup"]},
    }],
}
if preview := os.environ.get("BOZHOU_PREVIEW_BUILD", "").strip():
    info["BozhouPreviewBuild"] = preview
with (app / "Contents" / "Info.plist").open("wb") as stream:
    plistlib.dump(info, stream, sort_keys=False)
