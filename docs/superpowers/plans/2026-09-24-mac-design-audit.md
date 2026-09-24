# StockSage Mac design and reliability repair plan

Baseline: `7b16b12`; installed Saleh Mac binary matches the older `f578733` release. No installation or fresh model/provider verification is implied by this review.

## Design direction

Use a quieter rose-magenta for primary actions, a lighter related color for small foreground text, and opaque charcoal layers. Preserve native Mac controls, clear status colors and dated evidence. Lead each page with its purpose, current state and one main action; place lengthy methodology in named disclosures. Errors, missing coverage, retained-results warnings and current timestamps remain visible.

The owner requested the critique, plan and implementation together. This plan records that authorized work. It does not authorize a new model run, provider probe, Telegram message or broker action.

## Verified finding ledger

- [x] D01: Saturated magenta dominates controls; retune shared fill/text/asset together and retain 4.5:1 text contrast.
- [x] D02: Low-opacity layers and small secondary reading text flatten hierarchy; use solid surfaces and readable status/body typography across primary and supporting pages.
- [x] D03: Small Kelly, beta and share-count text incorrectly uses the darker button-fill token; use the readable text token.
- [x] D04: Live quote and heatmap animations ignore Reduce Motion; respect the environment across their subtree.
- [x] D05: Custom input boundaries stay faint under Increase Contrast; use native chrome or a shared contrast-aware boundary.
- [x] D06: Flat sparklines are announced as rising; share the visual and spoken trend classification.
- [x] D07: Stop/target chart labels rely on color; add visible names.
- [x] L01: Cap and screener pages have nested scrolling and duplicate margins; one page owns scrolling and padding.
- [x] L02: Cap monitoring methodology and large market-context cards displace status, controls and results; compact the summary and disclose unchanged method/context detail.
- [x] L03: Retained earlier-results warning is collapsed; show warning and displayed capture date permanently.
- [x] L04: Horizon retry/resume controls compete with Run; one state-appropriate primary action, ordinary alternatives.
- [x] L05: Company-quality sheet opens only after work completes; open immediately with local progress, cancel and error states.
- [x] L06: Screener explanatory blocks push results away; keep coverage/date visible and group source/method detail without hiding missing data.
- [x] L07: Telegram setup feedback is below its controls; keep live status under the heading.
- [x] L08: WhatsApp/onboarding sheets enforce fixed sizes; use flexible ideal sizes, scrolling content and reachable dismissal, with adaptive source/date fields.
- [x] L09: Saved-check search says all checks despite filtering; show matching/total count and prioritize saved records.
- [x] L10: Model settings are discoverable only through textual directions; add a direct safe navigation action.
- [x] L11: Global running controls consume space and the Large cap stop label conceals that watching stops too; use compact adaptive controls with accurate labels.
- [x] L12: Setup guidance incorrectly describes every run as manual, and paired tracking can retain an unpaired instruction; correct only known informational copy while preserving dynamic failures.
- [x] L13: The saved-history method disclosure renders without a clear affordance inside a List row; verify actual press/reveal and use a native disclosure row if needed.
- [x] R01: Initial cap receipt-save failure retains the prior receipt and leaves the new scan unfinished; publish a terminal failed current attempt and preserve prior records.
- [x] R02: Cached writer-lock errors lose their relaunch recovery instruction; surface the safe typed reason without changing lock ownership.
- [x] R03: Isolation failure receipts erase the failing verification stage; retain bounded non-sensitive stage identifiers while keeping rejection strict. This does not establish the historical SHOP/GRAB cause.
- [x] R04: A queued Company quality request rejected while another request runs can display a previous capture; render only the snapshot returned by that exact admitted request, with explicit cancellation/unavailable states.
- [x] R05: Closing an older company-detail sheet can cancel another window's newer request for the same symbol; cancel only the operation owned by that sheet.

## Implementation and acceptance

1. Apply D01–D07 and L01 in shared design/Markets code. Check palette contrast, motion, native control boundaries and chart accessibility.
2. Apply L02–L04/L07/L09 to research, monitoring, setup and history. Keep all evidence and failures inspectable; verify compact and wide native fixtures.
3. Apply D02/L05/L06/L08/L10/L11 to screener, Library/model setup, sheets, Settings and global controls. Test actual loading/cancellation behavior with synthetic data.
4. Apply R01–R03 with temporary-directory and injected-executor regressions. No private records or real inference in tests.
5. Review all main routes plus supporting pages/sheets with native fixtures; run focused checks, then the canonical serial macOS suite. Record executed counts and failures, not merely compilation.
6. Independently review the complete diff. Fix verified follow-up findings, build the signed Mac candidate, update both living guides and the owner PDF (maximum 20 pages), merge/push under existing authority. Request action-time restart approval only when the tested candidate is ready, naming in-memory screener and momentum state that will reset.

## Verified implementation

All 25 findings above are implemented and covered by the final Mac review and regression run. The serial canonical suite passed **3,263 definitions / 4,247 executions / zero failures / five existing skips**, direct exit 0. All 479 source/project/resource hashes stayed unchanged. The native layout/constraint/reentrant/publication/geometry diagnostic guard is clean; five existing excessive-window-count warnings remain. Independent final source review found no additional release blockers.

Build, publication and installation are tracked separately in the [audit receipt](../../reviews/2026-09-24-mac-design-audit.md); checked implementation items do not imply an installed candidate.

## Verification limits

Live inspection is read-only: all nine main destinations are included, and existing fixtures cover secondary routes. The current app has repeated feed gaps and an active Large cap run; neither is attributed to the repaired receipt or isolation defects without evidence. iOS changes fetched from main are preserved; this task performs Mac work and Mac verification only.
