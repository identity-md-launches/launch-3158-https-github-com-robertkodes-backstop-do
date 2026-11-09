// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NightshiftBackstop} from "src/NightshiftBackstop.sol";
import {MockERC20, MockPool} from "./mocks/Mocks.sol";

/// forge-config: default.fuzz.runs = 512
contract NightshiftEconomicPropertiesTest is Test {
    NightshiftBackstop internal b;
    MockERC20 internal token;
    MockERC20 internal quote;
    MockPool internal pool;
    address internal seller = makeAddr("economic seller");
    address internal alice = makeAddr("economic alice");
    address internal bob = makeAddr("economic bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new MockERC20("Test IMD", "IMD", 18);
        quote = new MockERC20("Test quote", "Q", 18);
        // Equal-decimal, tick-zero market isolates base-unit rounding from oracle precision.
        b = new NightshiftBackstop(address(this), address(token), address(quote), 100, type(uint256).max, 0);
        pool = new MockPool(address(token), address(quote));
        b.setPriceSource(address(pool));
        address[3] memory actors = [seller, alice, bob];
        for (uint256 i; i < actors.length; ++i) {
            token.mint(actors[i], 1_000_000e18);
            quote.mint(actors[i], 1_000_000e18);
            vm.startPrank(actors[i]);
            token.approve(address(b), type(uint256).max);
            quote.approve(address(b), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _offer(uint256 amount) internal returns (uint256 id) {
        vm.prank(seller);
        id = b.createOffer(amount);
    }

    function _bid(address who, uint256 id, uint256 lots) internal returns (uint256 bidId) {
        vm.prank(who);
        bidId = b.placeBid(id, lots);
    }

    function _settle(uint256 id) internal {
        uint256 deadline = b.getOffer(id).deadline;
        if (deadline > block.timestamp) vm.warp(deadline);
        b.settle(id);
    }

    function test_oneBaseUnitLotAndRoundedFeeConserveEveryUnit() public {
        uint256 id = _offer(199); // only 100 base units escrowed
        uint256 bidId = _bid(alice, id, 1);
        assertEq(b.getOffer(id).lotSize, 1);
        assertEq(b.getOffer(id).lotCost, 1);
        _settle(id);
        uint256 sellerBefore = token.balanceOf(seller);
        uint256 buyerBefore = token.balanceOf(alice);
        vm.prank(seller);
        b.claimSeller(id);
        vm.prank(alice);
        b.claimBid(bidId);
        uint256 treasuryBefore = quote.balanceOf(address(this));
        b.withdrawTreasury();
        assertEq(token.balanceOf(seller) - sellerBefore, 99);
        assertEq(token.balanceOf(alice) - buyerBefore, 1);
        assertEq(quote.balanceOf(address(this)) - treasuryBefore, 1);
        assertEq(token.balanceOf(address(b)), 0);
        assertEq(quote.balanceOf(address(b)), 0);
    }

    function test_lastOf101OneLotBidsGetsFullRefundAndNoTokens() public {
        uint256 id = _offer(10_000);
        uint256[] memory bids = new uint256[](101);
        for (uint256 i; i < bids.length; ++i) {
            bids[i] = _bid(alice, id, 1);
        }
        _settle(id);
        uint256 tokenBefore = token.balanceOf(alice);
        uint256 quoteBefore = quote.balanceOf(alice);
        assertEq(b.filledLotsOf(bids[100]), 0);
        vm.prank(alice);
        b.claimBid(bids[100]);
        assertEq(token.balanceOf(alice), tokenBefore);
        assertEq(quote.balanceOf(alice), quoteBefore + b.getOffer(id).lotCost);
        uint256 totalFilled;
        for (uint256 i; i < 100; ++i) {
            totalFilled += b.filledLotsOf(bids[i]);
            vm.prank(alice);
            b.claimBid(bids[i]);
        }
        assertEq(totalFilled, 100);
        assertEq(token.balanceOf(alice), tokenBefore + 10_000);
        vm.prank(seller);
        b.claimSeller(id);
        b.withdrawTreasury();
        assertEq(token.balanceOf(address(b)), 0);
        assertEq(quote.balanceOf(address(b)), 0);
    }

    function testFuzz_adjacentBidSplitsPreserveCombinedAllocation(uint8 firstSeed, uint8 secondSeed, uint8 thirdSeed)
        public
    {
        uint256 first = bound(firstSeed, 1, 99);
        uint256 second = bound(secondSeed, 1, 100 - first);
        uint256 third = bound(thirdSeed, 1, 100);
        uint256 splitOffer = _offer(1_000e18);
        uint256 mergedOffer = _offer(1_000e18);
        _bid(bob, splitOffer, third);
        uint256 left = _bid(alice, splitOffer, first);
        uint256 right = _bid(alice, splitOffer, second);
        _bid(bob, mergedOffer, third);
        uint256 merged = _bid(alice, mergedOffer, first + second);
        _settle(splitOffer);
        _settle(mergedOffer);
        assertEq(b.filledLotsOf(left) + b.filledLotsOf(right), b.filledLotsOf(merged));
    }

    function testFuzz_claimOrderDoesNotChangeTokenOrQuoteDistribution(uint256 ordering) public {
        uint256 id = _offer(10_000);
        uint256[3] memory bids = [_bid(alice, id, 71), _bid(bob, id, 43), _bid(alice, id, 29)];
        _settle(id);
        uint256 snapshot = vm.snapshotState();
        _claimEverything(id, bids, 0);
        bytes32 first = _balancesHash();
        vm.revertToState(snapshot);
        _claimEverything(id, bids, ordering);
        assertEq(_balancesHash(), first, "claim ordering changes payouts");
    }

    function _claimEverything(uint256 id, uint256[3] memory bids, uint256 ordering) internal {
        // Four independent claims plus treasury, shuffled with a deterministic Fisher-Yates permutation.
        uint256[5] memory actions = [uint256(0), 1, 2, 3, 4];
        for (uint256 i = 4; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(ordering, i))) % (i + 1);
            (actions[i], actions[j]) = (actions[j], actions[i]);
        }
        for (uint256 i; i < actions.length; ++i) {
            uint256 action = actions[i];
            if (action < 3) {
                address bidder = b.getBid(bids[action]).bidder;
                vm.prank(bidder);
                b.claimBid(bids[action]);
            } else if (action == 3) {
                vm.prank(seller);
                b.claimSeller(id);
            } else {
                b.withdrawTreasury();
            }
        }
    }

    function _balancesHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.balanceOf(seller),
                quote.balanceOf(seller),
                token.balanceOf(alice),
                quote.balanceOf(alice),
                token.balanceOf(bob),
                quote.balanceOf(bob),
                quote.balanceOf(address(this)),
                token.balanceOf(address(b)),
                quote.balanceOf(address(b))
            )
        );
    }

    function test_priceAndPumpEligibilityAreFrozenBeforeOracleChanges() public {
        vm.prank(alice);
        b.shieldDeposit(10_000e18);
        uint256 stable = _offer(1_000e18);
        int24 up = address(token) < address(quote) ? int24(2500) : int24(-2500);
        pool.setTicks(0, up);
        uint256 pumped = _offer(1_000e18);
        uint256 frozenCost = b.getOffer(pumped).lotCost;
        assertFalse(b.getOffer(pumped).shieldEligible);
        MockPool replacement = new MockPool(address(token), address(quote));
        b.setPriceSource(address(replacement));
        // A replacement is only scheduled: open offers settle against the source they were priced by.
        assertEq(b.priceSource(), address(pool));
        assertEq(b.pendingPriceSource(), address(replacement));
        _settle(pumped);
        _settle(stable);
        assertEq(b.getOffer(pumped).shieldLots, 0);
        assertEq(b.getOffer(pumped).lotCost, frozenCost);
        assertEq(b.getOffer(stable).shieldLots, 50);
        assertEq(b.getOffer(stable).lotCost, 9.5e18);
    }

    /// @dev Revised design: a Shield that absorbs nothing earns no fee share, so idle or dust deposits
    /// cannot farm fees paid by bidders; the whole fee is the treasury's.
    function test_zeroShieldCapPaysBidFeesToTreasuryNotIdleDepositors() public {
        NightshiftBackstop zeroCap = new NightshiftBackstop(address(this), address(token), address(quote), 100, 0, 0);
        zeroCap.setPriceSource(address(pool));
        vm.startPrank(alice);
        quote.approve(address(zeroCap), type(uint256).max);
        zeroCap.shieldDeposit(1_000e18);
        vm.stopPrank();
        vm.startPrank(seller);
        token.approve(address(zeroCap), type(uint256).max);
        uint256 id = zeroCap.createOffer(1_000e18);
        vm.stopPrank();
        vm.startPrank(bob);
        quote.approve(address(zeroCap), type(uint256).max);
        zeroCap.placeBid(id, 100);
        vm.stopPrank();
        vm.warp(zeroCap.getOffer(id).deadline);
        zeroCap.settle(id);
        assertEq(zeroCap.getOffer(id).shieldLots, 0);
        assertEq(zeroCap.getOffer(id).filledLots, 100);
        (uint256 dep, uint256 tg, uint256 qg,) = zeroCap.shieldPosition(alice);
        assertEq(dep, 1_000e18);
        assertEq(tg, 0);
        assertEq(qg, 0);
        assertEq(zeroCap.getOffer(id).shieldReservedLots, 0);
        assertEq(zeroCap.treasuryAccrued(), 28.5e18);
    }

    function test_joiningShieldAfterSettlementCannotClaimPastRewards() public {
        vm.prank(alice);
        b.shieldDeposit(2_000e18);
        uint256 first = _offer(1_000e18);
        _settle(first);
        (uint256 alicePrincipal, uint256 aliceTokens, uint256 aliceFees,) = b.shieldPosition(alice);
        vm.prank(bob);
        b.shieldDeposit(alicePrincipal);
        (uint256 bobPrincipal, uint256 bobTokens, uint256 bobFees,) = b.shieldPosition(bob);
        assertEq(bobPrincipal, alicePrincipal);
        assertEq(bobTokens, 0);
        assertEq(bobFees, 0);
        uint256 tokenBefore = token.balanceOf(bob);
        uint256 quoteBefore = quote.balanceOf(bob);
        vm.prank(bob);
        b.shieldClaimGains();
        assertEq(token.balanceOf(bob), tokenBefore);
        assertEq(quote.balanceOf(bob), quoteBefore);
        (, uint256 aliceTokensAfter, uint256 aliceFeesAfter,) = b.shieldPosition(alice);
        assertEq(aliceTokensAfter, aliceTokens);
        assertEq(aliceFeesAfter, aliceFees);
    }

    function testFuzz_depositWithdrawCyclesCannotCreatePrincipal(uint128 amountSeed, uint8 cyclesSeed) public {
        uint256 amount = bound(amountSeed, 1, 100_000e18);
        uint256 cycles = bound(cyclesSeed, 1, 24);
        uint256 balance = quote.balanceOf(alice);
        for (uint256 i; i < cycles; ++i) {
            vm.prank(alice);
            b.shieldDeposit(amount);
            (,,, uint256 unlock) = b.shieldPosition(alice);
            vm.warp(unlock);
            vm.prank(alice);
            b.shieldWithdraw(amount);
            assertEq(quote.balanceOf(alice), balance);
            assertEq(b.shieldTotalDeposits(), 0);
        }
        assertEq(quote.balanceOf(address(b)), 0);
    }

    function testFuzz_partialWithdrawAndGainsClaimDoNotExtendLock(uint128 amountSeed) public {
        uint256 amount = bound(amountSeed, 2, 100_000e18);
        vm.prank(alice);
        b.shieldDeposit(amount);
        (,,, uint256 unlock) = b.shieldPosition(alice);
        vm.warp(unlock - 1);
        vm.prank(alice);
        b.shieldClaimGains();
        (,,, uint256 afterClaim) = b.shieldPosition(alice);
        assertEq(afterClaim, unlock);
        vm.prank(alice);
        vm.expectRevert(NightshiftBackstop.ShieldLocked.selector);
        b.shieldWithdraw(1);
        vm.warp(unlock);
        vm.prank(alice);
        b.shieldWithdraw(1);
        (,,, uint256 afterPartial) = b.shieldPosition(alice);
        assertEq(afterPartial, unlock);
        vm.prank(alice);
        b.shieldWithdraw(amount - 1);
        assertEq(b.shieldTotalDeposits(), 0);
    }

    function test_ShieldRescalesTwiceThroughRealOffersAndNewDepositorCanExit() public {
        uint256 initial = uint256(1900) << 65;
        vm.prank(alice);
        b.shieldDeposit(initial);
        uint256 allocatedTokens;
        uint256 spent;
        uint256 allocatedFees;
        for (uint256 i; i < 65; ++i) {
            uint256 k = uint256(1) << (65 - i);
            uint256 id = _offer(2000 * k);
            uint256 depositsBefore = b.shieldTotalDeposits();
            _settle(id);
            NightshiftBackstop.Offer memory offer = b.getOffer(id);
            assertEq(offer.shieldLots, 50);
            assertEq(depositsBefore - b.shieldTotalDeposits(), depositsBefore / 2);
            allocatedTokens += offer.shieldLots * offer.lotSize;
            spent += offer.shieldLots * offer.lotCost;
            uint256 gross = offer.shieldLots * offer.lotCost;
            allocatedFees += gross - offer.sellerProceeds - b.treasuryAccrued();
            vm.prank(seller);
            b.claimSeller(id);
            b.withdrawTreasury();
            (uint256 principal, uint256 pendingToken, uint256 pendingQuote,) = b.shieldPosition(alice);
            assertLe(principal, initial - spent);
            assertLe(pendingToken, allocatedTokens);
            assertLe(pendingQuote, allocatedFees);
            assertLe(principal + pendingQuote, quote.balanceOf(address(b)));
            assertLe(pendingToken, token.balanceOf(address(b)));
        }
        assertEq(b.shieldScale(), 2, "public settlement did not reach two rescalings");
        uint256 beforeToken = token.balanceOf(alice);
        uint256 beforeQuote = quote.balanceOf(alice);
        (, uint256 oldTg, uint256 oldQg,) = b.shieldPosition(alice);
        vm.prank(alice);
        b.shieldClaimGains();
        assertEq(token.balanceOf(alice) - beforeToken, oldTg);
        assertEq(quote.balanceOf(alice) - beforeQuote, oldQg);
        // Bound precision loss; never bless a large forfeiture by only checking that custody is solvent.
        assertApproxEqRel(oldTg, allocatedTokens, 1e11);
        assertApproxEqRel(oldQg, allocatedFees, 1e11);
        vm.prank(bob);
        b.shieldDeposit(1_000e18);
        uint256 next = _offer(100e18);
        _settle(next);
        (uint256 dep, uint256 tg, uint256 qg, uint256 unlock) = b.shieldPosition(bob);
        assertGt(dep, 0);
        assertGt(tg, 0);
        assertGt(qg, 0);
        beforeToken = token.balanceOf(bob);
        beforeQuote = quote.balanceOf(bob);
        vm.warp(unlock);
        vm.prank(bob);
        b.shieldWithdraw(dep);
        assertEq(token.balanceOf(bob) - beforeToken, tg);
        assertEq(quote.balanceOf(bob) - beforeQuote, dep + qg);
    }
}
