# Same-Day Trading, Interactive Brokers, and StockSage

## Executive assessment

StockSage can become a more credible same-day research and paper-trading system. It does not yet have evidence that its model produces a dependable trading edge. Its next milestone should be realistic, independently reproducible net performance—not a particular number of trades or a weekly profit quota.

Three issues dominate. First, US day-trading regulation changed in 2026, but an individual Interactive Brokers account can still be subject to the former rules during the transition. Second, StockSage's native simulator is neither a faithful cash-account settlement model nor a complete margin-account model. Third, the existing local forecasting comparison did not establish a profitable candidate under its primary cost and delay assumptions. These are separate regulatory, engineering, and statistical questions; solving one does not solve the others.[^1][^2][^3][^4]

The recommended sequence is: verify the account regime; improve execution and cash-account realism; preserve the existing prospective experiment; test a small number of explicit intraday hypotheses; and validate broker-paper behavior separately. Qwen should organize evidence and explain decisions while deterministic code controls money, deadlines, data eligibility, and order state. No research conclusion here authorizes live orders, changes to account type, or increased leverage.

### Scope and confidence

The scope is US-listed stocks and ETFs, with positions intended to close within the same New York trading date. Pre-market and after-hours are included, but not treated as interchangeable with the regular session or IBKR's separate overnight service. Options, futures, CFDs, and Saudi equities require separate product-specific studies.

Public rules and product documentation are assessed as of **September 9, 2026**. The account's legal entity, cash/margin classification, applicable transition regime, permissions, and real-money funding remain **unverified**. Code findings refer to StockSage worktree `qwen-context`, revision `02e19a4`; historical broker diagnostics are identified by their own dates. This is research and engineering analysis, not individualized investment, legal, or tax advice.

## 1. Return objectives and evidence

### The meaning of 5% every week

A single 5% week is possible. Sustaining that return as a portfolio expectation is a radically different claim. Pure compounding gives `1.05^52 = 12.6428`: approximately **1,164.3% annual profit**, or $10,000 becoming approximately $126,428 before withdrawals, taxes, and costs. Across five trading days per week, the equivalent constant daily return is approximately 0.9806%. These are arithmetic implications, not forecasts.

A target that high should not become a rule telling the system to increase risk after losses or force entries when no setup qualifies. A trade-count target similarly rewards activity even when expected profit is negative. A more useful research objective is positive out-of-sample expectancy after realistic costs, subject to a predefined drawdown tolerance and operational reliability requirements.

Drawdown matters independently of average returns. A 20% loss needs a 25% recovery; a 50% loss needs a 100% recovery. Small persistent gains punctuated by rare large losses can look attractive until the loss occurs. Same-day liquidation reduces intended overnight exposure but cannot eliminate losses, trading halts, execution failures, or an unexpected position left open.

### What studies of day traders establish

Chague, De-Losso, and Giovannetti studied new Brazilian equity-futures day traders who began during 2013–2015. Among those persisting for at least 300 days, 97% lost money. This is strong evidence against portraying day trading as easy income, but it is not a measured failure probability for a US equity algorithm or for StockSage.[^5]

Barber, Lee, Liu, and Odean found substantial differences in skill among Taiwanese day traders, but fewer than 1% could predictably earn positive abnormal returns after fees. That finding allows for genuine skill while showing how unusual persistent net profitability was in the studied population. Neither paper supplies a transferable 2026 stock-picking recipe.[^6]

**Analytical conclusion:** profitability is an empirical question. A fluent explanation, an accurate earnings date, a successful API call, or a favorable training loss does not establish it. A system must demonstrate that the timing and direction of its actions improve outcomes after the costs and constraints it will actually face.

## 2. IBKR account rules and the 2026 transition

### The old PDT rule is not the whole current answer

The SEC approved FINRA's replacement of the day-trading margin provisions on April 14, 2026. FINRA set an effective date of June 4, 2026, with implementation flexibility through October 20, 2027. The new framework replaces the old pattern-day-trader structure with intraday margin standards; it does not eliminate ordinary margin obligations.[^1][^7]

IBKR explicitly warns that an account **may still be subject to existing PDT rules during the transition**. Its update describes removal of the $25,000 PDT minimum, retention of a $2,000 minimum for margin use/short sales, prompt satisfaction of intraday margin deficits, and possible restrictions for repeated failures. Its legacy section describes the four-day-trades/five-business-days framework and preventive restrictions below $25,000.[^2]

Therefore, neither “everyone still needs $25,000” nor “IBKR removed PDT for everyone on June 4” is a supportable account-specific answer. The broker's actual configuration and governing entity must be established before a trading policy is selected.

| Account situation | Constraint to establish | StockSage treatment proposed |
|---|---|---|
| Cash account | Settled funds, currency, settlement calendar, product permissions | Model cash debits and settlement lots; do not assume immediate recycling of sale proceeds |
| Margin account still under legacy rules | Applicable PDT/day-trade restrictions and buying power | Read broker restrictions; do not infer allowance from portfolio cash alone |
| Margin account under new standards | Intraday margin, house requirements, excess liquidity, deficit status | Use account-specific risk information; do not implement an unconditional trade-count bypass |
| Different entity or special account | Local rules, product and account restrictions | Keep the regime unknown until verified |
| Free trial or broker-paper account | API eligibility and simulator limitations | Keep separate from a verified real-money account profile |

This table is an implementation framework, not a substitute for the broker's determination.

### Account identification without exposing credentials

IBKR's documented Client Portal path is the user menu, **Settings → Account Configuration → Account Type**. This is a way to inspect the classification, not a recommendation to upgrade it. The legal entity should be checked on the account's statement or agreement; a location, currency, or app branding alone does not establish it.[^8]

A useful broker-support question is: “Which legal entity holds this account, is it cash or margin, and is it currently governed by legacy PDT restrictions or the new intraday margin standards? What account fields and restrictions should an API client rely on?” No password, account number, access token, or full financial statement needs to be placed in chat to discuss the answer.

### Cash accounts: same-day trading is possible, unlimited recycling is not

For most US securities, standard settlement is **T+1**, effective since May 28, 2024: the next business day, not the next calendar day.[^9] A fully funded cash-account purchase can be sold the same day. Buying with unsettled proceeds and selling the new holding before the funding settles can cause a good-faith violation; buying and selling before payment can constitute freeriding.[^10]

**Illustrative cash ledger:** start with $10,000 of settled USD. Buy and sell $2,000 of stock on Monday. Subject to fees and the broker's actual balances, roughly $8,000 of the original settled funds remain available for further fully funded intraday purchases; the sale proceeds are a separate receivable until settlement. Repeating approximately five $2,000 round trips consumes the original cash budget—fees mean exact sizing must leave a reserve. It does not replenish an unlimited Monday buying budget. A holiday can move the settlement date.

IBKR distinguishes cash balance from settled cash; the former can include stock-sale proceeds on trade date. Consequently, a missing settled-cash field must not be replaced with total cash. Actual currency balances also matter: reporting an account in USD is not evidence that every asset or cash balance has been converted into settled USD.[^11]

**Implementation addendum, September 9:** settlement days are not merely exchange trading days. FINRA's current holiday schedule explicitly excludes Columbus Day and Veterans Day from settlement even though securities markets generally trade. The paper calendar must include those bank-only closures as well as the listed exchange/settlement holidays; a service being open for processing does not establish CNS settlement availability. [FINRA holiday schedule](https://www.finra.org/rules-guidance/key-topics/margin-accounts/margin-extension-holiday-schedule), [DTCC Good Friday 2026 notice](https://www.dtcc.com/-/media/Files/pdf/2026/3/6/23891-26.pdf).

There is a documentation conflict worth recording: IBKR's general account-configuration page retains a three-business-day stock-settlement statement, while current SEC guidance and IBKR's account-balances documentation reflect T+1 for US equities. The obsolete generic statement should not drive a new US-equity simulator.[^9][^11][^12]

### Margin: available buying power is not a loss budget

Margin capacity can change with prices, concentration, security eligibility, and house requirements. A maintenance threshold is not a recommended exposure level. The implementation should reserve headroom rather than repeatedly consume the last available dollar, and should recheck account and order state immediately before any permitted submission.

IBKR's margin disclosure warns that it can liquidate positions without first contacting the customer. A regulatory deadline or the phrase “promptly” must not be interpreted as a guaranteed grace period before broker liquidation. The new framework still requires prompt resolution of intraday deficits and provides restrictions for persistent failures.[^13][^1]

The prudent initial simulator remains unleveraged and long-only. That is a research simplification, not a claim that margin accounts cannot be used responsibly. Adding leverage before demonstrating an edge would make losses and modeling errors larger without making the forecast better.

## 3. Sessions, calendars, halts, and same-day exits

### New York is the strategy's trading clock

US regular equity hours are 09:30–16:00 Eastern Time. Extended-hours availability depends on the venue, security, broker, and order instructions; the commonly supported pre/post windows relevant to StockSage are 04:00–09:30 and 16:00–20:00.[^14][^15] Saudi Arabia does not share New York's daylight-saving changes, so a hard-coded Saudi clock is unsafe.

| Session | New York | Riyadh during US daylight time | Riyadh during US standard time |
|---|---|---|---|
| Pre-market | 04:00–09:30 | 11:00–16:30 | 12:00–17:30 |
| Regular | 09:30–16:00 | 16:30–23:00 | 17:30–00:00 |
| After-hours | 16:00–20:00 | 23:00–03:00 next day | 00:00–04:00 next day |
| Current native close-out trigger | 19:55 | 02:55 next day | 03:55 next day |

Riyadh conversions are calculated from the session times; the last row is a StockSage policy, not an exchange or IBKR requirement.[^3] Crossing midnight in Riyadh is not necessarily an overnight position in New York. All records should retain UTC event time, receipt time, New York session date, and a human-readable local display.

IBKR also offers a separate overnight service, generally 20:00–03:50 ET, with trades from 20:00 to midnight assigned the following trade date. This is not equivalent to enabling “Outside RTH.” Its current product page and an educational lesson describe different combined-session order durations, so the exact route, time-in-force, platform, and contract need verification; a generic overnight toggle is insufficient.[^16][^17]

### Weekday checks are insufficient

The published 2026 exchange calendar includes full closures and 13:00 ET early closes, including November 27 and December 24. Session logic must distinguish the regular close from any separately available extended session. An early regular close does not justify assuming that every extended venue follows the same schedule.[^14][^18]

Limit Up–Limit Down operates during regular hours for covered securities. Trading pauses and other halts mean that an exit can be impossible at the desired moment. The correct state is “exit due, unresolved,” not a fictional fill at the last price or at the scheduled close.[^19]

**Recommendation:** use the already existing verified calendar in the research tooling as a specification/reference where appropriate, then share consistent session behavior with native automation and the relay. Avoid creating another conflicting calendar. Add explicit entry-stop, close-out, broker-order-expiry, and final-reconciliation deadlines for each supported session. A last-minute liquidation policy needs enough allowance for rejects, partial fills, reconnects, and illiquidity; 19:55 is not evidence that five minutes will always suffice.

### Extended hours are a separate experiment

FINRA highlights lower liquidity, wider spreads, greater volatility, execution uncertainty, and differences in market connectivity outside regular hours. Regular-session quote-protection arrangements should not be assumed to apply identically there.[^15]

StockSage should report pre-market, regular, and after-hours performance separately. Keep the requested extended-hours capability, but do not let a profitable regular-session result certify it. Candidate eligibility should depend on current spread, displayed size, trade activity, quote age, and venue availability—not simply the wall clock.

## 4. Orders, data, costs, and execution quality

### Last trade is not an executable price

A reported trade tells what already happened; bid and ask show current displayed interest. Buying at an observed last trade and selling later at another last trade omits whether those prices were available to the strategy. For simulation, an aggressive buy should normally be evaluated against a contemporaneous eligible ask and a sell against a bid, with size, latency, and participation constraints. Even top-of-book prices cannot prove a fill of arbitrary size.

Massive's trades include conditions, correction information, and participant/SIP timestamps. Aggregate bars follow eligibility rules; a raw trade need not update every aggregate field. Missing bars can reflect absence of qualifying activity rather than an authentication problem.[^20][^21][^22]

This explains why “fresh observation unavailable” needs a typed reason. Authentication failure, missing entitlement, timeout, stale participant timestamp, no eligible trade in a bounded request, missing quote, halt, and market closure are different conditions. The remedy for a request-window bug is not to loosen freshness for every security. A two-minute-old print can meet a software threshold and still be unsuitable for a rapidly moving trade.

**Recommendation:** preserve quote/trade provenance; separate latest observation, research-eligible evidence, and fill-eligible liquidity. Never fabricate timestamps or substitute delayed Yahoo observations into a lane represented as fresh SIP execution evidence. A bounded query that finds nothing should report its bound, not claim there were no trades anywhere.

### Order types and failure modes

A market order prioritizes execution, not a guaranteed price. A limit order bounds price but may never fill. A stop-market order can execute far beyond its trigger; a stop-limit order can trigger without executing. Order duration and outside-hours eligibility must be explicit.[^23][^24]

For research, use marketable-limit simulation with a predefined maximum adverse price, rather than unlimited chasing. This is a proposed execution policy, not a universal best order type. An IOC can partially fill and cancel its remainder; canceled remainder does not undo the filled shares. Model each execution separately and protect/reconcile the actual residual quantity.

For exits, test the order lifecycle rather than merely checking a Sell badge. The lifecycle includes intent, broker acceptance, execution quantities, cancellation acknowledgments, fees, and final positions. A submitted close is not a closed position. A timeout is not proof of rejection. IBKR's legacy API documentation explicitly warns that order-status messages can duplicate or omit transitions and recommends monitoring executions as well; exact behavior must also be checked against the installed API version.[^25]

### Commission minimums matter at StockSage's position size

IBKR's published US equity schedule currently lists, at its first volume tier, Pro Tiered at $0.0035/share with a $0.35 minimum per order, and Pro Fixed at $0.005/share with a $1 minimum. The page lists additional applicable charges; Tiered passes through several categories of third-party fees. Lite eligibility is US-resident-specific and cannot be assumed here.[^26]

The following calculations illustrate the schedule, not actual fills or a verified account plan. Assume whole-share round trips with unchanged prices and no special routing treatment:

| Example | Base commission, round trip | Commission as fraction of opening notional |
|---|---:|---:|
| 100 shares × $20, Pro Fixed | $2.00 | 10 basis points |
| 100 shares × $20, Pro Tiered | $0.70 | 3.5 basis points |
| 10 shares × $20, Pro Fixed | $2.00 | 100 basis points |

These figures exclude the applicable additional charges and market costs. A $0.02 bid/ask spread on a $20 stock represents another 10 basis points for an immediate buy-at-ask/sell-at-bid round trip around an unchanged midpoint. Price movement, latency, adverse selection, partial fills, and fees can raise or alter the realized cost.

Native StockSage currently assumes 10 basis points adverse movement **per side**. That is transparent, but it is not a measured IBKR fee/spread model. Its separate historical comparison used a primary assumption of 5 basis points **round trip**. Those results cannot be compared as if their execution assumptions matched.[^3][^4]

### Expectancy rather than win rate

For gross average win `W`, gross average loss magnitude `L`, win probability `p`, and expected round-trip cost `C`, expected net return per trade is `pW − (1−p)L − C`. The break-even win probability is `(L+C)/(W+L)`. If wins average 40 basis points, losses 20, and costs 10, break-even is 50%, not the cost-free 33.3%. If the measured wins/losses already include costs, do not deduct them again.

**Recommendation:** log implementation shortfall against a decision-time benchmark, spread paid, fees, fill rate, time to fill, maximum favorable/adverse excursion, and session-specific net expectancy. A model that predicts direction slightly better but acts too late or trades more expensive names can be economically worse.

## 5. Same-day strategies worth testing

### Evidence-ranked candidates

The following are research priorities, not approved profitable strategies. Parameters must be frozen before evaluation, and “no trade” must remain an eligible outcome.

| Candidate | Evidence and rationale | Main reason it can fail | Proposed priority |
|---|---|---|---|
| Opening-range breakout with unusual activity | A published working paper studies US equities and volume-conditioned opening behavior | False breaks, spreads, shorting assumptions, delayed entries, selection bias | First explicit stock-level hypothesis |
| Late-day index/ETF momentum | Peer-reviewed research links early-session and closing-session returns | Old sample, regime instability, auction costs, mismatched timing | Separate simple benchmark |
| Intraday reversal / VWAP-related reversion | Liquidity-related reversal is documented; VWAP provides a descriptive reference | Bid/ask bounce, trending/news days, mistaking a reference price for predictive value | Controlled comparator, not an automatic rule |
| News-conditioned continuation | Information arrival can define a testable event | Repeated/late headlines, prior expectations, unavailable historical timestamps | Add only with point-in-time news evidence |
| General Qwen Buy/Strong Buy opinion | Existing app integration makes it easy to generate explanations | No calibrated connection from language confidence to future net returns | Evaluate as a challenger, not ground truth |

### Opening-range breakout: promising hypothesis, not transferable headline returns

Zarattini, Barbon, and Aziz analyze over 7,000 US stocks during 2016–2023. Their enhanced variant selects 20 relative-volume leaders, trades long/short with up to 4× leverage, uses ATR-related stops, and exits by the regular close. It reports 41.6% annualized return versus 3.2% for its base variant, assuming $0.0035/share commission.[^27]

These are retrospective results, not audited StockSage returns. Deducting per-share commission does not establish realistic spread, impact, borrow availability, minimum charges, or latency. A $10,000 unleveraged long-only adaptation needs separate validation; the headline is not transferable.[^27]

**Proposed adaptation:** compare a long-only regular-session variant with the existing simple baselines. Calculate relative volume against the same elapsed session interval on prior days, not today's final volume. Require the opening bar to be complete and available before any signal. Evaluate a fresh tradeable quote at entry and a time exit derived from the actual session calendar. Choose a small fixed parameter set; count every tested variation in the research ledger.

A fifteen-minute Qwen sweep is not an adequate trigger for a five-minute opening strategy. The language model can summarize the preselected candidates; lightweight deterministic evaluation needs to recognize a setup before its entry window expires. This does not require an exchange-scale high-frequency system.

### Momentum and reversal are conditional, not contradictory magic indicators

Gao, Han, Li, and Zhou's peer-reviewed study found that SPY's first-half-hour return, measured from the previous close, predicted the last-half-hour return in its 1993–2013 sample, with related ETF evidence. This is a specific closing-session phenomenon, not proof that arbitrary recent price strength predicts the next five minutes in every stock.[^28]

Heston, Korajczyk, and Sadka document recurrent intraday return patterns as well as short-horizon reversal connected to liquidity imbalances and bid/ask bounce. A reversal backtest based on last trades can therefore count a microstructure effect as a profit that cannot be captured after crossing the spread.[^29]

**Recommendation:** distinguish trend, reversion, and news-event hypotheses with explicit conditions and controls. VWAP, RSI, moving averages, and a narrative can describe the same price path without supplying independent evidence. Avoid a voting system that counts several correlated indicators as several independent confirmations. Test whether a feature adds value after existing features and costs, rather than adding it because it is popular.

### News and Qwen

The useful Qwen role is bounded interpretation: identify what a source actually says, distinguish a scheduled event from a reported outcome, deduplicate stories, describe uncertainty, and produce an explanation tied to facts. Deterministic code should calculate returns, spreads, relative volume, position sizes, and money limits.

For historical tests, modern model weights may already encode events that happened after the simulated decision date. Research on GPT-driven financial sentiment explicitly identifies training/evaluation overlap as a look-ahead concern.[^30] Point-in-time retrieval alone cannot prove that a pretrained model has forgotten future outcomes; prospective evaluation is especially important.

Group-chat messages and social posts should be treated as unverified claims, not training labels for successful trades. Preserve original timestamps and publication/receipt times, distinguish quoted messages from new information, and corroborate material claims. Prevent retrieved text from changing system instructions, credentials, risk limits, or order permissions. Private messages should not be redistributed or sent to additional services without appropriate authorization.

## 6. Existing StockSage evidence and architecture

### The prior case study and the implemented comparison

The supplied *StockSage-Intraday-Case-Study.pdf* recommends separating numeric forecasting from the language-model layer, using smaller liquid universes, and testing LightGBM before more complex forecasting models. It was a design study, not evidence of a deployed profitable strategy. Its hardware context also differs from the current machine.[^31]

The repository now records a fixed retrospective comparison of 250 events over five selected morning windows. At the primary one-minute delay and assumed five-basis-point round-trip cost, results were:[^4]

| Candidate | Forecast MAE, basis points | Simulated net return | Trades |
|---|---:|---:|---:|
| No-change / no-trade | 25.576 | 0.000% | 0 |
| Momentum | 39.201 | −1.195% | 46 |
| Reversal | 34.694 | −0.179% | 36 |
| Saved LightGBM | 25.778 | 0.000% | 0 |
| Kronos-small | 30.443 | −0.052% | 32 |
| Chronos-2 | 27.903 | −0.886% | 33 |

This is a documented prior result, not a rerun or a live return statement. The windows were already seen, stock-selected, and contained correlated/overlapping targets. None establishes a positive edge; LightGBM's zero trades are not profitable execution, and lowest forecast error alone is not an investment objective. The repository also contains a separate prospective protocol, whose eligible forecasts must be recorded before hypothetical entry deadlines.[^4]

The sensible consequence is to preserve the negative result. Do not silently retune the same window until a winner appears. Any new strategy is a separate versioned experiment with a fresh holdout or prospective period.

### The minimal useful separation

`Verified data → deterministic features/setup → risk and eligibility checks → paper execution/reconciliation`

Qwen sits alongside this sequence to extract bounded news facts and explain the decision. It does not replace settlement, price arithmetic, trading calendars, or broker acknowledgments. Numerical forecast models are challengers in the existing research harness until they demonstrate incremental value.

The native system already has useful boundaries: independent paper history, no real-broker writes, later-observation fills, evidence citations, freshness checks, position/cash limits, and model-independent stop/target and day-exit handling. Preserve those. Numeric membership and citation validity do not prove that the prose correctly interprets the facts, nor do they calibrate a Buy badge's expected return.[^3][^32]

### Broad market discovery without querying every model for every tick

“Entire market” should mean an auditable discoverable universe, not a promise of simultaneous deep analysis of every security. A cheap broad screen can narrow by product eligibility, liquidity, spread, unusual activity, and available evidence. More expensive research then covers a bounded queue, while open positions receive priority monitoring independently of that queue.

The current native sweep admits 100 discovery candidates plus held names, with four research workers and a fifteen-minute cadence. Increasing concurrency further does not automatically improve latency if the same local model becomes saturated. Measure end-to-end completion time and stale-decision rate first. Use lightweight triggers for actionable setups and reserve Qwen generation for the smaller relevant set.[^3][^32]

A useful dashboard separates universe size, screened names, qualifying setups, model-reviewed names, actionable decisions, submitted orders, actual fills, and rejections. “100 reviewed” must not imply “100 trade opportunities.” This makes a zero-trade cycle explainable without manufacturing trades.

## 7. IBKR API and broker-paper readiness

### Native simulation, trial, paper account, and live account differ

IBKR's paper environment is simulated. Its documentation describes top-of-book fills without deep-book simulation, limitations in supported order types, and differences in stops and partial execution. Paper performance therefore remains a bridge for operational testing, not proof of actual exchange execution quality.[^33]

IBKR's API requirements refer to a funded/opened Pro account and compatible TWS or Gateway/API versions. Its published support guidance distinguishes free trials from API-capable paper accounts.[^34][^35] A successful connection or a balance response does not establish submission permission.

The repository's **September 8** diagnostic identifies the tested login as a free-trial DUT account, reports missing `SettledCash`, and records that the relay is off with no broker orders placed. It also leaves actual acceptance, fills, cancellation, and reconnect recovery unverified. Those historical observations do not establish the status of any other account or a later login.[^36]

### Integration mismatch requiring explicit resolution

Native simulation now permits pre-market and after-hours and requests day exits at 19:55 New York. The relay documentation describes IOC limit orders restricted to 09:30–16:00 with outside-RTH disabled. It also says protective stops are not hosted at the broker and that exits depend on both local programs running.[^3][^36]

This is a critical incompatibility, not a cosmetic label issue: a native evening exit can be outside the relay's submission window. Before enabling broker-paper execution, either align an explicitly approved session policy or reject incompatible intents with a visible reason. Preserve separate native and broker receipts; never convert a native simulated fill into an IBKR fill.

### Data entitlements, pacing, and authentication

IBKR's free Cboe One/IEX offering is not a full consolidated NBBO substitute. Data subscriptions, API permissions, and concurrent lines matter; its market-data documentation describes a default 100-line allowance shared across relevant usage. A Massive subscription does not establish IBKR data entitlement, and broker connectivity does not establish market-data licensing.[^37]

IBKR documents a general TWS API request-rate limit based on half the account's market-data lines—50 requests/second at the default 100 lines. This is a request budget, not a cap of 50 incoming quote updates per second; endpoint-specific limits still apply. Use subscriptions, bounded concurrency, caching, and backoff rather than repeated full-universe polling.[^38]

TWS/Gateway operation includes daily restart behavior and periodic manual authentication requirements. It must not be represented as indefinitely unattended simply because a process remains running.[^39] Authentication stays in the broker's interface; API credentials and raw account payloads should not be placed in model prompts or public logs.

The API's WhatIf facility estimates order impact without routing the order, but IBKR warns against using it as an indiscriminate mass scanner. Use approved pre-trade checks for a small final shortlist, within current broker guidance; a preview is not a guarantee of later acceptance or fees.[^40]

### Operational acceptance tests before expanding beyond simulation

The proposed test set is small but covers actual failure paths:

1. Confirm account, environment, currency, permissions, regime, and fresh balances without printing sensitive identifiers.
2. Verify an eligible broker-paper order's acceptance, fill/partial fill, fee report, and final position as distinct events.
3. Test cancellation racing with a fill, duplicate callbacks, disconnect after submission, and restart with an unresolved order. Reconcile before retrying.
4. Test day-exit timing against the same session calendar used for entry, including an early close and a rejected or partially filled exit.
5. Verify the stop mechanism's scope: stopping new entries, canceling owned outstanding orders, and closing existing positions are different actions.
6. Keep broker-paper and native results separately labeled. No automatic real-money promotion follows from passing these tests.

These are recommendations for a subsequent authorized implementation/test task. No order or account mutation is part of this report.

## 8. Validation, risk controls, and research governance

### What a credible test needs

Use point-in-time universes, corporate-action-consistent prices, and only completed data available before each decision. Keep raw event time, receipt time, model-ready time, decision time, and hypothetical submission time distinct. A signal that finishes after its permitted entry is late, not a successful historical prediction.

Split chronologically by session. Prevent overlapping future-return labels from leaking across train/test boundaries; use appropriate gaps and session-level analysis. Fit scalers and thresholds only on training data. Retain delisted and failed candidates where applicable, record missing events, and avoid selecting only symbols that later became interesting.

Test at several predeclared plausible execution-cost and delay scenarios, including conservative stress cases. Do not choose the cheapest scenario after seeing which one makes a strategy positive. Use daily equity returns and clustered/block uncertainty estimates so thousands of correlated intraday observations are not advertised as thousands of independent experiments.

Backtest-overfitting research formalizes the danger of selecting the best-looking result from many attempts. The Deflated Sharpe Ratio addresses selection and non-normal returns; it is a statistical confidence adjustment, not a guarantee of future profit or simply an ordinary Sharpe ratio reduced by a percentage.[^41][^42]

A minimum number of prospective sessions is an engineering checkpoint, not mathematical proof. Thirty sessions can identify operational faults, but may be far too short to measure rare losses or regime dependence. The existing five-session pilot is principally a small prospective evidence collection exercise; it should not be repurposed into a certification of a weekly return target.[^4]

### Proposed evaluation scorecard

| Dimension | Required measurements | Failure should mean |
|---|---|---|
| Data integrity | Eligible-event coverage, missing/late data, provenance, corrections | Exclude invalid actions while retaining missingness in reporting |
| Economic value | Net expectancy, daily returns, drawdown, turnover, cost sensitivity | No promotion if gains vanish under plausible costs |
| Prediction quality | Baseline-relative error, calibration, incremental feature value | Better prose or model size is not a substitute |
| Execution | Fill rate, partials, shortfall, rejects, exposure during outages | Investigate before increasing automation |
| Generalization | Unseen sessions, regimes, symbol cohorts, session segments | Avoid declaring a universal strategy from one favorable subset |
| Risk | Concentration, open risk, daily loss, unresolved exits, cash/margin headroom | Stop new risk while preserving protective/reconciliation activity |

### Risk should be explicit and independent of Qwen

The current 2% stop, 4% target, $2,000 position ceiling, five-position cap, and whole-share sizing are implementation defaults. They are not empirically optimized intraday risk parameters.[^3] A fixed percentage stop can be very different from current spread or volatility across symbols; a large notional cap does not itself define portfolio loss risk.

A proposed paper-only risk model should size from the smaller of cash capacity, notional cap, liquidity capacity, and a predefined risk budget divided by a conservative loss distance including costs. Correlated holdings should share a portfolio budget. If the estimated stop distance is smaller than plausible transaction noise, the strategy should be rejected or separately tested—not granted more shares because the denominator is small.

Add explicit limits for daily realized-plus-unrealized loss, repeated execution failures, and stale held-position data. A risk breach should normally block new entries while leaving position monitoring and permitted exit/reconciliation actions active. Parameters require a separate design decision; no financial risk limits are changed here.

Unfilled exits must remain visible. “Same-day” is an intended policy with measurable exceptions, not an excuse to erase a carried position or assign a fictitious closing price. Report how often flattening failed, why, and the subsequent exposure.

## 9. Product eligibility, tax, and market-data rights

### A stock-like ticker may not be an ordinary stock

USO is structured as a partnership fund; USCF lists it among products issuing K-1/K-3 forms and potentially requiring qualified notices.[^43] US tax rules can require 10% withholding on gross proceeds from certain publicly traded partnership interests held by foreign persons, with exceptions including qualifying notices.[^44] Withholding is not the same as a final tax liability.

The issuer's qualified-notice pages did not establish a current, account-applicable exemption in the material available here. Consequently, this report **does not conclude that a particular USO sale would or would not be withheld**. Verify the current notice and the broker's treatment before treating such products as interchangeable with ordinary equity ETFs. This matters for the native symbol classifier, which is not a tax/product eligibility service.

For a focused first strategy, propose a verified universe of ordinary listed equities and straightforward, unleveraged equity ETFs. Exclude or separately approve partnerships, leveraged/inverse funds, complex ETPs, penny stocks, illiquid securities, and unavailable short borrows. This is an experimental scope proposal, not a silent change to existing holdings or discovery.

### Shorting and derivatives are separate systems

Short sales require borrow availability and create potential borrow-fee, recall, and buy-in risks; borrow charges depend on the security, broker, and settlement treatment.[^49] US Rule 201 imposes price restrictions following a qualifying 10% decline, subject to its rules and exceptions.[^45] A historical short signal is not proof a retail account could have borrowed the shares. Keep long-only and long-short results separate.

Options, especially very short-dated options, introduce nonlinear exposure, exercise/assignment, liquidity, and settlement issues. Futures introduce different margin and liquidation mechanics. They should not be added merely to avoid an equity-account restriction or chase a weekly target.

### Cross-border tax and records

US tax consequences depend on residence, citizenship, presence, income type, and treaty eligibility. IRS guidance describes circumstances where nonresident capital gains are not subject to US tax, alongside exceptions; dividends and other income can have different withholding treatment. A W-8BEN establishes relevant foreign-status/beneficial-owner information, not a universal tax exemption.[^46][^47]

US-situs estate exposure can also matter: the IRS describes a $60,000 US-situs-asset filing threshold for certain nonresident noncitizen estates. That is a filing threshold, not a statement that every account above it immediately owes a fixed tax.[^48] Saudi or other local obligations require the actual taxpayer facts and appropriately qualified advice. Retain statements, executions, fees, distributions, and FX records rather than assuming intraday flatness eliminates reporting obligations.

Market-data availability and permission to redistribute or train models on it are separate questions. Confirm the relevant vendor and exchange terms for personal display, API use, storage, model training, and onward delivery before expanding beyond private research. Do not infer redistribution rights from a technically successful request.

## 10. Prioritized StockSage improvement plan

All items below are proposed work, not implemented changes. The aim is to reuse the existing ledger, calendar research, data providers, and test harness wherever they can support the required behavior.

| Priority | Finding at revision `02e19a4` | Smallest useful improvement | Acceptance evidence |
|---|---|---|---|
| P0 | Native cash immediately credits sales; no settlement model | Add explicit unsettled proceeds and settlement dates to a versioned cash simulation | Same-day sale cannot replenish same-day settled spending; next business day/holiday and fees verified; old ledger preserved |
| P0 | Native extended-hours exits conflict with regular-only relay | One explicitly supported session policy across intent and relay; incompatible intents rejected | Tests around 16:00, 19:55, early close, DST, and late/restarted exits |
| P0 | Broker account/regime and API eligibility are unresolved | Read-only account capability status with unknown states | Cash/margin/entity/transition/permissions not guessed; absent fields remain absent |
| P0 | Trade-price fills plus fixed adverse adjustment are not executable quotes | Separate observation eligibility from bid/ask fill simulation and actual broker receipts | Stale/crossed/missing quotes rejected; partial quantity, fees, latency, and no-fill outcomes retained |
| P0 | Held-position risk depends on local processes; native stops are sampled | Independent exit/reconciliation monitoring, explicit outage state, broker-paper protection study | Model timeout cannot block monitoring; disconnect/restart does not duplicate or erase orders |
| P1 | Fifteen-minute model sweep is too slow for short opening setups | Lightweight deterministic trigger for a small predeclared shortlist; Qwen off timing-critical path | Actual signal-ready latency precedes allowed entry; late signals counted |
| P1 | Fixed notional/stop defaults are not a coherent tested risk model | Paper-only risk budget and cost/volatility-aware sizing proposal | Cash, liquidity, concentration, daily-loss and residual-position tests |
| P1 | Honest unavailable states still combine operationally different causes | Typed provider/data/session/eligibility rejection reasons and funnel counts | Each skipped symbol has a bounded reason; unavailable is never reported as no activity |
| P1 | Retrospective results have not established a profitable candidate | Complete frozen prospective protocol; add new strategy only as a new experiment | Untouched old results, common eligible panel, cost/delay stress, no automatic promotion |
| P1 | Native retention limits can pause long runs | Durable archive/rotation with verified recovery before changing limits | No discarded evidence or double-written ledger; monitoring behavior at capacity tested |
| P2 | Generic equity classification misses product-specific restrictions | Verified instrument metadata and explicit complex-product exclusions | Partnership/leveraged/borrow/permission cases distinguished |
| P2 | Qwen validation does not prove semantic correctness | Typed fact claims and a fixed adversarial evaluation set | Wrong symbol/time/session/attribution rejected; correct abstention and direct factual answers measured |

The most important user-interface addition is a concise **decision-to-fill explanation**: no qualifying setup, insufficient settled cash, session closed, stale quote, model evidence invalid, order not accepted, limit not reached, or position already held. A Buy badge is only one intermediate state. “Automatic” should mean reliably following a specified policy, not buying because the screen otherwise looks inactive.

### Decision gates

**Gate A — credible native paper accounting:** cash/settlement and execution assumptions are explicit, session calendars agree, unresolved exposure remains visible, and the cost model is internally consistent.

**Gate B — credible strategy evidence:** a frozen candidate beats relevant simple baselines on unseen, timestamped events after conservative costs, without depending on a small set of outliers or one session type. Uncertainty and unsuccessful trials remain visible.

**Gate C — credible broker-paper operation:** an eligible account is verified; orders, partial fills, fees, cancellations, and reconnects reconcile; risk and close-out behavior survive model and network failures.

**Any live-money decision is separate.** It requires verified account rules, product permissions, operational controls, and explicit authorization. Nothing in a passing paper test or this report guarantees profitability, particularly not 5% every week.

## Sources

Public sources were accessed September 9, 2026. Undated product pages are current-page observations, not guarantees that a feature applies to a particular account. Private records are identified by revision/date and are not public research publications. Footnotes provide the full source inventory.

[^1]: FINRA. [Regulatory Notice 26-10: FINRA Adopts New Intraday Margin Standards](https://www.finra.org/rules-guidance/notices/26-10). April 20, 2026. Effective date, transition period, and continuing intraday obligations.
[^2]: Interactive Brokers. [Stock Margin Requirements—Important Update and PDT sections](https://www.interactivebrokers.com/en/trading/margin-stocks.php?ex=us&hm=us&pm=1&rgt=1&rsk=0&rst=101004100808). Undated current page. Contains both new-framework guidance and explicit transitional legacy-account warning; the displayed margin table is jurisdiction-selected and is not assumed to govern this account.
[^3]: StockSage. [StockSagePaperAutomation.swift](/Users/saleh/StockSage-wt/qwen-context/StockSage/Sources/StockSage/StockSagePaperAutomation.swift). Revision `02e19a4`, inspected September 9, 2026. Constants, Book cash accounting/propose/settle, session and day-exit logic. Private source code, not a broker statement.
[^4]: StockSage. [Intraday research record](/Users/saleh/StockSage-wt/qwen-context/tools/intraday_research.md). Revision `02e19a4`; sections “Executed fixed comparison” and the frozen prospective pilot. September 8, 2026 results and protocol; private engineering/research record.
[^5]: Fernando Chague, Rodrigo De-Losso, Bruno Giovannetti. [Day Trading for a Living?](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3423101). Working paper, 2019/2020 versions. Brazilian equity-futures entrant cohort; population-specific loss evidence.
[^6]: Brad M. Barber, Yi-Tsung Lee, Yu-Jane Liu, Terrance Odean. [The Cross-Section of Speculator Skill: Evidence from Day Trading](https://www.sciencedirect.com/science/article/pii/S1386418113000190). *Journal of Financial Markets* 18, 2014, pp. 1–24. Persistent skill and net profitability in Taiwan.
[^7]: US Securities and Exchange Commission. [Release No. 34-105226, SR-FINRA-2025-017](https://www.sec.gov/files/rules/sro/finra/2026/34-105226.pdf). April 14, 2026. Approval of amended intraday margin standards.
[^8]: Interactive Brokers. [Client Portal Guide: Account Type](https://www.ibkrguides.com/clientportal/accounttype.htm). Current guide. Location of the account-type setting.
[^9]: SEC, Investor.gov. [New T+1 Settlement Cycle—What Investors Need to Know](https://www.investor.gov/introduction-investing/general-resources/news-alerts/alerts-bulletins/investor-bulletins/new-t1-settlement-cycle-what-investors-need-know-investor-bulletin). March 27, 2024. May 28, 2024 US transition and settlement implications.
[^10]: FINRA. [Frequent Intraday Trading: Understanding the Basics](https://www.finra.org/investors/insights/frequent-intraday-trading). June 4, 2026. Cash-account funding, freeriding and good-faith violations.
[^11]: Interactive Brokers. [TWS Guide: Account Balances](https://www.ibkrguides.com/traderworkstation/account-balances.htm). Current guide. Cash versus settled cash, settlement and account-field distinctions; product-specific statements outside US equities are not relied on here.
[^12]: Interactive Brokers. [Configuring Your Account](https://www.interactivebrokers.com/en/accounts/configuring-your-account.php). Current page with legacy settlement wording; cited as a bounded documentation conflict, not authority for T+3 US equity settlement.
[^13]: Interactive Brokers. [Disclosure of Risks of Margin Trading](https://brokerage.ibkr.com/Universal/servlet/Registration_v2.formSampleView?formdb=1005). Form dated June 1, 2022. Broker liquidation and margin risk; actual current account agreement remains controlling.
[^14]: Nasdaq. [Stock Market Holiday Schedule](https://www.nasdaq.com/market-activity/stock-market-holiday-schedule). 2026 schedule and session information.
[^15]: FINRA. [Extended-Hours Trading: Know the Risks](https://www.finra.org/investors/insights/extended-hours-trading). July 31, 2024. Session availability, liquidity and execution risks.
[^16]: Interactive Brokers. [Overnight Trading](https://www.interactivebrokers.com/en/trading/us-overnight-trading.php?menu=B). Current product page. Overnight hours, trade-date convention, and current combined-session product description.
[^17]: Interactive Brokers, Traders' Academy. [Overnight Trading Using Limit Order](https://www.interactivebrokers.com/campus/trading-lessons/overnight-trading-using-limit-order/?retakeFinal=1). Current accessible lesson. Order-type/TIF descriptions; differs from current product page on combined-session duration, requiring platform-specific confirmation.
[^18]: NYSE. [Trading Hours and Calendars](https://www.nyse.com/trade/hours-calendars). 2026 holiday and early-close schedule.
[^19]: US equity exchanges and FINRA. [Limit Up–Limit Down Plan](https://www.luldplan.com/). Current plan information. Regular-session scope and pause mechanism.
[^20]: Massive. [Stocks REST API: Trades](https://www.massive.com/docs/rest/stocks/trades-quotes/trades). Current specification. Conditions, corrections, participant/SIP timestamps and pagination.
[^21]: Massive. [Understanding Trade Eligibility](https://www.massive.com/blog/understanding-trade-eligibility). May 26, 2020. CTA/UTP sale-condition handling and aggregate eligibility.
[^22]: Massive. [Trades FAQs](https://massive.com/knowledge-base/categories/trades). Current knowledge base. Missing aggregates, timestamp units and canceled-trade information.
[^23]: FINRA. [Order Types](https://www.finra.org/investors/investing/investment-products/stocks/order-types). Current investor guidance. Market, limit and stop-order tradeoffs.
[^24]: FINRA. [Time Parameters and Qualifiers for Stock Orders](https://www.finra.org/investors/insights/time-parameters-qualifiers-stock-orders). Current investor guidance. Duration and execution qualifiers.
[^25]: Interactive Brokers. [TWS API: Placing Orders—Important Considerations Concerning Order Status](https://interactivebrokers.github.io/tws-api/order_submission.html). Legacy official API documentation; expressly treated as legacy, with installed-version behavior still requiring tests. Duplicate/missing status callbacks and execution monitoring.
[^26]: Interactive Brokers. [Commissions: Stocks, ETFs, Warrants and Structured Products—United States](https://www.interactivebrokers.com/en/pricing/commissions-stocks.php?re=amer). Current schedule. Tiered/Fixed rates, minimums, additional charges and Lite eligibility. Worked examples are original calculations, not broker quotes.
[^27]: Carlo Zarattini, Andrea Barbon, Andrew Aziz. [A Profitable Day Trading Strategy for the U.S. Equity Market](https://www.alexandria.unisg.ch/server/api/core/bitstreams/3c2989c4-688d-4d78-8a71-f02690990d51/content). Swiss Finance Institute Research Paper 24-98; SSRN record revised April 29, 2025. University-hosted paper, printed pp. 8–16, particularly Table 2. Historical methodology and reported results, not an independently replicated performance claim.
[^28]: Lei Gao, Yufeng Han, Sophia Zhengzi Li, Guofu Zhou. [Market Intraday Momentum](https://profiles.wustl.edu/en/publications/market-intraday-momentum/). *Journal of Financial Economics* 129(2), 2018, pp. 394–414; DOI 10.1016/j.jfineco.2018.05.009. Author-university publication record and abstract.
[^29]: Steven L. Heston, Robert A. Korajczyk, Ronnie Sadka. [Intraday Patterns in the Cross-Section of Stock Returns](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=1107590). Published 2010; working-paper record. Intraday continuation and liquidity-related reversal; not a present-day retail execution study.
[^30]: Paul Glasserman and Caden Lin. [Assessing Look-Ahead Bias in Stock Return Predictions Generated By GPT Sentiment Analysis](https://arxiv.org/abs/2309.17322). Original research preprint, 2023. LLM training-window and backtest-overlap concerns.
[^31]: *StockSage-Intraday-Case-Study.pdf*. September 8, 2026, 14 pages; particularly pp. 2 and 8–12. Supplied private design study at `/Users/saleh/Library/Messages/Attachments/cd/13/24EB7734-EE9A-4C9E-B234-8433452C22F5/StockSage-Intraday-Case-Study.pdf`; all pages inspected. No public URL.
[^32]: StockSage. [Paper Automation Review](/Users/saleh/StockSage-wt/qwen-context/agent-docs/PAPER_AUTOMATION_REVIEW_2026-09-09.md). September 9, 2026; revision `02e19a4`. Native automation boundaries, evidence/fill limitations, retention and model validation.
[^33]: Interactive Brokers. [About Paper Trading Accounts](https://www.ibkrguides.com/clientportal/aboutpapertradingaccounts.htm). Current guide, updated February 11, 2026. Simulator limitations, permissions, fill model and supported features.
[^34]: Interactive Brokers. [TWS API Requirements](https://www.interactivebrokers.com/docs/tws-api/doc/notes-limitations/requirements). Current API documentation. Account and platform prerequisites.
[^35]: Interactive Brokers, Traders' Academy. [Request Paper Trading Account](https://www.interactivebrokers.com/campus/trading-lessons/request-paper-trading-account/). Lesson and official support responses, including November 12, 2024 trial/API clarification. Not account-specific authorization.
[^36]: StockSage. [IBKR Paper Relay](/Users/saleh/StockSage-wt/qwen-context/tools/ibkr_paper_relay.md). September 8, 2026 diagnostic and relay limitations, revision `02e19a4`. Private record; not a fresh account login or live broker probe.
[^37]: Interactive Brokers. [Market Data Pricing and Subscriptions](https://www.interactivebrokers.com/en/pricing/market-data-pricing.php). Current page. Nonconsolidated free feed, market-data lines and subscription distinctions.
[^38]: Interactive Brokers. [TWS API Pacing Limitations: Introduction](https://www.interactivebrokers.com/docs/tws-api/doc/pacing-limitations/introduction). Current API documentation. General request rate versus subscription updates; endpoint-specific restrictions remain relevant.
[^39]: Interactive Brokers. [Daily and Weekly Reauthentication](https://www.interactivebrokers.com/docs/tws-api/doc/tws-settings/daily-weekly-reauthentication). Current API documentation. Session restart/authentication constraints.
[^40]: Interactive Brokers. [Test Order Impact: What If](https://www.interactivebrokers.com/docs/tws-api/doc/orders/test-order-impact-what-if). Current API documentation. Nonrouting credit-check preview and limits on indiscriminate use.
[^41]: David H. Bailey, Jonathan M. Borwein, Marcos López de Prado, Qiji Jim Zhu. [The Probability of Backtest Overfitting](https://www.davidhbailey.com/dhbpapers/backtest-prob.pdf). 2015 publication. Multiple-testing and selection risk.
[^42]: David H. Bailey, Marcos López de Prado. [The Deflated Sharpe Ratio: Correcting for Selection Bias, Backtest Overfitting, and Non-Normality](https://www.davidhbailey.com/dhbpapers/deflated-sharpe.pdf). 2014. Statistical adjustment, not a profitability guarantee.
[^43]: USCF Investments. [Partnership Tax Information](https://www.uscfinvestments.com/tax-information) and [Qualified Notices](https://www.uscfinvestments.com/qualified-notices). Current issuer pages. USO partnership status and qualified-notice mechanism; current exemption applicability not established.
[^44]: Internal Revenue Service. [Publication 515, 2026](https://www.irs.gov/publications/p515), partnership-interest withholding sections; [Notice 2023-8](https://www.irs.gov/pub/irs-drop/n-23-08.pdf). General section 1446(f) withholding and exceptions, not a taxpayer-specific determination.
[^45]: SEC Division of Trading and Markets. [Regulation SHO Frequently Asked Questions](https://www.sec.gov/rules-regulations/staff-guidance/trading-markets-frequently-asked-questions-7). Staff guidance, October 2017 version. Rule 201 price-test trigger and conditions.
[^46]: Internal Revenue Service. [Federal Income Tax Withholding and Reporting on Other Kinds of US-Source Income Paid to Nonresident Aliens](https://www.irs.gov/individuals/international-taxpayers/federal-income-tax-withholding-and-reporting-on-other-kinds-of-us-source-income-paid-to-nonresident-aliens). Current guidance. General treatment and exceptions.
[^47]: Internal Revenue Service. [Instructions for Form W-8BEN](https://www.irs.gov/instructions/iw8ben). Current instructions. Foreign status, beneficial ownership and applicable claims.
[^48]: Internal Revenue Service. [Some Nonresidents with US Assets Must File Estate Tax Returns](https://www.irs.gov/individuals/international-taxpayers/some-nonresidents-with-us-assets-must-file-estate-tax-returns). Current guidance. US-situs assets and filing threshold for specified estates.
[^49]: Interactive Brokers. [Short-Securities Availability](https://www.interactivebrokers.com/en/trading/short-securities-availability.php), [Short Sale Cost](https://www.interactivebrokers.com/en/pricing/short-sale-cost.php), and [Short-Selling Risk Disclosure, form 3085](https://gdcdyn.interactivebrokers.com/Universal/servlet/Registration_v2.formSampleView?formdb=3085). Current product/pricing pages and May 4, 2023 disclosure. Availability, variable borrow costs, recall/buy-in exposure and settled-position charging basis.
