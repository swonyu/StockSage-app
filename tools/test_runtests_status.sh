#!/usr/bin/env bash
# Exercise the actual native wrapper with fake tools; no compiler, app or owner state.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
probe_dir=$(mktemp -d /private/tmp/stocksage-runner-status.XXXXXX)
trap 'rm -rf "$probe_dir"' EXIT
mkdir "$probe_dir/bin"
cat > "$probe_dir/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$PROBE_ARGS"
test -z "${STOCKSAGE_PAPER_DIAGNOSTICS:-}${STOCKSAGE_PAPER_RESPONSE_REPLAY:-}${STOCKSAGE_PAPER_PROCESS_DEATH:-}${SIMCTL_CHILD_STOCKSAGE_PAPER_DIAGNOSTICS:-}${SIMCTL_CHILD_STOCKSAGE_PAPER_RESPONSE_REPLAY:-}${SIMCTL_CHILD_STOCKSAGE_PAPER_PROCESS_DEATH:-}" || exit 99
test -z "${TEST_RUNNER_STOCKSAGE_PAPER_DIAGNOSTICS:-}${TEST_RUNNER_STOCKSAGE_PAPER_RESPONSE_REPLAY:-}${TEST_RUNNER_STOCKSAGE_PAPER_PROCESS_DEATH:-}" || exit 99
printf '%s\n' "${PROBE_LOG:-}"
exit "$PROBE_EXIT"
STUB
cat > "$probe_dir/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
printf '{"result":"Passed","passedTests":%s,"failedTests":0,"skippedTests":0}\n' "$PROBE_PASSED"
STUB
chmod +x "$probe_dir/bin/xcodebuild" "$probe_dir/bin/xcrun"
for scenario in success failure empty build layout table publication constraints; do
    expected=0; native_exit=0; passed=1; log=''; args=(--filter StockSageQuoteCacheTests --no-parallel)
    case "$scenario" in
        failure) expected=65; native_exit=65 ;;
        empty) expected=1; passed=0 ;;
        build) args=(--build-only) ;;
        layout) expected=1; log="It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out." ;;
        table) expected=1; log='WARNING: Application performed a reentrant operation in its NSTableView delegate.' ;;
        publication) expected=1; log='Publishing changes from within view updates is not allowed.' ;;
        constraints) expected=1; log='Unable to simultaneously satisfy constraints.' ;;
    esac
    result=0
    PATH="$probe_dir/bin:$PATH" TMPDIR="$probe_dir" PROBE_ARGS="$probe_dir/args" \
      PROBE_EXIT="$native_exit" PROBE_PASSED="$passed" PROBE_LOG="$log" STOCKSAGE_PAPER_PROCESS_DEATH=fixture \
      STOCKSAGE_PAPER_DIAGNOSTICS=fixture STOCKSAGE_PAPER_RESPONSE_REPLAY=fixture \
      SIMCTL_CHILD_STOCKSAGE_PAPER_DIAGNOSTICS=fixture SIMCTL_CHILD_STOCKSAGE_PAPER_RESPONSE_REPLAY=fixture \
      SIMCTL_CHILD_STOCKSAGE_PAPER_PROCESS_DEATH=fixture \
      TEST_RUNNER_STOCKSAGE_PAPER_DIAGNOSTICS=fixture TEST_RUNNER_STOCKSAGE_PAPER_RESPONSE_REPLAY=fixture \
      TEST_RUNNER_STOCKSAGE_PAPER_PROCESS_DEATH=fixture \
      bash "$repo/tools/runtests.sh" "$repo" "${args[@]}" >"$probe_dir/output" 2>&1 || result=$?
    test "$result" -eq "$expected" || { echo "$scenario: expected exit $expected, got $result"; exit 1; }
    if [ "$scenario" = build ]; then
        test "$(head -1 "$probe_dir/args")" = build-for-testing
    else
        test "$(head -1 "$probe_dir/args")" = test
        grep -q -- '-only-testing:StockSageTests/StockSageQuoteCacheTests' "$probe_dir/args"
    fi
    grep -q -- '-skip-testing:StockSageTests/LiveUniverseVerificationTests' "$probe_dir/args"
done
test "$(find "$probe_dir" -maxdepth 1 -type d -name 'stocksage-tests.*' | wc -l | tr -d ' ')" -eq 8
result=0
bash "$repo/tools/runtests.sh" "$repo" --filter '.*' >/dev/null 2>&1 || result=$?
test "$result" -eq 2
echo 'native runner status, isolation flags, unique artifacts, empty-run and native diagnostic checks ok'
