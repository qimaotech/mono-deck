import os
import signal
import subprocess
import time


def stop_process(process):
  try:
    stop_process_group(process.pid, process)
    process.wait(timeout=3)
  finally:
    for stream in [process.stdin, process.stdout, process.stderr]:
      if stream is not None:
        stream.close()


def stop_process_group(group, process=None):
  if group <= 1 or group == os.getpgrp():
    raise ValueError(f"Not an isolated test process group: {group}")
  for number in [signal.SIGTERM, signal.SIGKILL]:
    if process is not None:
      process.poll()
    if not group_exists(group):
      return
    try:
      os.killpg(group, number)
    except ProcessLookupError:
      return
    except PermissionError:
      if group_exists(group):
        raise
      return
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
      if process is not None:
        process.poll()
      if not group_exists(group):
        return
      time.sleep(0.01)
  raise subprocess.TimeoutExpired(f"process group {group}", 6)


def group_exists(group):
  try:
    os.killpg(group, 0)
    return True
  except ProcessLookupError:
    return False
  except PermissionError:
    # macOS may deny a signal probe after the last owned group member exits.
    groups = subprocess.check_output(["/bin/ps", "-axo", "pgid="], text=True, timeout=3).split()
    return str(group) in groups
