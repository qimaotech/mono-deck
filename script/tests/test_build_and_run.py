import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parents[1]


class BuildAndRunScriptTests(unittest.TestCase):
  def test_verification_preserves_existing_instances(self):
    result = self.trace_logs(["--verify"])
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertTrue(result.stdout.startswith("build\n"))
    self.assertIn("launch:", result.stdout)
    self.assertNotIn("stop", result.stdout)
    self.assertNotIn("log:", result.stdout)

  def test_logging_uses_only_the_launched_instance(self):
    for mode, mock in [("--logs", False), ("--telemetry", True)]:
      with self.subTest(mode=mode, mock=mock):
        arguments = [mode] + (["--mock", "linked-worktree-selected"] if mock else [])
        result = self.trace_logs(arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.startswith("stop\n"), not mock)
        self.assertIn("launch:--activate", result.stdout)
        invocations = [line for line in result.stdout.splitlines() if line.startswith("log:")]
        self.assertEqual(invocations, [
          'log:--process 12345 --predicate subsystem == "fun.armantang.MonoDeck"'
          if mode == "--telemetry" else "log:--process 12345"
        ])

  def test_logging_rejects_missing_or_ambiguous_instance_ids(self):
    for output in ["", "App instance PID: 12345\nApp instance PID: 67890"]:
      with self.subTest(output=output):
        result = self.trace_logs(["--logs"], output=output)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn("log:", result.stdout)
        self.assertIn("Could not identify the launched App instance", result.stderr)

  def test_failed_launch_does_not_start_logging_even_when_it_reports_a_pid(self):
    result = self.trace_logs(["--telemetry"], status=23)
    self.assertEqual(result.returncode, 23, result.stderr)
    self.assertIn("App instance PID: 12345", result.stdout)
    self.assertNotIn("log:", result.stdout)

  def trace_logs(self, arguments, output="App instance PID: 12345", status=0):
    with tempfile.TemporaryDirectory(prefix="mono-deck log tests ") as temporary:
      directory = Path(temporary)
      environment = dict(os.environ, TMPDIR=temporary, PYTHONDONTWRITEBYTECODE="1")
      driver = r"""
        source "$1"
        launch_output="$2"
        launch_status="$3"
        stop_app() { echo stop; }
        build_app() { echo build; }
        launch_verified_app() {
          echo "launch:$1"
          printf '%s\n' "$launch_output"
          return "$launch_status"
        }
        stream_log() { printf 'log:%s\n' "$*"; }
        main "${@:4}"
      """
      command = [
        "/bin/bash", "-c", driver, "mono-deck-log-tests",
        str(SCRIPT_DIRECTORY / "build_and_run.sh"), output, str(status),
      ] + arguments
      process = subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 start_new_session=True)
      try:
        stdout, stderr = process.communicate(timeout=10)
      except BaseException:
        stop_process(process)
        process.communicate(timeout=3)
        raise
      self.assertEqual(list(directory.iterdir()), [])
      return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


@unittest.skipUnless(sys.platform == "darwin", "Mock process lookup requires macOS")
class BuildAndRunLifecycleTests(unittest.TestCase):
  def test_interrupted_verification_keeps_its_live_instance_and_data(self):
    for number, prints_pid in [(signal.SIGINT, True), (signal.SIGTERM, False)]:
      with self.subTest(signal=number, prints_pid=prints_pid), LifecycleSession() as session:
        own = session.start_app(session.workspace)
        unrelated = session.start_app(session.other_workspace)
        condition = "true" if prints_pid else "false"
        result = session.run_script("--verify", number=number, pid=own.pid, overrides=f"""
          launch_verified_app() {{
            if {condition}; then echo "App instance PID: $test_pid"; fi
            if {condition}; then kill -"$test_signal" "$$"; else kill -"$test_signal" -- "-$$"; fi
            /bin/sleep 0.05
          }}
        """)
        self.assertEqual(result.returncode, 128 + number, result.stderr)
        self.assertIsNone(own.poll())
        self.assertIn(f"App instance PID: {own.pid}", result.stdout)
        self.assertEqual((session.workspace / "sample.txt").read_text(), "own")
        self.assert_unrelated_is_intact(session, unrelated)

  def test_interrupted_verification_without_an_instance_cleans_only_its_data(self):
    with LifecycleSession() as session:
      unrelated = session.start_app(session.other_workspace)
      result = session.run_script("--verify", overrides="""
        launch_verified_app() { kill -"$test_signal" -- "-$$"; /bin/sleep 0.05; }
      """)
      self.assertEqual(result.returncode, 128 + signal.SIGTERM, result.stderr)
      self.assertFalse(session.directory.exists())
      self.assert_unrelated_is_intact(session, unrelated)

  def test_debugger_exit_without_run_cleans_only_its_data(self):
    with LifecycleSession() as session:
      unrelated = session.start_app(session.other_workspace)
      result = session.run_script("--debug", status=1, overrides='lldb() { return "$test_status"; }')
      self.assertEqual(result.returncode, 1, result.stderr)
      self.assertFalse(session.directory.exists())
      self.assert_unrelated_is_intact(session, unrelated)

  def test_completed_launch_keeps_its_live_instance_for_explicit_quit(self):
    for mode in ["--debug", "--verify"]:
      with self.subTest(mode=mode), LifecycleSession() as session:
        own = session.start_app(session.workspace)
        unrelated = session.start_app(session.other_workspace)
        result = session.run_script(mode, pid=own.pid, overrides="""
          lldb() { return 0; }
          launch_verified_app() { echo "App instance PID: $test_pid"; }
        """)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"App instance PID: {own.pid}", result.stdout)
        self.assertNotIn(f"App instance PID: {unrelated.pid}", result.stdout)
        self.assertIsNone(own.poll())
        self.assertTrue(session.workspace.exists())
        self.assert_unrelated_is_intact(session, unrelated)

  def test_stopping_log_collection_keeps_its_app_and_removes_temporary_capture(self):
    with LifecycleSession() as session:
      own = session.start_app(session.workspace)
      unrelated = session.start_app(session.other_workspace)
      result = session.run_script("--logs", number=signal.SIGINT, pid=own.pid, overrides="""
        launch_verified_app() { echo "App instance PID: $test_pid"; }
        stream_log() { kill -"$test_signal" -- "-$$"; /bin/sleep 0.05; }
      """)
      self.assertEqual(result.returncode, 128 + signal.SIGINT, result.stderr)
      self.assertIsNone(own.poll())
      self.assertEqual(list(session.base.glob("mono-deck-app-launch.*")), [])
      self.assert_unrelated_is_intact(session, unrelated)

  def test_completed_verification_does_not_keep_data_for_an_exited_instance(self):
    with LifecycleSession() as session:
      exited = session.start_app(session.workspace)
      stop_process(exited)
      unrelated = session.start_app(session.other_workspace)
      result = session.run_script("--verify", status=1, pid=exited.pid, overrides="""
        launch_verified_app() { echo "App instance PID: $test_pid"; return "$test_status"; }
      """)
      self.assertEqual(result.returncode, 1, result.stderr)
      self.assertFalse(session.directory.exists())
      self.assert_unrelated_is_intact(session, unrelated)

  def test_unknown_process_state_preserves_data_and_the_original_failure(self):
    with LifecycleSession() as session:
      result = session.run_script("--debug", status=1, overrides="""
        lldb() { return "$test_status"; }
        find_mock_app() { return 2; }
      """)
      self.assertEqual(result.returncode, 1, result.stderr)
      self.assertTrue(session.workspace.exists())
      self.assertIn("Could not confirm mock App state", result.stderr)

  def test_process_lookup_matches_executable_and_whole_workspace_argument(self):
    with LifecycleSession() as session:
      session.start_app(session.workspace.with_name(session.workspace.name + ".other"))
      absent = session.lookup("/bin/bash")
      self.assertEqual(absent.returncode, 1, absent.stderr)
      own = session.start_app(session.workspace)
      found = session.lookup("/bin/bash")
      self.assertEqual(found.returncode, 0, found.stderr)
      self.assertEqual(found.stdout.strip(), f"App instance PID: {own.pid}")
      other_executable = session.lookup("/bin/sleep")
      self.assertEqual(other_executable.returncode, 1, other_executable.stderr)

  def assert_unrelated_is_intact(self, session, process):
    self.assertIsNone(process.poll())
    self.assertEqual((session.other_workspace / "sample.txt").read_text(), "unrelated")


class LifecycleSession:
  def __enter__(self):
    self.base = Path(tempfile.mkdtemp(prefix="mono-deck lifecycle tests "))
    self.processes = []
    self.environment = dict(os.environ, TMPDIR=str(self.base), PYTHONDONTWRITEBYTECODE="1")
    try:
      self.directory = self.allocate()
      self.other_directory = self.allocate()
      self.workspace = self.directory / "example-workspace"
      self.other_workspace = self.other_directory / "example-workspace"
      for workspace, contents in [(self.workspace, "own"), (self.other_workspace, "unrelated")]:
        workspace.mkdir()
        (workspace / "sample.txt").write_text(contents)
      return self
    except BaseException:
      self.cleanup()
      raise

  def __exit__(self, *_):
    self.cleanup()

  def run_script(self, mode, overrides, number=signal.SIGTERM, status=0, pid=0):
    driver = """
      source "$1"
      MOCK_DIRECTORY="$2"
      TMPDIR="${MOCK_DIRECTORY%/*}"
      APP_BINARY=/bin/bash
      test_pid="$3"
      test_signal="$4"
      test_status="$5"
      build_app() { :; }
      stream_log() { return "$test_status"; }
    """ + overrides + '\nmain "${@:6}"\n'
    return self.run([
      "/bin/bash", "-c", driver, "mono-deck-lifecycle-tests",
      str(SCRIPT_DIRECTORY / "build_and_run.sh"), str(self.directory), str(pid), str(int(number)),
      str(status), mode, "--mock", "linked-worktree-selected",
    ])

  def start_app(self, workspace):
    ready = self.base / f"app-{len(self.processes)}.ready"
    process = subprocess.Popen([
      "/bin/bash", "-c",
      'trap \'exit 0\' TERM; : > "$1"; while :; do /bin/sleep 0.05; done',
      "mono-deck-lifecycle-app", str(ready), "--mock", "linked-worktree-selected",
      "--mock-workspace", str(workspace),
    ], env=self.environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL, start_new_session=True)
    self.processes.append(process)
    deadline = time.monotonic() + 5
    while not ready.exists():
      if process.poll() is not None:
        raise RuntimeError("Controlled App exited before becoming ready")
      if time.monotonic() >= deadline:
        raise TimeoutError("Controlled App did not become ready")
      time.sleep(0.01)
    return process

  def lookup(self, executable):
    return self.run([
      "/usr/bin/python3", "-B", str(SCRIPT_DIRECTORY / "find_mock_app.py"),
      "--executable", executable, "--workspace", str(self.workspace),
    ])

  def allocate(self):
    result = self.run([
      "/usr/bin/python3", "-B", str(SCRIPT_DIRECTORY / "prepare_mock_workspace.py"), "allocate",
    ])
    if result.returncode != 0:
      raise RuntimeError(result.stderr)
    directory = Path(result.stdout.strip())
    if directory.resolve().parent != self.base.resolve():
      raise RuntimeError(f"Mock session escaped its test directory: {directory}")
    return directory

  def run(self, arguments):
    # The script can signal -$$; isolate it from the test runner and controlled Apps.
    process = subprocess.Popen(arguments, env=self.environment, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                               start_new_session=True)
    self.processes.append(process)
    try:
      output, error = process.communicate(timeout=10)
    except BaseException:
      stop_process(process)
      process.communicate(timeout=3)
      raise
    return subprocess.CompletedProcess(arguments, process.returncode, output, error)

  def cleanup(self):
    failures = []
    for process in self.processes:
      try:
        stop_process(process)
      except (OSError, subprocess.TimeoutExpired) as error:
        failures.append(str(error))
    if failures:
      raise RuntimeError(f"Could not stop test processes; keeping {self.base}: {failures}")
    shutil.rmtree(self.base)


def stop_process(process):
  if process.poll() is not None:
    return
  try:
    os.killpg(process.pid, signal.SIGTERM)
  except ProcessLookupError:
    pass
  try:
    process.wait(timeout=3)
  except subprocess.TimeoutExpired:
    try:
      os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
      pass
    process.wait(timeout=3)


if __name__ == "__main__":
  unittest.main()
