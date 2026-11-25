"""Offline check of the Xcode target, shared pages and the optional release ZIP.

    python Tests/verify_bundle.py [path/to/source.zip]

No third-party dependencies. Does not compile Swift or simulate an iPhone camera.
"""
from __future__ import annotations

import base64
import hashlib
import json
import plistlib
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LUTS = {"FL2", "FL3", "Classic-Negative", "GR-Positive", "Nostalgic-Negative", "Classic-Chrome"}
PAGES = ("FL-Camera-Review.html", "Stilltone-Album.html")
VERSION, BUILD = "0.2.2", "25"


def require(condition, text):
    if not condition:
        raise ValueError(text)


def check():
    project = plistlib.loads((ROOT / "FL-Camera.xcodeproj/project.pbxproj").read_bytes())
    objs = project["objects"]
    target, = [objs[ref] for ref in objs[project["rootObject"]]["targets"] if objs[ref].get("name") == "FLCamera"]
    config_ids = objs[target["buildConfigurationList"]]["buildConfigurations"]
    require({objs[ref]["name"] for ref in config_ids} == {"Debug", "Release"}, "target configs")
    for ref in config_ids:
        cfg = objs[ref]["buildSettings"]
        require((cfg["MARKETING_VERSION"], cfg["CURRENT_PROJECT_VERSION"]) == (VERSION, BUILD), "target version")
        require(cfg["INFOPLIST_FILE"] == "Info.plist", "target plist")
    info = plistlib.loads((ROOT / "Info.plist").read_bytes())
    require(info["CFBundleVersion"] == "$(CURRENT_PROJECT_VERSION)", "plist build number")
    for key in ("NSCameraUsageDescription", "NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"):
        require(bool(info.get(key)), key)
    phases = {p["isa"]: {objs[objs[f]["fileRef"]]["path"] for f in p["files"]}
              for ref in target["buildPhases"] if (p := objs[ref]).get("files")}
    require(phases["PBXSourcesBuildPhase"] == {"Camera.swift", "StudioApp.swift"}, "Swift target membership")
    expected = {n + ".rgba" for n in LUTS}.union(PAGES)
    require(phases["PBXResourcesBuildPhase"] == expected | {'Assets.xcassets'}, "resource target membership")
    require(info.get("CADisableMinimumFrameDurationOnPhone") is True, "ProMotion opt-in")
    icons = ROOT / "Assets.xcassets/AppIcon.appiconset"
    image = json.loads((icons/"Contents.json").read_text())["images"][0]
    require(image["size"] == "1024x1024" and (icons/image["filename"]).is_file(), "App icon")
    for name in expected | phases["PBXSourcesBuildPhase"]:
        require((ROOT / name).is_file(), "missing " + name)
    print(f"PASS: FLCamera Debug/Release {VERSION} ({BUILD}), plist, sources and all eight resources")

    for page in PAGES:
        text = (ROOT / page).read_text(encoding="utf-8")
        m = re.search(r'<script id="assets" type="application/json">(.*?)</script>', text, re.S)
        require(m, "missing assets: " + page)
        assets = json.loads(m[1]); require(set(assets) == LUTS, "LUT names: " + page)
        for name, entry in assets.items():
            raw = (ROOT / (name + ".rgba")).read_bytes()
            require(len(raw) == 33**3 * 4 * 4, "wrong LUT dimension: " + name)
            require(base64.b64decode(entry["data"], validate=True) == raw, f"{page} differs from native {name}")
            require(hashlib.sha256(raw).hexdigest() == entry["sha256"], f"wrong digest: {page} {name}")
        print(f"PASS: all six embedded LUTs in {page} equal the bundled native LUTs byte-for-byte")

    workflow = (ROOT / ".github/workflows/ipa.yml").read_text(encoding="utf-8")
    require(f"Stilltone-{VERSION}-build{BUILD}-unsigned" in workflow, "workflow artifact version")
    require(re.search(r"CFBundleVersion.*?=\s*" + BUILD + r"\s*$", workflow, re.M), "workflow build-number gate")
    if len(sys.argv) > 1:
        with zipfile.ZipFile(sys.argv[1]) as archive:
            require(archive.testzip() is None, "ZIP CRC failure")
            files = {p.relative_to(ROOT).as_posix(): p for p in ROOT.rglob("*") if p.is_file() and "__pycache__" not in p.parts}
            members = [n for n in archive.namelist() if not n.endswith("/")]
            require(len(members) == len(set(members)) and set(members) == set(files), "ZIP manifest does not match the project folder")
            for name, path in files.items():
                require(archive.read(name) == path.read_bytes(), "ZIP differs: " + name)
            print(f"PASS: all {len(files)} ZIP members match the candidate folder, including .github/workflows/ipa.yml")


if __name__ == "__main__":
    check()
