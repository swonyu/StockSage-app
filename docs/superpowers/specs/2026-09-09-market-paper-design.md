# Market-wide native paper autopilot

Approved by the owner at00:10 Riyadh on2026-09-09: “i want the entire market
and it should trade and buy and sell”, following the proposed broader automatic
discovery design. This task owns qwen-context from clean2face4d.

## Scope and contract

- Fetch Massive's full US stock-market snapshot every fifteen minutes, with no
  watchlist/curated-universe ticker filter and OTC explicitly excluded. This is
  the full provider-returned US listed market, not all global exchanges. Source:
  https://massive.com/docs/rest/stocks/snapshots/full-market-snapshot (verified
  September9). Publish returned, usable/fresh, and model-reviewed counts separately.
- Screen all returned rows. Deep-research up to twelve fresh, affordable supported
  new symbols per cycle, least recently attempted first, then observed daily dollar
  activity descending and ticker ascending. This prioritizes research, not a return
  forecast. No required trade quota. Stale, malformed, missing-history and unsupported
  symbols remain disclosed exclusions. Existing bare-letter Massive routing is unchanged.
- Always research open paper holdings first (maximum five), independent of discovery
  success, before new entries. A failed full-market fetch blocks discovery, not exits.
- Use existing price/history/news/Qwen evidence validation. Create off-board symbol
  definitions locally without changing the user's watchlist or main board. Replace
  every watchlist-only eligibility check with the same selected-market/held rule.
- Qwen Buy/Strong Buy proposes a simulated entry. Sell/Reduce proposes a full close
  of an existing paper holding. Supply current held/not-held context. Hold/Avoid never
  forces a fill. Existing sampled stop/target exits remain active during inference.
- Preserve the $10,000 existing ledger, $2,000/new-position cap, maximum five positions,
  whole shares, long-only/no margin, subsequent Massive trade observations,120s
  freshness/expiry,10bps assumed adverse cost,2% stop/4% target, extended US hours,
  cancellation, one-writer lease, atomic persistence and no backfilling.
- Show market-scan coverage, current research scope, latest saved decision and next
  scheduled cycle on the panel without requiring the user to expand the history.
- IBKR relay stays OFF; no real/broker orders, model restart, new dependency, frozen
  research changes, merge or push. A complete snapshot is not a complete Qwen analysis
  of every stock and simulated fills do not prove broker execution or profitability.

## Verification and rollout

Add deterministic tests before code: full-market request/parse, unsupported and stale
exclusions, discovery beyond ORCL/curated list, holdings priority and rotation, and a
selected off-board Buy followed by a later simulated fill and Sell without watchlist
membership. Retain original no-force, expiry, costs/caps and persistence tests.
Run focused tests, then final canonical macOS and iPhone17Pro(gate) suites serially.
Use the tested signed bundle, quit normally, preserve the old app in Trash, install
and reopen. Observe real full-market coverage and actual decisions without inventing
trades. Record evidence in HANDOFF and commit explicit paths only.
