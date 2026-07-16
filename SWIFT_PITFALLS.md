# Swift / SwiftUI / Liquid Glass pitfall checklist (macOS 26 "Tahoe")

Provenance: adversarially-verified deep research, 2026-07-16 (105 agents; every claim
required 3-0 survival against primary sources — Apple docs and WWDC transcripts, fetched
live against the Xcode 26.6 / MacOSX26.5 SDK). Refuted and unverifiable claims were
killed, not reported. Confidence below is the verifier vote, not vibes.
Requested by the owner ("deep research swift coding and never makin mistakes with swift").

**How to use:** read before touching Liquid Glass APIs, sheets, pinned bars, appearance
scoping, or before any MarketsView performance work. This document records the OS 26
generation's rules as of 2026-07-16; point releases have already shifted behavior once
(verifier-noted iOS 26.1 Menu-in-GlassEffectContainer morphing bug) — re-verify before
relying on container/morphing specifics.

## Liquid Glass (all 3-0 unanimous, Apple primary sources)

1. **`.glassEffect()` without a shape renders a Capsule.** Default is `.regular` glass in
   a Capsule behind the content — a card/bar/panel gets pill geometry. Pass the shape:
   `.glassEffect(in: .rect(cornerRadius: 16))`.
2. **Modifier order: glass goes LAST.** `glassEffect` captures the view as composed so
   far and anchors to its bounds at that point. Padding/font/appearance before the
   modifier are inside the glass; anything after is not captured.
3. **Co-located glass belongs in one `GlassEffectContainer`.** Renders shapes together
   (performance) and enables blending/morphing via `glassEffectID`. macOS 26.0+
   (verified in the shipping SDK). Best-practice, not hard requirement — a shipping app
   reports ~9 un-contained non-morphing effects performing acceptably.
4. **Don't overuse glass.** Apple explicitly: too many containers, or too many effects
   outside containers, degrade performance. Limit simultaneous onscreen effects;
   profile with the SwiftUI Instruments tooling.
5. **Don't hand-roll glass buttons.** `.buttonStyle(.glass)` / `.glassProminent` are the
   sanctioned styles (macOS 26.0+, non-beta).
6. **REFUTED RATIONALE — "glass can't sample glass".** The never-stack-glass-on-glass
   rule's researched mechanism was refuted 0-3. The rule itself may still be HIG
   guidance, but do not repeat that basis (the parent repo's
   DESIGN_RESEARCH_macOS27.md cites it — treat that line as corrected here; the parent
   repo is read-only).

## Sheets & bars (macOS-specific)

7. **macOS sheet presentation backgrounds are ALWAYS opaque.**
   `.presentationBackground(.ultraThinMaterial)` will not show through on Mac — the
   translucency is gated to supported platforms and macOS sheets are carved out by an
   official Note. Under the new design Apple advises removing custom presentation
   backgrounds entirely (sheets get a system background by default).
   *StockSage consequence:* the idea detail sheet keeps its owner-drawn gradient root
   (also required by the QA snapshot path); BrowseMarketsView deliberately has no
   custom sheet background.
8. **Extra backgrounds behind pinned bars fight the automatic scroll edge effect.**
   The OS 26 design blurs/fades content under system bars automatically; custom
   materials/darkening behind `safeAreaInset` bar items interfere. Apple's remedy:
   remove custom bar backgrounds, tune with `.scrollEdgeEffectStyle(.hard, for: .top)`.
   *StockSage status (2026-07-16):* the disclaimer footer and the detail-sheet CTA bar
   carry explicit `.ultraThinMaterial` — pixel-verified correct on macOS 26.5, kept
   because the Apple demo evidence is iOS-framed and exact macOS visuals were not
   independently confirmed. Open experiment: bare bar + scrollEdgeEffectStyle, owner
   to eyeball.
9. **`.preferredColorScheme` stops at presentation boundaries.** It sets the scheme for
   the nearest enclosing presentation (window/sheet/popover) and its children — it
   never crosses scene boundaries. Every scene that must be dark needs its own:
   main WindowGroup ✓, Settings ✓, and the PARKED MenuBarExtra will need one if
   revived (StockSageApp.swift landmine comment).

## SwiftUI performance (for the MarketsView optimization phase)

10. **Dependency fan-out is the re-render storm mechanism.** (a) Reading any element of
    an @Observable collection (even via a helper) makes the view depend on the WHOLE
    array — one mutation re-runs every dependent body. (b) Frequently-updating values
    in Environment (geometry, timers) notify every @Environment-reading view.
    (c) Passing whole objects where a view needs one field coarsens dependencies.
    Note: StockSage uses ObservableObject/@ObservedObject (store-level invalidation via
    objectWillChange — even coarser); the fix direction is the same: narrow what each
    child view observes. (WWDC25-306, WWDC23-10160)
11. **Expensive work in `body` causes hitches.** Formatter construction
    (NumberFormatter/MeasurementFormatter) in computed properties read during body,
    heavy interpolation, filtering — a body that overruns the frame deadline holds the
    frame. Cache formatters in stored/model properties; precompute derived strings.
    *Audit target:* grep MarketsView for formatter construction in computed vars.
12. **List/Table row IDs are gathered EAGERLY** (rows lazy, IDs not) — slow/allocating
    ID generation taxes initial load and every update. Keep row IDs trivially cheap.

## Verified-empty topics (NOT pitfall-free — just unverified)

- Swift 6 strict-concurrency mistakes under MainActor default isolation: zero claims
  survived verification.
- @ScaledMetric / Dynamic Type behavior on macOS: zero claims survived; whether macOS
  honors content size categories at all remains an open question.

Full run artifacts (claims, votes, per-source evidence): workflow run wf_947a5975-243,
2026-07-16. Sources are cited per-claim in the run journal; headline ones:
developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views,
WWDC25 sessions 323 & 306, WWDC23 session 10160.
