# StockSage native workspace refinement

Owner direction: “Polished native Mac — refined and spacious” (14 September 2026).

Keep the native sidebar, titlebar, inspector, SF typography, charcoal canvas, owner-selected magenta, and semantic financial colors. Improve hierarchy and useful space across the existing workflows rather than adding destinations or data. No new dependency or persistence layer.

- Home: a prominent daily overview, a legible briefing, compact navigation actions, then market context aligned at the top.
- Research: a clear title and horizon/action bar, compact current status, search and filter above a native results table, and the existing adjacent inspector. Remove the enclosing GroupBox and scrolling table-on-page on Mac. Keep compact layouts usable with the inspector open. Empty research should explain the workflow without looking like a giant disabled form.
- Paper: separate mode/monitoring, prominent account values, positions/pending requests, and historical activity. Reuse exact existing value calculations and warnings. No simulated or real actions during visual checks.
- Chat: a calm reading column, a compact current app briefing, distinct user questions, readable assistant answers, and lighter evidence grouping. Keep cited sources visible and original snapshots explicitly historical. Preserve the stationary native composer and all lifecycle state.
- Shared chrome: reduce redundant status padding while retaining full freshness warnings and the finite line caps that protect split-view layout. Use a modest native sidebar label scale rather than oversized symbols.

Safety and compatibility: preserve all current dirty Unicode/Research/Chat changes; no financial calculations, execution, inference, provider, settings or storage changes. Preserve Research selection/filter semantics, window-level inspector and observed detail; Chat drafts/history/cancellation; iPhone navigation and type-erasure boundary; bounded banners/composer; lazy market projections.

Research references: Apple HIG [materials](https://developer.apple.com/design/human-interface-guidelines/materials), [lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [typography](https://developer.apple.com/design/human-interface-guidelines/typography), and [AppKit design update](https://developer.apple.com/videos/play/wwdc2025/310/). Native materials belong to controls/navigation; content uses quiet surfaces. Type and alignment establish hierarchy before decoration.

Acceptance: visibly improved actual Mac app at 1300×840 and minimum width; native results/inspector fixtures including missing/incomplete evidence; existing functional regressions and canonical serial Mac/iPhone gates pass after final changes. Reversible install with app identity and protected-state verification. No claim of live trading, model, or provider validation from visual fixtures.
