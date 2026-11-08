// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NightshiftBackstop} from "../src/NightshiftBackstop.sol";
import {UniV3Math} from "../src/libraries/UniV3Math.sol";
import {MockERC20, MockPool, FeeOnTransferToken, BlockingToken, ReentrantToken} from "./mocks/Mocks.sol";

/// @dev Exposes Shield absorption so the rescale path can be driven directly.
contract ShieldHarness is NightshiftBackstop {
    constructor(address o, address t, address q) NightshiftBackstop(o, t, q, 100, type(uint256).max, 0) {}

    function absorb(uint256 debt, uint256 coll) external {
        _shieldAbsorb(debt, coll);
    }
}

contract NightshiftBackstopTest is Test {
    NightshiftBackstop internal bs;
    MockERC20 internal imd;
    MockERC20 internal usdc;
    MockPool internal pool;

    address internal owner = makeAddr("owner");
    address internal seller = makeAddr("seller");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal shielder = makeAddr("shielder");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant MIN_OFFER = 1_000e18;
    uint256 internal constant CAP = 10_000e18;
    uint256 internal constant HOLDING = 1e18;
    uint256 internal constant OFFER = 1_000e18; // lot size 10e18
    uint256 internal constant LOT_COST = 9.5e18; // tick 0, zero momentum, 5 % discount

    function setUp() public {
        vm.warp(1_700_000_000);
        imd = new MockERC20("IMD", "IMD", 18);
        usdc = new MockERC20("USD Coin", "USDC", 18);
        bs = new NightshiftBackstop(owner, address(imd), address(usdc), MIN_OFFER, CAP, HOLDING);
        pool = new MockPool(address(imd), address(usdc));
        vm.prank(owner);
        bs.setPriceSource(address(pool));

        address[6] memory users = [seller, alice, bob, carol, shielder, outsider];
        for (uint256 i; i < users.length; ++i) {
            imd.mint(users[i], 100_000e18);
            usdc.mint(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            imd.approve(address(bs), type(uint256).max);
            usdc.approve(address(bs), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------ helpers

    function _offer() internal returns (uint256 id) {
        vm.prank(seller);
        id = bs.createOffer(OFFER);
    }

    function _bid(address who, uint256 id, uint256 lots) internal returns (uint256 bidId) {
        vm.prank(who);
        bidId = bs.placeBid(id, lots);
    }

    /// @dev Moves the IMD price by `ticks` (positive = IMD up) whichever token the pool sorts first.
    function _move(int24 ticks) internal {
        pool.setTicks(0, address(imd) < address(usdc) ? ticks : -ticks);
    }

    /// @dev Sets the IMD price of the older and the current TWAP window, in ticks (positive = IMD up).
    function _setTicks(int24 past, int24 now_) internal {
        bool imdFirst = address(imd) < address(usdc);
        pool.setTicks(imdFirst ? past : -past, imdFirst ? now_ : -now_);
    }

    function _settle(uint256 id) internal {
        vm.warp(block.timestamp + bs.OFFER_WINDOW());
        bs.settle(id);
    }

    // ------------------------------------------------------------------ construction and admin

    function test_constructorSetsOwnerNotDeployer() public view {
        assertEq(bs.owner(), owner);
        assertEq(bs.treasury(), owner);
        assertEq(bs.token(), address(imd));
        assertEq(bs.quote(), address(usdc));
        assertTrue(bs.owner() != address(this));
    }

    function test_constructorRejectsBadArgs() public {
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        new NightshiftBackstop(address(0), address(imd), address(usdc), MIN_OFFER, CAP, HOLDING);
        vm.expectRevert(NightshiftBackstop.SameTokens.selector);
        new NightshiftBackstop(owner, address(imd), address(imd), MIN_OFFER, CAP, HOLDING);
        vm.expectRevert(NightshiftBackstop.ZeroValue.selector);
        new NightshiftBackstop(owner, address(imd), address(usdc), 99, CAP, HOLDING);
    }

    function test_constructorNeedsNoCodeAtAddresses() public {
        NightshiftBackstop b = new NightshiftBackstop(owner, address(0xBEEF), address(0xCAFE), MIN_OFFER, CAP, HOLDING);
        assertEq(b.priceSource(), address(0));
    }

    function test_unsetPriceSourceBlocksOffers() public {
        NightshiftBackstop b = new NightshiftBackstop(owner, address(imd), address(usdc), MIN_OFFER, CAP, HOLDING);
        vm.prank(seller);
        imd.approve(address(b), type(uint256).max);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.PriceSourceNotConfigured.selector);
        b.createOffer(OFFER);
        vm.expectRevert(NightshiftBackstop.PriceSourceNotConfigured.selector);
        b.quoteLot(10e18);
    }

    function test_setPriceSourceOnlyOwnerAndMatchingPool() public {
        vm.prank(outsider);
        vm.expectRevert(NightshiftBackstop.NotOwner.selector);
        bs.setPriceSource(address(pool));

        MockPool wrong = new MockPool(address(imd), address(0x1234));
        vm.prank(owner);
        vm.expectRevert(NightshiftBackstop.PriceSourceMismatch.selector);
        bs.setPriceSource(address(wrong));

        vm.prank(owner);
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        bs.setPriceSource(address(0));

        // The first configuration is immediate.
        NightshiftBackstop fresh = new NightshiftBackstop(owner, address(imd), address(usdc), MIN_OFFER, CAP, HOLDING);
        MockPool other = new MockPool(address(usdc), address(imd));
        vm.expectEmit(true, false, false, false, address(fresh));
        emit NightshiftBackstop.PriceSourceSet(address(other));
        vm.prank(owner);
        fresh.setPriceSource(address(other));
        assertEq(fresh.priceSource(), address(other));
        assertEq(fresh.pendingPriceSource(), address(0));
    }

    function test_priceSourceChangeIsDelayed() public {
        MockPool other = new MockPool(address(usdc), address(imd));
        bool imdFirst = address(imd) < address(usdc);
        other.setTicks(imdFirst ? int24(46_000) : int24(-46_000), imdFirst ? int24(46_000) : int24(-46_000)); // ~100x
        uint256 activatesAt = block.timestamp + bs.PRICE_SOURCE_DELAY();
        assertGt(bs.PRICE_SOURCE_DELAY(), bs.SHIELD_MIN_LOCK());

        vm.expectEmit(true, false, false, true, address(bs));
        emit NightshiftBackstop.PriceSourceChangeScheduled(address(other), activatesAt);
        vm.prank(owner);
        bs.setPriceSource(address(other));
        assertEq(bs.priceSource(), address(pool), "old source still prices offers");
        assertEq(bs.pendingPriceSource(), address(other));
        assertEq(bs.priceSourceActivatesAt(), activatesAt);
        (uint256 cost,,) = bs.quoteLot(10e18);
        assertEq(cost, LOT_COST);
        uint256 id = _offer();
        assertEq(bs.getOffer(id).lotCost, LOT_COST);

        vm.prank(outsider);
        vm.expectRevert(NightshiftBackstop.NotOwner.selector);
        bs.applyPriceSource();
        vm.warp(activatesAt - 1);
        vm.prank(owner);
        vm.expectRevert(NightshiftBackstop.PriceSourceDelayNotElapsed.selector);
        bs.applyPriceSource();

        vm.warp(activatesAt);
        vm.expectEmit(true, false, false, false, address(bs));
        emit NightshiftBackstop.PriceSourceSet(address(other));
        vm.prank(owner);
        bs.applyPriceSource();
        assertEq(bs.priceSource(), address(other));
        assertEq(bs.pendingPriceSource(), address(0));
        assertEq(bs.priceSourceActivatesAt(), 0);
        vm.prank(owner);
        vm.expectRevert(NightshiftBackstop.NoPendingPriceSource.selector);
        bs.applyPriceSource();
    }

    function test_priceSourceChangeCanBeCancelledAndRescheduled() public {
        MockPool other = new MockPool(address(usdc), address(imd));
        vm.prank(owner);
        vm.expectRevert(NightshiftBackstop.NoPendingPriceSource.selector);
        bs.cancelPriceSourceChange();
        vm.prank(owner);
        bs.setPriceSource(address(other));
        vm.prank(outsider);
        vm.expectRevert(NightshiftBackstop.NotOwner.selector);
        bs.cancelPriceSourceChange();
        vm.expectEmit(true, false, false, false, address(bs));
        emit NightshiftBackstop.PriceSourceChangeCancelled(address(other));
        vm.prank(owner);
        bs.cancelPriceSourceChange();
        assertEq(bs.pendingPriceSource(), address(0));

        // Scheduling again restarts the whole delay.
        vm.warp(block.timestamp + 10 days);
        vm.prank(owner);
        bs.setPriceSource(address(other));
        vm.warp(block.timestamp + 20 days);
        vm.prank(owner);
        bs.setPriceSource(address(other));
        assertEq(bs.priceSourceActivatesAt(), block.timestamp + bs.PRICE_SOURCE_DELAY());
    }

    function test_lockedDepositorCanLeaveBeforeNewPriceSource() public {
        vm.prank(shielder);
        bs.shieldDeposit(1_000e18); // locked for 30 days from now
        MockPool other = new MockPool(address(usdc), address(imd));
        vm.prank(owner);
        bs.setPriceSource(address(other)); // announced in the same block as the deposit
        vm.warp(block.timestamp + bs.SHIELD_MIN_LOCK());
        assertLt(block.timestamp, bs.priceSourceActivatesAt());
        vm.prank(owner);
        vm.expectRevert(NightshiftBackstop.PriceSourceDelayNotElapsed.selector);
        bs.applyPriceSource();
        vm.prank(shielder);
        bs.shieldWithdraw(1_000e18);
        assertEq(bs.shieldTotalDeposits(), 0);
    }

    function test_shieldDepositNeedsPriceSource() public {
        NightshiftBackstop b = new NightshiftBackstop(owner, address(imd), address(usdc), MIN_OFFER, CAP, HOLDING);
        vm.startPrank(shielder);
        usdc.approve(address(b), type(uint256).max);
        vm.expectRevert(NightshiftBackstop.PriceSourceNotConfigured.selector);
        b.shieldDeposit(1e18);
        vm.stopPrank();
        vm.prank(owner);
        b.setPriceSource(address(pool));
        vm.prank(shielder);
        b.shieldDeposit(1e18);
        assertEq(b.shieldTotalDeposits(), 1e18);
    }

    function test_twoStepOwnership() public {
        vm.prank(outsider);
        vm.expectRevert(NightshiftBackstop.NotOwner.selector);
        bs.transferOwnership(outsider);

        vm.prank(owner);
        bs.transferOwnership(alice);
        assertEq(bs.owner(), owner);
        vm.prank(bob);
        vm.expectRevert(NightshiftBackstop.NotPendingOwner.selector);
        bs.acceptOwnership();
        vm.prank(alice);
        bs.acceptOwnership();
        assertEq(bs.owner(), alice);
        assertEq(bs.pendingOwner(), address(0));
    }

    function test_setTreasury() public {
        vm.prank(outsider);
        vm.expectRevert(NightshiftBackstop.NotOwner.selector);
        bs.setTreasury(outsider);
        vm.prank(owner);
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        bs.setTreasury(address(0));
        vm.prank(owner);
        bs.setTreasury(carol);
        assertEq(bs.treasury(), carol);
    }

    function test_pauseBlocksEntryButNotExit() public {
        uint256 id = _offer();
        uint256 bidId = _bid(alice, id, 10);
        vm.prank(outsider);
        vm.expectRevert(NightshiftBackstop.NotOwner.selector);
        bs.setPaused(true);
        vm.prank(owner);
        bs.setPaused(true);

        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.Paused.selector);
        bs.createOffer(OFFER);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.Paused.selector);
        bs.createOffer(OFFER, 0, block.timestamp);
        vm.prank(shielder);
        vm.expectRevert(NightshiftBackstop.Paused.selector);
        bs.shieldDeposit(1e18);
        // An offer that is already open stays biddable: its clock does not stop for a pause.
        uint256 bobBid = _bid(bob, id, 10);
        assertEq(bs.getBid(bobBid).lots, 10);

        _settle(id);
        vm.prank(alice);
        bs.claimBid(bidId);
        vm.prank(seller);
        bs.claimSeller(id);
    }

    // ------------------------------------------------------------------ pricing

    function test_quoteAtZeroMomentumUsesBaseDiscount() public view {
        (uint256 lotCost, uint256 d, int256 m) = bs.quoteLot(10e18);
        assertEq(m, 0);
        assertEq(d, 500);
        assertEq(lotCost, LOT_COST);
    }

    function test_discountRisesWithMomentumAndClamps() public {
        _move(1000); // ~ +10.5 %
        (, uint256 d, int256 m) = bs.quoteLot(10e18);
        assertGt(m, 1000);
        assertLt(m, 1100);
        assertEq(d, 500 + uint256(m) * 2500 / 10_000);

        _move(5000); // ~ +65 %: clamps at the max
        (, d,) = bs.quoteLot(10e18);
        assertEq(d, 1200);
    }

    function test_discountFallsWithNegativeMomentumAndClamps() public {
        _move(-1000); // ~ -9.5 %
        (, uint256 d, int256 m) = bs.quoteLot(10e18);
        assertLt(m, -900);
        assertEq(d, 500 - uint256(-m) * 1500 / 10_000);

        _move(-4000); // ~ -33 %: clamps at the min
        (, d,) = bs.quoteLot(10e18);
        assertEq(d, 200);
    }

    function test_mathMatchesMainnetPoolScale() public pure {
        // USDC (token0) / IMD (token1) 0.3 % pool on Ethereum, tick 263819 read at build time.
        address usdcMain = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address imdMain = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
        uint256 usdcPerImd = UniV3Math.getQuoteAtTick(263819, 1e18, imdMain, usdcMain);
        assertGt(usdcPerImd, 1e6); // above $1
        assertLt(usdcPerImd, 100e6); // below $100
        // Inverse direction is consistent.
        uint256 imdPerUsdc = UniV3Math.getQuoteAtTick(263819, 1e6, usdcMain, imdMain);
        assertApproxEqRel(usdcPerImd * imdPerUsdc, 1e24, 1e15);
    }

    function test_sqrtRatioKnownValues() public pure {
        assertEq(UniV3Math.getSqrtRatioAtTick(0), 79228162514264337593543950336);
        assertEq(UniV3Math.getSqrtRatioAtTick(-887272), 4295128739);
        assertEq(UniV3Math.getSqrtRatioAtTick(887272), 1461446703485210103287273052203988822378723970342);
    }

    function test_meanTickRoundsDown() public pure {
        assertEq(UniV3Math.meanTick(0, -7, 2), -4);
        assertEq(UniV3Math.meanTick(0, 7, 2), 3);
        assertEq(UniV3Math.meanTick(0, -8, 2), -4);
    }

    function test_brokenOracleBlocksOfferButNotSettlement() public {
        uint256 id = _offer();
        pool.setBroken(true);
        vm.prank(seller);
        vm.expectRevert(bytes("OLD"));
        bs.createOffer(OFFER);
        _settle(id);
        assertTrue(bs.getOffer(id).settled);
    }

    // ------------------------------------------------------------------ offers

    function test_createOfferEscrowsWholeLots() public {
        uint256 before = imd.balanceOf(seller);
        vm.prank(seller);
        uint256 id = bs.createOffer(OFFER + 99); // dust below one lot stays with the seller
        NightshiftBackstop.Offer memory o = bs.getOffer(id);
        assertEq(o.seller, seller);
        assertEq(o.lotSize, 10e18);
        assertEq(o.lotCost, LOT_COST);
        assertEq(o.deadline, block.timestamp + 1 hours);
        assertEq(before - imd.balanceOf(seller), OFFER);
        assertEq(imd.balanceOf(address(bs)), OFFER);
    }

    function test_createOfferTooSmall() public {
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.OfferTooSmall.selector);
        bs.createOffer(MIN_OFFER - 100);
    }

    function test_fullCoverageNoShield() public {
        uint256 id = _offer();
        uint256 a = _bid(alice, id, 60);
        uint256 b = _bid(bob, id, 40);
        _settle(id);

        NightshiftBackstop.Offer memory o = bs.getOffer(id);
        assertEq(o.filledLots, 100);
        assertEq(o.shieldLots, 0);
        uint256 gross = 100 * LOT_COST;
        uint256 fee = gross * 300 / 10_000;
        assertEq(o.sellerProceeds, gross - fee);
        // No Shield depositors: the whole fee goes to the treasury.
        assertEq(bs.treasuryAccrued(), fee);

        uint256 aliceImd = imd.balanceOf(alice);
        vm.prank(alice);
        bs.claimBid(a);
        assertEq(imd.balanceOf(alice) - aliceImd, 600e18);
        vm.prank(bob);
        bs.claimBid(b);

        uint256 sellerUsdc = usdc.balanceOf(seller);
        vm.prank(seller);
        bs.claimSeller(id);
        assertEq(usdc.balanceOf(seller) - sellerUsdc, gross - fee);

        bs.withdrawTreasury();
        assertEq(usdc.balanceOf(address(bs)), 0);
        assertEq(imd.balanceOf(address(bs)), 0);
    }

    function test_oversubscribedProRata() public {
        uint256 id = _offer();
        uint256 a = _bid(alice, id, 100);
        uint256 b = _bid(bob, id, 50);
        uint256 c = _bid(carol, id, 50);
        _settle(id);
        // C = 200 for 100 lots: each gets half.
        assertEq(bs.filledLotsOf(a), 50);
        assertEq(bs.filledLotsOf(b), 25);
        assertEq(bs.filledLotsOf(c), 25);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        bs.claimBid(a);
        assertEq(usdc.balanceOf(alice) - before, 50 * LOT_COST);
    }

    function test_undersubscribedReturnsRemainderToSeller() public {
        uint256 id = _offer();
        _bid(alice, id, 30);
        _settle(id);
        uint256 imdBefore = imd.balanceOf(seller);
        vm.prank(seller);
        bs.claimSeller(id);
        assertEq(imd.balanceOf(seller) - imdBefore, 70 * 10e18);
    }

    function test_noBidsReturnsEverything() public {
        uint256 id = _offer();
        _settle(id);
        uint256 imdBefore = imd.balanceOf(seller);
        vm.prank(seller);
        bs.claimSeller(id);
        assertEq(imd.balanceOf(seller) - imdBefore, OFFER);
        assertEq(bs.treasuryAccrued(), 0);
    }

    function test_bidRules() public {
        uint256 id = _offer();
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.SelfBid.selector);
        bs.placeBid(id, 1);
        vm.prank(alice);
        vm.expectRevert(NightshiftBackstop.InvalidLots.selector);
        bs.placeBid(id, 0);
        vm.prank(alice);
        vm.expectRevert(NightshiftBackstop.InvalidLots.selector);
        bs.placeBid(id, 101);
        vm.prank(alice);
        vm.expectRevert(NightshiftBackstop.UnknownOffer.selector);
        bs.placeBid(99, 1);

        address newcomer = makeAddr("newcomer");
        usdc.mint(newcomer, 1_000e18);
        vm.startPrank(newcomer);
        usdc.approve(address(bs), type(uint256).max);
        vm.expectRevert(NightshiftBackstop.NotHolder.selector);
        bs.placeBid(id, 1);
        vm.stopPrank();
    }

    function test_lateBidRejectedAtDeadline() public {
        uint256 id = _offer();
        vm.warp(bs.getOffer(id).deadline);
        vm.prank(alice);
        vm.expectRevert(NightshiftBackstop.BiddingClosed.selector);
        bs.placeBid(id, 1);
    }

    function test_settleRules() public {
        uint256 id = _offer();
        vm.expectRevert(NightshiftBackstop.BiddingOpen.selector);
        bs.settle(id);
        vm.expectRevert(NightshiftBackstop.UnknownOffer.selector);
        bs.settle(42);
        _settle(id);
        vm.expectRevert(NightshiftBackstop.AlreadySettled.selector);
        bs.settle(id);
    }

    function test_claimRules() public {
        uint256 id = _offer();
        uint256 a = _bid(alice, id, 10);
        vm.prank(alice);
        vm.expectRevert(NightshiftBackstop.NotSettled.selector);
        bs.claimBid(a);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.NotSettled.selector);
        bs.claimSeller(id);
        _settle(id);
        vm.prank(bob);
        vm.expectRevert(NightshiftBackstop.NotBidder.selector);
        bs.claimBid(a);
        vm.prank(alice);
        vm.expectRevert(NightshiftBackstop.NotSeller.selector);
        bs.claimSeller(id);
        vm.expectRevert(NightshiftBackstop.UnknownBid.selector);
        bs.claimBid(77);
        vm.prank(alice);
        bs.claimBid(a);
        vm.prank(alice);
        vm.expectRevert(NightshiftBackstop.AlreadyClaimed.selector);
        bs.claimBid(a);
        vm.prank(seller);
        bs.claimSeller(id);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.AlreadyClaimed.selector);
        bs.claimSeller(id);
    }

    function test_withdrawTreasuryNothing() public {
        vm.expectRevert(NightshiftBackstop.NothingToWithdraw.selector);
        bs.withdrawTreasury();
    }

    // ------------------------------------------------------------------ Shield

    function test_shieldTakesPrioritySliceAndEarnsFees() public {
        vm.prank(shielder);
        bs.shieldDeposit(2_000e18);
        uint256 id = _offer();
        uint256 a = _bid(alice, id, 100);
        _settle(id);

        NightshiftBackstop.Offer memory o = bs.getOffer(id);
        // min(50 lots, cap 10_000/9.5 = 1052, funds 1_000/9.5 = 105) = 50
        assertEq(o.shieldLots, 50);
        assertEq(o.filledLots, 50);
        assertEq(bs.filledLotsOf(a), 50);

        // The Shield earns 80 % of the fee on the 50 lots it absorbed; the rest is the treasury's.
        uint256 fee = (100 * LOT_COST * 300 + 9_999) / 10_000;
        uint256 shieldFee = fee * 8_000 / 10_000 * 50 / 100;
        assertEq(bs.treasuryAccrued(), fee - shieldFee);
        assertEq(bs.shieldReservedQuote(), 0);

        (uint256 dep, uint256 tokenGain, uint256 quoteGain,) = bs.shieldPosition(shielder);
        assertApproxEqAbs(dep, 2_000e18 - 50 * LOT_COST, 1e6);
        assertLe(dep, 2_000e18 - 50 * LOT_COST);
        assertApproxEqAbs(tokenGain, 500e18, 1e6);
        assertLe(tokenGain, 500e18);
        assertApproxEqAbs(quoteGain, shieldFee, 1e6);
        assertLe(quoteGain, shieldFee);

        uint256 imdBefore = imd.balanceOf(shielder);
        vm.prank(shielder);
        bs.shieldClaimGains();
        assertEq(imd.balanceOf(shielder) - imdBefore, tokenGain);
        (, tokenGain, quoteGain,) = bs.shieldPosition(shielder);
        assertEq(tokenGain, 0);
        assertEq(quoteGain, 0);
    }

    function test_shieldLimitedByCapAndFunds() public {
        vm.prank(shielder);
        bs.shieldDeposit(100e18); // half usable = 50e18 -> 5 lots
        uint256 id = _offer();
        _settle(id);
        assertEq(bs.getOffer(id).shieldLots, 5);

        NightshiftBackstop small = new NightshiftBackstop(owner, address(imd), address(usdc), MIN_OFFER, 20e18, 0);
        vm.prank(owner);
        small.setPriceSource(address(pool));
        vm.startPrank(shielder);
        usdc.approve(address(small), type(uint256).max);
        small.shieldDeposit(10_000e18);
        vm.stopPrank();
        vm.startPrank(seller);
        imd.approve(address(small), type(uint256).max);
        uint256 id2 = small.createOffer(OFFER);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours);
        small.settle(id2);
        assertEq(small.getOffer(id2).shieldLots, 2); // cap 20 / 9.5
    }

    function test_pumpFilterSkipsShield() public {
        vm.prank(shielder);
        bs.shieldDeposit(2_000e18);
        _move(2000); // ~ +22 %
        uint256 id = _offer();
        assertFalse(bs.getOffer(id).shieldEligible);
        _settle(id);
        assertEq(bs.getOffer(id).shieldLots, 0);
    }

    function test_shieldSharedProRata() public {
        vm.prank(shielder);
        bs.shieldDeposit(3_000e18);
        vm.prank(carol);
        bs.shieldDeposit(1_000e18);
        uint256 id = _offer();
        _settle(id);
        (uint256 d1, uint256 t1,,) = bs.shieldPosition(shielder);
        (uint256 d2, uint256 t2,,) = bs.shieldPosition(carol);
        assertApproxEqAbs(t1, 3 * t2, 1e6);
        assertApproxEqAbs(d1, 3 * d2, 1e6);
        assertApproxEqAbs(t1 + t2, 500e18, 1e6);
    }

    function test_shieldLockAndWithdraw() public {
        vm.prank(shielder);
        bs.shieldDeposit(1_000e18);
        vm.prank(shielder);
        vm.expectRevert(NightshiftBackstop.ShieldLocked.selector);
        bs.shieldWithdraw(1e18);

        vm.warp(block.timestamp + 30 days - 1);
        vm.prank(shielder);
        vm.expectRevert(NightshiftBackstop.ShieldLocked.selector);
        bs.shieldWithdraw(1e18);

        vm.warp(block.timestamp + 1);
        vm.prank(shielder);
        vm.expectRevert(NightshiftBackstop.InsufficientShieldDeposit.selector);
        bs.shieldWithdraw(1_000e18 + 1);

        uint256 before = usdc.balanceOf(shielder);
        vm.prank(shielder);
        bs.shieldWithdraw(1_000e18);
        assertEq(usdc.balanceOf(shielder) - before, 1_000e18);
        assertEq(bs.shieldTotalDeposits(), 0);

        vm.prank(outsider);
        vm.expectRevert(NightshiftBackstop.InsufficientShieldDeposit.selector);
        bs.shieldWithdraw(1);
    }

    function test_redepositRestartsLock() public {
        vm.prank(shielder);
        bs.shieldDeposit(1_000e18);
        vm.warp(block.timestamp + 29 days);
        vm.prank(shielder);
        bs.shieldDeposit(1e18);
        vm.warp(block.timestamp + 2 days);
        vm.prank(shielder);
        vm.expectRevert(NightshiftBackstop.ShieldLocked.selector);
        bs.shieldWithdraw(1e18);
    }

    function test_shieldZeroDeposit() public {
        vm.prank(shielder);
        vm.expectRevert(NightshiftBackstop.ZeroValue.selector);
        bs.shieldDeposit(0);
    }

    function test_shieldScaleChangeKeepsAccounting() public {
        ShieldHarness h = new ShieldHarness(owner, address(imd), address(usdc));
        vm.prank(owner);
        h.setPriceSource(address(pool));
        vm.startPrank(shielder);
        usdc.approve(address(h), type(uint256).max);
        h.shieldDeposit(1_000_000e18);
        vm.stopPrank();
        // 40 absorptions each spending half the pool: P falls by 2^40 and must rescale once.
        uint256 coll;
        for (uint256 i; i < 40; ++i) {
            uint256 debt = h.shieldTotalDeposits() / 2;
            h.absorb(debt, 1e18);
            coll += 1e18;
        }
        assertEq(h.shieldScale(), 1, "rescaled");
        (uint256 dep, uint256 tg,,) = h.shieldPosition(shielder);
        assertApproxEqRel(dep, 1_000_000e18 >> 40, 1e12);
        assertLe(dep, h.shieldTotalDeposits());
        assertApproxEqRel(tg, coll, 1e9);
        assertLe(tg, coll);

        // A depositor joining after the rescale shares the next absorption with the old one.
        vm.startPrank(carol);
        usdc.approve(address(h), type(uint256).max);
        h.shieldDeposit(dep);
        vm.stopPrank();
        h.absorb(h.shieldTotalDeposits() / 2, 2e18);
        (, uint256 tg1,,) = h.shieldPosition(shielder);
        (uint256 dep2, uint256 tg2,,) = h.shieldPosition(carol);
        assertApproxEqRel(tg1 - tg, 1e18, 1e12);
        assertApproxEqRel(tg2, 1e18, 1e12);
        assertApproxEqRel(dep2, dep / 2, 1e12);
    }

    function test_shieldDepositsBeyondTwoScalesCompoundToZero() public {
        ShieldHarness h = new ShieldHarness(owner, address(imd), address(usdc));
        vm.prank(owner);
        h.setPriceSource(address(pool));
        usdc.mint(shielder, 1e30);
        vm.startPrank(shielder);
        usdc.approve(address(h), type(uint256).max);
        h.shieldDeposit(1e30);
        vm.stopPrank();
        for (uint256 i; i < 62 && h.shieldScale() < 2; ++i) {
            h.absorb(h.shieldTotalDeposits() / 2, 1);
        }
        assertEq(h.shieldScale(), 2);
        (uint256 dep,,,) = h.shieldPosition(shielder);
        assertEq(dep, 0);
    }

    // ------------------------------------------------------------------ token behaviour

    function test_feeOnTransferTokenRejected() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        NightshiftBackstop b = new NightshiftBackstop(owner, address(fot), address(usdc), MIN_OFFER, CAP, 0);
        MockPool p = new MockPool(address(fot), address(usdc));
        vm.prank(owner);
        b.setPriceSource(address(p));
        fot.mint(seller, OFFER);
        vm.startPrank(seller);
        fot.approve(address(b), type(uint256).max);
        vm.expectRevert(NightshiftBackstop.FeeOnTransferUnsupported.selector);
        b.createOffer(OFFER);
        vm.stopPrank();
    }

    function test_blockedRecipientDoesNotFreezeOthers() public {
        BlockingToken blk = new BlockingToken();
        NightshiftBackstop b = new NightshiftBackstop(owner, address(imd), address(blk), MIN_OFFER, CAP, 0);
        MockPool p = new MockPool(address(imd), address(blk));
        vm.prank(owner);
        b.setPriceSource(address(p));
        vm.startPrank(seller);
        imd.approve(address(b), type(uint256).max);
        uint256 id = b.createOffer(OFFER);
        vm.stopPrank();
        address[2] memory bidders = [alice, bob];
        uint256[2] memory ids;
        for (uint256 i; i < 2; ++i) {
            blk.mint(bidders[i], 10_000e18);
            vm.startPrank(bidders[i]);
            blk.approve(address(b), type(uint256).max);
            ids[i] = b.placeBid(id, 100);
            vm.stopPrank();
        }
        blk.setBlocked(alice);
        vm.warp(block.timestamp + 1 hours);
        b.settle(id); // settlement never pushes funds
        vm.prank(alice);
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        b.claimBid(ids[0]);
        vm.prank(bob);
        b.claimBid(ids[1]);
        vm.prank(seller);
        b.claimSeller(id);
    }

    function test_reentrancyBlocked() public {
        ReentrantToken re = new ReentrantToken();
        NightshiftBackstop b = new NightshiftBackstop(owner, address(re), address(usdc), MIN_OFFER, CAP, 0);
        MockPool p = new MockPool(address(re), address(usdc));
        vm.prank(owner);
        b.setPriceSource(address(p));
        re.mint(seller, OFFER);
        vm.startPrank(seller);
        re.approve(address(b), type(uint256).max);
        uint256 id = b.createOffer(OFFER);
        vm.stopPrank();
        vm.startPrank(alice);
        usdc.approve(address(b), type(uint256).max);
        uint256 bidId = b.placeBid(id, 10);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours);
        b.settle(id);

        re.arm(address(b), abi.encodeCall(NightshiftBackstop.claimBid, (bidId)));
        vm.prank(alice);
        b.claimBid(bidId);
        assertTrue(re.attempted());
        assertEq(bytes4(re.reentryResult()), NightshiftBackstop.Reentrancy.selector);
        assertEq(re.balanceOf(alice), 100e18);
    }

    // ------------------------------------------------------------------ conservation (fuzz)

    function testFuzz_conservation(uint8 nBids, uint256 seed, uint96 shieldAmt, int16 tickMove) public {
        nBids = uint8(bound(nBids, 0, 12));
        int24 move = int24(bound(int256(tickMove), -3000, 3000));
        _move(move);
        uint256 shieldIn = bound(uint256(shieldAmt), 0, 5_000e18);
        if (shieldIn != 0) {
            vm.prank(shielder);
            bs.shieldDeposit(shieldIn);
        }
        uint256 imdStart = imd.balanceOf(address(bs));
        uint256 usdcStart = usdc.balanceOf(address(bs));

        uint256 id = _offer();
        address[3] memory who = [alice, bob, carol];
        uint256[] memory bidIds = new uint256[](nBids);
        uint256 bidUsdc;
        NightshiftBackstop.Offer memory o = bs.getOffer(id);
        for (uint256 i; i < nBids; ++i) {
            uint256 lots = bound(uint256(keccak256(abi.encode(seed, i))), 1, 100);
            bidIds[i] = _bid(who[i % 3], id, lots);
            bidUsdc += lots * o.lotCost;
        }
        _settle(id);
        o = bs.getOffer(id);

        uint256 lotsOut;
        uint256 refunds;
        for (uint256 i; i < nBids; ++i) {
            NightshiftBackstop.Bid memory b = bs.getBid(bidIds[i]);
            uint256 n = bs.filledLotsOf(bidIds[i]);
            assertLe(n, b.lots);
            lotsOut += n;
            refunds += (b.lots - n) * o.lotCost;
            vm.prank(b.bidder);
            bs.claimBid(bidIds[i]);
        }
        assertEq(lotsOut, o.filledLots, "fills telescope exactly");
        assertEq(o.shieldLots + o.filledLots + (100 - o.shieldLots - o.filledLots), 100);
        assertEq(o.filledLots, o.bidCapacity < 100 - o.shieldLots ? o.bidCapacity : 100 - o.shieldLots);

        vm.prank(seller);
        bs.claimSeller(id);
        if (bs.treasuryAccrued() != 0) bs.withdrawTreasury();

        uint256 gross = (o.shieldLots + o.filledLots) * o.lotCost;
        // Quote: bids in = refunds + fills; fills = seller + fee(treasury + shield).
        assertEq(bidUsdc, refunds + o.filledLots * o.lotCost);
        assertGe(o.sellerProceeds * 10_000 + 10_000, gross * (10_000 - 300));
        assertLe(o.sellerProceeds, gross);

        // What remains is exactly the Shield's: its deposits and its gains (rounded down).
        assertEq(imd.balanceOf(address(bs)) - imdStart, o.shieldLots * o.lotSize);
        _assertShieldSolvent();
        assertGe(usdc.balanceOf(address(bs)), usdcStart - o.shieldLots * o.lotCost);

        if (shieldIn != 0) {
            vm.warp(block.timestamp + 30 days);
            (uint256 dep,,,) = bs.shieldPosition(shielder);
            if (dep != 0) {
                vm.prank(shielder);
                bs.shieldWithdraw(dep);
            }
            assertLe(imd.balanceOf(address(bs)), 1e6, "token dust only");
            assertLe(usdc.balanceOf(address(bs)), 1e6, "quote dust only");
        }
    }

    function _assertShieldSolvent() internal view {
        address[2] memory ds = [shielder, carol];
        uint256 owedQuote;
        uint256 owedToken;
        for (uint256 i; i < ds.length; ++i) {
            (uint256 dep, uint256 tg, uint256 qg,) = bs.shieldPosition(ds[i]);
            owedQuote += dep + qg;
            owedToken += tg;
        }
        assertLe(owedQuote, usdc.balanceOf(address(bs)) - bs.treasuryAccrued());
        assertLe(owedToken, imd.balanceOf(address(bs)));
    }

    // ------------------------------------------------------------------ revision: Shield price bound at settlement

    function test_shieldDoesNotBuyAboveSettlementTwap() public {
        vm.prank(shielder);
        bs.shieldDeposit(10_000e18);
        _setTicks(23_027, 23_027); // ~10x held across both windows: momentum 0, the pump filter passes
        uint256 id = _offer();
        NightshiftBackstop.Offer memory o = bs.getOffer(id);
        assertTrue(o.shieldEligible);
        assertEq(o.discountBps, 500);
        assertEq(o.shieldReservedLots, 50);
        assertEq(bs.shieldReservedQuote(), 50 * o.lotCost);
        uint256 a = _bid(alice, id, 10); // a bidder who accepts the price is still filled

        _setTicks(0, 0); // the price is back at 1 by settlement
        _settle(id);
        o = bs.getOffer(id);
        assertEq(o.shieldLots, 0, "Shield must not pay 10x the pool price");
        assertEq(o.filledLots, 10);
        assertEq(bs.filledLotsOf(a), 10);
        assertEq(bs.shieldTotalDeposits(), 10_000e18);
        assertEq(bs.shieldReservedQuote(), 0, "reservation released");
        (uint256 dep, uint256 tg, uint256 qg,) = bs.shieldPosition(shielder);
        assertEq(dep, 10_000e18);
        assertEq(tg, 0);
        assertEq(qg, 0);
        assertEq(bs.treasuryAccrued(), (10 * o.lotCost * 300 + 9_999) / 10_000, "no Shield lots, no Shield fee");
    }

    function test_shieldBuysDownToTheFrozenPriceAndNotBelow() public {
        vm.prank(shielder);
        bs.shieldDeposit(10_000e18);
        uint256 id1 = _offer();
        uint256 id2 = _offer();
        vm.warp(block.timestamp + bs.OFFER_WINDOW());

        _setTicks(0, -512); // a lot is worth ~9.5009, just above the frozen 9.5
        assertGe(bs.twapLotValue(10e18), LOT_COST);
        bs.settle(id1);
        assertEq(bs.getOffer(id1).shieldLots, 50);

        _setTicks(0, -513); // ~9.49996, just below
        assertLt(bs.twapLotValue(10e18), LOT_COST);
        bs.settle(id2);
        assertEq(bs.getOffer(id2).shieldLots, 0);
        assertEq(bs.shieldReservedQuote(), 0);
        assertEq(bs.shieldTotalDeposits(), 10_000e18 - 50 * LOT_COST);
    }

    function test_unreadablePoolAtSettlementSkipsShieldOnly() public {
        vm.prank(shielder);
        bs.shieldDeposit(2_000e18);
        uint256 id = _offer();
        uint256 a = _bid(alice, id, 100);
        assertEq(bs.getOffer(id).shieldReservedLots, 50);
        pool.setBroken(true);
        _settle(id); // must not revert
        NightshiftBackstop.Offer memory o = bs.getOffer(id);
        assertEq(o.shieldLots, 0);
        assertEq(o.filledLots, 100);
        assertEq(bs.filledLotsOf(a), 100);
        assertEq(bs.shieldTotalDeposits(), 2_000e18);
        assertEq(bs.shieldReservedQuote(), 0);
    }

    // ------------------------------------------------------------------ revision: Shield slice fixed at creation

    function test_lateShieldDepositDoesNotJoinOffer() public {
        uint256 id = _offer(); // Shield empty at creation
        uint256 a = _bid(alice, id, 100);
        vm.warp(block.timestamp + bs.OFFER_WINDOW());
        vm.prank(outsider);
        bs.shieldDeposit(950e18); // after the deadline
        bs.settle(id);
        NightshiftBackstop.Offer memory o = bs.getOffer(id);
        assertEq(o.shieldReservedLots, 0);
        assertEq(o.shieldLots, 0);
        assertEq(bs.filledLotsOf(a), 100);
        (uint256 dep, uint256 tg, uint256 qg,) = bs.shieldPosition(outsider);
        assertEq(dep, 950e18);
        assertEq(tg, 0);
        assertEq(qg, 0);
        assertEq(bs.treasuryAccrued(), (100 * LOT_COST * 300 + 9_999) / 10_000);
    }

    function test_depositDuringWindowDoesNotEnlargeShieldSlice() public {
        vm.prank(shielder);
        bs.shieldDeposit(100e18); // half usable = 50 -> 5 lots
        uint256 id = _offer();
        assertEq(bs.getOffer(id).shieldReservedLots, 5);
        vm.prank(carol);
        bs.shieldDeposit(10_000e18);
        _settle(id);
        assertEq(bs.getOffer(id).shieldLots, 5);
    }

    function test_withdrawCannotTakeFundsReservedForOpenOffers() public {
        vm.prank(shielder);
        bs.shieldDeposit(1_000e18);
        vm.warp(block.timestamp + 30 days);
        uint256 id = _offer();
        assertEq(bs.shieldReservedQuote(), 475e18); // 50 lots x 9.5

        vm.startPrank(shielder);
        vm.expectRevert(NightshiftBackstop.ShieldFundsReserved.selector);
        bs.shieldWithdraw(1_000e18);
        vm.expectRevert(NightshiftBackstop.ShieldFundsReserved.selector);
        bs.shieldWithdraw(50e18 + 2);
        bs.shieldWithdraw(50e18); // 950 left: half of it still covers the 475 reserved
        vm.stopPrank();

        _settle(id);
        assertEq(bs.getOffer(id).shieldLots, 50);
        (uint256 dep,,,) = bs.shieldPosition(shielder);
        vm.prank(shielder);
        bs.shieldWithdraw(dep); // free again once the offer is settled
    }

    function test_splitOffersShareOneShieldBudget() public {
        vm.prank(shielder);
        bs.shieldDeposit(1_000e18);
        uint256[5] memory ids;
        for (uint256 i; i < 5; ++i) {
            ids[i] = _offer(); // same block, same price
        }
        assertEq(bs.getOffer(ids[0]).shieldReservedLots, 50); // 475 of the 500 usable
        assertEq(bs.getOffer(ids[1]).shieldReservedLots, 2); // 19 of the 25 left
        assertEq(bs.getOffer(ids[2]).shieldReservedLots, 0);
        assertLe(bs.shieldReservedQuote(), 500e18);
        vm.warp(block.timestamp + bs.OFFER_WINDOW());
        uint256 lots;
        for (uint256 i; i < 5; ++i) {
            bs.settle(ids[i]);
            lots += bs.getOffer(ids[i]).shieldLots;
        }
        assertEq(lots, 52);
        assertGe(bs.shieldTotalDeposits(), 500e18, "at most half of the Shield went to one price");
    }

    // ------------------------------------------------------------------ revision: seller's price bound

    function test_createOfferWithPriceBound() public {
        vm.startPrank(seller);
        vm.expectRevert(NightshiftBackstop.LotCostBelowMinimum.selector);
        bs.createOffer(OFFER, LOT_COST + 1, block.timestamp);
        vm.expectRevert(NightshiftBackstop.OfferExpired.selector);
        bs.createOffer(OFFER, LOT_COST, block.timestamp - 1);
        uint256 id = bs.createOffer(OFFER, LOT_COST, block.timestamp);
        vm.stopPrank();
        assertEq(bs.getOffer(id).lotCost, LOT_COST);
        assertEq(imd.balanceOf(address(bs)), OFFER);

        // The TWAP falls while the next offer is pending: the bounded call refuses the lower price.
        _move(-1000);
        (uint256 lower,,) = bs.quoteLot(10e18);
        assertLt(lower, LOT_COST);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.LotCostBelowMinimum.selector);
        bs.createOffer(OFFER, LOT_COST, block.timestamp + 1 hours);
        assertEq(bs.offerCount(), 1);
    }

    // ------------------------------------------------------------------ revision: fee share follows absorbed lots

    function test_dustLeftInShieldDoesNotStrandFees() public {
        vm.prank(shielder);
        bs.shieldDeposit(28.5e18);
        uint256 id1 = _offer();
        _settle(id1);
        assertEq(bs.getOffer(id1).shieldLots, 1);
        vm.warp(block.timestamp + 30 days);
        (uint256 dep,,,) = bs.shieldPosition(shielder);
        vm.prank(shielder);
        bs.shieldWithdraw(dep);
        assertLe(bs.shieldTotalDeposits(), 1e3, "only rounding dust is left");

        uint256 before = bs.treasuryAccrued();
        uint256 id2 = _offer();
        _bid(alice, id2, 50);
        _settle(id2);
        uint256 fee = (50 * LOT_COST * 300 + 9_999) / 10_000;
        assertEq(bs.treasuryAccrued() - before, fee, "the whole fee goes to the treasury");
        bs.withdrawTreasury();
        vm.prank(seller);
        bs.claimSeller(id1);
        vm.prank(seller);
        bs.claimSeller(id2);
    }

    function test_oneWeiDepositEarnsNoFees() public {
        vm.prank(carol);
        bs.shieldDeposit(1);
        uint256 id = _offer();
        _bid(alice, id, 100);
        _settle(id);
        assertEq(bs.getOffer(id).shieldLots, 0);
        assertEq(bs.treasuryAccrued(), (100 * LOT_COST * 300 + 9_999) / 10_000);
        (,, uint256 qg,) = bs.shieldPosition(carol);
        assertEq(qg, 0);
    }

    // ------------------------------------------------------------------ revision: momentum, pause, recipients

    function test_momentumSaturatesWhenPastValueRoundsToZero() public {
        MockERC20 usdc6 = new MockERC20("USD Coin", "USDC", 6);
        NightshiftBackstop b = new NightshiftBackstop(owner, address(imd), address(usdc6), MIN_OFFER, 10_000e6, 0);
        MockPool p = new MockPool(address(imd), address(usdc6));
        vm.prank(owner);
        b.setPriceSource(address(p));
        bool imdFirst = address(imd) < address(usdc6);
        usdc6.mint(shielder, 10_000e6);
        vm.startPrank(shielder);
        usdc6.approve(address(b), type(uint256).max);
        b.shieldDeposit(10_000e6);
        vm.stopPrank();

        // The older window values a 10 IMD lot below one USDC unit; the current one at ~33 USDC.
        p.setTicks(imdFirst ? int24(-460_000) : int24(460_000), imdFirst ? int24(-264_331) : int24(264_331));
        (uint256 lotCost, uint256 discount, int256 momentum) = b.quoteLot(10e18);
        assertEq(momentum, int256(type(int128).max));
        assertEq(discount, 1_200);
        assertGt(lotCost, 0);
        vm.startPrank(seller);
        imd.approve(address(b), type(uint256).max);
        uint256 id = b.createOffer(OFFER);
        vm.stopPrank();
        assertFalse(b.getOffer(id).shieldEligible, "the largest rise must trip the pump filter");
        assertEq(b.getOffer(id).shieldReservedLots, 0);

        // No price in either window is no momentum.
        p.setTicks(imdFirst ? int24(-460_000) : int24(460_000), imdFirst ? int24(-460_000) : int24(460_000));
        (,, momentum) = b.quoteLot(10e18);
        assertEq(momentum, 0);
    }

    function test_pauseDoesNotShutBiddersOut() public {
        uint256 id = _offer();
        imd.mint(owner, 1e18);
        usdc.mint(owner, 10_000e18);
        vm.startPrank(owner);
        usdc.approve(address(bs), type(uint256).max);
        uint256 first = bs.placeBid(id, 100);
        bs.setPaused(true);
        vm.stopPrank();
        uint256 second = _bid(alice, id, 100);
        _settle(id);
        assertEq(bs.filledLotsOf(first), 50);
        assertEq(bs.filledLotsOf(second), 50);
    }

    function test_blockedRecipientClaimsToAnotherAddress() public {
        BlockingToken blk = new BlockingToken();
        NightshiftBackstop b = new NightshiftBackstop(owner, address(imd), address(blk), MIN_OFFER, CAP, 0);
        MockPool p = new MockPool(address(imd), address(blk));
        vm.prank(owner);
        b.setPriceSource(address(p));
        address[2] memory funders = [shielder, alice];
        for (uint256 i; i < 2; ++i) {
            blk.mint(funders[i], 10_000e18);
            vm.prank(funders[i]);
            blk.approve(address(b), type(uint256).max);
        }
        vm.prank(shielder);
        b.shieldDeposit(10_000e18);
        vm.startPrank(seller);
        imd.approve(address(b), type(uint256).max);
        uint256 id = b.createOffer(OFFER);
        vm.stopPrank();
        vm.prank(alice);
        uint256 bidId = b.placeBid(id, 100); // 50 filled, 50 refunded
        vm.warp(block.timestamp + 1 hours);
        b.settle(id);
        address safe = makeAddr("safe");

        // Bidder: tokens and a refund are owed; the quote token refuses the bidder.
        blk.setBlocked(alice);
        vm.startPrank(alice);
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        b.claimBid(bidId);
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        b.claimBidTo(bidId, address(0));
        b.claimBidTo(bidId, safe);
        vm.stopPrank();
        assertEq(imd.balanceOf(safe), 500e18);
        assertEq(blk.balanceOf(safe), 50 * LOT_COST);
        vm.prank(bob);
        vm.expectRevert(NightshiftBackstop.NotBidder.selector);
        b.claimBidTo(bidId, bob);

        // Seller.
        blk.setBlocked(seller);
        vm.prank(outsider);
        vm.expectRevert(NightshiftBackstop.NotSeller.selector);
        b.claimSellerTo(id, outsider);
        vm.startPrank(seller);
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        b.claimSeller(id);
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        b.claimSellerTo(id, address(0));
        uint256 beforeSafe = blk.balanceOf(safe);
        b.claimSellerTo(id, safe);
        vm.stopPrank();
        assertEq(blk.balanceOf(safe) - beforeSafe, b.getOffer(id).sellerProceeds);

        // Shield depositor: IMD gains and fee gains, then the deposit itself.
        blk.setBlocked(shielder);
        (uint256 dep, uint256 tg, uint256 qg,) = b.shieldPosition(shielder);
        assertGt(tg, 0);
        assertGt(qg, 0);
        address vault = makeAddr("vault");
        vm.startPrank(shielder);
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        b.shieldClaimGains();
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        b.shieldClaimGainsTo(address(0));
        b.shieldClaimGainsTo(vault);
        assertEq(imd.balanceOf(vault), tg);
        assertEq(blk.balanceOf(vault), qg);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        b.shieldWithdrawTo(dep, address(0));
        b.shieldWithdrawTo(dep, vault);
        vm.stopPrank();
        assertEq(blk.balanceOf(vault), qg + dep);
    }

    // ------------------------------------------------------------------ revision: many offers, one Shield (fuzz)

    function testFuzz_multiOfferShieldConservation(uint96 depSeed, uint8 nOffers, uint256 seed) public {
        uint256 dep = bound(uint256(depSeed), 1e18, 50_000e18);
        uint256 n = bound(uint256(nOffers), 1, 6);
        vm.prank(shielder);
        bs.shieldDeposit(dep);
        vm.prank(carol);
        bs.shieldDeposit(dep / 3 + 1);

        uint256[] memory ids = new uint256[](n);
        uint256[] memory bidIds = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = _offer();
            uint256 lots = uint256(keccak256(abi.encode(seed, i))) % 101;
            if (lots != 0) bidIds[i] = _bid(alice, ids[i], lots);
            assertLe(bs.shieldReservedQuote(), bs.shieldTotalDeposits() / 2, "never more than half committed");
        }
        // A late deposit changes nothing for the offers above.
        vm.prank(bob);
        bs.shieldDeposit(dep);

        vm.warp(block.timestamp + bs.OFFER_WINDOW());
        uint256 shieldLots;
        for (uint256 i; i < n; ++i) {
            // Some offers settle with the price under the frozen one: the Shield skips those.
            bool dipped = uint256(keccak256(abi.encode(seed, i, "dip"))) % 3 == 0;
            _setTicks(0, dipped ? int24(-600) : int24(0));
            uint256 totalBefore = bs.shieldTotalDeposits();
            bs.settle(ids[i]);
            NightshiftBackstop.Offer memory o = bs.getOffer(ids[i]);
            assertEq(o.shieldLots, dipped ? 0 : o.shieldReservedLots);
            assertLe(o.shieldLots * o.lotCost, totalBefore / 2, "an absorption never exceeds half");
            shieldLots += o.shieldLots;
            if (bidIds[i] != 0) {
                vm.prank(alice);
                bs.claimBid(bidIds[i]);
            }
            vm.prank(seller);
            bs.claimSeller(ids[i]);
        }
        assertEq(bs.shieldReservedQuote(), 0, "every reservation released");
        if (bs.treasuryAccrued() != 0) bs.withdrawTreasury();

        vm.warp(block.timestamp + 30 days);
        address[3] memory ds = [shielder, carol, bob];
        uint256 tokensOut;
        for (uint256 i; i < 3; ++i) {
            (uint256 d, uint256 tg,,) = bs.shieldPosition(ds[i]);
            tokensOut += tg;
            vm.prank(ds[i]);
            if (d != 0) bs.shieldWithdraw(d);
            else bs.shieldClaimGains();
        }
        assertLe(tokensOut, shieldLots * 10e18);
        assertLe(imd.balanceOf(address(bs)), 1e9, "token dust only");
        assertLe(usdc.balanceOf(address(bs)), 1e9, "quote dust only");
    }
}
