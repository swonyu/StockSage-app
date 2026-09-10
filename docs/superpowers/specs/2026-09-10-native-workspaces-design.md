# Native StockSage Workspaces

## Decision and authorization

The owner approved native Apple navigation and workflow reconstruction and explicitly authorized choosing and implementing further improvements after deep research. This specification records that approved direction and the bounded first batch; no additional cosmetic choice is required before routine work. Research: `/Users/saleh/StockSage-native27-20260910.jhR6DG/NATIVE_PLATFORM_RESEARCH.md`.

Alternatives considered: restyle existing cards (does not solve discoverability), native workspace migration (selected), full terminal/data architecture rewrite (unnecessary risk). The implementation retains one Markets lifecycle owner and existing services.

## Navigation and identity

- Mac: native `NavigationSplitView` and sidebar `List`, native toolbar title/refresh, existing nine destinations plus Research and Paper Trading.
- iPhone: native `TabView`/`NavigationStack`; Home, Research, Catalysts, Chat first, secondary destinations available through native overflow. Remove custom drawer and section-swipe gestures.
- Append new raw routes after the existing nine. Preserve original Command-1…9 mapping; no numeric shortcuts for routes beyond nine. Use an explicit presentation order, not enum order, for navigation.
- Keep refresh, stream, store observations and sheet presentation in MarketsView outside route branches. A navigation action cannot start research, change the paper account or duplicate a stream.

## Workspaces

- Research: existing manual 500-listing, 1–7/7–14 trading-day scans only. Keep all-results default and explicit alphabetical-directory coverage. Retain horizon/filter/selection while changing Mac destinations. On Mac use a native inspector for selected evidence; on iPhone use a detail sheet. Clear selection on horizon changes or filtering it out.
- Paper Trading: existing Day101 engine on Mac, no changes to its execution rules, records or start policy. Label monitoring as enabled rather than verified healthy. State the consequence of Pause beside the control. iPhone clearly explains that this Mac paper automation is not enabled there and no Mac account is synchronized.
- Chat: no embedded research/automation panel. Retain unsent draft with the existing session across navigation, not as a historical turn. Leaving still cancels in-flight chat as before.
- Portfolio: relabel existing Paper subsection as Forward record, preserving its raw value and data store.
- Home owns market context; selected iPhone task screens no longer repeat unrelated context cards underneath.

## Presentation and boundaries

Use native system chrome; no custom glass cards, dependencies, model/strategy rewrites, data migrations or broad palette replacement. Retain dark mode for existing dark-content compatibility; full semantic light/dark migration is a separate verified change. Research columns and detail call prices daily-close references and stop/target scenarios; incomplete and unchecked remain visible.

## Verification

Before implementation, add failing production-view/state tests for native sidebar structure, navigation destinations, persistent Chat draft and monitoring wording. Preserve prior lifecycle, evidence and accounting regression suites. Add native-host layout/selection checks for new navigation and result detail, including narrow/large text where supported. Run full macOS/iPhone gates serially, strict checks, then explicit Xcode27/iOS27 compatibility tests. Inspect changed rendered UI. Never use the owner's real ledger as a test fixture.

Current installed app stays untouched. No push, merge, new paid resource, real order, broker relay, model training, historical-record edit, or automatic start. Report exact runtime/SDK, failures, skips and limitations. The batch is not a claim of whole-app perfection or profitable trading.
