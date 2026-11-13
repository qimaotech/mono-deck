#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
from release_notes import VERSION, release_notes


def main():
  parser = argparse.ArgumentParser(description="Prepare and publish a release from a merged commit.")
  commands = parser.add_subparsers(dest="command", required=True)
  prepare = commands.add_parser("prepare")
  prepare.add_argument("event", type=Path)
  prepare.add_argument("output", type=Path)
  publish = commands.add_parser("publish")
  publish.add_argument("tag")
  publish.add_argument("commit")
  publish.add_argument("installer", type=Path)
  publish.add_argument("notes", type=Path)
  arguments = parser.parse_args()
  try:
    if arguments.command == "prepare":
      plan = release_plan(json.loads(arguments.event.read_text(encoding="utf-8")))
      with arguments.output.open("a", encoding="utf-8") as output:
        output.write("".join(f"{key}={value}\n" for key, value in plan.items()))
    else:
      publish_release(arguments.tag, arguments.commit, arguments.installer, arguments.notes)
  except (OSError, ValueError, subprocess.CalledProcessError) as error:
    print(f"Release failed: {error}", file=sys.stderr)
    return 1
  return 0


def release_plan(event):
  if event.get("deleted") or event["ref"] != "refs/heads/main":
    return {"release": "false"}
  configuration = Path("Version.xcconfig").read_text(encoding="utf-8")
  version, build = configured_version(configuration)
  tag = f"v{version}"
  before = event["before"]
  if not re.fullmatch(r"[0-9a-f]{40}", before) or before == "0" * 40:
    raise ValueError("A main push must have an existing base commit.")
  previous, previous_build = configured_version(git("show", f"{before}:Version.xcconfig"))
  if version == previous:
    return {"release": "false"}
  if version_number(version) <= version_number(previous) or build <= previous_build:
    raise ValueError("A release must increase both the product version and build number.")
  commit = git("rev-parse", "HEAD")
  validate_release(tag, commit)
  return {"release": "true", "tag": tag, "commit": commit}


def publish_release(tag, commit, installer, notes):
  # Refresh refs before checking them; a retry must never move an existing tag.
  git("fetch", "origin", "+refs/heads/main:refs/remotes/origin/main", "--tags")
  validate_release(tag, commit)
  manifest = installer.parent / "MonoDeck-update.json"
  if installer.name != f"MonoDeck-{tag[1:]}-arm64.dmg" or not installer.is_file() or not manifest.is_file():
    raise ValueError("The release installer and update manifest are required.")
  if not tag_exists(tag):
    git("-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
        "tag", "-a", tag, "-m", tag, commit)
    git("-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
        "push", "origin", f"refs/tags/{tag}")
  result = subprocess.run(["gh", "release", "view", tag, "--json", "databaseId,isDraft,assets"],
                          stdout=subprocess.PIPE, text=True)
  if result.returncode == 0:
    release = json.loads(result.stdout)
    if not release["isDraft"]:
      assets = {asset["name"] for asset in release["assets"] if asset["size"] > 0}
      if not {installer.name, manifest.name} <= assets:
        raise ValueError("The published release is missing assets; manual recovery is required.")
      print(f"{tag} is already published; leaving its assets unchanged.")
      return
  else:
    run("gh", "release", "create", tag, "--draft", "--verify-tag", "--title", tag,
        "--notes-file", str(notes))
    release = json.loads(run("gh", "release", "view", tag, "--json", "databaseId"))
  run("gh", "release", "edit", tag, "--title", tag, "--notes-file", str(notes))
  run("gh", "release", "upload", tag, str(installer), str(manifest), "--clobber")
  # Let GitHub choose Latest by version, including when an older release finishes later.
  run("gh", "api", "--method", "PATCH", f"repos/{{owner}}/{{repo}}/releases/{release['databaseId']}",
      "-F", "draft=false", "-f", "make_latest=legacy")


def validate_release(tag, commit):
  if not re.fullmatch(rf"v{VERSION}", tag) or git("rev-parse", "HEAD") != commit:
    raise ValueError("The release tag and checked-out commit must match the release plan.")
  release_notes(tag, Path("Version.xcconfig").read_text(encoding="utf-8"),
                Path("CHANGELOG.md").read_text(encoding="utf-8"))
  git("merge-base", "--is-ancestor", commit, "refs/remotes/origin/main")
  stable_tags = [item for item in git("tag", "--list").splitlines()
                 if re.fullmatch(rf"v{VERSION}", item) and item != tag]
  if any(version_number(item[1:]) >= version_number(tag[1:]) for item in stable_tags):
    raise ValueError("The release version must exceed every existing stable tag.")
  if tag_exists(tag):
    if git("cat-file", "-t", f"refs/tags/{tag}") != "tag" or git("rev-parse", f"refs/tags/{tag}^{{commit}}") != commit:
      raise ValueError("The existing annotated tag must point to the release commit.")


def configured_version(configuration):
  values = []
  for key, pattern in [("MARKETING_VERSION", VERSION), ("CURRENT_PROJECT_VERSION", r"[0-9]+")]:
    matches = re.findall(rf"^[ \t]*{key}[ \t]*=[ \t]*([^\r\n]+)", configuration, re.MULTILINE)
    if len(matches) != 1 or not re.fullmatch(pattern, matches[0].split("//", 1)[0].strip()):
      raise ValueError(f"Expected one valid {key} in Version.xcconfig.")
    values.append(matches[0].split("//", 1)[0].strip())
  return values[0], int(values[1])


def version_number(version):
  return tuple(int(part) for part in version.split("."))


def tag_exists(tag):
  return subprocess.run(["git", "show-ref", "--verify", "--quiet", f"refs/tags/{tag}"]).returncode == 0


def git(*arguments):
  return run("git", *arguments).strip()


def run(*arguments):
  return subprocess.check_output(arguments, text=True)


if __name__ == "__main__":
  sys.exit(main())
