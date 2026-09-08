# StockSage macOS workspace redesign

Direction approved by Saleh's “continue the redesign” at18:07 +03, following the
right-sidebar proposal. The project's owner context waives routine reconfirmation.
All work stays inline on wt/coverage. No model restart or automation reactivation.

Update2026-09-08 16:38 +03:Saleh explicitly requested the tabs on the LEFT.
This supersedes the original side choice only; existing styling, routes, widths,
collapse preference and iPhone presentation remain unchanged. Qwen's later ON
instruction and the existing15-minute automation remain in effect.

## Experience

Rebuild the macOS presentation as a calm, wide native workspace, inspired by Apple
Music's hierarchy rather than its content. A LEFT-hand navigation sidebar slides
between a220pt labelled panel and a64pt icon rail. The selected destination remains
visible in both modes. Settings is pinned at the bottom, never buried in the page.
Retain all nine existing section identities and their Command-number shortcuts:
Briefing is labelled Home on Mac, All is labelled Markets, and Heatmap remains reachable.
Home is the normal macOS opening destination. Explicit QA sections and iPhone opening
behavior remain unchanged. Sidebar state is macOS-specific.

The content area has a compact, fixed heading/refresh bar, dated feed status before
financial figures, and a wide independently scrolling page. No global context stack
above Watchlist, Ideas, Portfolio, Chat or other selected content. Existing source,
stale/cache/sample, risk and failure labels stay attached to the facts they qualify.

Home: deterministic daily briefing, obvious Watchlist/Ideas/Chat entry points, then
market regime, catalyst overview and forward-progress context. Model generation is
never necessary to read Home. Ideas: header, top opportunity, actual ranked list;
allocation, fast lane, today's actions and backtests stay accessible in labelled
disclosures rather than blocking the list. Portfolio: Holdings, Journal, Paper and
Analytics subviews separate real holdings, real trades, simulated trades and diagnostics.
No feature/data deletion. Watchlist/Markets use the available width with aligned price
columns and quieter row chrome. Catalysts, Heatmap and Alerts retain their working
actions inside the common desktop workspace. Chat gets its own transcript scroll
and fixed composer, preserving its existing session, cancellation, evidence and
privacy behavior. Model settings still route to the existing Catalysts controls.

## Visual contract

SF Pro system typography:30pt semibold page titles,15pt navigation,13–15pt body,
11–12pt metadata; monetary values use monospaced digits. Palette: canvas #18181A,
raised surfaces #232326, primary #F5F5F7, secondary #B3B3BA, navigation berry #D94B70,
selection well #3D2630. Existing semantic gain/loss/caution and accessible primary
button colors remain unchanged. This avoids recoloring financial meaning as branding.
Use restrained native material on navigation only, generous24–32pt gutters, flat
card fills, thin separators and no decorative aurora on Mac. The signature is the
left-side library-style rail; do not add decorative charts, invented prices or art.
Respect Reduce Motion/Transparency, visible keyboard focus and VoiceOver labels.
Minimum main window900×700, preferred1280×840. Expanded and collapsed modes must fit
the minimum window. Wide content caps at1200pt for tables/cards and860pt for Chat.

## Implementation boundaries

Keep MarketsView as the single lifecycle owner for shared stores and refresh tasks.
Introduce a small macOS-only navigation view/metadata file, not a second data engine
or generic routing framework. Common tasks stay outside the changing section content.
Keep the current iPhone tree, deep generic erasure and gestures intact with compile-time
platform branches. Split Chat presentation into shared transcript/composer subviews
with distinct macOS layout, without changing send/validation/storage logic. Restyle
shared design tokens only inside macOS compile-time branches. Use native SettingsLink
to the existing Settings scene, and existing model controls rather than new credentials.

## Verification and scope

Pin desktop navigation coverage, shortcut preservation, names and widths in the
existing navigation test file; keep iPhone traversal tests. Exercise resize, expand/
collapse, all destinations, Portfolio subtabs, Chat composer/cancel and Settings in
an offline populated UI if native control is available. Run canonical macOS/iPhone
gates serially with the existing three opt-in exclusions. Report visual acceptance
separately from unit tests; no claim of a live broker/model test while services are off.
No financial engine, risk policy, credentials, owner records, network entitlements,
model files or iPhone visual redesign is in scope. No push. Preserve main checkout's
unrelated project.pbxproj and review artifacts. Keep previous app recoverable when
showing the rebuilt macOS app; do not relaunch Qwen or overnight automation.
