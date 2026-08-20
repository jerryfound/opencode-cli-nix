#!/usr/bin/env python3
"""Refresh hashes.json with the latest stable opencode release from npm.

Reads the registry metadata of the opencode-ai meta package to find the
latest stable version, then records the tarball URL and sha512 integrity
hash of every supported platform package. No tarballs are downloaded and
no Nix installation is required.

Exits 0 whether or not an update was needed. Prints a one-line summary.
"""

import json
import sys
import urllib.request
from pathlib import Path

REGISTRY = "https://registry.npmjs.org"
META_PACKAGE = "opencode-ai"
TARGETS = ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"]
OUT_FILE = Path(__file__).resolve().parent.parent / "hashes.json"


def fetch_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def latest_stable_version() -> str:
    dist_tags = fetch_json(f"{REGISTRY}/{META_PACKAGE}")["dist-tags"]
    version = dist_tags["latest"]
    # Guard against a prerelease ever being tagged as latest.
    if "-" in version:
        sys.exit(f"latest dist-tag points at a prerelease ({version}), refusing to update")
    return version


def platform_entry(target: str, version: str) -> dict:
    meta = fetch_json(f"{REGISTRY}/opencode-{target}/{version}")
    return {
        "url": meta["dist"]["tarball"],
        "hash": meta["dist"]["integrity"],
    }


def main() -> None:
    current = json.loads(OUT_FILE.read_text()) if OUT_FILE.exists() else {}
    version = latest_stable_version()

    if current.get("version") == version:
        print(f"already up to date: {version}")
        return

    platforms = {target: platform_entry(target, version) for target in TARGETS}
    data = {"version": version, "platforms": platforms}
    OUT_FILE.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    print(f"updated: {current.get('version', '<none>')} -> {version}")


if __name__ == "__main__":
    main()
