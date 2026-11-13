from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "update_manifest.py"


class UpdateManifestTests(unittest.TestCase):
  def test_mismatched_installer_name_is_rejected_without_a_manifest(self):
    with tempfile.TemporaryDirectory(prefix="mono-deck manifest tests ") as temporary:
      installer = Path(temporary) / "MonoDeck-2.0.0-arm64.dmg"
      installer.write_bytes(b"abc")
      result = self.run_manifest("v3.0.0", installer)
      self.assertNotEqual(result.returncode, 0)
      self.assertEqual(result.stdout, "")
      self.assertIn("Installer filename does not match the release tag.", result.stderr)

  def test_empty_installer_is_rejected_without_a_manifest(self):
    with tempfile.TemporaryDirectory(prefix="mono-deck manifest tests ") as temporary:
      installer = Path(temporary) / "MonoDeck-2.0.0-arm64.dmg"
      installer.write_bytes(b"")
      result = self.run_manifest("v2.0.0", installer)
      self.assertNotEqual(result.returncode, 0)
      self.assertEqual(result.stdout, "")
      self.assertIn("Installer is empty.", result.stderr)

  def run_manifest(self, tag, installer):
    return subprocess.run(
      [sys.executable, "-B", str(SCRIPT), tag, str(installer)],
      text=True, capture_output=True, timeout=10,
    )
