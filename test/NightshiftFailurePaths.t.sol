// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NightshiftBackstop} from "src/NightshiftBackstop.sol";
import {MockPool} from "./mocks/Mocks.sol";
import {AdversarialToken} from "./helpers/AdversarialToken.sol";

/// forge-config: default.fuzz.runs = 512
contract NightshiftFailurePathsTest is Test {
    NightshiftBackstop internal b;
    AdversarialToken internal token;
    AdversarialToken internal quote;
    MockPool internal pool;
    address internal owner = makeAddr("failure owner");
    address internal seller = makeAddr("failure seller");
    address internal bidder = makeAddr("failure bidder");
    address internal other = makeAddr("failure other");
    address internal depositor = makeAddr("failure depositor");
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new AdversarialToken(18);
        quote = new AdversarialToken(6);
        b = new NightshiftBackstop(owner, address(token), address(quote), AMOUNT, 10_000e6, 1e18);
        pool = new MockPool(address(token), address(quote));
        int24 tick = address(token) < address(quote) ? int24(-263819) : int24(263819);
        pool.setTicks(tick, tick);
        vm.prank(owner);
        b.setPriceSource(address(pool));
        address[4] memory users = [seller, bidder, other, depositor];
        for (uint256 i; i < users.length; ++i) {
            token.mint(users[i], 100_000e18);
            quote.mint(users[i], 1_000_000e6);
            vm.startPrank(users[i]);
            token.approve(address(b), type(uint256).max);
            quote.approve(address(b), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _offer() internal returns (uint256) {
        vm.prank(seller);
        return b.createOffer(AMOUNT);
    }

    function _bid(uint256 id, uint256 lots) internal returns (uint256) {
        vm.prank(bidder);
        return b.placeBid(id, lots);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(depositor);
        b.shieldDeposit(amount);
    }

    function _position() internal view returns (bytes memory) {
        (uint256 dep, uint256 tg, uint256 qg, uint256 unlock) = b.shieldPosition(depositor);
        return abi.encode(dep, tg, qg, unlock);
    }

    function _settle(uint256 id) internal {
        vm.warp(b.getOffer(id).deadline);
        vm.prank(other);
        b.settle(id);
    }

    function test_constructorRejectsEitherZeroAsset() public {
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        new NightshiftBackstop(owner, address(0), address(quote), 100, 0, 0);
        vm.expectRevert(NightshiftBackstop.ZeroAddress.selector);
        new NightshiftBackstop(owner, address(token), address(0), 100, 0, 0);
    }

    function test_quoteAndEscrowRejectUnrepresentableLotSizes() public {
        vm.expectRevert(NightshiftBackstop.OfferTooSmall.selector);
        b.quoteLot(0);
        vm.expectRevert(NightshiftBackstop.OfferTooSmall.selector);
        b.quoteLot(uint256(type(uint128).max) + 1);
        vm.expectRevert(NightshiftBackstop.OfferTooSmall.selector);
        b.createOffer((uint256(type(uint128).max) + 1) * 100);
        vm.expectRevert(NightshiftBackstop.OfferTooSmall.selector);
        b.createOffer(type(uint256).max);
        assertEq(b.offerCount(), 0);
    }

    function test_offerRejectsPriceThatRoundsToZeroWithoutTakingTokens() public {
        int24 tick = address(token) < address(quote) ? int24(-887272) : int24(887272);
        pool.setTicks(tick, tick);
        uint256 balance = token.balanceOf(seller);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.ZeroLotCost.selector);
        b.createOffer(AMOUNT);
        assertEq(token.balanceOf(seller), balance);
        assertEq(b.offerCount(), 0);
    }

    function test_approvalFailureRollsBackOfferAndAllowsRetry() public {
        vm.prank(seller);
        token.approve(address(b), AMOUNT - 1);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        b.createOffer(AMOUNT);
        assertEq(b.offerCount(), 0);
        assertEq(b.getOffer(1).seller, address(0));
        assertEq(token.balanceOf(address(b)), 0);
        vm.prank(seller);
        token.approve(address(b), AMOUNT);
        assertEq(_offer(), 1);
        assertEq(token.allowance(seller, address(b)), 0);
    }

    function test_insufficientQuoteRollsBackBidPrefixAndId() public {
        uint256 id = _offer();
        vm.startPrank(bidder);
        quote.transfer(other, quote.balanceOf(bidder));
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        b.placeBid(id, 100);
        vm.stopPrank();
        assertEq(b.bidCount(), 0);
        assertEq(b.getOffer(id).bidCapacity, 0);
        assertEq(b.getBid(1).bidder, address(0));
        uint256 paid = 100 * b.getOffer(id).lotCost;
        vm.prank(other);
        quote.transfer(bidder, paid);
        assertEq(_bid(id, 100), 1);
        assertEq(b.getBid(1).prefix, 0);
    }

    function test_taxedQuoteIsRejectedForBidsAndShieldDeposits() public {
        uint256 id = _offer();
        quote.setTaxIncoming(true);
        uint256 bidderBalance = quote.balanceOf(bidder);
        uint256 depositorBalance = quote.balanceOf(depositor);
        vm.prank(bidder);
        vm.expectRevert(NightshiftBackstop.FeeOnTransferUnsupported.selector);
        b.placeBid(id, 1);
        vm.prank(depositor);
        vm.expectRevert(NightshiftBackstop.FeeOnTransferUnsupported.selector);
        b.shieldDeposit(1);
        assertEq(quote.balanceOf(bidder), bidderBalance);
        assertEq(quote.balanceOf(depositor), depositorBalance);
        assertEq(b.bidCount(), 0);
        assertEq(b.getOffer(id).bidCapacity, 0);
        assertEq(b.shieldTotalDeposits(), 0);
        (uint256 principal,,, uint256 unlock) = b.shieldPosition(depositor);
        assertEq(principal, 0);
        assertEq(unlock, 0);
    }

    function testFuzz_badTransferReturnRollsBackIntake(uint8 modeSeed) public {
        AdversarialToken.Reply mode = AdversarialToken.Reply(bound(modeSeed, 2, 5));
        token.setReply(mode);
        uint256 balance = token.balanceOf(seller);
        vm.prank(seller);
        // Malformed ABI may revert without a custom error; in all cases custody must roll back.
        vm.expectRevert();
        b.createOffer(AMOUNT);
        assertEq(token.balanceOf(seller), balance);
        assertEq(token.balanceOf(address(b)), 0);
        assertEq(b.offerCount(), 0);
        token.setReply(AdversarialToken.Reply.True);
        assertEq(_offer(), 1, "revert must release the reentrancy lock");
    }

    function testFuzz_badTransferReturnRollsBackPayout(uint8 modeSeed) public {
        uint256 id = _offer();
        uint256 bidId = _bid(id, 100);
        _settle(id);
        token.setReply(AdversarialToken.Reply(bound(modeSeed, 2, 5)));
        uint256 balance = token.balanceOf(bidder);
        vm.prank(bidder);
        vm.expectRevert();
        b.claimBid(bidId);
        assertFalse(b.getBid(bidId).claimed);
        assertEq(token.balanceOf(bidder), balance);
        token.setReply(AdversarialToken.Reply.True);
        vm.prank(bidder);
        b.claimBid(bidId);
        assertEq(token.balanceOf(bidder), balance + AMOUNT);
    }

    function test_noReturnTokensSupportTheEntireLifecycle() public {
        token.setReply(AdversarialToken.Reply.Empty);
        quote.setReply(AdversarialToken.Reply.Empty);
        _deposit(20_000e6);
        uint256 id = _offer();
        uint256 bidId = _bid(id, 100);
        _settle(id);
        vm.prank(seller);
        b.claimSeller(id);
        vm.prank(bidder);
        b.claimBid(bidId);
        (uint256 dep, uint256 tg, uint256 qg, uint256 unlock) = b.shieldPosition(depositor);
        uint256 beforeQuote = quote.balanceOf(depositor);
        uint256 beforeToken = token.balanceOf(depositor);
        vm.warp(unlock);
        vm.prank(depositor);
        b.shieldWithdraw(dep);
        assertEq(quote.balanceOf(depositor), beforeQuote + dep + qg);
        assertEq(token.balanceOf(depositor), beforeToken + tg);
        b.withdrawTreasury();
        assertLe(quote.balanceOf(address(b)), 2, "quote rounding dust");
        assertLe(token.balanceOf(address(b)), 20_000e6, "gain index rounding bound");
    }

    function test_sellerSecondTransferFailureRollsBackFirstTransfer() public {
        uint256 id = _offer();
        _bid(id, 20);
        _settle(id);
        token.setBlocked(seller);
        uint256 beforeQuote = quote.balanceOf(seller);
        uint256 beforeToken = token.balanceOf(seller);
        vm.prank(seller);
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        b.claimSeller(id);
        assertFalse(b.getOffer(id).sellerClaimed);
        assertEq(quote.balanceOf(seller), beforeQuote);
        assertEq(token.balanceOf(seller), beforeToken);
        token.setBlocked(address(0));
        vm.prank(seller);
        b.claimSeller(id);
        assertEq(token.balanceOf(seller), beforeToken + AMOUNT * 80 / 100);
        assertEq(quote.balanceOf(seller), beforeQuote + b.getOffer(id).sellerProceeds);
    }

    function test_bidRefundFailureRollsBackTokensAndCanRetry() public {
        uint256 id = _offer();
        uint256 bidId = _bid(id, 100);
        vm.prank(other);
        uint256 otherBid = b.placeBid(id, 100);
        _settle(id);
        quote.setBlocked(bidder);
        uint256 beforeQuote = quote.balanceOf(bidder);
        uint256 beforeToken = token.balanceOf(bidder);
        vm.prank(bidder);
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        b.claimBid(bidId);
        assertFalse(b.getBid(bidId).claimed);
        assertEq(quote.balanceOf(bidder), beforeQuote);
        assertEq(token.balanceOf(bidder), beforeToken);
        vm.prank(other);
        b.claimBid(otherBid);
        quote.setBlocked(address(0));
        vm.prank(bidder);
        b.claimBid(bidId);
        assertEq(token.balanceOf(bidder), beforeToken + AMOUNT / 2);
        assertEq(quote.balanceOf(bidder), beforeQuote + 50 * b.getOffer(id).lotCost);
    }

    function test_failedGainPaymentPreservesSnapshotsAndPrincipal() public {
        _deposit(20_000e6);
        uint256 id = _offer();
        _settle(id);
        (uint256 dep, uint256 tg, uint256 qg, uint256 unlock) = b.shieldPosition(depositor);
        assertGt(tg, 0);
        assertGt(qg, 0);
        uint256 beforeQuote = quote.balanceOf(depositor);
        uint256 beforeToken = token.balanceOf(depositor);
        quote.setBlocked(depositor);
        vm.prank(depositor);
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        b.shieldClaimGains();
        (uint256 dep2, uint256 tg2, uint256 qg2, uint256 unlock2) = b.shieldPosition(depositor);
        assertEq(abi.encode(dep2, tg2, qg2, unlock2), abi.encode(dep, tg, qg, unlock));
        assertEq(token.balanceOf(depositor), beforeToken);
        assertEq(quote.balanceOf(depositor), beforeQuote);
        quote.setBlocked(address(0));
        vm.prank(depositor);
        b.shieldClaimGains();
        assertEq(token.balanceOf(depositor), beforeToken + tg);
        assertEq(quote.balanceOf(depositor), beforeQuote + qg);
    }

    function test_failedRedepositDoesNotPayGainsOrRestartLock() public {
        _deposit(20_000e6);
        uint256 id = _offer();
        _settle(id);
        bytes memory beforePosition = _position();
        uint256 total = b.shieldTotalDeposits();
        uint256 balance = token.balanceOf(depositor);
        vm.prank(depositor);
        quote.approve(address(b), 0);
        vm.prank(depositor);
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        b.shieldDeposit(1);
        assertEq(_position(), beforePosition);
        assertEq(b.shieldTotalDeposits(), total);
        assertEq(token.balanceOf(depositor), balance);
    }

    function test_invalidAndFailedWithdrawalsPreservePendingGains() public {
        _deposit(20_000e6);
        uint256 id = _offer();
        _settle(id);
        (uint256 dep,,, uint256 unlock) = b.shieldPosition(depositor);
        vm.warp(unlock);
        bytes memory position = _position();
        uint256 total = b.shieldTotalDeposits();
        vm.prank(depositor);
        vm.expectRevert(NightshiftBackstop.InsufficientShieldDeposit.selector);
        b.shieldWithdraw(0);
        vm.prank(depositor);
        vm.expectRevert(NightshiftBackstop.InsufficientShieldDeposit.selector);
        b.shieldWithdraw(dep + 1);
        quote.setBlocked(depositor);
        vm.prank(depositor);
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        b.shieldWithdraw(dep);
        assertEq(_position(), position);
        assertEq(b.shieldTotalDeposits(), total);
        quote.setBlocked(address(0));
        vm.prank(depositor);
        b.shieldWithdraw(dep);
        (uint256 afterDeposit, uint256 afterTg, uint256 afterQg, uint256 afterUnlock) = b.shieldPosition(depositor);
        assertEq(afterDeposit + afterTg + afterQg + afterUnlock, 0);
    }

    function test_failedTreasuryTransferCanBeReroutedByOwner() public {
        uint256 id = _offer();
        _bid(id, 100);
        _settle(id);
        uint256 accrued = b.treasuryAccrued();
        quote.setBlocked(owner);
        vm.expectRevert(NightshiftBackstop.TokenTransferFailed.selector);
        b.withdrawTreasury();
        assertEq(b.treasuryAccrued(), accrued);
        vm.prank(owner);
        b.setTreasury(depositor);
        uint256 beforeRecipient = quote.balanceOf(depositor);
        uint256 beforeCaller = quote.balanceOf(other);
        vm.prank(other);
        b.withdrawTreasury();
        assertEq(quote.balanceOf(depositor), beforeRecipient + accrued);
        assertEq(quote.balanceOf(other), beforeCaller);
        assertEq(b.treasuryAccrued(), 0);
    }

    function test_settlementDoesNotCallOracleOrTransferTokens() public {
        _deposit(20_000e6);
        uint256 id = _offer();
        _bid(id, 100);
        pool.setBroken(true);
        token.setReply(AdversarialToken.Reply.Revert);
        quote.setReply(AdversarialToken.Reply.Revert);
        uint256 beforeToken = token.balanceOf(address(b));
        uint256 beforeQuote = quote.balanceOf(address(b));
        _settle(id);
        assertTrue(b.getOffer(id).settled);
        assertEq(token.balanceOf(address(b)), beforeToken);
        assertEq(quote.balanceOf(address(b)), beforeQuote);
    }

    function test_deadlineMinusOneAndExactDeadlineAreComplementary() public {
        uint256 id = _offer();
        vm.warp(b.getOffer(id).deadline - 1);
        vm.expectRevert(NightshiftBackstop.BiddingOpen.selector);
        b.settle(id);
        _bid(id, 1);
        vm.warp(block.timestamp + 1);
        vm.prank(bidder);
        vm.expectRevert(NightshiftBackstop.BiddingClosed.selector);
        b.placeBid(id, 1);
        b.settle(id);
        assertEq(b.getOffer(id).filledLots, 1);
    }

    function test_exactHolderThresholdAndBalanceAtSecondBid() public {
        uint256 id = _offer();
        uint256 excess = token.balanceOf(bidder) - 1e18;
        vm.prank(bidder);
        token.transfer(other, excess);
        _bid(id, 1);
        vm.prank(bidder);
        token.transfer(other, 1);
        vm.prank(bidder);
        vm.expectRevert(NightshiftBackstop.NotHolder.selector);
        b.placeBid(id, 1);
        assertEq(b.bidCount(), 1);
    }

    function test_pendingOwnerCanBeReplacedAndCancelledWithoutChangingOwner() public {
        vm.startPrank(owner);
        b.transferOwnership(bidder);
        b.transferOwnership(other);
        vm.stopPrank();
        vm.prank(bidder);
        vm.expectRevert(NightshiftBackstop.NotPendingOwner.selector);
        b.acceptOwnership();
        vm.prank(owner);
        b.transferOwnership(address(0));
        vm.prank(other);
        vm.expectRevert(NightshiftBackstop.NotPendingOwner.selector);
        b.acceptOwnership();
        assertEq(b.owner(), owner);
        vm.prank(owner);
        b.transferOwnership(other);
        vm.prank(other);
        b.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(NightshiftBackstop.NotOwner.selector);
        b.setPaused(true);
        vm.prank(other);
        b.setPaused(true);
        assertTrue(b.paused());
        assertEq(b.treasury(), owner, "ownership transfer must not redirect earned fees");
    }

    function test_pauseStillAllowsShieldAndTreasuryExitAndResume() public {
        _deposit(20_000e6);
        uint256 id = _offer();
        _settle(id);
        vm.prank(owner);
        b.setPaused(true);
        vm.prank(depositor);
        b.shieldClaimGains();
        (uint256 dep,,, uint256 unlock) = b.shieldPosition(depositor);
        vm.warp(unlock);
        vm.prank(depositor);
        b.shieldWithdraw(dep);
        b.withdrawTreasury();
        vm.prank(owner);
        b.setPaused(false);
        _deposit(1);
        (uint256 nextDep,,,) = b.shieldPosition(depositor);
        assertEq(nextDep, 1);
        assertEq(_offer(), 2);
    }

    function test_emptyAccountGainsClaimCannotCollectOthersRewards() public {
        _deposit(20_000e6);
        uint256 id = _offer();
        _settle(id);
        uint256 beforeToken = token.balanceOf(other);
        uint256 beforeQuote = quote.balanceOf(other);
        vm.prank(other);
        b.shieldClaimGains();
        assertEq(token.balanceOf(other), beforeToken);
        assertEq(quote.balanceOf(other), beforeQuote);
    }

    function testFuzz_callbacksCannotReenterCustody(uint8 entrySeed, uint8 callbackSeed) public {
        _deposit(20_000e6);
        uint256 id = _offer();
        uint256 bidId = _bid(id, 100);
        _settle(id);
        uint256 callback = bound(callbackSeed, 0, 8);
        bytes memory data;
        if (callback == 0) data = abi.encodeCall(b.createOffer, (AMOUNT));
        else if (callback == 1) data = abi.encodeCall(b.placeBid, (id, 1));
        else if (callback == 2) data = abi.encodeCall(b.settle, (id));
        else if (callback == 3) data = abi.encodeCall(b.claimSeller, (id));
        else if (callback == 4) data = abi.encodeCall(b.claimBid, (bidId));
        else if (callback == 5) data = abi.encodeCall(b.shieldDeposit, (1));
        else if (callback == 6) data = abi.encodeCall(b.shieldWithdraw, (1));
        else if (callback == 7) data = abi.encodeCall(b.shieldClaimGains, ());
        else data = abi.encodeCall(b.withdrawTreasury, ());
        uint256 entry = bound(entrySeed, 0, 7);
        AdversarialToken hooked = (entry == 0 || entry == 4 || entry == 6) ? token : quote;
        hooked.arm(address(b), data, entry <= 2, entry > 2);
        if (entry == 0) {
            _offer();
        } else if (entry == 1) {
            _bid(_offer(), 1);
        } else if (entry == 2) {
            _deposit(1);
        } else if (entry == 3) {
            vm.prank(seller);
            b.claimSeller(id);
        } else if (entry == 4) {
            vm.prank(bidder);
            b.claimBid(bidId);
        } else if (entry == 5) {
            (uint256 dep,,, uint256 unlock) = b.shieldPosition(depositor);
            vm.warp(unlock);
            vm.prank(depositor);
            b.shieldWithdraw(dep);
        } else if (entry == 6) {
            vm.prank(depositor);
            b.shieldClaimGains();
        } else {
            b.withdrawTreasury();
        }
        assertTrue(hooked.attempted(), "callback path not exercised");
        assertFalse(hooked.callbackSucceeded());
        assertEq(hooked.callbackResult(), abi.encodeWithSelector(NightshiftBackstop.Reentrancy.selector));
        // Guard also resets after a successful outer call.
        vm.prank(other);
        b.shieldClaimGains();
    }
}
