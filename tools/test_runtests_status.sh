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
exit "$PROBE_EXIT"
STUB
cat > "$probe_dir/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
printf '{"result":"Passed","passedTests":%s,"failedTests":0,"skippedTests":0}\n' "$PROBE_PASSED"
STUB
chmod +x "$probe_dir/bin/xcodebuild" "$probe_dir/bin/xcrun"
for scenario in success failure empty build; do
    expected=0; native_exit=0; passed=1; args=(--filter StockSageQuoteCacheTests --no-parallel)
    case "$scenario" in
        failure) expected=65; native_exit=65 ;;
        empty) expected=1; passed=0 ;;
        build) args=(--build-only) ;;
    esac
    result=0
    PATH="$probe_dir/bin:$PATH" TMPDIR="$probe_dir" PROBE_ARGS="$probe_dir/args" \
      PROBE_EXIT="$native_exit" PROBE_PASSED="$passed" STOCKSAGE_PAPER_PROCESS_DEATH=fixture \
      STOCKSAGE_PAPER_DIAGNOSTICS=fixture STOCKSAGE_PAPER_RESPONSE_REPLAY=fixture \
      SIMCTL_CHILD_STOCKSAGE_PAPER_DIAGNOSTICS=fixture SIMCTL_CHILD_STOCKSAGE_PAPER_RESPONSE_REPLAY=fixture \
      SIMCTL_CHILD_STOCKSAGE_PAPER_PROCESS_DEATH=fixture \
      TEST_RUNNER_STOCKSAGE_PAPER_DIAGNOSTICS=fixture TEST_RUNNER_STOCKSAGE_PAPER_RESPONSE_REPLAY=fixture \
      TEST_RUNNER_STOCKSAGE_PAPER_PROCESS_DEATH=fixture \
      bash "$repo/tools/runtests.sh" "$repo" "${args[@]}" >"$probe_dir/output" 2>&1 || result=$?
    test "$result" -eq "$expected"
    if [ "$scenario" = build ]; then
        test "$(head -1 "$probe_dir/args")" = build-for-testing
    else
        test "$(head -1 "$probe_dir/args")" = test
        grep -q -- '-only-testing:StockSageTests/StockSageQuoteCacheTests' "$probe_dir/args"
    fi
    grep -q -- '-skip-testing:StockSageTests/LiveUniverseVerificationTests' "$probe_dir/args"
done
test "$(find "$probe_dir" -maxdepth 1 -type d -name 'stocksage-tests.*' | wc -l | tr -d ' ')" -eq 4
result=0
bash "$repo/tools/runtests.sh" "$repo" --filter '.*' >/dev/null 2>&1 || result=$?
test "$result" -eq 2
echo 'native runner status, isolation flags, unique artifacts and empty-run checks ok'
