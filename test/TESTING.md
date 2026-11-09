# NightshiftBackstop test coverage

The added suite tests the accepted Ethereum IMD implementation in `src/`. It uses the
existing vendored forge-std and local token/pool mocks; it needs no network, packages,
RPC endpoint, keys, or configuration changes. The original tests are retained.

## Run

```sh
forge build
FOUNDRY_FUZZ_SEED=0x40b3fa2208789092d333f2de3019d5226af3c2cbf2c7581a2c39ff5388ba2a21 forge test
```

During this assignment, build output and cache were placed in `test/scratch/` using
`FOUNDRY_OUT=test/scratch/out` and `FOUNDRY_CACHE_PATH=test/scratch/cache`. Nothing in
that directory is required by the delivered tests.

| File | Coverage |
| --- | --- |
| `NightshiftInvariant.t.sol`, `invariant/BackstopHandler.sol` | Four actors, overlapping offers, bids, claims, Shield deposits, partial/full withdrawals, donations, treasury withdrawals, pauses, oracle changes/failures, time, and rejected operations. 256 sequences of 128 calls. |
| `NightshiftFailurePaths.t.sol`, `helpers/AdversarialToken.sol` | Exact revert paths, atomic rollback of multi-token payouts, allowance/balance failures, taxed incoming quote, false/reverting/malformed/empty ERC-20 return data, blocked recipients, every custody entry point under callbacks, authorization, deadlines, and lock boundaries. 512 runs per fuzz property. |
| `NightshiftEconomicProperties.t.sol` | One-unit lots/fees, zero-fill refunds, 101 bids, split/merged bids, shuffled claims, frozen prices and pump eligibility, late Shield entry, deposit/withdraw cycles, disabled Shield purchasing, and two product rescalings through 65 real offers. 512 runs per fuzz property. |
| `NightshiftRevisionProperties.t.sol` | The revised implementation: Shield reservations fixed at offer creation (concurrent offers, late deposits, the exact withdrawal boundary of `ShieldFundsReserved`), the settlement-time check that the Shield buys only at or below the TWAP (fuzzed price moves and bid sizes, broken source), the fee share pro rata to absorbed lots, the bounded `createOffer` overload (exact `validUntil`/`minLotCost` boundaries), bids during a pause, the pump filter when the older TWAP rounds to zero, the price-source timelock (exact boundary, rescheduling, cancel, outsiders, mismatched pools) and the `...To` exits (zero recipient, outsiders, blocked bidder). 512 runs per fuzz property. |
| `UniV3MathProperties.t.sol` | Full-domain tick monotonicity, negative mean-tick rounding, both token orders, decimal-price reference vectors, quote round trips, 512-bit quotient inequalities, maximum values and arithmetic errors. 1,000 runs per fuzz property. |

## Invariant design

The following five manual discovery passes use the supplied Pashov fizz and Trail of
Bits references as methodology. Tests and this analysis were written for this project;
no upstream harness or additional dependency is copied.

| Pass | Property and implementation basis | Check |
| --- | --- | --- |
| Conservation | Escrows and bids enter custody; seller/bid claims release their entitlements; Shield purchases move liabilities internally (`createOffer`, `placeBid`, `settle`, `claimSeller`, `claimBid`). | Independent input/output ledgers equal both actual balances. Every unsettled and settled-but-unclaimed offer/bid is included. |
| State transitions | Offer price, deadline and seller are frozen; bids keep their owner, offer, size and prefix; settlement and claims are final. | Store immutable term hashes and bid inputs, compare after each call, reject repeated settlement/claims. |
| Round trips and rounding | Deposits/withdrawals cannot create principal; fills are floor/ceil proportional allocations; total fills exhaust the declared allocation; claims do not reset locks. | Per-actor principal bounds, exact fill totals, independent proportional inequalities, repeated cycles, claim-order equivalence, lock tests. |
| Adversarial value extraction and liveness | Unauthorized actors cannot claim/control other accounts; failed transfers must revert every effect; pause and oracle failure must not prevent exits. | Negative tests, token callbacks, rollback assertions, and complete unwind after every random sequence. |
| Protocol-specific accounting | Shield spends at most half its principal, at most 50 lots and at most its configured cap; pump-ineligible offers spend nothing; paid/pending rewards cannot exceed their allocation. The Shield buys exactly its creation-time reservation or nothing, and only while the frozen price is at or below the TWAP; open reservations never exceed half of the deposits; a Shield that absorbs nothing earns no fee. | Per-settlement spending and reservation checks, `shieldReservedQuote` equal to the sum over unsettled offers, withdrawals expected to fail with `ShieldFundsReserved` exactly when they would uncover a reservation, separate principal/token/fee ghost ledgers, late-depositor checks, and public settlement across two scales. |
| Owner timelock | A replacement price source never takes effect before `PRICE_SOURCE_DELAY`; cancel restores nothing but the pending slot. | Handler `rotateSource` schedules, cancels and applies against a second pool; early applies must fail with `PriceSourceDelayNotElapsed`. |

The global checks distinguish exact conservation from rounded user entitlements:

- Actual IMD equals outstanding seller/bid obligations, unspent Shield token rewards,
  and explicitly tracked donations.
- Actual USDC equals outstanding seller/bid obligations, Shield principal, unspent
  Shield fee rewards, treasury fees, and explicitly tracked donations.
- Compounded principal and pending gains must be covered by their respective pools.
  Rounding dust is retained in the exact ledger; donations cannot hide underfunding
  of any individual liability pool.
- The handler never mints after setup or edits application storage. The primary
  invariant market uses 18-decimal IMD, 6-decimal USDC, and realistic raw-unit ticks.
- Unexpected application reverts and handler postcondition failures set a persistent
  failure flag checked by the invariant. They are not silently caught as valid cases.
  The deterministic handler tour exercises every action and the exit routine.
- After every sequence, time advances beyond all locks/deadlines and all offers,
  bids, gains, deposits and treasury claims are closed while entry is paused and
  observations fail. This checks that solvency also results in executable exits.

The arithmetic suite checks `q*d <= a*b < (q+1)*d` using a separate 128-bit-limb
multiplication implementation, rather than reproducing the contract's modular
inverse division algorithm. Decimal quote fixtures use `1.0001 ** tick` calculated
at 110 decimal digits. The rescaling test bounds reward loss as well as solvency.

## Limits

These are local contract tests, not live-chain oracle/liquidity verification. No fork
block or RPC variable was supplied. Mock ERC-20 behaviour exercises compatibility
and failure handling, not the current administration of the real IMD or USDC token.
The primary random campaign does not traverse the whole `uint256` economic domain;
arithmetic extremes and long Shield rescaling sequences have dedicated tests.
The owner-selected oracle is a trust assumption of the implementation.

## Revision notes

The implementation was revised after the first version of this suite. The tests changed
only where the behaviour changed on purpose:

- `createOffer` is overloaded, so the handler and callback tests encode
  `createOffer(uint256)` by signature.
- Bids are no longer pausable. The handler now bids during pauses and counts those bids.
- Fees go to the Shield only for lots it absorbed. The zero-cap test now asserts that
  idle depositors earn nothing and the treasury takes the whole fee
  (`test_zeroShieldCapPaysBidFeesToTreasuryNotIdleDepositors`).
- A second `setPriceSource` only schedules the change. The frozen-price test now asserts
  that the old source stays in force.

No defect was found in the revision. Two trade-offs are documented here rather than
reported as defects:

- Open reservations can block withdrawals, by design. Anyone who keeps creating offers
  can hold up to half of the Shield's deposits in reservations, so withdrawals larger
  than the uncommitted part revert until those offers settle. Each such offer sells to
  the Shield at the discount plus the 3 % fee, which makes this costly to sustain.
- Settlement is permissionless, so the settler picks the block. If the pool TWAP is
  below the frozen lot cost in that block, the Shield's reservation goes to bidders
  instead.
