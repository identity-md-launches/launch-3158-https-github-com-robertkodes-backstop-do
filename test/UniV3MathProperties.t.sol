// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {UniV3Math} from "src/libraries/UniV3Math.sol";

contract UniV3MathProbe {
    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return UniV3Math.mulDiv(a, b, d);
    }

    function meanTick(int56 older, int56 newer, uint32 period) external pure returns (int24) {
        return UniV3Math.meanTick(older, newer, period);
    }

    function sqrt(int24 tick) external pure returns (uint160) {
        return UniV3Math.getSqrtRatioAtTick(tick);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract UniV3MathPropertiesTest is Test {
    UniV3MathProbe internal probe = new UniV3MathProbe();
    address internal constant FIRST = address(1);
    address internal constant SECOND = address(2);

    function test_mulDivRejectsZeroDenominatorAndUnrepresentableQuotient() public {
        vm.expectRevert(UniV3Math.MulDivOverflow.selector);
        probe.mulDiv(0, 1, 0);
        vm.expectRevert(UniV3Math.MulDivOverflow.selector);
        probe.mulDiv(type(uint256).max, type(uint256).max, 0);
        vm.expectRevert(UniV3Math.MulDivOverflow.selector);
        probe.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max - 1);
        vm.expectRevert(UniV3Math.MulDivOverflow.selector);
        probe.mulDiv(uint256(1) << 200, uint256(1) << 100, uint256(1) << 44);
    }

    function test_mulDivZeroOneAndMaximum() public pure {
        assertEq(UniV3Math.mulDiv(0, type(uint256).max, 1), 0);
        assertEq(UniV3Math.mulDiv(1, 1, 2), 0);
        assertEq(UniV3Math.mulDiv(1, type(uint256).max, 1), type(uint256).max);
        assertEq(UniV3Math.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max), type(uint256).max);
        assertEq(UniV3Math.mulDiv(uint256(1) << 200, uint256(1) << 100, uint256(1) << 80), uint256(1) << 220);
    }

    function testFuzz_mulDivFitsOrdinaryIntegerArithmetic(uint128 a, uint128 b, uint256 dSeed) public pure {
        uint256 d = bound(dSeed, 1, type(uint256).max);
        assertEq(UniV3Math.mulDiv(a, b, d), uint256(a) * b / d);
    }

    function testFuzz_mulDivCancelsFactorEvenWhenProductOverflows(uint256 a, uint256 bSeed) public pure {
        uint256 b = bound(bSeed, 1, type(uint256).max);
        assertEq(UniV3Math.mulDiv(a, b, b), a);
    }

    /// @dev Verifies the quotient inequalities with an independent four-limb multiplication oracle.
    function testFuzz_mulDivIsTheFloorOfTheFull512BitProduct(uint256 a, uint256 b, uint256 dSeed) public pure {
        (uint256 productHi, uint256 productLo) = _product(a, b);
        uint256 d = bound(dSeed, productHi + 1, type(uint256).max);
        uint256 q = UniV3Math.mulDiv(a, b, d);
        (uint256 lowerHi, uint256 lowerLo) = _product(q, d);
        assertTrue(_le(lowerHi, lowerLo, productHi, productLo), "q*d exceeds a*b");
        uint256 upperHi;
        uint256 upperLo;
        if (q == type(uint256).max) upperHi = d; // (q+1)*d == d * 2**256
        else (upperHi, upperLo) = _product(q + 1, d);
        assertFalse(_le(upperHi, upperLo, productHi, productLo), "quotient is too small");
        assertEq(UniV3Math.mulDiv(b, a, d), q, "multiplication symmetry");
    }

    function _product(uint256 a, uint256 b) private pure returns (uint256 hi, uint256 lo) {
        uint256 mask = type(uint128).max;
        uint256 ll = (a & mask) * (b & mask);
        uint256 lh = (a & mask) * (b >> 128);
        uint256 hl = (a >> 128) * (b & mask);
        uint256 hh = (a >> 128) * (b >> 128);
        uint256 middle = (ll >> 128) + (lh & mask) + (hl & mask);
        lo = (ll & mask) | (middle << 128);
        hi = hh + (lh >> 128) + (hl >> 128) + (middle >> 128);
    }

    function _le(uint256 ah, uint256 al, uint256 bh, uint256 bl) private pure returns (bool) {
        return ah < bh || (ah == bh && al <= bl);
    }

    function test_tickMathRejectsBothEndsAndInt24Minimum() public {
        vm.expectRevert(UniV3Math.TickOutOfRange.selector);
        probe.sqrt(-887273);
        vm.expectRevert(UniV3Math.TickOutOfRange.selector);
        probe.sqrt(887273);
        vm.expectRevert(UniV3Math.TickOutOfRange.selector);
        probe.sqrt(type(int24).min);
    }

    function testFuzz_sqrtRatioStrictlyIncreasesAcrossFullDomain(int24 tickSeed) public pure {
        int24 tick = int24(bound(int256(tickSeed), -887272, 887271));
        assertLt(UniV3Math.getSqrtRatioAtTick(tick), UniV3Math.getSqrtRatioAtTick(tick + 1));
    }

    function test_meanTickRejectsZeroPeriod() public {
        vm.expectRevert(UniV3Math.ZeroPeriod.selector);
        probe.meanTick(0, 0, 0);
    }

    function testFuzz_meanTickIsFloorAndIgnoresCumulativeOrigin(
        int24 tickSeed,
        uint32 periodSeed,
        uint32 remainderSeed,
        int56 originSeed
    ) public pure {
        int56 period = int56(int256(bound(periodSeed, 1, type(uint32).max)));
        int56 tick = int56(bound(int256(tickSeed), -887271, 887271));
        int56 remainder = int56(int256(bound(remainderSeed, 0, uint256(uint56(period)) - 1)));
        int56 delta = tick * period + remainder;
        int56 origin = int56(bound(int256(originSeed), -(int256(1) << 54), int256(1) << 54));
        int24 actual = UniV3Math.meanTick(origin, origin + delta, uint32(uint56(period)));
        assertLe(int256(actual) * period, delta);
        assertGt((int256(actual) + 1) * period, delta);
        assertEq(actual, UniV3Math.meanTick(0, delta, uint32(uint56(period))));
    }

    function test_meanTickNegativeFractionAndExactBoundary() public pure {
        assertEq(UniV3Math.meanTick(0, -1, 1800), -1);
        assertEq(UniV3Math.meanTick(0, -1800, 1800), -1);
        assertEq(UniV3Math.meanTick(0, -1801, 1800), -2);
        assertEq(UniV3Math.meanTick(0, 1799, 1800), 0);
        assertEq(UniV3Math.meanTick(0, 1800, 1800), 1);
    }

    function test_zeroAndMaximumAmountAtEqualPrice() public pure {
        assertEq(UniV3Math.getQuoteAtTick(0, type(uint128).max, FIRST, SECOND), type(uint128).max);
        assertEq(UniV3Math.getQuoteAtTick(0, type(uint128).max, SECOND, FIRST), type(uint128).max);
        assertEq(UniV3Math.getQuoteAtTick(-887272, 0, FIRST, SECOND), 0);
        assertEq(UniV3Math.getQuoteAtTick(887272, 0, SECOND, FIRST), 0);
    }

    function testFuzz_quoteIsMonotoneInAmountForBothTokenOrders(int24 tickSeed, uint128 amount, uint128 extra)
        public
        pure
    {
        int24 tick = int24(bound(int256(tickSeed), -887272, 887272));
        uint128 smaller = amount < extra ? amount : extra;
        uint128 larger = amount < extra ? extra : amount;
        assertLe(
            UniV3Math.getQuoteAtTick(tick, smaller, FIRST, SECOND),
            UniV3Math.getQuoteAtTick(tick, larger, FIRST, SECOND)
        );
        assertLe(
            UniV3Math.getQuoteAtTick(tick, smaller, SECOND, FIRST),
            UniV3Math.getQuoteAtTick(tick, larger, SECOND, FIRST)
        );
    }

    function testFuzz_quoteRoundTripCannotCreateTokens(int24 tickSeed, uint128 amountSeed) public pure {
        int24 tick = int24(bound(int256(tickSeed), -300_000, 300_000));
        uint128 amount = uint128(bound(amountSeed, 1, 1e24));
        uint256 forward = UniV3Math.getQuoteAtTick(tick, amount, FIRST, SECOND);
        // Even at the largest tick above, forward fits uint128; check before narrowing.
        assertLe(forward, type(uint128).max);
        uint256 returned = UniV3Math.getQuoteAtTick(tick, uint128(forward), SECOND, FIRST);
        assertLe(returned, amount, "round-trip creates value");
    }

    function test_quotesMatchIndependentDecimalPriceVectors() public pure {
        // floor(amount * Decimal("1.0001") ** tick), calculated at 110 decimal digits.
        // These cover both quote branches and Ethereum's 18-to-6 decimal price range.
        assertEq(UniV3Math.getQuoteAtTick(-276324, 1e18, FIRST, SECOND), 1_000_002);
        assertEq(UniV3Math.getQuoteAtTick(-263819, 1e18, FIRST, SECOND), 3_491_879);
        assertEq(UniV3Math.getQuoteAtTick(-10000, 1e18, FIRST, SECOND), 367_897_834_377_123_709);
        assertEq(UniV3Math.getQuoteAtTick(10000, 1e18, FIRST, SECOND), 2_718_145_926_825_224_864);
        assertEq(UniV3Math.getQuoteAtTick(263819, 1e18, FIRST, SECOND), 286_378_727_255_878_614_751_634_630_707);
        assertEq(UniV3Math.getQuoteAtTick(276324, 1e18, FIRST, SECOND), 999_997_356_176_039_153_113_976_863_680);
        assertEq(UniV3Math.getQuoteAtTick(-276324, 1e6, SECOND, FIRST), 999_997_356_176_039_153);
        assertEq(UniV3Math.getQuoteAtTick(-263819, 1e6, SECOND, FIRST), 286_378_727_255_878_614);
    }
}
