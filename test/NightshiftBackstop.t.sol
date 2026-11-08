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

        MockPool other = new MockPool(address(usdc), address(imd));
        vm.expectEmit(true, false, false, false, address(bs));
        emit NightshiftBackstop.PriceSourceSet(address(other));
        vm.prank(owner);
        bs.setPriceSource(address(other));
        assertEq(bs.priceSource(), address(other));
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
        vm.prank(bob);
        vm.expectRevert(NightshiftBackstop.Paused.selector);
        bs.placeBid(id, 1);
        vm.prank(shielder);
        vm.expectRevert(NightshiftBackstop.Paused.selector);
        bs.shieldDeposit(1e18);

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

        uint256 fee = (100 * LOT_COST * 300 + 9_999) / 10_000;
        uint256 shieldFee = fee * 8_000 / 10_000;
        assertEq(bs.treasuryAccrued(), fee - shieldFee);

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
}
