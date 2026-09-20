# Benzinga production review — 2026-09-09

**Scope changed at 04:37 Riyadh:** the owner cancelled direct Benzinga credentials
and provider routing. The parent is removing that unshipped slice. Its findings and
synthetic reproduction below are retained as historical evidence only; none is a
release blocker for the continuing Massive/Benzinga integration. Active review now
covers the Massive evidence client and consumers, coordinated with evidence worker
`01a083cc-283c-7232-92f9-9d4a671305c1`; its final implementation review follows separately.

Independent review of the key-entry slice and shared-evidence design. Parent owns
integration, builds and installation. Review branch starts at `50c96cc`; production
files were read only. No credentials, clipboard, real Keychain items, provider/model
requests, services, model settings, ledger, app installation or pushes were used.

## Reviewed bytes and limits

Parent: `/Users/saleh/StockSage-wt/qwen-context`. Initial snapshot at
`2026-09-09T01:34:26Z`; source recheck at `01:37:06Z`. Exact hashes are in
`BENZINGA_REVIEW_HASHES_2026-09-09.json`. Frozen copies are under
`/var/folders/b1/tvm3jn711kq48mcrc1skxdn80000gn/T/stocksage-benzinga-review-0909-94oo8vkg`.
Paths and line references below are relative to the parent. Initial and recheck
bytes are explicitly distinguished because the parent changed source during review.

The key-entry plan intentionally delivers storage plus a news-only connection test.
It does not claim the nine-product consumer integration is implemented. Missing
future consumers are requirements below, not regressions in this slice.

## Cancelled direct-key findings — historical, not Massive blockers

### P2 — The connection test bounds its Data buffer, not received bytes

Evidence: initial `StockSage/Sources/StockSage/StockSageBenzinga.swift:137–158`,
SHA-256 `bdafbb4e0f264ebbc7ba967299b6d936a884e0e1366759a7f41ffa4e2b7e7c3f`;
same logic remains at recheck lines `145–166`. `session.bytes(for:)` produces an
async byte stream; the consumer tests `data.count` and invalidates the session only
when it observes the excess. URLSession can buffer ahead while the per-byte loop
runs. Unknown-length/chunked bodies bypass the Content-Length precheck.

The runnable check uses that exact production fetch, injecting only a custom
URLProtocol into its ephemeral configuration. It delivers synthetic 64 KiB chunks
one millisecond apart, without a Content-Length. Initial run received 4,063,232
bytes before cancellation. The committed runner reproduced 3,932,160 bytes against
the 1,048,576-byte cap; it exited **1**, intentionally failing the cap assertion.
Both production fetches correctly returned `.tooLarge`; the defect is late transport
cancellation, not malformed-response acceptance. The count measures bytes handed
to URLSession by the fake protocol, not a live socket or total process memory.

Small proposed change: a concrete serial `URLSessionDataDelegate` counts chunks
before appending; reject and cancel the task at the first crossing. Keep at most one
incoming chunk of unavoidable transport granularity. Preserve no-redirect handling,
resource timeout, cancellation and one-shot completion on every exit. Do not replace
this with `data(for:)` followed by a size test. The new shared product transport needs
the same mechanism at its specified 2 MB limit.

### P2 — Manual tests ignore provider Retry-After throttling

Evidence: recheck `StockSageBenzinga.swift:104–110,145–158` converts HTTP 429 to a
bare `.rateLimited` without inspecting headers or retaining a cooldown. Recheck
`StockSage/Sources/Views/StockSageBenzingaKeyField.swift:24–25,84–89` clears
`probeTask` on completion and immediately enables Test again. Repeated clicks can
make new requests during a provider-requested pause. The approved spec explicitly
says manual tests may bypass old authorization denial, but not provider throttling.

Small proposed change: retain one shared, bounded retry deadline for the direct
news endpoint. Parse bounded numeric seconds or an HTTP date from `Retry-After`,
use a conservative bounded default when absent/invalid, and check the deadline
before dispatch. Key replacement and manual Test must not reset a valid provider
cooldown. Test this with an injected clock and synthetic 429 response; retain only
the parsed deadline and fixed status, never raw response text.

### P2 — Device-only accessibility does not satisfy the no-backup promise

Evidence: recheck `StockSageBenzinga.swift:56–59` uses
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; the approved spec's first-delivery
requirements say the key must never enter backups. This accessibility class prevents
migration to another device, but ordinary ThisDeviceOnly items can still be included
in a backup protected by the original device UID. Apple's no-backup class on iOS-family
devices is `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`, with different passcode
and credential-loss behavior. This is a documented contract mismatch, not an observed
plaintext leak or claim about any owner's backup. See [Apple Keychain data protection](https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web)
and [backup keybags](https://support.apple.com/en-euro/guide/security/sec6483d5760/web).

Small proposed resolution: enforce a supported no-backup class where the strict
requirement applies, fail visibly if unavailable, and update the attribute during
successful replacements too. Check macOS support separately. If the approved product
requirement instead means no app-created export/plaintext backup and no migration,
correct that guarantee explicitly; do not describe the current attribute as excluding
all device backups. This reviewer changed neither policy nor device configuration.

## Cancelled direct-key source fixes recorded before cancellation

These are not remaining source defects. Their runtime acceptance remains owned by
the parent, which was notified as soon as each issue was established.

- **Original P1, Mac Keychain signing prerequisite:** Initial key source forced
  `kSecUseDataProtectionKeychain=true`, while initial project lines `441–515` supplied
  no Mac entitlement file. Read-only `codesign -d --entitlements :-
  /Applications/StockSageX.app` returned only test/debug exceptions, no app identity,
  keychain-access-groups or application-groups. No Keychain call was made. The parent
  added Mac-only `StockSage/StockSageMac.entitlements` and two SDK-specific project
  settings. Source recheck confirms the intended app-private identity/default group.
  Parent must still verify resolved `AppIdentifierPrefix`, trusted final signing,
  successful signed-app-host synthetic roundtrip and stable identity after replacement.
  A source plist alone cannot prove OS access. [Apple access-group documentation](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
  and [Apple SecItem guidance](https://developer.apple.com/forums/thread/724013).
- **Original P2, stale results across Settings instances:** Original `revision` was
  an unobserved static UUID. It rejected in-flight stale completions, but a completed
  success and `saved` state could survive replacement/removal in another mounted
  field. Parent added `@Observable Configuration.shared` and field `onChange` that
  cancels, clears and refreshes. Recheck confirms the source repair; no native UI
  runtime claim is made.
- **Parent-discovered read error:** Failed secret reads previously called only
  `refresh()`, so metadata presence could mask a read denial. Recheck field lines
  `76–80` now preserve a visible read-failure message. Do not count this as a new
  unresolved finding.

## Historical direct-key boundaries that held

`KeyStore.save` performs Update first and Add only for ItemNotFound. It never deletes
the existing item to replace it, and denied updates do not fall through to Add.
Removal targets the same service/account/non-sync/Data Protection query. No test
uses the production service for native storage; the parent-added hosted roundtrip
uses a UUID service and cleanup. Run it only in the designated signed test host;
its explicit unhosted skip is not positive Keychain evidence.

Normalization accepts a bounded printable ASCII key after trimming outer whitespace;
embedded spaces/controls fail. Save does not start networking. The field never reads
the stored value for display, and clears the successful draft/dismissed view. The
only outgoing key is an Authorization header on the fixed HTTPS Benzinga origin.
There is no query-token fallback, redirect forwarding, provider body echo, localized
network error text, or path from this key store into Massive, Qwen or chat history.

The probe distinguishes 401/403/429, malformed, valid empty, transport, timeout,
cancellation, policy denial, configuration change and redirects. Both permission
and credential revision are checked before and after its await. The result is
news-only; a nonempty title establishes a successful connection probe, not a validated
article record. A 12-second resource timeout supplements per-byte deadline checks.

The official [authentication page](https://docs.benzinga.com/api-reference/authentication)
recommends header authentication; the [news endpoint schema](https://docs.benzinga.com/api-reference/news-api/get-news-items)
still requires a query token. Header-only service acceptance remains intentionally
unverified until private owner entry and testing. The current explicit uncertainty
and no-secret-URL retry behavior are correct.

## Nine-product integration requirements, not first-slice defects

The approved mapping is coherent. These are the acceptance points that must remain
visible when the separate integration lands:

| Product | Existing boundary / required consumer behavior |
|---|---|
| Earnings | Preserve schedule/date-status selection independently; reported EPS/revenue must carry fiscal period and actual/estimate meaning. A scheduled date is not a reported beat. |
| Guidance | Reuse `StockSageMassiveEvents` attribution and issuer-expectation caveat; never an actual result or settlement price. |
| Ratings | Preserve analyst, currency and original/adjusted target basis. Never copy targets into `LiveQuote`, paper entry/exit prices or app technical targets. |
| Analyst insights | Keep dated bounded source commentary. Join supplied rating/firm identifiers; narrative is not an instruction or verified price. |
| Bulls/Bears Say | Preserve both supplied sides and independent missing sides. Keep provider update time; do not invent publication precision or an app recommendation. |
| Benzinga news | Separate direct and Massive schemas/product identities. Missing bodies are valid. Preserve original publication text/offset/precision, update time and material revisions. |
| Analyst details | Resolve at most three retained references using documented `benzinga_id` lookup, not name matching or an invented ticker filter. Track-record metrics are provider claims. |
| Firm details | Resolve at most three retained references with `benzinga_id`; enrich parent records rather than create scheduled catalysts. |
| Consensus | Keep distribution/contributor counts and target opinions separate from quotes. The documented two-hour update cadence is not a record timestamp; absent source time remains unknown. |

Primary contracts checked: [analyst insights](https://massive.com/docs/rest/partners/benzinga/analyst-insights),
[bull/bear cases](https://massive.com/docs/rest/partners/benzinga/bulls-bears-say),
[news](https://massive.com/docs/rest/partners/benzinga/news),
[analyst details](https://massive.com/docs/rest/partners/benzinga/analyst-details),
[firm details](https://massive.com/docs/rest/partners/benzinga/firm-details), and
[consensus](https://massive.com/docs/rest/partners/benzinga/consensus-ratings).
No fresh entitlement or payload coverage claim is made from documentation.

Consumer-specific integration points from the pinned source:

- **NewsService:** Original `recentNews` returns arrays and conflates failed/empty
  outcomes; `NewsItem.id` was date+title and `Date` alone lost original precision.
  Worker commit `f00f621ec9ee98872ec2eb64c9d8af5a795bac4b` already addresses these
  concerns for existing providers and adds post-await Chat policy guards. These are
  merge dependencies, not new defects to fix twice. Generalize its ordered attempts
  to Massive Benzinga → generic Massive → EODHD after direct-provider cancellation,
  stopping on cancellation/policy denial. Existing fallback `data(for:)` bounds are not a template
  for the required new streaming transport.
- **AIAssessment:** `Context.facts` lines `46–59` mixes attributed event/news text into
  numbered facts while preserving caveats; numeric acceptance is only membership,
  explicitly not semantic certification (`parse:150–165`). Keep acceptance unchanged.
  Add typed product status/provenance to the captured context, preserve source-vs-price
  separation, and never call a target an observed quote. `assess:283–291` writes a
  draft before `stillValid()`: the new credential/policy generation must guard all
  publication, including drafts, not only accepted records. Existing `stillValid`
  checks model/sample/snapshot state, not a Benzinga generation.
- **Chat:** Source material already has a separate typed `Source` collection and is
  JSON-encoded outside price facts. `prompt:175–188` removes whole oldest exchanges
  to satisfy a UTF-8 byte budget. Preserve it. The six-source history/attach limits
  (`init:233–234`, `attachResearch:270–275`) cannot silently truncate nine products;
  encode a bounded product projection with status coverage first, and update bounded
  decoding compatibly without rewriting old facts. Source IDs must remain tied to
  the captured snapshot rather than whichever cache entries exist when Qwen returns.
- **PaperAutomation:** `researchSymbol:595–638` captures a fresh quote after research
  awaits, checks policy/configuration/run generation after inference, and `Book.settle`
  accepts only a later typed quote. Preserve these money boundaries. New evidence
  must not shift the intraday citation-index calculation without matching tests.
  Its final facts append intraday/account context after `Context.canAssess`'s size
  check: validate the actual assembled new prompt against existing model limits while
  keeping the added evidence at three records/product, 400 characters/excerpt and
  12,000 total characters including attribution. Do not change model settings to fit.

The new app-wide three-request limit, single-flight ownership/cancellation, cache
keys including credential generation, 500-entry eviction, TTLs, metadata join bounds
and per-product failures/partial/empty states remain to be demonstrated. Existing
24-hour company-event cache semantics are explicitly preserved, not silently replaced
by the new five-minute event policy. No quote-tick fetches or new dashboards are needed.

## Reproduction and handoff

From this review worktree:

```sh
python3 agent-docs/checks/run_benzinga_stream_review.py /path/to/pinned/StockSageBenzinga.swift
```

The runner prints the reviewed SHA-256, compiles only the two tiny source files,
intercepts all URLSession requests, and exits 1 for transport read-ahead beyond the
cap plus one chunk. Compilation exited 0; the regression exited 1 in 0.81 seconds
including compilation. No full build, XCTest/Swift Testing suite, heavy compiler
run, app host or native Keychain test was run here. Parent retains the heavy slot;
the independent source report and offline reproduction need no further slot.

Historical direct-key fixes were source-reviewed only and are now cancelled. No
Keychain, backup or header-auth acceptance is required for the continuing Massive
scope. Its transport, cooldown, full Mac/iPhone gates and visual acceptance remain
parent-owned.
