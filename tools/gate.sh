#!/usr/bin/env bash
# StockSage compile gate while xcodebuild is licence-blocked.
# Usage: tools/gate.sh [repo_dir] [macos|ios|tests|all]   (defaults: this repo, all)
# Mirrors the pbxproj: Swift 6, SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor,
# SWIFT_APPROACHABLE_CONCURRENCY=YES (5 upcoming features), MemberImportVisibility, 26.5 targets.
# Uses -emit-module (NOT -typecheck) so SIL-stage Swift 6 isolation diagnostics run too.
# tests = swiftc -typecheck StockSageTests/*.swift against the emitted macOS module + Testing.framework.
set -uo pipefail
REPO="${1:-$(cd "$(dirname "$0")/.." && pwd)}"; MODE="${2:-all}"
if [ "$#" -gt 2 ] || [[ ! "$MODE" =~ ^(macos|ios|tests|all)$ ]]; then
  echo 'Usage: tools/gate.sh [repo_dir] [macos|ios|tests|all]' >&2
  exit 2
fi
cd "$REPO" || exit 2
DEV=$(xcode-select -p) || exit 2
TC="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin"
PLUGINS="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
OUT=$(mktemp -d "${TMPDIR:-/tmp}/stocksage_gate.XXXXXX") || exit 2
COMMON=(-swift-version 6 -default-isolation MainActor -strict-concurrency=complete -D DEBUG
  -enable-upcoming-feature MemberImportVisibility
  -enable-upcoming-feature InferIsolatedConformances
  -enable-upcoming-feature NonisolatedNonsendingByDefault
  -enable-upcoming-feature InferSendableFromCaptures
  -enable-upcoming-feature DisableOutwardActorInference
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability)
status_macos=SKIP; status_ios=SKIP; status_tests=SKIP; rc=0
emit() { # $1 platform
  local sdk tgt cache
  if [ "$1" = macos ]; then sdk="$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"; tgt=arm64-apple-macosx26.5
  else sdk="$DEV/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"; tgt=arm64-apple-ios26.5-simulator; fi
  cache="${TMPDIR:-/tmp}/stocksage_mcache_$1"
  local t0=$(date +%s)
  find StockSage/Sources -name '*.swift' -print0 | xargs -0 "$TC/swiftc" -emit-module -parse-as-library -enable-testing \
    -sdk "$sdk" -target "$tgt" "${COMMON[@]}" -module-name StockSage -module-cache-path "$cache" \
    -emit-module-path "$OUT/$1/StockSage.swiftmodule" 2>"$OUT/$1.log"
  local r=$?
  grep -E "error:" "$OUT/$1.log" | grep -v "^\s*|" | head -30
  echo "[$1] emit-module rc=$r in $(( $(date +%s) - t0 ))s (log: $OUT/$1.log)"
  return $r
}
mkdir -p "$OUT/macos" "$OUT/ios"
if [ "$MODE" = all ] || [ "$MODE" = macos ] || [ "$MODE" = tests ]; then
  if emit macos; then status_macos=OK; else status_macos=FAIL; rc=1; fi
fi
if [ "$MODE" = all ] || [ "$MODE" = ios ]; then
  if emit ios; then status_ios=OK; else status_ios=FAIL; rc=1; fi
fi
if { [ "$MODE" = all ] || [ "$MODE" = tests ]; } && [ "$status_macos" = OK ]; then
  t0=$(date +%s)
  find StockSageTests -name '*.swift' -print0 | xargs -0 "$TC/swiftc" -typecheck \
    -sdk "$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" -target arm64-apple-macosx26.5 "${COMMON[@]}" \
    -module-name StockSageTests -module-cache-path "${TMPDIR:-/tmp}/stocksage_mcache_macos" \
    -I "$OUT/macos" -F "$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
    -plugin-path "$PLUGINS" 2>"$OUT/tests.log"
  r=$?
  grep -E "error:" "$OUT/tests.log" | grep -v "^\s*|" | head -30
  echo "[tests] typecheck rc=$r in $(( $(date +%s) - t0 ))s (log: $OUT/tests.log)"
  if [ $r -eq 0 ]; then status_tests=OK; else status_tests=FAIL; rc=1; fi
elif [ "$MODE" = all ] || [ "$MODE" = tests ]; then status_tests=BLOCKED; fi
echo "GATE repo=$(basename "$REPO") macos=$status_macos ios=$status_ios tests=$status_tests"
exit $rc
