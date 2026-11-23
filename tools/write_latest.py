"""Write release/latest.json, the file the installed apps read to see whether a newer build is out
(app/lib/app_update.dart on Android, ios/JuanGo/AppUpdate.swift on iPhone). Called by
tools/build_release.sh.

usage: write_latest.py VERSION BUILD [NOTES]
"""
import json
import os
import sys

version, build = sys.argv[1:3]
notes = sys.argv[3] if len(sys.argv) > 3 else ""
base = f"https://github.com/HowWeiChi-app/JuanGo/releases/download/v{version}"
latest = {
    "version": version,
    "build": int(build),
    "notes": notes,
    "ipa": f"{base}/JuanGo-{version}.ipa",
    "apk": f"{base}/JuanGo-{version}.apk",
}
path = os.path.join(os.path.dirname(__file__), "..", "release", "latest.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(latest, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"release/latest.json → {version} ({build})")
