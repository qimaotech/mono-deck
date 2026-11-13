import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "The test runner uses macOS preferences domains")
class RunTestsTests(unittest.TestCase):
  def test_actual_execution_and_environment_cleanup(self):
    for outcome, status in [("passed", 0), ("zero", 1), ("skipped", 1), ("failed", 65)]:
      with self.subTest(outcome=outcome), TestTask(outcome) as task:
        result = task.run()
        self.assertEqual(result.returncode, status, result.stdout)
        invocation = task.invocation()
        arguments, environment = invocation["arguments"], invocation["environment"]
        self.assertIn("-only-testing:MonoDeckTests", arguments)
        self.assertEqual(environment["MONO_DECK_UNIT_TEST_HOST"], "1")
        self.assertEqual(environment["TEST_RUNNER_MONO_DECK_UNIT_TEST_HOST"], "1")
        self.assertNotIn("MONO_DECK_TEST_WORKSPACE", environment)
        for key in ["MONO_DECK_TEST_SUPPORT_DIRECTORY", "MONO_DECK_TEST_HOME_DIRECTORY",
                    "MONO_DECK_TEST_SESSION_DIRECTORY", "MONO_DECK_TEST_DEFAULTS",
                    "MONO_DECK_TEST_LOGIN_SHELL", "TMPDIR"]:
          self.assertEqual(environment[key], environment[f"TEST_RUNNER_{key}"])
        self.assertNotEqual(environment["MONO_DECK_TEST_DEFAULTS"], "inherited-preferences")
        self.assertFalse(task.session().exists(), result.stdout)
        self.assertFalse(task.defaults_exist())
        self.assertEqual(task.sentinel.read_text(encoding="utf-8"), "keep me")

  def test_filtered_tests_keep_explicit_results_after_failure(self):
    with TestTask("failed") as task:
      results = task.directory / "saved results.xcresult"
      result = task.run("MonoDeckTests/WorkflowTests", "-resultBundlePath", str(results), "-quiet")
      self.assertEqual(result.returncode, 65, result.stdout)
      arguments = task.invocation()["arguments"]
      self.assertIn("-only-testing:MonoDeckTests/WorkflowTests", arguments)
      self.assertEqual(arguments.count("-resultBundlePath"), 1)
      self.assertEqual(arguments[-1], "-quiet")
      self.assertTrue(results.exists())
      self.assertFalse(task.session().exists(), result.stdout)

  def test_enumeration_does_not_require_executed_tests(self):
    with TestTask("zero") as task:
      result = task.run("MonoDeckTests", "-enumerate-tests")
      self.assertEqual(result.returncode, 0, result.stdout)
      self.assertFalse(task.session().exists(), result.stdout)

  def test_unconfirmed_host_cleanup_fails_and_preserves_its_environment(self):
    with TestTask("cleanup-failed") as task:
      result = task.run()
      self.assertEqual(result.returncode, 1, result.stdout)
      self.assertTrue(task.session().exists(), result.stdout)


class TestTask:
  def __init__(self, outcome):
    self.outcome = outcome

  def __enter__(self):
    self.temporary = tempfile.TemporaryDirectory(prefix="mono-deck test task ")
    try:
      self.directory = Path(self.temporary.name)
      self.sentinel = self.directory / "unrelated.txt"
      self.sentinel.write_text("keep me", encoding="utf-8")
      bin_directory = self.directory / "bin"
      bin_directory.mkdir()
      for name in ["xcodebuild", "xcrun"]:
        fixture = Path(__file__).parent / "fixtures" / f"{name}.py"
        executable = bin_directory / name
        executable.write_text(f"#!{sys.executable}\n" + fixture.read_text(encoding="utf-8"), encoding="utf-8")
        executable.chmod(0o755)
      self.environment = dict(os.environ)
      self.environment.update({
        "PATH": str(bin_directory) + os.pathsep + os.defpath,
        "TMPDIR": str(self.directory),
        "MONO_DECK_TEST_DEFAULTS": "inherited-preferences",
        "MONO_DECK_TEST_WORKSPACE": "/unrelated-workspace",
        "MONO_DECK_UNIT_TEST_HOST": "1",
        "TEST_RUNNER_MONO_DECK_UNIT_TEST_HOST": "1",
        "MONO_DECK_SCRIPT_TEST_DIRECTORY": str(self.directory),
        "MONO_DECK_SCRIPT_TEST_OUTCOME": self.outcome,
        "PYTHONDONTWRITEBYTECODE": "1",
      })
      return self
    except BaseException:
      self.temporary.cleanup()
      raise

  def __exit__(self, *_):
    try:
      if (self.directory / "invocation.json").exists():
        subprocess.run(["/usr/bin/defaults", "delete", self.suite()],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        preferences = Path.home() / "Library" / "Preferences" / f"{self.suite()}.plist"
        if preferences.exists():
          with preferences.open("rb") as file:
            if plistlib.load(file) != {}:
              raise RuntimeError(f"Could not remove test preferences: {preferences}")
          preferences.unlink()
    finally:
      self.temporary.cleanup()

  def run(self, test_filter="MonoDeckTests", *arguments):
    process = subprocess.Popen(
      [sys.executable, str(ROOT / "script" / "run_tests.py"), "--filter", test_filter, "--", *arguments],
      cwd=ROOT, env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
      text=True, start_new_session=True)
    try:
      output, _ = process.communicate(timeout=20)
      return subprocess.CompletedProcess(process.args, process.returncode, output)
    finally:
      if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
          process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
          os.killpg(process.pid, signal.SIGKILL)
          process.communicate(timeout=5)

  def invocation(self):
    return json.loads((self.directory / "invocation.json").read_text(encoding="utf-8"))

  def session(self):
    return Path(self.invocation()["environment"]["MONO_DECK_TEST_SESSION_DIRECTORY"])

  def suite(self):
    suite = self.invocation()["environment"]["MONO_DECK_TEST_DEFAULTS"]
    prefix, separator, suffix = suite.partition(".")
    if prefix != "MonoDeckTests" or separator != "." or str(uuid.UUID(suffix)) != suffix:
      raise ValueError(f"Unexpected test preferences domain: {suite}")
    return suite

  def defaults_exist(self):
    return subprocess.run(["/usr/bin/defaults", "read", self.suite()], capture_output=True,
                          timeout=5).returncode == 0


if __name__ == "__main__":
  unittest.main()
