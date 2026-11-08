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
| `createOffer(amount)` | any seller | `amount` is rounded down to 100 equal lots (`LOTS_PER_OFFER`) and held in escrow. The price is frozen: `lotCost = ceil(lotSize × TWAP × (1 − discount))`. The offer cannot be cancelled. Bidding stays open for `OFFER_WINDOW` (1 h). |
| `placeBid(offerId, lots)` | IMD holders | Each bid is 1–100 whole lots. The bidder locks `lots × lotCost` USDC. The bidder must hold at least `minBidderHolding` IMD when bidding. The seller cannot bid on their own offer. Late bids (`timestamp ≥ deadline`) are rejected. |
| `settle(offerId)` | anyone, after the deadline | Needs no oracle and moves no funds. The Shield takes `s = min(50 lots, ⌊shieldPerOfferCap / lotCost⌋, ⌊50 % of Shield deposits / lotCost⌋)` lots. If the pump filter tripped at creation, `s` is 0. Bidders then fill `F = min(100 − s, total bid lots)`. Lots left over go back to the seller. |
| `claimBid(bidId)` | bidder | Pays out the bid's filled lots in IMD and refunds the USDC for unfilled lots. |
| `claimSeller(offerId)` | seller | Pays out `gross − 3 % fee` in USDC and returns any unabsorbed IMD. |
| `shieldDeposit / shieldWithdraw / shieldClaimGains` | Shield depositors | Depositors put USDC into a pool. The pool buys its slice of each offer at the discounted price, and depositors earn 80 % of the fees. Withdrawals open 30 days after your latest deposit. Gains can be claimed at any time. |
| `withdrawTreasury()` | anyone | Sends the treasury's share of fees to `treasury`. |

### Pricing (BACKSTOP economic-spec §4)

Prices come from a Uniswap v3 IMD/USDC pool, set by the owner as `priceSource`:

```
TWAP_now  = mean tick over the last TWAP_WINDOW (30 min)
TWAP_past = mean tick over the same window, MOMENTUM_LOOKBACK (1 h) earlier
m         = TWAP_now / TWAP_past − 1
discount  = clamp(5 % + 0.25·max(m,0) − 0.15·max(−m,0), 2 %, 12 %)
```

The Shield takes no slice of an offer created when `m > +20 %` (pump filter).

### Allocation when oversubscribed

Bid `i` has `c_i` lots and comes after `Q_i` lots of earlier bids. With `C` total lots bid and `F` lots
filled, it receives `ceil((Q_i + c_i)·F / C) − ceil(Q_i·F / C)` lots. Every bid gets the floor or the
ceiling of its pro-rata share, and the totals add up to exactly `F` (checked by a fuzz test).
BACKSTOP adds a random offset from slot hashes. **This port uses no randomness at all.** The offset is
fixed at zero, because block values can be manipulated and the floor/ceil rounding is worth very little.
Allocation is computed lazily at claim time, so settlement is O(1) however many bids there are.

### Fees

`TRADE_FEE_BPS = 300` (3 %), rounded up. The seller pays it on the absorbed lots (Shield slice plus
bidder fills). Absorbers pay no fee. `SHIELD_FEE_SHARE_BPS = 8_000` of the fee goes to Shield
depositors. That is BACKSTOP's 70 % holder-chest share plus its 10 % Shield share, explained below.
The remaining 20 % goes to `treasury`, which starts as the owner. If the Shield is empty, the whole fee
goes to the treasury.

### Shield accounting

The Shield uses Liquity stability-pool accounting:
- A running product `P` tracks how much each deposit has been spent.
- `S` accumulates IMD gains and `G` accumulates fee gains.
- `P` is rescaled by 1e9 whenever it drops below 1e9.

All rounding goes down, so the amounts owed never exceed what the contract holds (tested). The Shield
spends at most 50 % of its deposits on one offer, so the pool can never be fully drained.

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
| `SHIELD_MAX_FUNDS_USE_BPS` | 5 000 | my choice: caps Shield spending per offer at half its deposits |
| `SHIELD_MIN_LOCK` | 30 days | spec. Restarts on every deposit. |

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
| Price source | `setPriceSource(pool)` → `PriceSourceSet` | A Uniswap v3 IMD/USDC pool | Read at build time from the Uniswap v3 factory `0x1F98431c8aD98523631AE4a59f267346ea31F984`: the 0.3 % pool `0x894d4e6d3d2abc64fc0de0e4e2ea63a93bc9c520` holds the liquidity, and the 1 % pool `0x3a6a81b9950bcdfc01eff5ff599c31e919576a5f` was empty. **First** call `increaseObservationCardinalityNext(≥ 600)` on the pool (its cardinality was 1 at build time). Then wait at least 90 minutes (`TWAP_WINDOW + MOMENTUM_LOOKBACK`) for history to build up. Until then `observe` reverts and so does `createOffer`. |
| Treasury | `setTreasury(addr)` → `TreasurySet` | Where the 20 % fee share goes | Owner's choice. Defaults to the owner. |
| Pause | `setPaused(bool)` → `PausedSet` | Emergency stop for new offers, bids and Shield deposits | Owner's choice |

Until `priceSource` is set, `createOffer` and `quoteLot` revert with `PriceSourceNotConfigured`. Bids,
settlement and the Shield do not need it.

## Administrative powers and trust assumptions

- **Owner** (two-step transfer: `transferOwnership` then `acceptOwnership`) can:
  - set or change the price source. A malicious pool could misprice *new* offers. Existing offers keep their frozen price.
  - set the treasury.
  - pause entry.

  The owner **cannot** pause or block settlement, claims, Shield withdrawals or treasury withdrawal. It
  cannot move escrowed funds, change fees or parameters, or upgrade the contract. There is no sweep, no
  proxy, no `delegatecall` and no `selfdestruct`.
- **TWAP oracle**: a 30-minute v3 TWAP can be moved by someone willing to hold a skewed price across
  many blocks. A shallow pool makes that cheaper. The discount is capped at 12 %, and the pump filter
  stops the Shield buying after a +20 % move, but a seller who pushes the TWAP up still sells high to
  bidders. Bidders choose whether to bid after seeing `lotCost`.
- **"Existing holder"** means the bidder's IMD balance at the moment of bidding. A flash loan or a
  second wallet gets past this check. BACKSTOP measures tenure with a Token-2022 transfer hook, which
  IMD, an existing OFT, cannot get. The seller can also bid from a second address.
- **Tokens**: transfers must deliver the exact amount, so fee-on-transfer tokens are rejected. If USDC
  blacklists a recipient, only that recipient's claim fails. Everyone else's claims and settlement go
  through, because all payouts are pulled by the recipient.
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

- **Owner**: set and maintain the price source (pool cardinality), keep the owner key safe, and use the
  pause only in emergencies.
- **Anyone or a keeper**: call `settle(offerId)` after each deadline. It is permissionless and cheap.
  Users then claim their own funds. Nothing ever expires, so unclaimed funds stay claimable forever.
- **Before release**: these tests are not an audit. An independent adversarial review is required,
  because this contract holds user funds.

## Build and test

```
forge build
forge test        # 40 tests: unit, failure paths, reentrancy, blocked recipient, Shield rescale, fuzzed conservation
forge fmt --check
```

The compiler is pinned to solc 0.8.26 with `bytecode_hash = "none"`. forge-std is vendored in
`lib/forge-std` (MIT). `src/libraries/UniV3Math.sol` ports Uniswap v3 `TickMath`/`FullMath`
(GPL-2.0-or-later), so `NightshiftBackstop.sol` is GPL-2.0-or-later as well.
