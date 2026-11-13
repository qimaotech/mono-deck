import json
import os
from pathlib import Path
import subprocess
import sys
import time


base = Path(os.environ["MONO_DECK_SCRIPT_TEST_DIRECTORY"])
environment = {
  key: value for key, value in os.environ.items()
  if key.startswith(("MONO_DECK_TEST_", "TEST_RUNNER_MONO_DECK_TEST_"))
  or key in ("MONO_DECK_UNIT_TEST_HOST", "TEST_RUNNER_MONO_DECK_UNIT_TEST_HOST", "TMPDIR", "TEST_RUNNER_TMPDIR")
}
(base / "invocation.json").write_text(
  json.dumps({"arguments": sys.argv[1:], "environment": environment}), encoding="utf-8")
subprocess.run(["/usr/bin/defaults", "write", os.environ["MONO_DECK_TEST_DEFAULTS"], "marker", "test"],
               check=True, timeout=5)
Path(sys.argv[sys.argv.index("-resultBundlePath") + 1]).mkdir()
outcome = os.environ["MONO_DECK_SCRIPT_TEST_OUTCOME"]
if outcome == "cleanup-failed":
  (Path(os.environ["MONO_DECK_TEST_SESSION_DIRECTORY"]) / "hosts" / "identity.json").write_text(
    "{}", encoding="utf-8")
if outcome == "waiting":
  helper = subprocess.Popen(["/bin/sleep", "30"])
  # The Swift cancellation test uses this atomic write as its readiness signal.
  temporary = base / "helper.pid.tmp"
  temporary.write_text(str(helper.pid), encoding="utf-8")
  temporary.replace(base / "helper.pid")
  time.sleep(30)
sys.exit(65 if outcome == "failed" else 0)
