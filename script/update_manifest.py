#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


def main():
  parser = argparse.ArgumentParser(description="Generate update metadata for a MonoDeck release installer.")
  parser.add_argument("tag")
  parser.add_argument("installer", type=Path)
  arguments = parser.parse_args()
  try:
    manifest = update_manifest(arguments.tag, arguments.installer)
  except (OSError, ValueError) as error:
    print(f"Update manifest failed: {error}", file=sys.stderr)
    return 1
  print(json.dumps(manifest, indent=2))
  return 0


def update_manifest(tag, installer):
  version = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
  if not re.fullmatch(rf"v{version}", tag):
    raise ValueError("Expected a release tag in vX.Y.Z format.")
  if installer.name != f"MonoDeck-{tag[1:]}-arm64.dmg":
    raise ValueError("Installer filename does not match the release tag.")
  size = installer.stat().st_size
  if size <= 0:
    raise ValueError("Installer is empty.")
  digest = hashlib.sha256()
  with installer.open("rb") as source:
    while chunk := source.read(1_048_576):
      digest.update(chunk)
  releases = "https://github.com/qimaotech/mono-deck/releases"
  return {
    "tag_name": tag,
    "html_url": f"{releases}/tag/{tag}",
    "draft": False,
    "prerelease": False,
    "assets": [{
      "name": installer.name,
      "size": size,
      "browser_download_url": f"{releases}/download/{tag}/{installer.name}",
      "digest": f"sha256:{digest.hexdigest()}",
    }],
  }


if __name__ == "__main__":
  sys.exit(main())
