#!/usr/bin/env bash
# Use the real app test host: its XCTest detection disables owner-state startup.
# Usage: tools/runtests.sh [repo_dir] [--build-only] [--filter ExactSuite] [--no-parallel]
# Xcode unavailable? tools/gate.sh provides compile checks only.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
if [ $# -gt 0 ] && [[ "$1" != -* ]]; then REPO=$1; shift; fi
action=test
test_options=(-parallel-testing-enabled NO)
while [ $# -gt 0 ]; do
  case "$1" in
    --build-only) action=build-for-testing; shift ;;
    --no-parallel) shift ;; # All runs are serial.
    --filter)
      if [ $# -lt 2 ] || [[ ! "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo '--filter requires an exact test suite identifier, not a regex.' >&2; exit 2
      fi
      test_options+=("-only-testing:StockSageTests/$2"); shift 2 ;;
    *) echo 'Usage: tools/runtests.sh [repo_dir] [--build-only] [--filter ExactSuite] [--no-parallel]' >&2; exit 2 ;;
  esac
done
cd "$REPO" || exit 2
OUT=$(mktemp -d "${TMPDIR:-/tmp}/stocksage-tests.XXXXXX") || exit 2
echo "[runtests] native $action; artifacts: $OUT"
env -u STOCKSAGE_PAPER_DIAGNOSTICS -u STOCKSAGE_PAPER_RESPONSE_REPLAY -u STOCKSAGE_PAPER_PROCESS_DEATH \
  -u SIMCTL_CHILD_STOCKSAGE_PAPER_DIAGNOSTICS -u SIMCTL_CHILD_STOCKSAGE_PAPER_RESPONSE_REPLAY \
  -u SIMCTL_CHILD_STOCKSAGE_PAPER_PROCESS_DEATH \
  -u TEST_RUNNER_STOCKSAGE_PAPER_DIAGNOSTICS -u TEST_RUNNER_STOCKSAGE_PAPER_RESPONSE_REPLAY \
  -u TEST_RUNNER_STOCKSAGE_PAPER_PROCESS_DEATH \
  xcodebuild "$action" -project StockSage.xcodeproj -scheme StockSage -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -jobs 4 \
  -derivedDataPath "$OUT/derived" -resultBundlePath "$OUT/result.xcresult" \
  -skip-testing:StockSageTests/CalibrationPersistRunTests \
  -skip-testing:StockSageTests/LiveUniverseVerificationTests \
  -skip-testing:StockSageTests/StrategyBaselineMeasurementTests \
  "${test_options[@]}" >"$OUT/run.log" 2>&1
result=$?
if [ "$result" -eq 0 ] && [ "$action" = test ]; then
  xcrun xcresulttool get test-results summary --path "$OUT/result.xcresult" --format json >"$OUT/summary.json"
  result=$?
  if [ "$result" -eq 0 ]; then
    python3 - "$OUT/summary.json" "$OUT/run.log" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    summary = json.load(source)
passed, failed = summary.get("passedTests", 0), summary.get("failedTests", 0)
print(f"[runtests] {passed} passed, {failed} failed, {summary.get('skippedTests', 0)} skipped")
with open(sys.argv[2], errors="replace") as source:
    log = source.read()
# These native warnings are not included in xcresult's runtimeWarnings summary.
diagnostics = [message for message in (
    "It's not legal to call -layoutSubtreeIfNeeded",
    "Application performed a reentrant operation in its NSTableView delegate",
    "Publishing changes from within view updates",
    "Unable to simultaneously satisfy constraints",
) if message in log]
for message in diagnostics:
    print(f"[runtests] native UI diagnostic: {message}")
sys.exit(0 if summary.get("result") == "Passed" and passed > 0 and failed == 0 and not diagnostics else 1)
PY
    result=$?
  fi
fi
tail -8 "$OUT/run.log"
echo "[runtests] exit=$result (full log: $OUT/run.log)"
exit "$result"
