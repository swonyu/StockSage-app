#!/usr/bin/env python3
"""Offline transport regression. Exit 1 reproduces the received-byte limit defect.

Pass the exact StockSageBenzinga.swift file to review. The only injected production
seam is URLSessionConfiguration.protocolClasses; all requests use URLProtocol.
No application launch, network connection, settings access, or Keychain operation.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    raw = args.source.read_bytes()
    source = raw.decode()
    marker = "let configuration = URLSessionConfiguration.ephemeral"
    if source.count(marker) != 1:
        parser.error("Transport changed: review the injection seam before running")
    source = source.replace(marker, marker + "\n        configuration.protocolClasses = [ReviewProtocol.self]")
    harness = Path(__file__).with_name("benzinga_stream_review.swift")
    print("reviewed_sha256=" + hashlib.sha256(raw).hexdigest(), flush=True)
    with tempfile.TemporaryDirectory(prefix="benzinga-offline-review-") as temporary:
        directory = Path(temporary)
        injected = directory / "Benzinga+ReviewProtocol.swift"
        injected.write_text(source)
        executable = directory / "stream-review"
        built = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                                str(injected), str(harness), "-o", str(executable)], timeout=30)
        if built.returncode:
            return built.returncode
        return subprocess.run([str(executable)], timeout=15).returncode


if __name__ == "__main__":
    raise SystemExit(main())
