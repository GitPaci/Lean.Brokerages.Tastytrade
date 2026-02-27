# Options Trading Automation — System Design

**Platform:** QuantConnect Lean + Tastytrade Brokerage Plugin
**Philosophy:** Risk-first, probability-driven, Greek-controlled short premium
**Basis:** *The Unlucky Investor's Guide to Options Trading*, *Strategies Blueprint*, *tastytrade Greeks & Risk Tools*

---

## Table of Contents

1. [Foundational Assumptions](#1-foundational-assumptions)
2. [Tastytrade Integration Architecture](#2-tastytrade-integration-architecture)
3. [Volatility Regime Detection](#3-volatility-regime-detection)
4. [Strategy Selection Engine](#4-strategy-selection-engine)
5. [Strike Selection & Entry Rules](#5-strike-selection--entry-rules)
6. [Greek Exposure Control Engine](#6-greek-exposure-control-engine)
7. [Position Sizing Framework](#7-position-sizing-framework)
8. [Trade Management Engine](#8-trade-management-engine)
9. [Binary Event Filter](#9-binary-event-filter)
10. [Portfolio Risk Controller](#10-portfolio-risk-controller)
11. [Lean Algorithm Architecture](#11-lean-algorithm-architecture)
12. [Backtesting & Walk-Forward Methodology](#12-backtesting--walk-forward-methodology)
13. [Failure Modes & Stress Tests](#13-failure-modes--stress-tests)
14. [What the System Must Never Do](#14-what-the-system-must-never-do)
15. [Implementation Roadmap](#15-implementation-roadmap)

---

## 1. Foundational Assumptions

### Market Model

The system adopts the **semi-strong Efficient Market Hypothesis** as its operating constraint:

- Price direction is not predictable with consistent edge.
- Statistical edge exists in:
  - Selling **implied volatility** that is systematically overpriced vs. realized volatility.
  - Capturing **time decay** (Theta) through defined-risk spread structures.
  - Managing **position sizing** so that tail events do not cause ruin.

### Edge Sources (Ranked by Reliability)

| Rank | Source | Mechanism |
|------|--------|-----------|
| 1 | Position sizing | Survival through drawdowns |
| 2 | Implied volatility premium | IV > RV historically (~70% of time) |
| 3 | Theta capture | Credit spreads decay toward zero |
| 4 | POP-based entry | ~70% POP credit spreads win more often |
| 5 | Structured exit | 50% profit close improves expectancy |

### Non-Negotiables

- **No naked short calls.** Max loss must always be defined.
- **No price prediction.** The system does not forecast direction.
- **No holding to expiration.** Gamma risk in final week is unacceptable.
- **No 0DTE without explicit gamma controls** (treated as a separate, capped sub-strategy if used at all).

---

## 2. Tastytrade Integration Architecture

### Available API Capabilities (via Lean Plugin)

The `TastytradeBrokerage` plugin exposes:

```
GetHistory()              → Historical OHLCV + options chain history
GetAccountHoldings()      → Current positions with Greeks
GetCashBalance()          → Net liquidity, buying power
PlaceOrder()              → Spreads via multi-leg combo orders
GetOpenOrders()           → Active order status
IDataQueueHandler         → Real-time options chain streaming
IDataQueueUniverseProvider→ Option chain universe (all strikes/expiries)
```

### Options Chain Data Requirements

For each underlying under evaluation, the system requires:

```csharp
// Per contract, streamed via IDataQueueHandler
struct OptionContractData {
    decimal ImpliedVolatility;   // IV per strike
    decimal Delta;
    decimal Gamma;
    decimal Theta;
    decimal Vega;
    decimal Bid, Ask, Last;
    decimal OpenInterest;
    DateTime Expiration;
    decimal Strike;
    OptionRight Right;           // Call / Put
}
```

### IVR Computation

Tastytrade exposes IV per underlying. The system must compute **IV Rank (IVR)** locally:

```
IVR = (Current IV - 52-week IV Low) / (52-week IV High - 52-week IV Low) × 100
```

- **IVR > 30** → High IV regime → sell premium (credit spreads)
- **IVR < 30** → Low IV regime → buy premium (debit spreads) or stay flat

Store 252-day rolling IV history per underlying using Lean's `RollingWindow<decimal>`.

---

## 3. Volatility Regime Detection

### IVR Thresholds

```
IVR >= 50  → Strongly elevated → preferred credit spread environment
IVR 30-50  → Moderately elevated → reduced size credit spreads
IVR 15-30  → Neutral → debit spreads or no trade
IVR < 15   → Suppressed IV → avoid short premium entirely
```

### IV Percentile vs. IV Rank

The system tracks **both** metrics:

- **IVR** is skewed by recent spikes (one large spike sets the "high" for a year).
- **IV Percentile** (what % of past 252 days had lower IV) is more robust.

```csharp
decimal ivPercentile = _ivHistory.Count(x => x < currentIV) / (decimal)_ivHistory.Count * 100;
```

Trade signal requires **both** IVR and IV Percentile to confirm the regime before sizing up.

### Volatility Term Structure

Before entry, inspect the term structure:

- **Contango** (near-term IV < far-term IV): Normal. Short near-term spreads favored.
- **Backwardation** (near-term IV > far-term IV): Elevated event risk. Reduce size or skip.

---

## 4. Strategy Selection Engine

### Decision Matrix

```
┌─────────────────────┬──────────────────────────┬───────────────────────────┐
│ Condition           │ Strategy                 │ Notes                     │
├─────────────────────┼──────────────────────────┼───────────────────────────┤
│ IVR > 30, Neutral   │ Put Credit Spread        │ Default high-IV play      │
│ IVR > 30, Bearish   │ Call Credit Spread       │ Cap upside risk           │
│ IVR > 30, Both      │ Iron Condor              │ Only if portfolio Delta ok │
│ IVR < 30, Bullish   │ Bull Call Debit Spread   │ Long Vega, defined risk   │
│ IVR < 30, Bearish   │ Bear Put Debit Spread    │ Long Vega, defined risk   │
│ Any, IV spike >50%  │ No new trades            │ Wait for stabilization    │
│ Earnings within 5d  │ No new trades            │ Binary event blackout     │
└─────────────────────┴──────────────────────────┴───────────────────────────┘
```

### Underlying Universe Filters

Before strategy selection, filter the universe:

```
Liquidity:        Average volume > 500,000 shares/day
Options volume:   Average daily options volume > 5,000 contracts
Bid-ask spread:   Options spread < 10% of mid price
Market cap:       > $5B (avoids manipulation / low float risk)
Sector limit:     Max 3 underlyings per sector (correlation control)
```

---

## 5. Strike Selection & Entry Rules

### Credit Spreads (High IV: IVR > 30)

**Put Credit Spread (Bullish bias or neutral):**

```
Short Put:  ~30 delta (probability ITM ≈ 30%, POP ≈ 70%)
Long Put:   ~10 delta (protection leg)
Width:      $5 or $10 wide (based on underlying price tier)
Credit:     Must collect ≥ 1/3 of spread width
            e.g., $5 wide spread → minimum $1.65 credit

DTE target: 30-45 days to expiration (theta decay is optimal here)
DTE min:    21 days (avoid Gamma acceleration zone)
```

**Call Credit Spread (Bearish bias):**

```
Short Call: ~30 delta
Long Call:  ~10 delta
Same width / credit rules as put credit spread
```

**Iron Condor (Neutral, high IV):**

```
Combine put credit spread + call credit spread
Net credit ≥ 1/3 of one wing width
Total portfolio Delta impact must stay within limits (see §6)
```

### Debit Spreads (Low IV: IVR < 30)

**Bull Call Debit Spread:**

```
Long Call:  ~60 delta (in-the-money or near ATM)
Short Call: ~40 delta (above current price)
Debit:      ≤ 50% of spread width (max risk = debit paid)
DTE target: 45-60 days (more time for directional move)
```

**Bear Put Debit Spread:**

```
Long Put:   ~60 delta
Short Put:  ~40 delta
Same debit / DTE rules
```

### Entry Validation Checklist

Before any order is placed:

- [ ] IVR confirms regime
- [ ] No binary event within 5 trading days
- [ ] Credit ≥ 1/3 width (credit) or debit ≤ 1/2 width (debit)
- [ ] DTE in 21–60 day window
- [ ] Bid-ask spread < 10% of mid
- [ ] Position size within §7 limits
- [ ] Portfolio Greeks within §6 limits after adding position
- [ ] Not adding 4th position in same sector

---

## 6. Greek Exposure Control Engine

### Per-Position Limits

```
Delta per position:    ≤ ±0.30 (short strike delta, defined by entry rules)
Gamma per position:    Monitor; close if expiry < 7 days and untested
Theta per position:    Target positive (credit) or neutral (debit)
Vega per position:     Short Vega (credit) or Long Vega (debit); not mixed
```

### Portfolio-Level Greek Constraints

These are hard limits. A proposed trade that breaches any of these is **rejected**:

```csharp
// As % of Net Liquidation Value
const decimal MAX_PORTFOLIO_DELTA   = 0.10m;  // ±10% of NLV
const decimal MAX_PORTFOLIO_VEGA    = 0.05m;  // ±5% of NLV (in dollar terms)
const decimal MAX_PORTFOLIO_GAMMA   = 0.02m;  // 2% of NLV (tail convexity cap)
const decimal TARGET_THETA_RATIO    = 0.001m; // Daily theta ≥ 0.1% of NLV (for credit book)
```

### Greek Monitoring Loop

Runs on every `OnData()` bar (daily resolution minimum):

```
1. Aggregate Greeks across all open positions
2. Compute portfolio Delta as % of NLV
3. If |portfolio Delta| > 8% → alert; consider hedging leg
4. If |portfolio Delta| > 10% → reject all new trades that increase exposure
5. If portfolio Gamma > 1.5% NLV AND any position DTE < 14 → flag for early close
6. If portfolio Vega short > 4% NLV AND IVR spikes > 20 pts intraday → alert
```

### Delta Hedging Policy

The system is **not** a delta-hedging engine. It manages Delta through:

- Selecting balanced put/call structures (Iron Condors for neutral Delta)
- Rolling the untested side when directional drift occurs
- **Not** using stock/futures to hedge (introduces undefined risk)

---

## 7. Position Sizing Framework

### Capital Allocation Rules

```
Max risk per spread:       2% of Net Liquidation Value
Max risk per underlying:   5% of NLV (across all positions in that ticker)
Max total at-risk capital: 30% of NLV (sum of all max losses)
Max positions open:        10 concurrent spread positions
```

### Spread Width Selection by NLV Tier

```
NLV < $25,000:   Use $2.50 wide spreads, 1 contract
NLV $25k-$100k:  Use $5 wide spreads, 1-3 contracts
NLV > $100k:     Use $5-$10 wide spreads, scaled contracts
```

### Contract Count Formula

```csharp
decimal maxRiskPerTrade = nlv * 0.02m;          // 2% of NLV
decimal maxLossPerSpread = spreadWidth * 100     // e.g., $5 wide = $500 max loss
                           - creditReceived * 100;
int contracts = (int)Math.Floor(maxRiskPerTrade / maxLossPerSpread);
contracts = Math.Max(1, Math.Min(contracts, MAX_CONTRACTS_CAP));
```

### Concentration Risk

- Max 3 positions in the same GICS sector.
- Max 1 position in any single underlying at a time.
- If market correlation spikes (VIX > 30), reduce `MAX_TOTAL_AT_RISK` to 15% NLV.

---

## 8. Trade Management Engine

### Profit Taking (Mandatory)

```
Credit spreads:  Close at 50% of max profit
                 e.g., $1.65 credit → close when position value = $0.82 debit
Debit spreads:   Close at 50% of max profit (width - debit paid)
Time limit:      Close at 21 DTE regardless of P&L (Gamma risk avoidance)
```

### Loss Management

```
Credit spreads:  Close at 200% of credit received (2x loss)
                 e.g., $1.65 credit → close if position costs $3.30 to close
Debit spreads:   Close at 50% of debit paid (accept half-loss)
```

### Defensive Rolling (Only When Justified)

Rolling is **not** mechanical. It requires all of the following:

```
Condition 1:  POP of original position has dropped below 33%
Condition 2:  Tested short strike Delta has moved to > 0.45
Condition 3:  DTE > 14 days remaining (enough time for roll to recover)
Condition 4:  Can roll for a net credit (free roll), or small debit with
              statistical improvement in breakeven
```

**Roll mechanic (spread):**

```
Roll only the TESTED LEG, not the full spread.
→ Buy back the short option that's been tested.
→ Sell a new short option further OTM at a new expiration.
→ Keep the long protection leg if it still provides value.
→ Never convert to undefined risk in the process.
```

### Monitoring Frequency

```
Check profit targets:     Daily at market open (or on each bar for live trading)
Check loss stops:         Intraday (real-time via IDataQueueHandler streaming)
Check DTE close rule:     Daily
Check Greek limits:       Every bar
```

---

## 9. Binary Event Filter

### Events Requiring Trade Blackout

- **Earnings announcements:** No new positions within 5 trading days before earnings.
- **FOMC decisions:** Reduce size 2 days before; no new Iron Condors.
- **CPI / major macro data:** Flag underlying's sector; reduce new entries that day.

### Detection in Lean

```csharp
// Use QC's built-in corporate events data
Schedule.On(MarketOpen, () => {
    foreach (var symbol in _watchlist) {
        var earningsDate = EarningsCalendar.GetNextEarnings(symbol);
        int daysToEarnings = (earningsDate - Time).Days;
        _blackoutSymbols[symbol] = daysToEarnings <= 5;
    }
});
```

### Post-Earnings Behavior

After earnings with an IV crush:

- If short Vega position → profits from crush → consider early close to lock in.
- Do not open new positions immediately after earnings; wait 1-2 bars for IV stabilization.

---

## 10. Portfolio Risk Controller

### Daily Risk Report (logged to Lean's `OnEndOfDay`)

```
Portfolio Summary:
  Net Liquidation Value:    $X
  Total at-risk capital:    $X (Y% of NLV)
  Open positions:           N

Greek Summary:
  Net Delta:     X (±Z% of NLV)
  Net Theta:     $X/day
  Net Vega:      $X per 1-pt IV move
  Net Gamma:     $X per 1% underlying move

Position Summary:
  [Symbol] [Strategy] [DTE] [POP] [Current P&L] [% of max profit]
```

### Circuit Breakers

```
IF daily P&L < -5% of NLV:
    → Stop opening new positions for the day
    → Alert (log warning via OnMessage)

IF weekly P&L < -10% of NLV:
    → Reduce all position sizes by 50% for 2 weeks
    → Alert

IF drawdown from peak > 20% NLV:
    → Close all positions
    → Suspend trading until manual review
    → This is the ruin-prevention circuit breaker
```

---

## 11. Lean Algorithm Architecture

### Class Structure

```
TastytradeOptionsAlgorithm : QCAlgorithm
│
├── VolatilityRegimeDetector
│     ├── ComputeIVR(symbol, lookback=252)
│     ├── ComputeIVPercentile(symbol, lookback=252)
│     └── GetRegime() → High / Neutral / Low
│
├── StrategySelector
│     ├── SelectStrategy(symbol, regime, bias) → StrategyType
│     └── ValidateEntryConditions(symbol, strategy) → bool
│
├── StrikeSelector
│     ├── FindCreditSpreadLegs(chain, targetShortDelta, targetLongDelta)
│     ├── FindDebitSpreadLegs(chain, targetLongDelta, targetShortDelta)
│     └── ValidateCreditRequirement(short, long, minCreditRatio) → bool
│
├── GreekController
│     ├── GetPortfolioGreeks() → GreekSummary
│     ├── ValidateNewPosition(legs) → bool
│     └── CheckCircuitBreakers() → RiskStatus
│
├── PositionSizer
│     ├── ComputeContracts(spreadWidth, credit, nlv) → int
│     └── CheckConcentrationLimits(symbol, sector) → bool
│
├── TradeManager
│     ├── CheckProfitTargets() → List<CloseOrder>
│     ├── CheckLossStops() → List<CloseOrder>
│     ├── CheckDTEClose() → List<CloseOrder>
│     └── EvaluateRollCandidates() → List<RollOrder>
│
├── BinaryEventFilter
│     ├── IsBlackedOut(symbol) → bool
│     └── RefreshEarningsCalendar()
│
└── RiskReporter
      └── GenerateDailyReport() → void
```

### Key Lean Integration Points

```csharp
// Brokerage-specific: use Tastytrade combo orders for spreads
var order = new ComboLimitOrder(
    legs: new List<Leg> {
        new Leg(shortPutContract, -1),  // Sell short put
        new Leg(longPutContract,  +1),  // Buy long put
    },
    limitPrice: creditTarget
);

// Subscribe to the full options chain
AddOption(underlying, Resolution.Minute);
option.SetFilter(universe => universe
    .Strikes(-10, +10)
    .Expiration(TimeSpan.FromDays(21), TimeSpan.FromDays(60))
    .IncludeWeeklys());

// Greeks available per contract
var contract = optionChain.Single(c => c.Symbol == shortPut);
decimal delta = contract.Greeks.Delta;
decimal theta = contract.Greeks.Theta;
decimal vega  = contract.Greeks.Vega;
decimal gamma = contract.Greeks.Gamma;
decimal iv    = contract.ImpliedVolatility;
```

---

## 12. Backtesting & Walk-Forward Methodology

### Backtest Configuration

```
Data:         Lean's options history (minute resolution for entries, daily for management)
Period:       Minimum 5 years, including at least one major volatility event
Slippage:     Fill at mid-price + 10% of bid-ask spread (conservative)
Commissions:  Tastytrade pricing: $0 equity options, $1/contract futures options
Margin:       Defined-risk spreads: width × contracts × 100 (no margin multiplier needed)
```

### Walk-Forward Protocol

```
In-sample period:    3 years (optimize IVR thresholds, delta targets, size %)
Out-of-sample:       1 year (validate without re-optimization)
Walk-forward step:   6 months (roll forward, re-calibrate in-sample window)
```

### Key Performance Metrics to Track

```
Win rate:           Target > 65% (credit spread POP)
Average win:        50% of max profit (by design)
Average loss:       ≤ 200% of credit (by stop rule)
Profit Factor:      Target > 1.5
Max drawdown:       Target < 15% NLV
Sharpe Ratio:       Target > 0.8
Theta decay capture:%  Actual P&L / theoretical max Theta P&L over period
IV premium capture: % of (IV - RV) monetized
```

### Regime-Specific Analysis

Analyze performance separately by:

- IVR quartile at trade entry
- DTE at entry
- Underlying sector
- Market regime (VIX < 15, 15-25, > 25)

---

## 13. Failure Modes & Stress Tests

### Identified Failure Modes

| Failure Mode | Trigger | Impact | Mitigation |
|---|---|---|---|
| Volatility spike | VIX doubles in < 5 days | Short Vega book hemorrhages | IVR entry filter, 200% stop |
| Gamma acceleration | DTE < 7, near short strike | Delta explodes, P&L nonlinear | 21-DTE mandatory close |
| Correlated blow-up | Bear market; all positions move together | All credit spreads lose simultaneously | Sector diversification, circuit breaker |
| Liquidity gap | Open interest dries up on leg | Cannot close at fair price | Liquidity filters at entry |
| IV surface inversion | Front month IV > back month (event) | Roll impossible for credit | Term structure check; blackout |
| Model failure | Greeks stale / incorrect from API | Wrong sizing / hedging | Cross-check Greeks with manual calc |

### Stress Scenarios (Backtest Validation Required)

```
Scenario 1: COVID-19 (Feb-Mar 2020) — VIX spikes from 15 to 85
  → Verify: circuit breaker fires, drawdown contained to < 20% NLV

Scenario 2: 2022 Rate Hike Cycle — sustained high IV, trending market
  → Verify: IVR filter reduces size during trending phases

Scenario 3: Flash Crash (any 2010-2020 intraday event)
  → Verify: intraday loss stops fire before EOD

Scenario 4: Low IV Regime (2017) — IVR persistently < 20
  → Verify: system switches to debit spreads or reduces activity

Scenario 5: Earnings Miss (individual stock, IV crush reversal)
  → Verify: binary event filter blocked position pre-earnings
```

---

## 14. What the System Must Never Do

```
NEVER:  Sell naked calls (undefined upside risk)
NEVER:  Hold to expiration (Gamma risk in final week)
NEVER:  Trade on price prediction or analyst targets
NEVER:  Open new positions when drawdown > 15% NLV
NEVER:  Roll a losing spread by converting to undefined risk
NEVER:  Add to a losing position to "average down"
NEVER:  Ignore portfolio Greeks to chase a high-premium trade
NEVER:  Trade 0DTE without a hard cap on total capital (< 1% NLV)
NEVER:  Use correlated underlyings to artificially inflate position count
NEVER:  Push credentials or API keys to version control
```

---

## 15. Implementation Roadmap

### Phase 1: Foundation (Weeks 1-4)

- [ ] Implement `GetHistory()` for options chains in `TastytradeBrokerage`
- [ ] Implement `IDataQueueUniverseProvider` for real-time chain streaming
- [ ] Build `VolatilityRegimeDetector` with IVR + IV Percentile
- [ ] Unit test: IVR computation against known historical values
- [ ] Unit test: Options chain parsing from Tastytrade API

### Phase 2: Strategy Engine (Weeks 5-8)

- [ ] Build `StrikeSelector` for credit and debit spreads
- [ ] Build `StrategySelector` with decision matrix
- [ ] Build `BinaryEventFilter` using earnings calendar
- [ ] Implement `ComboLimitOrder` for spread placement via Tastytrade API
- [ ] Unit test: Strike selection for each strategy type
- [ ] Unit test: Entry validation checklist

### Phase 3: Risk Engine (Weeks 9-12)

- [ ] Build `GreekController` with portfolio-level aggregation
- [ ] Build `PositionSizer` with NLV-based contract calculator
- [ ] Implement circuit breakers in `RiskReporter`
- [ ] Build `TradeManager` (profit targets, loss stops, DTE close)
- [ ] Unit test: Portfolio Greek constraints
- [ ] Unit test: Circuit breaker triggers

### Phase 4: Backtest & Validation (Weeks 13-16)

- [ ] Run 5-year backtest across credit and debit spread strategies
- [ ] Validate performance across all stress scenarios (§13)
- [ ] Walk-forward analysis on IVR thresholds
- [ ] Tune position sizing parameters
- [ ] Document regime-specific performance breakdowns

### Phase 5: Paper Trading & Live Deployment (Weeks 17-20)

- [ ] Paper trade for minimum 60 days
- [ ] Validate Greek reporting matches Tastytrade platform display
- [ ] Validate order fills match expected slippage model
- [ ] Enable live trading with minimum capital ($25k)
- [ ] Monitor daily risk report for first 30 live days before scaling

---

## Appendix A: Key Parameter Reference

```
IVR high threshold:       30
IVR preferred threshold:  50
Short strike delta:        0.30 (credit spreads)
Long strike delta:         0.10 (credit spreads)
DTE entry range:           21–60 days
DTE mandatory close:       21 days
Profit target:             50% of max profit
Loss stop (credit):        200% of credit received
Max risk per position:     2% NLV
Max risk per underlying:   5% NLV
Max total at-risk:         30% NLV
Max portfolio delta:       ±10% NLV
Max portfolio vega:        ±5% NLV
Circuit breaker (daily):   -5% NLV P&L
Circuit breaker (weekly):  -10% NLV P&L
Ruin prevention:           -20% NLV drawdown from peak
```

---

## Appendix B: Glossary

| Term | Definition |
|------|-----------|
| IVR | IV Rank: current IV vs. 52-week range, expressed 0–100 |
| IV Percentile | % of past 252 days with lower IV than today |
| POP | Probability of Profit: ~1 - short strike delta |
| NLV | Net Liquidation Value: total portfolio value |
| DTE | Days to Expiration |
| ATM | At The Money |
| OTM | Out of The Money |
| ITM | In The Money |
| Credit spread | Sell higher-premium option, buy cheaper protection |
| Debit spread | Buy option, sell cheaper option to reduce cost |
| Iron Condor | Credit put spread + credit call spread |
| Short Vega | Position profits when IV decreases |
| Long Vega | Position profits when IV increases |
| Roll | Close current position, open similar position at new strike/expiry |

---

*This document is a living design specification. Parameters marked with specific values (IVR thresholds, delta targets, sizing %) are initial hypotheses to be validated via backtesting and walk-forward analysis before live deployment.*
