# NightshiftBackstop: the BACKSTOP exit mechanic for IMD on Ethereum

This is an EVM port of the core mechanic of [RobertKodes/backstop](https://github.com/RobertKodes/backstop),
built for the **IMD** token on Ethereum (chain id 1) and the [NIGHTSHIFT](https://getnightshift.tech) project,
which is built on IMD.

BACKSTOP turns a sell into a time-limited, discounted offer to existing holders, so a seller does not
dump on the pool. Holders absorb the offer with USDC. A pooled **Shield** gets a priority slice, and
whatever nobody absorbs goes back to the seller. Nothing here is a security or an investment product.
Fills are not guaranteed, offers cannot be cancelled, and Shield deposits are time-locked.

One contract is deployed: `src/NightshiftBackstop.sol`. It deploys no token, pool or distributor.

## How it works

| Step | Who | What happens |
|---|---|---|
| `createOffer(amount, minLotCost, validUntil)` | any seller | `amount` is rounded down to 100 equal lots (`LOTS_PER_OFFER`) and held in escrow. The price is frozen: `lotCost = ceil(lotSize × TWAP × (1 − discount))`. The call reverts if `lotCost < minLotCost` (`LotCostBelowMinimum`) or if it is mined after `validUntil` (`OfferExpired`). The offer cannot be cancelled. Bidding stays open for `OFFER_WINDOW` (1 h). `createOffer(amount)` is the same call with no bound: it accepts whatever the pool reports in the mined block, so do not send it through a public mempool. |
| (at creation) | the Shield | Unless the pump filter trips, the Shield **reserves** `r = min(50 lots, ⌊shieldPerOfferCap / lotCost⌋, ⌊(50 % of Shield deposits − quote already reserved for unsettled offers) / lotCost⌋)` lots. This is the most it will ever take from this offer. Deposits made later do not change it. |
| `placeBid(offerId, lots)` | IMD holders | Each bid is 1–100 whole lots. The bidder locks `lots × lotCost` USDC. The bidder must hold at least `minBidderHolding` IMD when bidding. The seller cannot bid on their own offer. Late bids (`timestamp ≥ deadline`) are rejected. Bids are not pausable. |
| `settle(offerId)` | anyone, after the deadline | Moves no funds. It reads the pool once more: the Shield buys its `r` reserved lots only if `lotCost ≤` the 30-minute TWAP value of a lot **at settlement**. If the price fell below the frozen price, or the pool cannot be read, the Shield buys nothing (`s = 0`); settlement itself never reverts because of the pool. Bidders then fill `F = min(100 − s, total bid lots)`. Lots left over go back to the seller. |
| `claimBid(bidId)` / `claimBidTo(bidId, to)` | bidder | Pays out the bid's filled lots in IMD and refunds the USDC for unfilled lots. |
| `claimSeller(offerId)` / `claimSellerTo(offerId, to)` | seller | Pays out `gross − 3 % fee` in USDC and returns any unabsorbed IMD. |
| `shieldDeposit`, `shieldWithdraw` / `shieldWithdrawTo`, `shieldClaimGains` / `shieldClaimGainsTo` | Shield depositors | Depositors put USDC into a pool. The pool buys its slice of each offer at the discounted price, and depositors earn 80 % of the fee on the lots the Shield absorbs. Withdrawals open 30 days after your latest deposit, and cannot take funds reserved for unsettled offers (`ShieldFundsReserved`). Gains can be claimed at any time. |
| `withdrawTreasury()` | anyone | Sends the treasury's share of fees to `treasury`. |

### Pricing (BACKSTOP economic-spec §4)

Prices come from a Uniswap v3 IMD/USDC pool, set by the owner as `priceSource`:

```
TWAP_now  = mean tick over the last TWAP_WINDOW (30 min)
TWAP_past = mean tick over the same window, MOMENTUM_LOOKBACK (1 h) earlier
m         = TWAP_now / TWAP_past − 1
discount  = clamp(5 % + 0.25·max(m,0) − 0.15·max(−m,0), 2 %, 12 %)
```

The Shield takes no slice of an offer created when `m > +20 %` (pump filter). If the older window values
a lot at zero quote units, `m` is reported as the largest value (`type(int128).max`), so that rise trips
the filter too.

The pump filter compares two windows of the same pool, so it cannot see a price that was held for both of
them. Two further guards cover that:

- **Settlement-time bound.** Bidders see `lotCost` and choose. Shield depositors cannot choose, so the
  Shield buys only if `lotCost` is still at or below the pool TWAP when `settle` runs. A seller who
  inflates the TWAP before `createOffer` must keep it inflated until settlement is mined, and anyone may
  settle the moment the deadline passes.
- **Seller's bound.** `minLotCost` and `validUntil` let a seller refuse an offer priced below what they
  saw, whatever moved the TWAP in between.

### Allocation when oversubscribed

Bid `i` has `c_i` lots and comes after `Q_i` lots of earlier bids. With `C` total lots bid and `F` lots
filled, it receives `ceil((Q_i + c_i)·F / C) − ceil(Q_i·F / C)` lots. Every bid gets the floor or the
ceiling of its pro-rata share, and the totals add up to exactly `F` (checked by a fuzz test).
BACKSTOP adds a random offset from slot hashes. **This port uses no randomness at all.** The offset is
fixed at zero, because block values can be manipulated and the floor/ceil rounding is worth very little.
Allocation is computed lazily at claim time, so settlement is O(1) however many bids there are.

### Fees

`TRADE_FEE_BPS = 300` (3 %), rounded up. The seller pays it on the absorbed lots (Shield slice plus
bidder fills). Absorbers pay no fee. Shield depositors receive `SHIELD_FEE_SHARE_BPS = 8_000` of the
fee **on the lots the Shield absorbed**: `shieldFee = fee × 80 % × s / (s + F)`. That share is
BACKSTOP's 70 % holder-chest share plus its 10 % Shield share, explained below. Everything else goes
to `treasury`, which starts as the owner: 20 % of the fee on Shield lots and the whole fee on lots
bought by bidders. When the Shield absorbs nothing (empty, dust, pump filter, price bound), the whole
fee goes to the treasury. A deposit that cannot absorb a lot therefore earns no fee, and no fee is ever
credited to a Shield with no live deposits.

### Shield accounting

The Shield uses Liquity stability-pool accounting:
- A running product `P` tracks how much each deposit has been spent.
- `S` accumulates IMD gains and `G` accumulates fee gains.
- `P` is rescaled by 1e9 whenever it drops below 1e9.

All rounding goes down, so the amounts owed never exceed what the contract holds (tested).

The Shield's commitments are counted across offers, not per offer. `shieldReservedQuote` is the quote
reserved for all unsettled offers. A new offer can reserve only what is left of 50 % of the deposits,
and a withdrawal reverts if it would leave less than twice the reserved amount. So at most half of the
Shield is committed at any time, however an escrow is split into offers, and one absorption never takes
more than half of the deposits. Settling an offer releases its reservation whether or not the Shield
bought.

What the Shield does **not** do is fix the set of depositors at creation. The lots are bought at
settlement and shared among the deposits present then. Someone who deposits during an offer's window
shares the reserved lots (and the 30-day lock) with earlier depositors; they cannot enlarge the slice or
take lots from bidders. Someone who withdraws unreserved funds before settlement leaves the reserved
lots to the depositors who stay. This is the same behaviour as a Liquity stability pool.

## Parameters

Constants are BACKSTOP's `economic-spec.md` defaults. Where I changed one for Ethereum, the reason is given.

| Name | Value | Note |
|---|---|---|
| `LOTS_PER_OFFER` | 100 | spec |
| `OFFER_WINDOW` | 1 hour | spec has 600 s. Raised because Ethereum blocks are 12 s and bidders need time. |
| `TRADE_FEE_BPS` | 300 | spec, 3 % |
| `SHIELD_FEE_SHARE_BPS` | 8 000 | spec chest 70 % + Shield 10 % |
| `BASE / K_UP / K_DOWN / MIN / MAX discount` | 500 / 2 500 / 1 500 / 200 / 1 200 bps | spec |
| `TWAP_WINDOW` | 30 min | spec has 300 s. Longer on Ethereum to make manipulation more expensive. |
| `MOMENTUM_LOOKBACK` | 1 hour | spec |
| `SHIELD_MAX_PREMIUM_BPS` | 2 000 | spec pump filter |
| `SHIELD_MAX_SHARE_BPS` | 5 000 | spec |
| `SHIELD_MAX_FUNDS_USE_BPS` | 5 000 | my choice: caps what the Shield commits to all unsettled offers together at half its deposits |
| `SHIELD_MIN_LOCK` | 30 days | spec. Restarts on every deposit. |
| `PRICE_SOURCE_DELAY` | 37 days (`SHIELD_MIN_LOCK + 7 days`) | my choice: a replacement price source waits this long, so every deposit locked when the change is announced has 7 days to leave before it applies |

### Constructor arguments for the launch

| # | Argument | Value | Source |
|---|---|---|---|
| 1 | `owner_` | `$owner` = `0x6c4c78f2c3bdf4c4318fe305fb1c8bc1694d19b5` | launch owner. It is also the initial treasury. |
| 2 | `token_` | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | IMD on Ethereum. Code, `symbol()` = IMD and `decimals()` = 18 checked on chain 1. |
| 3 | `quote_` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | USDC on Ethereum. Code, `symbol()` = USDC and `decimals()` = 6 checked. |
| 4 | `minOfferSize_` | `1000000000000000000000` (1,000 IMD) | 0.01 % of IMD's 10M supply (spec) |
| 5 | `shieldPerOfferCap_` | `10000000000` (10,000 USDC) | spec |
| 6 | `minBidderHolding_` | `1000000000000000000` (1 IMD) | my choice for "existing holders" |

The constructor calls no other contract and sends no ETH. It runs on an empty chain.
`script/DeployNightshiftBackstop.s.sol` holds the same values as constants, and
`test/DeployNightshiftBackstop.t.sol` tests them. IMD's factory does the actual deployment; this
assignment broadcasts nothing.

## After launch

| Setting | Setter (owner only, emits an event) | What to set it to | Where to get it |
|---|---|---|---|
| Price source (first time, immediate) | `setPriceSource(pool)` → `PriceSourceSet` | A Uniswap v3 IMD/USDC pool **with real two-sided liquidity** (see the oracle warning below) | Read at build time from the Uniswap v3 factory `0x1F98431c8aD98523631AE4a59f267346ea31F984`: the 0.3 % pool `0x894d4e6d3d2abc64fc0de0e4e2ea63a93bc9c520` holds the liquidity, and the 1 % pool `0x3a6a81b9950bcdfc01eff5ff599c31e919576a5f` was empty. **First** call `increaseObservationCardinalityNext(≥ 600)` on the pool (its cardinality was 1 at build time). Then wait at least 90 minutes (`TWAP_WINDOW + MOMENTUM_LOOKBACK`) for history to build up. Until then `observe` reverts and so does `createOffer`. |
| Price source (replacement, delayed) | `setPriceSource(pool)` → `PriceSourceChangeScheduled`, then `applyPriceSource()` → `PriceSourceSet` after `PRICE_SOURCE_DELAY` (37 days). `cancelPriceSourceChange()` → `PriceSourceChangeCancelled` drops it. | Another Uniswap v3 IMD/USDC pool, for example after liquidity migrates | Same factory. The old source keeps pricing offers until `applyPriceSource` succeeds. Pause new offers meanwhile if the old pool is no longer usable. |
| Treasury | `setTreasury(addr)` → `TreasurySet` | Where the treasury's fee share goes | Owner's choice. Defaults to the owner. |
| Pause | `setPaused(bool)` → `PausedSet` | Emergency stop for new offers and Shield deposits | Owner's choice |

Until `priceSource` is set, `createOffer`, `quoteLot`, `twapLotValue` and `shieldDeposit` revert with
`PriceSourceNotConfigured`. A Shield deposit is therefore never made before the pool that will price it
is public.

**Oracle warning for the launch pool.** Read on chain 1 during this revision, the
0.3 % pool `0x894d…c520` held about 0.21 USDC against about 6,550 IMD, with observation cardinality 1.
A pool like that can be moved for almost nothing and holds no price history. The contract cannot verify
depth for the owner. Before setting it as the price source, the owner must make sure the pool has deep
liquidity on both sides and enough cardinality, and should keep Shield deposits small relative to the
cost of moving that pool. The guards in this contract (settlement-time bound, 50 % commitment cap,
`shieldPerOfferCap`, pump filter) limit the damage of a manipulated TWAP; they do not make a shallow
pool a sound oracle.

## Administrative powers and trust assumptions

- **Owner** (two-step transfer: `transferOwnership` then `acceptOwnership`) can:
  - choose the first price source, and schedule a replacement that applies 37 days later. The contract
    checks only that the pool's `token0`/`token1` are IMD and USDC. It does not check that the pool
    comes from the Uniswap factory or that it is liquid, so **the price source is trusted**: a source
    that reports a false price misprices offers, and the Shield, which must buy, pays that price
    (bounded by the 50 % commitment cap and `shieldPerOfferCap` per offer, and by nothing else). That
    is how an owner could move Shield deposits to itself as a seller. The delay is what protects
    depositors: the source in force is public before anyone can deposit, a replacement is announced
    37 days ahead by an event, and a deposit locked at the announcement can be withdrawn at least
    7 days before the replacement applies. A deposit made after the announcement accepts the pending
    source.
  - set the treasury.
  - pause new offers and Shield deposits. A pause does not stop bids on open offers, settlement, claims
    or withdrawals, so it cannot be used to shut bidders out of an open offer or to hold funds.

  The owner **cannot** block settlement, claims, Shield withdrawals or treasury withdrawal, change fees
  or parameters, or upgrade the contract. Apart from the price-source power described above, it has no
  way to move escrowed funds. There is no sweep, no proxy, no `delegatecall` and no `selfdestruct`.
- **TWAP oracle**: a 30-minute v3 TWAP can be moved by someone willing to hold a skewed price across
  many blocks. A shallow pool makes that cheaper. The discount is capped at 12 %, the pump filter
  stops the Shield buying after a +20 % move, and the Shield re-checks the TWAP at settlement. A seller
  who holds the TWAP up from 90 minutes before `createOffer` until settlement still sells high to the
  Shield's reserved slice and to bidders. Bidders choose whether to bid after seeing `lotCost`; Shield
  depositors rely on the pool being expensive to move.
- **Settlement timing**: `settle` is permissionless and the Shield's purchase depends on the TWAP in
  the block it is mined in. Whoever settles first decides that block, so depositors and sellers both
  have a reason to run a keeper at the deadline.
- **"Existing holder"** means the bidder's IMD balance at the moment of bidding. A flash loan or a
  second wallet gets past this check. BACKSTOP measures tenure with a Token-2022 transfer hook, which
  IMD, an existing OFT, cannot get. The seller can also bid from a second address.
- **Tokens**: transfers must deliver the exact amount, so fee-on-transfer tokens are rejected. If USDC
  blacklists a recipient, only that recipient's claim fails. Everyone else's claims and settlement go
  through, because all payouts are pulled by the recipient. The blocked party can still collect both
  legs at another address with `claimSellerTo`, `claimBidTo`, `shieldClaimGainsTo` or `shieldWithdrawTo`.
- **Reentrancy**: every state-changing function is `nonReentrant`, and state is updated before any
  transfer (tested with a reentrant token).

## Differences from BACKSTOP (scope)

Ported: offers, lot bids, the counter-cyclical discount, the Shield priority slice and Shield
accounting, the pump filter, fees, and the "no cancel, fills not guaranteed" rules.

Not ported, and why:
- **Transfer hook, tenure and per-wallet chests**: IMD already exists and has no hook. The chest fee
  share goes to the Shield instead.
- **Remainder sold to the AMM**: unabsorbed lots go back to the seller, who keeps full control of the
  exit.
- **Return Ticket, SOL treasury floor and redemption, launchpad, lending adapter and AI agent**: these
  need BACKSTOP's own token and AMM. They are possible follow-ups.
- **Early close and random offset**: not included.
- **Shield lock multipliers**: dropped. The Shield uses one 30-day lock.

**NIGHTSHIFT's own $SHIFT token** can use the same contract, deployed again with `token_ = SHIFT`. I
could not find $SHIFT's chain or contract address, so this launch deploys the IMD instance only.

## Operational responsibilities

- **Owner**: set and maintain the price source (pool depth and cardinality), announce a replacement
  37 days ahead, keep the owner key safe, and use the pause only in emergencies.
- **Sellers**: use `createOffer(amount, minLotCost, validUntil)` with `minLotCost` taken from
  `quoteLot(amount / 100)`.
- **Shield depositors**: watch for `PriceSourceChangeScheduled`, and leave before `priceSourceActivatesAt`
  if you do not accept the new pool.
- **Anyone or a keeper**: call `settle(offerId)` after each deadline. It is permissionless and cheap.
  Users then claim their own funds. Nothing ever expires, so unclaimed funds stay claimable forever.
- **Before release**: these tests are not an audit. An independent adversarial review is required,
  because this contract holds user funds.

## Build and test

```
forge build
forge test        # 58 tests: unit, failure paths, reentrancy, blocked recipient, Shield rescale, price bounds, delayed price source, fuzzed conservation
forge fmt --check
```

The compiler is pinned to solc 0.8.26 with `bytecode_hash = "none"`. forge-std is vendored in
`lib/forge-std` (MIT). `src/libraries/UniV3Math.sol` ports Uniswap v3 `TickMath`/`FullMath`
(GPL-2.0-or-later), so `NightshiftBackstop.sol` is GPL-2.0-or-later as well.
