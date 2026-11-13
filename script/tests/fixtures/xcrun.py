import json
import os
import sys


outcome = os.environ["MONO_DECK_SCRIPT_TEST_OUTCOME"]
if sys.argv[1] == "swift":
  sys.exit(1)
print(json.dumps({"totalTestCount": 0 if outcome == "zero" else 2,
                  "skippedTests": 2 if outcome == "skipped" else 0}))
