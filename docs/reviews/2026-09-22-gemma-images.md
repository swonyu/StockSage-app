# Mac and Gemma image verification — 22 September 2026

## Current connection

Read-only checks on Salman's Mac found the app configured for canonical Gemma at `http://127.0.0.1:18080`, with no listener there. LM Studio answered at 1234 but listed no Gemma model. The accessible RunPod account listed no Gemma pod and no running GPU pod. This does not establish the contents of Saleh's account. Salman's installed app metadata identifies `b0ca7ac`.

## Mac artifact

- Source: `2f711dad512a6e98199f9fac3866487223db43d8` (includes the extended-hours fix).
- `xcodebuild -project StockSage.xcodeproj -scheme StockSage -configuration Release -destination 'platform=macOS,arch=arm64' -jobs 4 build`: exit 0, isolated DerivedData and external ad hoc signing xcconfig.
- Staged source stamp: `StockSageSourceCommit`. `codesign --verify --deep --strict` passed on staged, ZIP-extracted and readonly-mounted DMG app.
- Eight file hashes matched across all three bundles; `hdiutil verify` passed.
- Executable SHA-256: `0a6f63139870f3e9fa8a632decf8adcd256fa3baedcf87e4467baa7e958d0fa9`.
- DMG: 24,055,720 bytes; SHA-256 `40f73d5b4d2f06e8487e4aeea3ad7fe1b0775fdb8b49380ec04ce53b9bd0e5aa`.
- ZIP: 18,881,489 bytes; SHA-256 `8a268d85e2a5599b2df12b66f7b8802b5d45e6f743d54a1adcc85e7f3f7f16b2`.
- Local ad hoc signature only: not Developer ID/notarized. Not installed or launched; existing app/preferences/records were not replaced.

## Native model checks

`XCODE_XCCONFIG_FILE=/tmp/stocksage-extended-hours-tests.xcconfig tools/runtests.sh . --filter StockSageRunPodGemmaTests --filter StockSageLocalModelServerTests --filter StockSageManagedModelLifecycleTests` passed with exit 0: **60 definitions / 137 executions / zero failures or skips**. Targeted UI diagnostic guard passed and xcresult runtime warnings were empty. Apple `linkd.autoShortcut` connection messages were present; this is not an all-log-warning-free claim. No live provider or model transport was used.

Result bundle: `/var/folders/qb/cnp00ynx0qg3lxyfgf4p2b4h0000gn/T/stocksage-tests.EYJV38/result.xcresult`. Logs and summary were copied to the stable artifact directory below. The earlier extended-hours 158-definition gate remains separate.

## Container checks

- Build: `docker build --platform linux/amd64 -t stocksage-gemma:20260922 deploy/gemma-runpod`, exit 0.
- Image identity: `sha256:669c422f7c4e5cb1fe1368f3c730f9d097914878eb4162914b2a16648940166c`; reported size 2,334,452,951 bytes.
- Actual binary `--version`: llama.cpp 0.4.1-dev / build 11096 / `c550d2f60`, Linux x86_64. All twenty configured server flags appear in its actual `--help`.
- `docker run --rm --network none --platform linux/amd64` startup checks: missing public key exits 64, missing NVIDIA GPU exits 69, existing corrupt model exits 65 with a stub GPU probe. No weights downloaded or model inference performed. Passing `--help` to the normal entrypoint also preserves the missing-key refusal.
- Image configuration exposes only `22/tcp`; inference binds only `127.0.0.1:8080`. Password authentication is disabled and port forwarding is restricted to that loopback service.
- A bounded 32 MiB metadata read from the pinned model revision verified GGUF v3, `gemma4`, 833 tensors and embedded template SHA-256 `6a1015c47ccfcfa67c3b772385bccee357a4d37c3cda37bd202e9047f391ab82`. Full weights were not downloaded on this Mac; the startup script verifies their full SHA-256 before serving.
- The current image uses a newer backend than the historical B300 benchmark, so no prior latency, quality or GPU-memory result is claimed for it. The image is built/exported locally, not published to a registry or deployed.

Reproduction and pinned inputs: [container README](../../deploy/gemma-runpod/README.md). Stable local artifacts: `/Users/salman/Documents/Codex/StockSage-Builds-2026-09-22/`, including `macos-build-receipt.json`, `container-receipt.json`, `connectivity-receipt.json`, native test logs and the artifact archives.

The 16 September handoff's inference profile/cohort/quality wiring is already present in production source. No duplicate implementation was added. Remaining work is installation, authorized registry publication and GPU deployment, private tunnel, actual readiness and inference verification. No research, model loading, GPU-pod start, broker operation or iOS action was performed.

Container export: **2,325,301,216 bytes**, SHA-256 `111ad1b1cab8c762483161cd8c67dfcb5625e3d8182a6011ff59353c7cbe540d`. Archive manifest and referenced config/layer entries were verified. Docker was started only for this local build and stopped afterward, restoring its initial state. No GPU pod or tunnel was started.

Guide edition 40: ten pages, all pages visually reviewed, source and PDF hashes recorded in the living guide. The prior local export remains intact; the exact owner attachment path is absent and was not replaced.
