# Tradier planning sources

Accessed 2026-09-08 (Asia/Riyadh, +03). Public documentation only: no authenticated broker requests, onboarding, funding or purchase. These sources support the design facts below, not runtime acceptance. Recheck schemas/versions before implementation and record real discrepancies in the standalone copy. User brief source IDs remain in the original untracked brief; IDs below are this plan's source register.

| ID | Official source | Planning fact / surface checked |
| --- | --- | --- |
| R01 | [Tradier FAQ](https://docs.tradier.com/docs/faq) | Sandbox 15-minute delay; no paper market-data streaming endpoint; personal-use restriction; individual API access. |
| R02 | [Trading guide](https://docs.tradier.com/docs/trading) | Separate production/sandbox REST bases, form-encoded order fields, preview and status workflow. |
| R03 | [Place order](https://docs.tradier.com/reference/brokerage-api-trading-place-order) | POST `/v1/accounts/{account_id}/orders`; equity fields, tag and preview. |
| R04 | [Streaming guide](https://docs.tradier.com/docs/streaming-data) | Short-lived sessions, reconnect behavior and one stream of each type; initial design omits account stream. |
| R05 | [Market WebSocket](https://docs.tradier.com/reference/websocket-market-data-streaming) | `wss://ws.tradier.com/v1/markets/events`; JSON symbols/sessionid/filter payload; five-minute initial connection window. |
| R06 | [Create market session](https://docs.tradier.com/reference/brokerage-api-streaming-create-market-session) | Production `POST /v1/markets/events/session` is necessary for a read-only observer. |
| R07 | [Rate limiting](https://docs.tradier.com/docs/rate-limiting) | Per-token category limits and X-Ratelimit response headers. The plan's 30/min ordinary trading cap is an engineering policy. |
| R08 | [Permitted countries](https://support.tradier.com/kb/guide/en/permitted-and-blocked-countries-CLzSa0D1rf/Steps/4997916) | Saudi Arabia listed; individual approval and account terms still require broker confirmation. |
| R09 | [Tradier pricing](https://tradier.com/individuals/pricing) | Lite $0 plan and $0.35 stock trade; Pro $10/month and $0 stock commission; other fees and conditions apply. No upgrade selected. |
| R10 | [Lightsail pricing](https://aws.amazon.com/lightsail/pricing/) | Listed Linux public-IPv4 bundle: $7/month, 1 GB memory, 2 vCPUs, 40 GB disk, 2 TB transfer. Regional availability and all-in cost not verified. |
| R11 | [Python downloads/support](https://www.python.org/downloads/) | Python 3.14 is a supported bugfix series; no prerelease is needed. Exact patch/dependency lock belongs to implementation. |
| R12 | [HTTPX async](https://www.python-httpx.org/async/) | AsyncClient pooling/reuse; do not construct a client inside the hot loop. |
| R13 | [websockets getting started](https://websockets.readthedocs.io/en/stable/intro/index.html) | Current async client documentation located; implementation must pin/test compatible APIs. |
| R14 | [pytest documentation](https://docs.pytest.org/en/stable/) | Test framework reference located; no suite executed in planning. |

## Observed discrepancies and follow-up

- R02 calls `preview` optional/recommended; R03 labels it required. Proposal: always send explicit `true` for preview and `false` only for a separately authorized sandbox submission. Confirm in real sandbox before G1; no silent fallback to production.
- R05's symbols parameter example appears as a comma-containing string inside an array, while its Python example uses separate symbols. Use a real JSON array and validate the payload against current reference/sandbox-free production read-only access before accepting it. Never print the example's session payload because it contains a session ID.
- The user brief says no StockStage repository was supplied; this working directory is a StockSage app checkout. Its README/layout are known, but identity with the deferred target and its integration interfaces remain unconfirmed. This is a naming/scope question, not permission for early integration.

## Endpoint references to inspect during authorized implementation

These URLs came from the brief and are **not independently schema-verified in this planning pass**: [profile](https://docs.tradier.com/reference/brokerage-api-user-get-profile), [balances](https://docs.tradier.com/reference/brokerage-api-accounts-get-account-balance), [positions](https://docs.tradier.com/reference/brokerage-api-accounts-get-account-positions), [market clock](https://docs.tradier.com/reference/brokerage-api-markets-get-clock), [account WebSocket](https://docs.tradier.com/reference/websocket-account-data-streaming). Discover current quote/calendar/order-list/status/cancel schemas via the [official index](https://docs.tradier.com/llms.txt). Record method, path, accepted payload, normalization and discrepancies before implementing each surface. Account streaming remains deferred.

## Local provenance

- Baseline `fc455ccf67415a9e45493a6471e4c6d28da52f00`; branch `codex/tradier-plan-only`; fetch and fast-forward pull completed without application changes.
- Read root README and latest HANDOFF section; historical test reports were not rerun. The codebase inventory informed the isolation boundary only.
- Original `Astra_Trading_Master_Prompt.md` SHA-256: `d714da7e5d039f7006df6f5139345a6476420b2aae34423382bf70a49a2496f9`. The original remains user-owned/untracked; this source register does not publish it.
- A bounded read-only requirements review checked the brief's gates and safety requirements. No independent cross-family review or runtime broker validation was performed in planning.
