#!/usr/bin/env bash
# Invalid modes must fail without compiling or creating gate artifacts.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
probe_dir=$(mktemp -d /private/tmp/stocksage-gate-args.XXXXXX)
trap 'rm -rf "$probe_dir"' EXIT
result=0
TMPDIR="$probe_dir" bash "$repo/tools/gate.sh" "$repo" typo >"$probe_dir/output" 2>&1 || result=$?
test "$result" -eq 2
grep -q 'Usage:' "$probe_dir/output"
test "$(find "$probe_dir" -type f | wc -l | tr -d ' ')" -eq 1
echo 'compile-gate argument self-check ok'
