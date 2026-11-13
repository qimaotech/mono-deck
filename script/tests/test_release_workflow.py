import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "release_workflow.py"


class ReleaseWorkflowTests(unittest.TestCase):
  def test_non_release_pushes_skip_publication(self):
    for kind in ["ordinary", "build-only", "tag", "deleted-tag"]:
      with self.subTest(kind=kind), Repository() as repo:
        before = repo.git("rev-parse", "HEAD")
        repo.record_version("1.10.0" if kind == "tag" else "1.9.0", 1 if kind == "ordinary" else 2)
        ref = "refs/heads/main"
        if kind == "tag":
          repo.git("tag", "-a", "v1.10.0", "-m", "v1.10.0")
          ref = "refs/tags/v1.10.0"
        elif kind == "deleted-tag":
          ref = "refs/tags/v1.9.0"
        result, output = repo.prepare(before, ref=ref, deleted=kind == "deleted-tag")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, {"release": "false"})

  def test_numeric_version_and_merged_commit_are_used_when_main_advances(self):
    with Repository() as repo:
      before = repo.git("rev-parse", "HEAD")
      repo.record_version("1.10.0", 2)
      commit = repo.git("rev-parse", "HEAD")
      repo.git("commit", "--allow-empty", "-m", "Later change")
      repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
      repo.git("checkout", "--detach", commit)
      result, output = repo.prepare(before)
      self.assertEqual(result.returncode, 0, result.stderr)
      self.assertEqual(output, {"release": "true", "tag": "v1.10.0", "commit": commit})

  def test_invalid_releases_are_rejected(self):
    for kind in ["downgrade", "build", "changelog", "newer-tag", "unmerged", "wrong-tag", "lightweight"]:
      with self.subTest(kind=kind), Repository() as repo:
        before = repo.git("rev-parse", "HEAD")
        repo.record_version("1.8.0" if kind == "downgrade" else "1.10.0", 1 if kind == "build" else 2)
        if kind == "changelog":
          (repo.root / "CHANGELOG.md").write_text("# Changelog\n", encoding="utf-8")
        elif kind == "newer-tag":
          repo.git("tag", "v2.0.0")
        elif kind == "unmerged":
          repo.git("update-ref", "refs/remotes/origin/main", before)
        elif kind == "wrong-tag":
          repo.git("tag", "-a", "v1.10.0", "-m", "v1.10.0", before)
        elif kind == "lightweight":
          repo.git("tag", "v1.10.0")
        result, output = repo.prepare(before)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, {})

  def test_matching_annotated_tag_allows_resuming_the_original_main_event(self):
    with Repository() as repo:
      before = repo.git("rev-parse", "HEAD")
      repo.record_version("1.10.0", 2)
      repo.git("tag", "-a", "v1.10.0", "-m", "v1.10.0")
      result, output = repo.prepare(before)
      self.assertEqual(result.returncode, 0, result.stderr)
      self.assertEqual(output["tag"], "v1.10.0")

  def test_failed_upload_can_resume_without_replacing_tag_or_published_assets(self):
    with Repository() as repo:
      repo.record_version("1.10.0", 2)
      repo.prepare_publisher()
      commit = repo.git("rev-parse", "HEAD")
      repo.environment["MOCK_UPLOAD_FAIL"] = "1"
      failed = repo.publish(commit)
      self.assertNotEqual(failed.returncode, 0)
      tag = repo.git("rev-parse", "refs/tags/v1.10.0")
      self.assertEqual(repo.git("cat-file", "-t", tag), "tag")
      self.assertEqual(repo.git("rev-parse", "refs/tags/v1.10.0^{commit}"), commit)
      self.assertTrue(repo.git("ls-remote", "origin", "refs/tags/v1.10.0").startswith(tag))
      self.assertTrue(repo.release()["isDraft"])

      repo.environment["MOCK_UPLOAD_FAIL"] = "0"
      resumed = repo.publish(commit)
      self.assertEqual(resumed.returncode, 0, resumed.stderr)
      self.assertFalse(repo.release()["isDraft"])
      calls = repo.calls()
      self.assertEqual(sum(call[:2] == ["release", "create"] for call in calls), 1)
      self.assertTrue(any("make_latest=legacy" in call for call in calls))

      repeated = repo.publish(commit)
      self.assertEqual(repeated.returncode, 0, repeated.stderr)
      self.assertIn("already published", repeated.stdout)
      self.assertEqual([call[:2] for call in repo.calls()[len(calls):]], [["release", "view"]])
      self.assertEqual(repo.git("rev-parse", "refs/tags/v1.10.0"), tag)

      calls = repo.calls()
      incomplete = repo.release()
      incomplete["assets"] = []
      (repo.directory / "release.json").write_text(json.dumps(incomplete), encoding="utf-8")
      damaged = repo.publish(commit)
      self.assertNotEqual(damaged.returncode, 0)
      self.assertIn("manual recovery", damaged.stderr)
      self.assertFalse(repo.release()["isDraft"])
      self.assertEqual([call[:2] for call in repo.calls()[len(calls):]], [["release", "view"]])


class Repository:
  def __enter__(self):
    self.temporary = tempfile.TemporaryDirectory(prefix="mono-deck-release-tests-")
    try:
      self.directory = Path(self.temporary.name)
      self.root = self.directory / "workspace"
      self.root.mkdir()
      self.environment = {key: value for key, value in os.environ.items()
                          if not key.startswith(("GIT_", "GH_"))}
      self.environment.update({
        "HOME": str(self.directory),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_AUTHOR_NAME": "MonoDeck Test",
        "GIT_AUTHOR_EMAIL": "test@example.invalid",
        "GIT_COMMITTER_NAME": "MonoDeck Test",
        "GIT_COMMITTER_EMAIL": "test@example.invalid",
        "GIT_ALLOW_PROTOCOL": "file",
        "GIT_TERMINAL_PROMPT": "0",
        "PYTHONDONTWRITEBYTECODE": "1",
      })
      self.git("init", "-b", "main")
      self.record_version("1.9.0", 1)
      self.git("tag", "-a", "v1.9.0", "-m", "v1.9.0")
      return self
    except BaseException:
      self.temporary.cleanup()
      raise

  def __exit__(self, *_):
    self.temporary.cleanup()

  def record_version(self, version, build):
    (self.root / "Version.xcconfig").write_text(
      f"MARKETING_VERSION = {version}\nCURRENT_PROJECT_VERSION = {build}\n", encoding="utf-8")
    (self.root / "CHANGELOG.md").write_text(
      f"# Changelog\n\n## [{version}] - 2026-11-13\n\n### Fixed\n\n- A fix.\n", encoding="utf-8")
    self.git("add", "Version.xcconfig", "CHANGELOG.md")
    self.git("commit", "--allow-empty", "-m", f"Release {version}")
    self.git("update-ref", "refs/remotes/origin/main", "HEAD")

  def prepare(self, before, ref="refs/heads/main", deleted=False):
    event = self.directory / "event.json"
    output = self.directory / "output"
    event.write_text(json.dumps({"ref": ref, "before": before, "deleted": deleted}), encoding="utf-8")
    result = self.run(sys.executable, str(SCRIPT), "prepare", str(event), str(output))
    values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines()) if output.exists() else {}
    return result, values

  def prepare_publisher(self):
    remote = self.directory / "release.git"
    self.git("init", "--bare", str(remote))
    self.git("remote", "add", "origin", str(remote))
    self.git("push", "origin", "main")
    gh = self.directory / "gh"
    fixture = Path(__file__).parent / "fixtures" / "gh.py"
    gh.write_text(f"#!{sys.executable}\n" + fixture.read_text(encoding="utf-8"), encoding="utf-8")
    gh.chmod(0o755)
    self.environment["PATH"] = os.pathsep.join([
      str(self.directory), str(Path(shutil.which("git")).parent), os.defpath,
    ])
    self.environment["MOCK_RELEASE_DIRECTORY"] = str(self.directory)
    for name in ["MonoDeck-1.10.0-arm64.dmg", "MonoDeck-update.json"]:
      (self.directory / name).write_text("asset", encoding="utf-8")

  def publish(self, commit):
    return self.run(sys.executable, str(SCRIPT), "publish", "v1.10.0", commit,
                    str(self.directory / "MonoDeck-1.10.0-arm64.dmg"), str(self.root / "CHANGELOG.md"))

  def release(self):
    return json.loads((self.directory / "release.json").read_text(encoding="utf-8"))

  def calls(self):
    return [json.loads(line) for line in (self.directory / "calls").read_text(encoding="utf-8").splitlines()]

  def git(self, *arguments):
    result = self.run("git", *arguments)
    result.check_returncode()
    return result.stdout.strip()

  def run(self, *arguments):
    return subprocess.run(arguments, cwd=self.root, env=self.environment, capture_output=True, text=True, timeout=30)


if __name__ == "__main__":
  unittest.main()
