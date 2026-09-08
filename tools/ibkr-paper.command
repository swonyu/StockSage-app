#!/bin/bash
set -euo pipefail
relay_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
relay_python="$relay_root/.research/ibkr-venv/bin/python"
if [[ ! -x "$relay_python" ]]; then
    printf '%s\n' 'Install the isolated environment described in tools/ibkr_paper_relay.md first.' >&2
    exit 1
fi
if [[ $# -eq 0 ]]; then set -- run; fi
exec "$relay_python" "$relay_root/tools/ibkr_paper_relay.py" "$@"
