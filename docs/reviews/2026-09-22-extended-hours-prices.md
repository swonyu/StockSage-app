# Extended-hours price display verification

Date: 22 September 2026. Code commit: `256f8385f99a9a9b26395e7a848376105ed9df4f`.
Base: `948aa412adfcf0d2c943b06517229fda5d4db6b1`.

## Behavior

Massive Form T trades now qualify for displayed prices within the existing verified extended-session calendar. A disallowed condition in a mixed trade still rejects it. Raw sequence ordering and the eligible display cache remain separate. Snapshot and streaming paths share the extended-session guard. Yahoo requests minute data with `includePrePost=true` and selects newer valid dated extended observations; its source stays delayed. Mac watchlist/idea labels use the selected observation's session, age and provenance.

Numeric research references, paper-trade qualification and model contracts were not changed. The 2026 calendar boundary remains; this change does not enable unverified overnight sessions.

## Gates and evidence

- `tools/gate.sh . tests`: exit 0; macOS module 214 seconds, test-source typecheck 283 seconds; iOS skipped. These are compile durations on this Mac, not price-update latency.
- Initial native build: exit 65 before tests because the configured team's Mac Development certificate is absent on this Mac.
- Final serial native run: exit 0; 158 definitions, 256 executions, 10 suites, zero failures/skips; Swift Testing execution 5.416 seconds. This is synthetic test time, not live-feed latency.
- `tools/runtests.sh` targeted native diagnostic guard: passed. xcresult runtime warnings: empty. This does not claim every compiler/framework warning is absent.
- SHA-256 values of the eight modified code/test files matched before and after the final test run; `git diff --check` passed.

The temporary external signing configuration (not committed or installed):

```xcconfig
CODE_SIGN_IDENTITY = -
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM =
PROVISIONING_PROFILE_SPECIFIER =
CODE_SIGNING_ALLOWED = YES
```

```sh
XCODE_XCCONFIG_FILE=/tmp/stocksage-extended-hours-tests.xcconfig \
  tools/runtests.sh . \
  --filter StockSageMassiveTicksTests \
  --filter StockSageMassiveTests \
  --filter StockSageFeedIngressTests \
  --filter StockSageQuoteServiceParsingTests \
  --filter StockSageQuoteTransportTests \
  --filter StockSagePriceSourceTests \
  --filter MarketsSourceTagLabelTests \
  --filter MarketsPolledQuoteMergeTests \
  --filter StockSageMarketHoursTests \
  --filter StockSageHealStaleQuotesTests
```

Regression cases cover pre/post sessions, regular/overnight rejection, weekends, holidays, early close, daylight saving, unsupported calendar years, invalid/mixed conditions, snapshot-to-display publication, raw-order preservation, fallback query parameters, observation timestamps, previous-close provenance, and honest live/delayed/cached/last labels.

Preserved local evidence: `/Users/salman/Documents/Codex/StockSage-Extended-Hours-2026-09-22/` contains `compile.log`, `native-test.log`, `native-summary.json`, `tested-source-manifest.json` and the PDF candidate/receipt. Native xcresult: `/var/folders/qb/cnp00ynx0qg3lxyfgf4p2b4h0000gn/T/stocksage-tests.SeEMsB/result.xcresult`.

## Remaining boundary

Source is tested; installation and live-provider observation were not performed. No model inference, research run, paid pod, broker, iOS or widget operation was initiated. The existing installed app and owner records were not replaced. The owner-designated PDF path under `/Users/saleh` is absent; the previous owner PDF remains untouched and exact-path replacement remains pending. No PDF attachment was sent.

PDF candidate: edition 39, ten pages, all pages visually reviewed. SHA-256 `a0fd0ad041d68afc35c0306862ad8eb4ad7b9af7e375f2930aeb97bfc0edcd69`. The final link-only rerender matched every reviewed page image byte-for-byte. This receipt confirms a local export, not replacement or delivery of the owner attachment.
