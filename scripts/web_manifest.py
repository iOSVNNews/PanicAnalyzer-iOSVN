#!/usr/bin/env python3
"""Writes assets/web_update.json, the manifest of the interface update.

The app (Sources/WebUpdater.swift) downloads web/<file> from main when this
manifest has a higher webBuild than the interface inside the app, checks each
file against its SHA-256 and uses it from the next start. So fixes to web/
reach users without a new installer or version number.

webBuild = number of commits that changed web/ (needs the full git history).
NATIVE_API must match WebUpdater.nativeApi: raise both when the page starts
using a native action older app builds do not have; those builds then keep
their bundled interface until the app itself is updated.
"""
import hashlib
import json
import pathlib
import subprocess
import sys

FILES = ["index.html", "app.js", "parts.js", "i18n.js", "app.css"]
NATIVE_API = 1

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> int:
    count = subprocess.check_output(
        ["git", "rev-list", "--count", "HEAD", "--", "web"], cwd=ROOT, text=True).strip()
    manifest = {
        "webBuild": int(count),
        "nativeApi": NATIVE_API,
        "files": {name: hashlib.sha256((ROOT / "web" / name).read_bytes()).hexdigest() for name in FILES},
    }
    out = ROOT / "assets" / "web_update.json"
    out.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{out.relative_to(ROOT)}: web build {manifest['webBuild']}, native API {NATIVE_API}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
