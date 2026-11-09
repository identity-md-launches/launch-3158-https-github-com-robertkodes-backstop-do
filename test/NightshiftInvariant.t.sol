// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BackstopHandler} from "./invariant/BackstopHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract NightshiftInvariantTest is Test {
    BackstopHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        handler = new BackstopHandler();
        // Exercise live, settled and partially claimed liabilities before random calls start.
        handler.deposit(0, 20_000e6);
        handler.deposit(1, 10_000e6);
        handler.createOffer(2, 1_000e18);
        handler.bid(0, 1, 100);
        handler.bid(1, 1, 70);
        handler.settle(1);
        handler.claimBid(1);
        handler.createOffer(3, 2_000e18);
        handler.bid(2, 2, 30);

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.createOffer.selector;
        selectors[1] = handler.bid.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.claimSeller.selector;
        selectors[4] = handler.claimBid.selector;
        selectors[5] = handler.deposit.selector;
        selectors[6] = handler.withdraw.selector;
        selectors[7] = handler.claimGains.selector;
        selectors[8] = handler.treasury.selector;
        selectors[9] = handler.donate.selector;
        selectors[10] = handler.advance.selector;
        selectors[11] = handler.changeMarket.selector;
        selectors[12] = handler.pause.selector;
        selectors[13] = handler.invalidCall.selector;
        selectors[14] = handler.rotateSource.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_custodyAllocationAndClaimsRemainSolvent() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.closeAll();
        handler.assertAccounting();
        for (uint256 i = 1; i <= handler.createdOffers(); ++i) {
            assertTrue(handler.backstop().getOffer(i).settled);
            assertTrue(handler.backstop().getOffer(i).sellerClaimed);
        }
        for (uint256 i = 1; i <= handler.createdBids(); ++i) {
            assertTrue(handler.backstop().getBid(i).claimed);
        }
        for (uint256 i; i < 4; ++i) {
            (uint256 deposit, uint256 tg, uint256 qg,) = handler.backstop().shieldPosition(handler.actors(i));
            assertEq(deposit, 0, "principal still locked after unwind");
            assertEq(tg, 0, "token gains remain after unwind");
            assertEq(qg, 0, "fee gains remain after unwind");
        }
        assertEq(handler.backstop().treasuryAccrued(), 0);
        assertGe(handler.successfulCalls(), 10, "campaign did not exercise custody");
    }

    /// @dev A deterministic tour keeps each handler operation reviewable outside the invariant runner.
    function test_handlerExercisesEveryActionAndUnwinds() public {
        handler.bid(0, 2, 100);
        handler.deposit(2, 1);
        handler.withdraw(2, 1, true); // locked withdrawal
        handler.invalidCall(0, 0);
        handler.invalidCall(0, 1);
        handler.invalidCall(0, 2);
        handler.invalidCall(0, 3);
        handler.invalidCall(0, 4);
        handler.donate(0, 3, true);
        handler.donate(1, 7, false);
        handler.changeMarket(-100, 2_100, false);
        handler.createOffer(3, 1_000e18);
        handler.settle(3);
        handler.settle(2);
        handler.claimSeller(2);
        handler.claimSeller(2);
        handler.claimBid(2);
        handler.claimBid(2);
        handler.claimGains(0);
        handler.claimGains(0);
        handler.advance(31 days);
        handler.withdraw(0, 1, false);
        handler.treasury();
        handler.treasury();
        handler.pause(true);
        handler.invalidCall(1, 4);
        handler.createOffer(0, 1_000e18); // skipped while paused
        handler.pause(false);
        handler.rotateSource(1); // nothing pending
        handler.rotateSource(0); // schedule
        handler.rotateSource(1); // too early
        handler.rotateSource(2); // cancel
        handler.rotateSource(0);
        handler.advance(31 days);
        handler.advance(6 days);
        handler.rotateSource(1); // applied
        assertEq(handler.sourceRotations(), 1);
        // Reservation blocks a full withdrawal until the offer settles.
        handler.deposit(1, 40_000e6);
        handler.advance(31 days);
        handler.withdraw(0, 0, true); // actor 1 now holds almost all Shield principal
        handler.changeMarket(0, 0, false); // leave the pump filter
        handler.createOffer(2, 20_000e18);
        assertGt(handler.backstop().getOffer(handler.createdOffers()).shieldReservedLots, 0);
        handler.pause(true);
        handler.bid(0, handler.createdOffers(), 5); // bids stay open during a pause
        handler.pause(false);
        assertEq(handler.bidsWhilePaused(), 1);
        handler.withdraw(1, 0, true);
        assertEq(handler.reservedWithdrawRejections(), 1);
        handler.deposit(0, 5);
        handler.assertAccounting();
        afterInvariant();
        assertGt(handler.rejectedCalls(), 8);
    }
}
