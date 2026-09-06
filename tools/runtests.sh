#!/usr/bin/env bash
# Execute the StockSageTests suite WITHOUT xcodebuild: build the app module as a testable dylib (macOS),
# link StockSageTests + a Swift Testing runner against it, run under a throwaway HOME.
# Usage: tools/runtests.sh [repo_dir] [--build-only] [swift-testing args, e.g. --filter Catalyst --no-parallel]
# Needs a repo_dir argument (or "." ) whenever you pass swift-testing args.
set -uo pipefail
REPO="${1:-$(cd "$(dirname "$0")/.." && pwd)}"; [ $# -gt 0 ] && shift
BUILD_ONLY=0; if [ "${1:-}" = "--build-only" ]; then BUILD_ONLY=1; shift; fi
DEV=/Applications/Xcode.app/Contents/Developer; TC="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin"
SDK="$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"; TGT=arm64-apple-macosx26.5
FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"; PLUG="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
OUT="${TMPDIR:-/tmp}/stocksage_testrun/$(basename "$REPO")"; mkdir -p "$OUT"; CACHE="${TMPDIR:-/tmp}/stocksage_mcache_macos"
COMMON=(-swift-version 6 -default-isolation MainActor -strict-concurrency=complete -D DEBUG
  -enable-upcoming-feature MemberImportVisibility -enable-upcoming-feature InferIsolatedConformances
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferSendableFromCaptures
  -enable-upcoming-feature DisableOutwardActorInference -enable-upcoming-feature GlobalActorIsolatedTypesUsability
  -sdk "$SDK" -target "$TGT" -module-cache-path "$CACHE")
cd "$REPO" || exit 2
ENTRY=$(grep -rl "^@main" StockSage/Sources | head -1); echo "[runtests] excluding entry file: $ENTRY"
if grep -rn "\bStockSageApp\b" StockSage/Sources | grep -v "^$ENTRY" | grep -q .; then echo "[runtests] WARNING: other files reference StockSageApp"; fi
t0=$(date +%s)
find StockSage/Sources -name '*.swift' ! -path "*/$ENTRY" -print0 | xargs -0 "$TC/swiftc" -emit-library -emit-module -parse-as-library -enable-testing \
  -module-name StockSage "${COMMON[@]}" -o "$OUT/libStockSage.dylib" -emit-module-path "$OUT/StockSage.swiftmodule" \
  -Xlinker -install_name -Xlinker "@rpath/libStockSage.dylib" 2>"$OUT/lib.log"
r=$?; grep -E "error:" "$OUT/lib.log" | grep -v "^\s*|" | head -20; echo "[runtests] library rc=$r in $(( $(date +%s)-t0 ))s"; [ $r -eq 0 ] || exit 3
cat > "$OUT/main.swift" <<'SW'
import Foundation
import Testing
@main struct StockSageTestRunner {
    static func main() async {
        let rc: CInt = await Testing.__swiftPMEntryPoint(passing: nil)
        exit(rc)
    }
}
SW
t1=$(date +%s)
find StockSageTests -name '*.swift' -print0 | xargs -0 "$TC/swiftc" -parse-as-library -module-name StockSageTests "${COMMON[@]}" \
  "$OUT/main.swift" -I "$OUT" -L "$OUT" -lStockSage -F "$FW" -framework Testing -framework SwiftUI -plugin-path "$PLUG" \
  -Xlinker -rpath -Xlinker "$OUT" -Xlinker -rpath -Xlinker "$FW" -o "$OUT/testrunner" 2>"$OUT/tests.log"
r=$?; grep -E "error:" "$OUT/tests.log" | grep -v "^\s*|" | head -20; echo "[runtests] runner rc=$r in $(( $(date +%s)-t1 ))s -> $OUT/testrunner"; [ $r -eq 0 ] || exit 4
[ $BUILD_ONLY -eq 1 ] && exit 0
export HOME="${TMPDIR:-/tmp}/stocksage_testhome"; mkdir -p "$HOME/Library/Application Support"
echo "[runtests] running with HOME=$HOME args: $*"; t2=$(date +%s)
"$OUT/testrunner" "$@" 2>&1 | tee "$OUT/run.log" | grep -E "Test run|✘|failed|Suite .* (passed|failed)|Test .* recorded an issue|Expectation failed|Issue recorded" | head -80
echo "[runtests] exit=${PIPESTATUS[0]} in $(( $(date +%s)-t2 ))s (full log: $OUT/run.log)"
