#!/bin/sh
set -eu
# Xcode Cloud invokes this after each action, including macOS builds.
# Only a completed iOS archive can establish the actual uploaded icon state.
if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ] || [ "${CI_PRODUCT_PLATFORM:-}" != "iOS" ]; then
    echo 'Compiled iOS icon check: no iOS archive in this action.'
    exit 0
fi
if [ -z "${CI_ARCHIVE_PATH:-}" ]; then
    echo 'Compiled iOS icon check failed: CI_ARCHIVE_PATH is missing.' >&2
    exit 1
fi
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 "$SCRIPT_DIR/verify_ios_icon.py" \
    --archive "$CI_ARCHIVE_PATH" \
    --expected-bundle-id SA.StockSage
