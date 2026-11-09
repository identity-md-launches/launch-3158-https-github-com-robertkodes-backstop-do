// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NightshiftBackstop} from "src/NightshiftBackstop.sol";
import {MockERC20, MockPool, BlockingToken} from "./mocks/Mocks.sol";

/// @notice Edge and failure properties of the revised implementation: Shield reservations fixed at offer
/// creation, the settlement-time price check, the bounded `createOffer` overload, the price-source timelock,
/// the `...To` exits and the pump filter when the older TWAP rounds a lot to zero.
/// forge-config: default.fuzz.runs = 512
contract NightshiftRevisionPropertiesTest is Test {
    NightshiftBackstop internal b;
    MockERC20 internal token;
    MockERC20 internal quote;
    MockPool internal pool;
    address internal seller = makeAddr("revision seller");
    address internal alice = makeAddr("revision alice");
    address internal bob = makeAddr("revision bob");
    address internal carol = makeAddr("revision carol");
    uint256 internal constant LOT_COST = 9.5e18; // 10e18 per lot at tick 0, 5 % base discount

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new MockERC20("Test IMD", "IMD", 18);
        quote = new MockERC20("Test quote", "Q", 18);
        b = new NightshiftBackstop(address(this), address(token), address(quote), 100, type(uint256).max, 0);
        pool = new MockPool(address(token), address(quote));
        b.setPriceSource(address(pool));
        _fund(b, quote);
    }

    function _fund(NightshiftBackstop target, MockERC20 q) internal {
        address[4] memory actors = [seller, alice, bob, carol];
        for (uint256 i; i < actors.length; ++i) {
            token.mint(actors[i], 10_000_000e18);
            q.mint(actors[i], 10_000_000e18);
            vm.startPrank(actors[i]);
            token.approve(address(target), type(uint256).max);
            q.approve(address(target), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _offer(uint256 amount) internal returns (uint256 id) {
        vm.prank(seller);
        id = b.createOffer(amount);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        b.shieldDeposit(amount);
    }

    function _settle(uint256 id) internal {
        uint256 deadline = b.getOffer(id).deadline;
        if (deadline > block.timestamp) vm.warp(deadline);
        b.settle(id);
    }

    /// @dev Moves the token's price by `ticks` (positive = token worth more quote) in both TWAP windows.
    function _price(int24 ticks) internal {
        int24 t = address(token) < address(quote) ? ticks : -ticks;
        pool.setTicks(t, t);
    }

    // ------------------------------------------------------------- bounded createOffer overload

    function testFuzz_boundedOfferSucceedsExactlyWhenPriceAndTimeHold(uint256 minSeed, uint256 untilSeed) public {
        uint256 minLotCost = bound(minSeed, 0, 2 * LOT_COST);
        uint256 validUntil = bound(untilSeed, block.timestamp - 2, block.timestamp + 2);
        vm.prank(seller);
        if (validUntil < block.timestamp) {
            vm.expectRevert(NightshiftBackstop.OfferExpired.selector);
        } else if (minLotCost > LOT_COST) {
            vm.expectRevert(NightshiftBackstop.LotCostBelowMinimum.selector);
        }
        b.createOffer(1_000e18, minLotCost, validUntil);
        if (validUntil >= block.timestamp && minLotCost <= LOT_COST) {
            assertEq(b.getOffer(1).lotCost, LOT_COST);
            assertEq(token.balanceOf(address(b)), 1_000e18);
        } else {
            assertEq(b.offerCount(), 0, "rejected offer left state");
            assertEq(token.balanceOf(address(b)), 0, "rejected offer kept escrow");
        }
    }

    function test_boundedOfferIsPausedAndChecksSizeBeforeMinimum() public {
        b.setPaused(true);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.Paused.selector);
        b.createOffer(1_000e18, 0, block.timestamp);
        b.setPaused(false);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.OfferTooSmall.selector);
        b.createOffer(99, 0, type(uint256).max);
    }

    function test_pauseDoesNotShutBiddersOutOfAnOpenOffer() public {
        uint256 id = _offer(1_000e18);
        b.setPaused(true);
        vm.prank(alice);
        uint256 bidId = b.placeBid(id, 100);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.Paused.selector);
        b.createOffer(1_000e18);
        vm.prank(bob);
        vm.expectRevert(NightshiftBackstop.Paused.selector);
        b.shieldDeposit(1);
        _settle(id);
        assertEq(b.filledLotsOf(bidId), 100);
    }

    // ------------------------------------------------------------- reservations

    function testFuzz_concurrentReservationsNeverExceedHalfOfDeposits(uint256 depositSeed, uint8 offersSeed) public {
        uint256 amount = bound(depositSeed, 1, 5_000e18);
        uint256 offers = bound(offersSeed, 1, 12);
        _deposit(alice, amount);
        uint256 sum;
        for (uint256 i; i < offers; ++i) {
            uint256 id = _offer(1_000e18);
            NightshiftBackstop.Offer memory o = b.getOffer(id);
            assertLe(o.shieldReservedLots, 50);
            sum += o.shieldReservedLots * o.lotCost;
            assertEq(b.shieldReservedQuote(), sum);
            assertLe(sum, amount / 2, "reservations exceed half of deposits");
            // The next offer gets only what is left; nothing is left that a whole lot fits in afterwards.
            assertEq(o.shieldReservedLots, _min(50, (amount / 2 - (sum - o.shieldReservedLots * o.lotCost)) / LOT_COST));
        }
        for (uint256 i = 1; i <= offers; ++i) {
            _settle(i);
        }
        assertEq(b.shieldReservedQuote(), 0);
        assertEq(b.shieldTotalDeposits(), amount - sum, "Shield spent other than its reservations");
    }

    function test_depositAfterCreationCannotEnlargeSliceOrDisplaceBidders() public {
        uint256 id = _offer(1_000e18);
        _deposit(alice, 1_000_000e18);
        vm.prank(bob);
        uint256 bidId = b.placeBid(id, 100);
        _settle(id);
        assertEq(b.getOffer(id).shieldReservedLots, 0);
        assertEq(b.getOffer(id).shieldLots, 0);
        assertEq(b.filledLotsOf(bidId), 100);
        assertEq(b.shieldTotalDeposits(), 1_000_000e18);
        (, uint256 tg, uint256 qg,) = b.shieldPosition(alice);
        assertEq(tg, 0);
        assertEq(qg, 0, "late depositor earned fees on an offer it could not buy");
    }

    function testFuzz_withdrawalSucceedsExactlyWhenReservationsStayCovered(uint256 amountSeed) public {
        _deposit(alice, 1_000e18);
        vm.warp(block.timestamp + 30 days);
        uint256 id = _offer(1_000e18);
        uint256 reserved = b.shieldReservedQuote();
        assertEq(reserved, 50 * LOT_COST);
        uint256 amount = bound(amountSeed, 1, 1_000e18);
        bool ok = (1_000e18 - amount) / 2 >= reserved;
        vm.prank(alice);
        if (!ok) vm.expectRevert(NightshiftBackstop.ShieldFundsReserved.selector);
        b.shieldWithdraw(amount);
        assertEq(b.shieldTotalDeposits(), ok ? 1_000e18 - amount : 1_000e18);
        // Settlement still finds its reservation funded, and then the rest can leave.
        _settle(id);
        assertEq(b.getOffer(id).shieldLots, 50);
        (uint256 dep,,,) = b.shieldPosition(alice);
        vm.prank(alice);
        b.shieldWithdraw(dep);
        assertEq(b.shieldReservedQuote(), 0);
    }

    // ------------------------------------------------------------- settlement-time price check

    function testFuzz_ShieldBuysOnlyIfFrozenPriceIsAtOrBelowSettlementTwap(int24 moveSeed, uint8 lotsSeed) public {
        int24 move = int24(bound(moveSeed, -2_000, 2_000));
        uint256 bidLots = bound(lotsSeed, 0, 100);
        _deposit(alice, 10_000e18);
        uint256 id = _offer(1_000e18);
        assertEq(b.getOffer(id).shieldReservedLots, 50);
        if (bidLots != 0) {
            vm.prank(bob);
            b.placeBid(id, bidLots);
        }
        _price(move);
        uint256 value = b.twapLotValue(10e18);
        _settle(id);
        NightshiftBackstop.Offer memory o = b.getOffer(id);
        uint256 s = LOT_COST <= value ? 50 : 0;
        assertEq(o.shieldLots, s, "Shield bought above the market or skipped a fair price");
        assertEq(o.filledLots, _min(bidLots, 100 - s), "freed slice not offered to bidders");
        assertEq(b.shieldTotalDeposits(), 10_000e18 - s * LOT_COST);
        assertEq(b.shieldReservedQuote(), 0);
        uint256 gross = (s + o.filledLots) * LOT_COST;
        uint256 fee = gross - o.sellerProceeds;
        uint256 treasuryShare = b.treasuryAccrued();
        if (s == 0) {
            assertEq(treasuryShare, fee, "idle Shield earned fees");
        } else {
            // The Shield's share is 80 % of the fee pro rata to the lots it bought; the treasury keeps the rest.
            uint256 shieldShare = fee - treasuryShare;
            assertEq(shieldShare, fee * 8_000 / 10_000 * s / (s + o.filledLots));
            (, uint256 tg, uint256 qg,) = b.shieldPosition(alice);
            assertLe(qg, shieldShare);
            assertApproxEqAbs(qg, shieldShare, 1e3);
            assertApproxEqAbs(tg, 500e18, 1e3);
        }
    }

    function test_brokenSourceAtSettlementReleasesReservationAndSettlesBidders() public {
        _deposit(alice, 10_000e18);
        uint256 id = _offer(1_000e18);
        vm.prank(bob);
        uint256 bidId = b.placeBid(id, 80);
        pool.setBroken(true);
        _settle(id);
        assertEq(b.getOffer(id).shieldLots, 0);
        assertEq(b.filledLotsOf(bidId), 80);
        assertEq(b.shieldReservedQuote(), 0);
        vm.prank(seller);
        b.claimSeller(id);
        assertEq(token.balanceOf(seller), 10_000_000e18 - 800e18);
    }

    // ------------------------------------------------------------- pump filter with a zero older price

    function test_riseFromZeroOlderPriceTripsPumpFilter() public {
        _deposit(alice, 10_000e18);
        int24 sign = address(token) < address(quote) ? int24(1) : int24(-1);
        pool.setTicks(sign * -100_000, 0); // one base unit was worth 0 quote an hour ago, 1 now
        (uint256 lotCost, uint256 discount, int256 momentum) = b.quoteLot(1);
        assertEq(momentum, int256(type(int128).max));
        assertEq(discount, b.MAX_DISCOUNT_BPS());
        assertEq(lotCost, 1);
        uint256 id = _offer(100);
        assertFalse(b.getOffer(id).shieldEligible);
        assertEq(b.getOffer(id).shieldReservedLots, 0);
        _settle(id);
        assertEq(b.getOffer(id).shieldLots, 0);
    }

    function test_flatZeroPriceIsRejectedNotSaturated() public {
        int24 sign = address(token) < address(quote) ? int24(1) : int24(-1);
        pool.setTicks(sign * -100_000, sign * -100_000);
        (uint256 lotCost,, int256 momentum) = b.quoteLot(1);
        assertEq(lotCost, 0);
        assertEq(momentum, 0);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.ZeroLotCost.selector);
        b.createOffer(100);
    }

    // ------------------------------------------------------------- price-source timelock

    function test_priceSourceChangeWaitsFullDelayAndRescheduleRestartsIt() public {
        MockPool next = new MockPool(address(token), address(quote));
        MockPool later = new MockPool(address(token), address(quote));
        uint256 t0 = block.timestamp;
        b.setPriceSource(address(next));
        assertEq(b.priceSourceActivatesAt(), t0 + 37 days);
        vm.warp(t0 + 10 days);
        b.setPriceSource(address(later));
        assertEq(b.pendingPriceSource(), address(later));
        assertEq(b.priceSourceActivatesAt(), t0 + 47 days, "reschedule kept the old clock");
        vm.warp(t0 + 47 days - 1);
        vm.expectRevert(NightshiftBackstop.PriceSourceDelayNotElapsed.selector);
        b.applyPriceSource();
        assertEq(b.priceSource(), address(pool));
        vm.warp(t0 + 47 days);
        b.applyPriceSource();
        assertEq(b.priceSource(), address(later));
        assertEq(b.pendingPriceSource(), address(0));
        assertEq(b.priceSourceActivatesAt(), 0);
        vm.expectRevert(NightshiftBackstop.NoPendingPriceSource.selector);
        b.applyPriceSource();
    }

    function test_priceSourceAdminRejectsOutsidersAndBadPools() public {
        MockPool next = new MockPool(address(token), address(quote));
        MockPool wrong = new MockPool(address(token), address(new MockERC20("x", "x", 6)));
        vm.startPrank(alice);
        vm.expectRevert(NightshiftBackstop.NotOwner.selector);
        b.setPriceSource(address(next));
        vm.expectRevert(NightshiftBackstop.NotOwner.selector);
        b.applyPriceSource();
        vm.expectRevert(NightshiftBackstop.NotOwner.selector);
        b.cancelPriceSourceChange();
        vm.stopPrank();
        vm.expectRevert(NightshiftBackstop.NoPendingPriceSource.selector);
        b.cancelPriceSourceChange();
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        b.setPriceSource(address(0));
        vm.expectRevert(NightshiftBackstop.PriceSourceMismatch.selector);
        b.setPriceSource(address(wrong));
        b.setPriceSource(address(next));
        b.cancelPriceSourceChange();
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(NightshiftBackstop.NoPendingPriceSource.selector);
        b.applyPriceSource();
        assertEq(b.priceSource(), address(pool));
    }

    function test_nothingCanBeDepositedOrOfferedBeforeASourceExists() public {
        NightshiftBackstop fresh =
            new NightshiftBackstop(address(this), address(token), address(quote), 100, type(uint256).max, 0);
        _fund(fresh, quote);
        vm.prank(alice);
        vm.expectRevert(NightshiftBackstop.PriceSourceNotConfigured.selector);
        fresh.shieldDeposit(1);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.PriceSourceNotConfigured.selector);
        fresh.createOffer(1_000e18);
    }

    // ------------------------------------------------------------- redirected exits

    function test_redirectedExitsPayOnlyTheirOwnersEntitlement() public {
        _deposit(alice, 10_000e18);
        uint256 id = _offer(1_000e18);
        vm.prank(bob);
        uint256 bidId = b.placeBid(id, 60);
        _settle(id);
        // Nobody can steer someone else's claim to themselves.
        vm.prank(carol);
        vm.expectRevert(NightshiftBackstop.NotBidder.selector);
        b.claimBidTo(bidId, carol);
        vm.prank(carol);
        vm.expectRevert(NightshiftBackstop.NotSeller.selector);
        b.claimSellerTo(id, carol);
        vm.prank(carol);
        vm.expectRevert(NightshiftBackstop.InsufficientShieldDeposit.selector);
        b.shieldWithdrawTo(1, carol);
        uint256 carolQuote = quote.balanceOf(carol);
        uint256 carolToken = token.balanceOf(carol);
        vm.prank(carol);
        b.shieldClaimGainsTo(carol);
        assertEq(quote.balanceOf(carol), carolQuote);
        assertEq(token.balanceOf(carol), carolToken);
        // Zero recipients are refused on every redirected exit.
        vm.startPrank(bob);
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        b.claimBidTo(bidId, address(0));
        vm.stopPrank();
        vm.startPrank(seller);
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        b.claimSellerTo(id, address(0));
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        b.shieldClaimGainsTo(address(0));
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        b.shieldWithdrawTo(1, address(0));
        vm.stopPrank();
        // Owners redirect their own entitlement, once.
        address vault = makeAddr("revision vault");
        vm.prank(bob);
        b.claimBidTo(bidId, vault);
        assertEq(token.balanceOf(vault), 50 * 10e18); // the Shield took 50 lots, bob 50 of his 60
        assertEq(quote.balanceOf(vault), 10 * LOT_COST);
        vm.prank(bob);
        vm.expectRevert(NightshiftBackstop.AlreadyClaimed.selector);
        b.claimBidTo(bidId, bob);
        vm.prank(seller);
        b.claimSellerTo(id, vault);
        assertEq(quote.balanceOf(vault), 10 * LOT_COST + b.getOffer(id).sellerProceeds);
        (uint256 dep, uint256 tg, uint256 qg, uint256 unlock) = b.shieldPosition(alice);
        vm.warp(unlock);
        uint256 vaultQuote = quote.balanceOf(vault);
        uint256 vaultToken = token.balanceOf(vault);
        vm.prank(alice);
        b.shieldWithdrawTo(dep, vault);
        assertEq(quote.balanceOf(vault) - vaultQuote, dep + qg);
        assertEq(token.balanceOf(vault) - vaultToken, tg);
        (uint256 left,,,) = b.shieldPosition(alice);
        assertEq(left, 0);
    }

    function test_blockedBidderCanStillLeaveThroughClaimBidTo() public {
        BlockingToken blocking = new BlockingToken();
        NightshiftBackstop bb =
            new NightshiftBackstop(address(this), address(token), address(blocking), 100, type(uint256).max, 0);
        MockPool p = new MockPool(address(token), address(blocking));
        bb.setPriceSource(address(p));
        _fund(bb, MockERC20(address(blocking)));
        vm.prank(seller);
        uint256 id = bb.createOffer(1_000e18);
        vm.prank(alice);
        bb.placeBid(id, 100);
        vm.prank(bob);
        uint256 bidId = bb.placeBid(id, 1); // 101st lot: the refund is all quote
        vm.warp(block.timestamp + 1 hours);
        bb.settle(id);
        blocking.setBlocked(bob);
        assertEq(bb.filledLotsOf(bidId), 0);
        vm.prank(bob);
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        bb.claimBid(bidId);
        address safe = makeAddr("revision safe");
        vm.prank(bob);
        bb.claimBidTo(bidId, safe);
        assertEq(blocking.balanceOf(safe), bb.getOffer(id).lotCost);
    }

    function _min(uint256 a, uint256 c) internal pure returns (uint256) {
        return a < c ? a : c;
    }
}
