# Missing-model recovery

Owner request: download the model when missing, using the current recommended version.

## Implementation contract

- Reuse LM Studio's native download manager, not a new weight-file downloader.
- A successful native inventory distinguishes missing from unloaded, wrong quantization,
  offline, unauthorized and unsupported-server states. Passive connection checks remain read-only.
- Actual AI requests may prepare the recommended local Mac profile when external access is
  enabled. One shared job downloads the latest available revision of
  `mlx-community/Qwen3.5-9B-6bit`; this does not authorize arbitrary newer model families,
  larger weights or a quality downgrade. Custom/Ollama/remote settings are not rewritten.
- Show native byte progress and actionable errors in model settings. Recheck inventory
  after completion; download completion alone is not inference or quality verification.
- Retain the native job ID across restart. An ambiguous POST never automatically repeats.
  Native downloads outlive the requesting research operation and may outlive StockSage;
  pause/cancel them in LM Studio (no cancellation REST endpoint is documented).
- Do not replay old stock evidence after a potentially long download. Retry research with
  current facts. Preserve the installed model and fine-tuned 27B rollback files.

## Sequence and regression checks

1. Reproduce the unloaded/missing inventory distinction with an offline transport.
2. Implement native inventory, shared acquisition state, explicit AI-use integration and
   the existing model-settings progress/recovery controls.
3. Verify missing/present/malformed/auth failures, wrong format/bit depth, progress bounds,
   duplicate prevention, restart, unknown acceptance, policy/settings changes and completion.
4. Run serial macOS/iPhone tests; inspect the changed model controls without owner-data edits.

## Sources and local observations

- https://lmstudio.ai/docs/developer/rest/download — POST `/api/v1/models/download`.
- https://lmstudio.ai/docs/developer/rest/download-status — GET job status; read through
  the official HTML when the browser extraction timed out.
- https://lmstudio.ai/docs/developer/rest/list — downloaded inventory and quantization.
- https://huggingface.co/mlx-community/Qwen3.5-9B-6bit — current compatible artifact.
- LM Studio 0.4.24+1 currently reports the 6-bit MLX 9B already installed (8,215,256,416
  bytes). No real missing-model download is needed on this Mac to implement the feature.

## Quit and request ownership

Normal macOS Quit stops new inference, cancels transport and the assessment busy slot,
and invalidates captured request owners. It unloads only the selected model's loaded
instances on a recognized loopback LM Studio/Ollama endpoint, then checks the inventory.
Other models, the server application, downloaded weights and historical records remain.
The cleanup has an eight-second ceiling. An unconfirmed unload offers Quit Anyway or
Keep StockSage Open; the latter creates a fresh transport and request revision. Force Quit
and an OS kill cannot execute this cleanup. Native downloads may continue in LM Studio.

The strict 9B profile also verifies the responding instance's loaded context before
publishing its buffered answer. That check shares the original deadline, cancellation
and settings owner; it does not extend the caller's timeout or start another model load.

Sources: [LM Studio unload](https://lmstudio.ai/docs/developer/rest/unload),
[Ollama generate/unload](https://docs.ollama.com/api/generate), and
[AppKit termination delegate](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)).

## Research screenshots added by the owner

The first screenshot showed a stopped preflight with zero results. Reproduction proved
that both explicit Stop and eligibility invalidation falsely claimed completed results
were retained. The original event that interrupted the owner's run is not recoverable
from that screenshot; do not claim that a particular key or setting caused it.

The runner now reports actual retained counts, differentiates Stop from fixed-text
settings/access reasons, and preserves model-setup/download guidance. No publication
guard or trading threshold was loosened. Download completion requires a fresh manual run.

The second screenshot and installed-app inspection showed an interior blank toolbar strip.
Moving the horizon controls into one scroll root alone passed tests but **failed native
visual verification**: the strip moved upward and covered the selector. The corrected
layout places the inspector outside the complete desktop NavigationSplitView, not under
the feed banner. The panel uses one scroll surface/padding boundary; iPhone retains its
parent scroll and sheet. An observing detail consumer keeps an open inspector current when
results arrive without refreshing the entire market workspace. Placement follows
[Apple's inspector guidance](https://developer.apple.com/videos/play/wwdc2023/10161/).

## Verification and installed-build receipt

- Artifacts: `/private/tmp/stocksage-model-download-20260912.C8gcfs`.
- Initial unloaded-inventory regression failed before implementation.
- Accepted-download/policy-change receipt regression failed before the receipt fix.
- `screenshot-red3`: 29 tests, 2 suites, 7 expected issues (zero-result stop messages and
  a stalled post-response inventory check extending the original deadline).
- `green5`: 104 tests, 4 suites passed after the lifecycle/deadline/message fixes.
- First full gates: Mac 2,380 tests / 227 suites and iPhone simulator 2,300 / 223 passed;
  these did not prove the gray-strip fix, which failed subsequent live visual inspection.
- Window-level layout gates: Mac 2,380 / 227 and iPhone 2,300 / 223 passed. Source review
  then caught the newly separated inspector's observation gap.
- `detail-red`: 48 tests / 1 suite with 1 expected failure. The same mounted inspector's
  pixels stayed unchanged when a held synthetic research result arrived without reselection.
  The detail now observes its supplied research instance directly.
- A compile-only failure in the first screenshot test and a zero-selected-tests invocation
  were corrected; neither is counted as behavioral verification.
- Final `release-mac.log`: **2,381 tests / 227 suites passed**, 85.597 seconds,
  including `openResearchDetailUpdatesWithoutReselectionOrRemount()` (0.393 seconds).
- Final `release-ios.log`: **2,300 tests / 223 suites passed**, 69.395 seconds.
  Both commands exited 0 with `TEST SUCCEEDED`. These are executed gates, not typechecks.
  Toolchain: Xcode 26.6 on macOS 27; iPhone 17 Pro (gate), iOS 26.5 simulator
  `3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA`. No physical-iPhone or Xcode 27 SDK claim.
  Canonical exclusions only: `CalibrationPersistRunTests`,
  `LiveUniverseVerificationTests`, `StrategyBaselineMeasurementTests`.
- Final sorted source/test/widget SHA-256 aggregate, unchanged across final gates:
  `6f3b4162285cd4c019e2fb8fd7ea37bab2bcbc6b7e57bc2ec75bf909e62cdae4`.
- The tested Mac bundle was installed reversibly at `/Applications/StockSageX.app`
  after normal Quit. Strict/deep signature verification passed; a recursive checksum
  comparison against the tested bundle had no differences. Installed executable SHA-256:
  `ee3de94d6b8b53d818d2cc059ac0f823d7131172623a87dc44655fcec62c2e11`.
- Final native screenshot inspection: the interior blank toolbar strip is gone; the
  horizon controls and Run button are visible. Both horizon selections and matching
  accessible scan labels were exercised without starting a new 500-stock scan. The app
  remains open on 1–7 trading days Research.
- Model settings in the installed feature build confirmed the existing recommended
  6-bit 9B as downloaded and load-on-demand; checking it did not start a duplicate transfer.
- After final replacement, all three present protected paper/journal/portfolio/price-alert/
  calibration preference keys were unchanged. The paper-account directory and chat history
  were byte-identical to the pre-replacement snapshot. Quote caches may update normally.
- Backup and detailed local installation receipt:
  `/Users/saleh/Codex-Backups/stocksage-model-update-20260912.pes0mT/INSTALL_RECEIPT.md`.
  Base HEAD is `e576d70c6fd3d4cc3f5a94d47cb3f61635bb91fa`. After installation, the owner
  requested commit and push of the verified continuation to the existing feature branch
  on `swonyu/StockSage-app`, without another merge to main. Confirm the publication commit
  from current Git history and the remote; the tested source aggregate above is unchanged.

### Explicit limits

No live 500-stock scan, real missing-model transfer or loaded-model RAM release was needed
or exercised. Normal Quit ran against an already-unloaded selected model; offline transport
checks cover loaded-instance unloading, failed confirmation and cancellation. A passing
transport test is not a claim that live RAM release was measured. Force Quit cannot run the
cleanup. No model weights, historical records, risk thresholds or broker execution were changed.
