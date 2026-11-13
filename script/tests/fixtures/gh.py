import json
import os
from pathlib import Path
import sys


def main():
  arguments = sys.argv[1:]
  root = Path(os.environ["MOCK_RELEASE_DIRECTORY"])
  with (root / "calls").open("a", encoding="utf-8") as log:
    log.write(json.dumps(arguments) + "\n")
  file = root / "release.json"
  if arguments[:2] == ["release", "view"]:
    if not file.exists():
      return 1
    print(file.read_text(encoding="utf-8"))
  elif arguments[:2] == ["release", "create"]:
    file.write_text(json.dumps({"databaseId": 1, "isDraft": True, "assets": []}), encoding="utf-8")
  elif arguments[:2] == ["release", "upload"]:
    if os.environ.get("MOCK_UPLOAD_FAIL") == "1":
      return 1
    release = json.loads(file.read_text(encoding="utf-8"))
    release["assets"] = [{"name": Path(p).name, "size": Path(p).stat().st_size} for p in arguments[3:-1]]
    file.write_text(json.dumps(release), encoding="utf-8")
  elif arguments[0] == "api":
    release = json.loads(file.read_text(encoding="utf-8"))
    release["isDraft"] = False
    file.write_text(json.dumps(release), encoding="utf-8")
  elif arguments[:2] != ["release", "edit"]:
    return 2
  return 0


if __name__ == "__main__":
  sys.exit(main())
