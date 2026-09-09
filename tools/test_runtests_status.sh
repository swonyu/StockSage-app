#!/usr/bin/env bash
# Offline regression of the actual runner tail; no compiler, app or owner settings.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
probe_dir=$(mktemp -d /private/tmp/stocksage-runner-status.XXXXXX)
trap 'rm -f "$probe_dir/testrunner" "$probe_dir/run.log"; rmdir "$probe_dir"' EXIT
snippet=$(sed -n '/^"$OUT\/testrunner"/,$p' "$repo/tools/runtests.sh")
test -n "$snippet"
for expected in 0 1; do
    if [ "$expected" -eq 0 ]; then command_path=/usr/bin/true; else command_path=/usr/bin/false; fi
    ln -sf "$command_path" "$probe_dir/testrunner"
    result=0
    bash -c 'OUT=$1; t2=$(date +%s); source /dev/stdin' runner-fixture "$probe_dir" <<< "$snippet" || result=$?
    test "$result" -eq "$expected"
done
echo 'runtests exit-status self-check ok'
