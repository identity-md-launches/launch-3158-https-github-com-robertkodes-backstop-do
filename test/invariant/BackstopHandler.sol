// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NightshiftBackstop} from "src/NightshiftBackstop.sol";
import {MockERC20, MockPool} from "../mocks/Mocks.sol";

/// @notice Drives only public application functions; never edits application storage or mints after setup.
contract BackstopHandler is Test {
    NightshiftBackstop public immutable backstop;
    MockERC20 public immutable imd;
    MockERC20 public immutable usdc;
    MockPool public immutable pool;
    address[4] public actors;
    address public immutable feeRecipient;

    bool public unexpectedFailure;
    string public failure;
    uint256 public successfulCalls;
    uint256 public rejectedCalls;
    uint256 public depositsIn;
    uint256 public principalOut;
    uint256 public shieldSpent;
    uint256 public shieldTokensAllocated;
    uint256 public shieldTokensPaid;
    uint256 public shieldFeesAllocated;
    uint256 public shieldFeesPaid;
    uint256 public treasuryAllocated;
    uint256 public treasuryPaid;
    uint256 public tokenIn;
    uint256 public tokenOut;
    uint256 public quoteIn;
    uint256 public quoteOut;
    uint256 public donatedToken;
    uint256 public donatedQuote;
    uint256 public createdOffers;
    uint256 public createdBids;
    mapping(uint256 => bytes32) public frozenTerms;
    mapping(uint256 => bytes32) public finalTerms;
    mapping(uint256 => bool) public sellerPaid;
    mapping(uint256 => bool) public bidPaid;
    mapping(uint256 => uint256) public bidLots;
    mapping(uint256 => uint256) public bidPrefix;
    mapping(uint256 => uint256) public bidOffer;
    mapping(uint256 => address) public bidOwner;
    mapping(uint256 => uint256) public capacity;
    mapping(address => uint256) public actorDeposited;
    mapping(address => uint256) public actorWithdrawn;

    constructor() {
        imd = new MockERC20("IMD", "IMD", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        backstop = new NightshiftBackstop(address(this), address(imd), address(usdc), 1_000e18, 10_000e6, 1e18);
        pool = new MockPool(address(imd), address(usdc));
        backstop.setPriceSource(address(pool));
        // At these ticks an 18-decimal IMD is worth a few 6-decimal USDC.
        _market(0, 0);
        feeRecipient = makeAddr("invariant treasury");
        backstop.setTreasury(feeRecipient);
        for (uint256 i; i < actors.length; ++i) {
            address actor = makeAddr(string.concat("invariant actor ", vm.toString(i)));
            actors[i] = actor;
            imd.mint(actor, 2_500_000e18);
            usdc.mint(actor, 1_000_000e6);
            vm.startPrank(actor);
            imd.approve(address(backstop), type(uint256).max);
            usdc.approve(address(backstop), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _check(bool condition, string memory reason) internal {
        if (!condition && !unexpectedFailure) {
            unexpectedFailure = true;
            failure = reason;
        }
    }

    /// @dev Persist unexpected errors instead of reverting the handler: fail_on_revert need not be changed.
    function _perform(address actor, bytes memory data) internal returns (bool ok) {
        vm.prank(actor);
        (ok,) = address(backstop).call(data);
        _check(ok, "valid operation unexpectedly reverted");
        if (ok) ++successfulCalls;
    }

    function _reject(address actor, bytes memory data, bytes4 expected) internal {
        vm.prank(actor);
        (bool ok, bytes memory result) = address(backstop).call(data);
        _check(!ok && result.length >= 4 && bytes4(result) == expected, "wrong failure path");
        if (!ok) ++rejectedCalls;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function createOffer(uint256 actorSeed, uint256 amountSeed) public {
        if (backstop.paused() || pool.broken()) return;
        address actor = _actor(actorSeed);
        uint256 available = imd.balanceOf(actor);
        if (available < 1_000e18) return;
        uint256 limit = available < 20_000e18 ? available : 20_000e18;
        uint256 amount = bound(amountSeed, 1_000e18, limit);
        uint256 beforeBalance = imd.balanceOf(actor);
        if (!_perform(actor, abi.encodeCall(backstop.createOffer, (amount)))) return;
        ++createdOffers;
        uint256 id = backstop.offerCount();
        NightshiftBackstop.Offer memory offer = backstop.getOffer(id);
        uint256 escrow = amount - amount % 100;
        tokenIn += escrow;
        _check(beforeBalance - imd.balanceOf(actor) == escrow, "offer did not escrow whole lots");
        _check(offer.seller == actor && offer.deadline == block.timestamp + 1 hours, "wrong offer identity or deadline");
        _check(offer.lotSize * 100 == escrow && offer.lotCost != 0, "invalid offer terms");
        frozenTerms[id] = _terms(offer);
    }

    function bid(uint256 actorSeed, uint256 offerSeed, uint256 lotsSeed) public {
        if (backstop.paused() || createdOffers == 0) return;
        uint256 id = bound(offerSeed, 1, createdOffers);
        NightshiftBackstop.Offer memory offer = backstop.getOffer(id);
        if (block.timestamp >= offer.deadline) return;
        address actor = _actor(actorSeed);
        if (actor == offer.seller) actor = _actor(actorSeed % actors.length + 1);
        if (imd.balanceOf(actor) < 1e18) return;
        uint256 affordable = usdc.balanceOf(actor) / offer.lotCost;
        if (affordable == 0) return;
        uint256 lots = bound(lotsSeed, 1, affordable < 100 ? affordable : 100);
        uint256 beforeBalance = usdc.balanceOf(actor);
        if (!_perform(actor, abi.encodeCall(backstop.placeBid, (id, lots)))) return;
        ++createdBids;
        uint256 bidId = backstop.bidCount();
        NightshiftBackstop.Bid memory placed = backstop.getBid(bidId);
        bidLots[bidId] = lots;
        bidPrefix[bidId] = capacity[id];
        bidOffer[bidId] = id;
        bidOwner[bidId] = actor;
        capacity[id] += lots;
        quoteIn += lots * offer.lotCost;
        _check(beforeBalance - usdc.balanceOf(actor) == lots * offer.lotCost, "wrong bid charge");
        _check(placed.offerId == id && placed.bidder == actor, "wrong bid identity");
    }

    function settle(uint256 offerSeed) public {
        if (createdOffers == 0) return;
        uint256 id = bound(offerSeed, 1, createdOffers);
        NightshiftBackstop.Offer memory beforeOffer = backstop.getOffer(id);
        if (beforeOffer.settled) {
            _reject(
                _actor(offerSeed), abi.encodeCall(backstop.settle, (id)), NightshiftBackstop.AlreadySettled.selector
            );
            return;
        }
        if (block.timestamp < beforeOffer.deadline) vm.warp(beforeOffer.deadline);
        uint256 total = backstop.shieldTotalDeposits();
        uint256 tokensBefore = imd.balanceOf(address(backstop));
        uint256 quoteBefore = usdc.balanceOf(address(backstop));
        uint256 treasuryBefore = backstop.treasuryAccrued();
        if (!_perform(_actor(offerSeed), abi.encodeCall(backstop.settle, (id)))) return;
        NightshiftBackstop.Offer memory offer = backstop.getOffer(id);
        finalTerms[id] = _settledTerms(offer);
        uint256 spent = offer.shieldLots * offer.lotCost;
        uint256 gross = (offer.shieldLots + offer.filledLots) * offer.lotCost;
        uint256 fee = gross - offer.sellerProceeds;
        uint256 treasuryShare = backstop.treasuryAccrued() - treasuryBefore;
        _check(fee * 10_000 >= gross * 300 && fee * 10_000 < gross * 300 + 10_000, "fee not rounded up to 3 percent");
        _check(spent <= total / 2 && spent <= 10_000e6 && offer.shieldLots <= 50, "Shield spending limit exceeded");
        _check(backstop.shieldTotalDeposits() == total - spent, "Shield spend not debited");
        if (!offer.shieldEligible) _check(spent == 0, "pump filter bypassed");
        uint256 availableLots = 100 - offer.shieldLots;
        _check(offer.filledLots == (capacity[id] < availableLots ? capacity[id] : availableLots), "wrong total fill");
        _check(
            tokensBefore == imd.balanceOf(address(backstop)) && quoteBefore == usdc.balanceOf(address(backstop)),
            "settlement transferred assets"
        );
        shieldSpent += spent;
        shieldTokensAllocated += offer.shieldLots * offer.lotSize;
        treasuryAllocated += treasuryShare;
        shieldFeesAllocated += fee - treasuryShare;
    }

    function claimSeller(uint256 offerSeed) public {
        if (createdOffers == 0) return;
        uint256 id = bound(offerSeed, 1, createdOffers);
        NightshiftBackstop.Offer memory offer = backstop.getOffer(id);
        if (!offer.settled) return;
        if (sellerPaid[id]) {
            _reject(
                offer.seller, abi.encodeCall(backstop.claimSeller, (id)), NightshiftBackstop.AlreadyClaimed.selector
            );
            return;
        }
        uint256 tokens = (100 - offer.shieldLots - offer.filledLots) * offer.lotSize;
        uint256 tokensBefore = imd.balanceOf(offer.seller);
        uint256 quoteBefore = usdc.balanceOf(offer.seller);
        if (!_perform(offer.seller, abi.encodeCall(backstop.claimSeller, (id)))) return;
        sellerPaid[id] = true;
        tokenOut += tokens;
        quoteOut += offer.sellerProceeds;
        _check(imd.balanceOf(offer.seller) == tokensBefore + tokens, "seller token return differs");
        _check(usdc.balanceOf(offer.seller) == quoteBefore + offer.sellerProceeds, "seller proceeds differ");
    }

    function claimBid(uint256 bidSeed) public {
        if (createdBids == 0) return;
        uint256 id = bound(bidSeed, 1, createdBids);
        NightshiftBackstop.Bid memory placed = backstop.getBid(id);
        NightshiftBackstop.Offer memory offer = backstop.getOffer(placed.offerId);
        if (!offer.settled) return;
        if (bidPaid[id]) {
            _reject(placed.bidder, abi.encodeCall(backstop.claimBid, (id)), NightshiftBackstop.AlreadyClaimed.selector);
            return;
        }
        uint256 filled = backstop.filledLotsOf(id);
        _check(filled <= placed.lots, "bid overfilled");
        if (filled > placed.lots) return;
        uint256 tokens = filled * offer.lotSize;
        uint256 refund = (placed.lots - filled) * offer.lotCost;
        uint256 tokensBefore = imd.balanceOf(placed.bidder);
        uint256 quoteBefore = usdc.balanceOf(placed.bidder);
        if (!_perform(placed.bidder, abi.encodeCall(backstop.claimBid, (id)))) return;
        bidPaid[id] = true;
        tokenOut += tokens;
        quoteOut += refund;
        _check(imd.balanceOf(placed.bidder) == tokensBefore + tokens, "wrong bid token delivery");
        _check(usdc.balanceOf(placed.bidder) == quoteBefore + refund, "wrong bid refund");
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) public {
        if (backstop.paused()) return;
        address actor = _actor(actorSeed);
        uint256 balance = usdc.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance < 50_000e6 ? balance : 50_000e6);
        (uint256 principal, uint256 tg, uint256 qg,) = backstop.shieldPosition(actor);
        uint256 tokensBefore = imd.balanceOf(actor);
        if (!_perform(actor, abi.encodeCall(backstop.shieldDeposit, (amount)))) return;
        _recordGains(tg, qg);
        depositsIn += amount;
        actorDeposited[actor] += amount;
        quoteIn += amount;
        (uint256 updated, uint256 nextTg, uint256 nextQg, uint256 unlock) = backstop.shieldPosition(actor);
        _check(updated == principal + amount && nextTg == 0 && nextQg == 0, "deposit credited incorrectly");
        _check(unlock == block.timestamp + 30 days, "deposit failed to restart lock");
        _check(
            imd.balanceOf(actor) == tokensBefore + tg && usdc.balanceOf(actor) == balance + qg - amount,
            "deposit paid wrong gains"
        );
    }

    function withdraw(uint256 actorSeed, uint256 amountSeed, bool full) public {
        address actor = _actor(actorSeed);
        (uint256 principal, uint256 tg, uint256 qg, uint256 unlock) = backstop.shieldPosition(actor);
        if (principal == 0) return;
        uint256 amount = full ? principal : bound(amountSeed, 1, principal);
        if (block.timestamp < unlock) {
            _reject(actor, abi.encodeCall(backstop.shieldWithdraw, (amount)), NightshiftBackstop.ShieldLocked.selector);
            return;
        }
        uint256 tokensBefore = imd.balanceOf(actor);
        uint256 quoteBefore = usdc.balanceOf(actor);
        if (!_perform(actor, abi.encodeCall(backstop.shieldWithdraw, (amount)))) return;
        _recordGains(tg, qg);
        principalOut += amount;
        actorWithdrawn[actor] += amount;
        quoteOut += amount;
        (uint256 updated, uint256 nextTg, uint256 nextQg, uint256 nextUnlock) = backstop.shieldPosition(actor);
        _check(updated == principal - amount && nextTg == 0 && nextQg == 0, "withdrawal accounting differs");
        _check(updated == 0 ? nextUnlock == 0 : nextUnlock == unlock, "withdrawal changed lock");
        _check(
            imd.balanceOf(actor) == tokensBefore + tg && usdc.balanceOf(actor) == quoteBefore + qg + amount,
            "withdrawal paid wrong amount"
        );
    }

    function claimGains(uint256 actorSeed) public {
        address actor = _actor(actorSeed);
        (uint256 principal, uint256 tg, uint256 qg, uint256 unlock) = backstop.shieldPosition(actor);
        uint256 tokensBefore = imd.balanceOf(actor);
        uint256 quoteBefore = usdc.balanceOf(actor);
        if (!_perform(actor, abi.encodeCall(backstop.shieldClaimGains, ()))) return;
        _recordGains(tg, qg);
        (uint256 updated, uint256 nextTg, uint256 nextQg, uint256 nextUnlock) = backstop.shieldPosition(actor);
        _check(updated == principal && nextTg == 0 && nextQg == 0, "gains claim changed principal or can be repeated");
        _check(principal == 0 ? nextUnlock == 0 : nextUnlock == unlock, "gains claim changed lock");
        _check(
            imd.balanceOf(actor) == tokensBefore + tg && usdc.balanceOf(actor) == quoteBefore + qg,
            "gains payment differs from preview"
        );
    }

    function _recordGains(uint256 tg, uint256 qg) internal {
        shieldTokensPaid += tg;
        shieldFeesPaid += qg;
        tokenOut += tg;
        quoteOut += qg;
    }

    function treasury() public {
        uint256 accrued = backstop.treasuryAccrued();
        if (accrued == 0) {
            _reject(
                actors[0], abi.encodeCall(backstop.withdrawTreasury, ()), NightshiftBackstop.NothingToWithdraw.selector
            );
            return;
        }
        uint256 beforeBalance = usdc.balanceOf(feeRecipient);
        if (!_perform(actors[1], abi.encodeCall(backstop.withdrawTreasury, ()))) return;
        treasuryPaid += accrued;
        quoteOut += accrued;
        _check(
            backstop.treasuryAccrued() == 0 && usdc.balanceOf(feeRecipient) == beforeBalance + accrued,
            "treasury paid wrong recipient or amount"
        );
    }

    function donate(uint256 actorSeed, uint256 amountSeed, bool quoteAsset) public {
        address actor = _actor(actorSeed);
        MockERC20 asset = quoteAsset ? usdc : imd;
        uint256 amount = bound(amountSeed, 0, asset.balanceOf(actor));
        vm.prank(actor);
        asset.transfer(address(backstop), amount);
        if (quoteAsset) {
            donatedQuote += amount;
            quoteIn += amount;
        } else {
            donatedToken += amount;
            tokenIn += amount;
        }
    }

    function advance(uint256 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 31 days));
    }

    function changeMarket(int256 pastSeed, int256 nowSeed, bool broken) public {
        _market(int24(bound(pastSeed, -3_000, 3_000)), int24(bound(nowSeed, -3_000, 3_000)));
        pool.setBroken(broken);
    }

    function _market(int24 pastMove, int24 nowMove) internal {
        int24 sign = address(imd) < address(usdc) ? int24(1) : int24(-1);
        pool.setTicks(sign * (-263819 + pastMove), sign * (-263819 + nowMove));
    }

    function pause(bool enabled) public {
        backstop.setPaused(enabled);
    }

    function invalidCall(uint256 actorSeed, uint256 choice) public {
        address actor = _actor(actorSeed);
        uint256 action = choice % 5;
        if (action == 0) {
            _reject(actor, abi.encodeCall(backstop.setPaused, (true)), NightshiftBackstop.NotOwner.selector);
        } else if (action == 1) {
            _reject(actor, abi.encodeCall(backstop.transferOwnership, (actor)), NightshiftBackstop.NotOwner.selector);
        } else if (action == 2) {
            _reject(actor, abi.encodeCall(backstop.claimBid, (createdBids + 1)), NightshiftBackstop.UnknownBid.selector);
        } else if (action == 3) {
            _reject(
                actor, abi.encodeCall(backstop.settle, (createdOffers + 1)), NightshiftBackstop.UnknownOffer.selector
            );
        } else {
            _reject(
                actor,
                abi.encodeCall(backstop.shieldDeposit, (0)),
                backstop.paused() ? NightshiftBackstop.Paused.selector : NightshiftBackstop.ZeroValue.selector
            );
        }
    }

    function _terms(NightshiftBackstop.Offer memory o) internal pure returns (bytes32) {
        return keccak256(abi.encode(o.seller, o.deadline, o.discountBps, o.shieldEligible, o.lotSize, o.lotCost));
    }

    function _settledTerms(NightshiftBackstop.Offer memory o) internal pure returns (bytes32) {
        return keccak256(abi.encode(o.settled, o.shieldLots, o.filledLots, o.sellerProceeds, o.bidCapacity));
    }

    /// @notice Checks all actors and all simultaneously live offers, including unclaimed and unsettled liabilities.
    function assertAccounting() external view {
        assertFalse(unexpectedFailure, failure);
        assertEq(backstop.offerCount(), createdOffers, "offer counter");
        assertEq(backstop.bidCount(), createdBids, "bid counter");
        assertEq(imd.balanceOf(address(backstop)) + tokenOut, tokenIn, "IMD flow ledger");
        assertEq(usdc.balanceOf(address(backstop)) + quoteOut, quoteIn, "USDC flow ledger");
        assertEq(backstop.shieldTotalDeposits() + principalOut + shieldSpent, depositsIn, "Shield principal ledger");
        assertEq(backstop.treasuryAccrued() + treasuryPaid, treasuryAllocated, "treasury fee ledger");
        uint256 owedToken;
        uint256 owedQuote;
        uint256[] memory filled = new uint256[](createdOffers + 1);
        for (uint256 i = 1; i <= createdBids; ++i) {
            NightshiftBackstop.Bid memory placed = backstop.getBid(i);
            NightshiftBackstop.Offer memory offer = backstop.getOffer(placed.offerId);
            assertEq(placed.lots, bidLots[i], "bid size changed");
            assertEq(placed.prefix, bidPrefix[i], "bid prefix changed");
            assertEq(placed.offerId, bidOffer[i], "bid moved to another offer");
            assertEq(placed.bidder, bidOwner[i], "bid owner changed");
            assertEq(placed.claimed, bidPaid[i], "bid reopened or claimed without payment");
            uint256 n = backstop.filledLotsOf(i);
            if (!offer.settled) {
                assertEq(n, 0, "premature fill");
                owedQuote += placed.lots * offer.lotCost;
                continue;
            }
            assertLe(n, placed.lots, "fill exceeds bid");
            // Independent proportional bounds, not a copy of the prefix allocation formula.
            uint256 proportional = uint256(placed.lots) * offer.filledLots;
            assertLe(n * offer.bidCapacity, proportional + offer.bidCapacity - 1, "fill above ceil share");
            assertLe(proportional, n * offer.bidCapacity + offer.bidCapacity - 1, "fill below floor share");
            filled[placed.offerId] += n;
            if (!placed.claimed) {
                owedToken += n * offer.lotSize;
                owedQuote += (placed.lots - n) * offer.lotCost;
            }
        }
        for (uint256 i = 1; i <= createdOffers; ++i) {
            NightshiftBackstop.Offer memory offer = backstop.getOffer(i);
            assertEq(_terms(offer), frozenTerms[i], "offer repriced or identity changed");
            assertEq(offer.bidCapacity, capacity[i], "capacity differs from bids");
            assertEq(offer.sellerClaimed, sellerPaid[i], "seller claim state differs");
            if (finalTerms[i] != bytes32(0)) assertEq(_settledTerms(offer), finalTerms[i], "settled offer changed");
            if (!offer.settled) {
                owedToken += 100 * offer.lotSize;
            } else {
                assertEq(filled[i], offer.filledLots, "bid allocations do not sum to fill");
                if (!offer.sellerClaimed) {
                    owedToken += (100 - offer.shieldLots - offer.filledLots) * offer.lotSize;
                    owedQuote += offer.sellerProceeds;
                }
            }
        }
        assertLe(shieldTokensPaid, shieldTokensAllocated, "excess Shield token payout");
        assertLe(shieldFeesPaid, shieldFeesAllocated, "excess Shield fee payout");
        assertEq(
            imd.balanceOf(address(backstop)),
            owedToken + shieldTokensAllocated - shieldTokensPaid + donatedToken,
            "IMD custody partition"
        );
        assertEq(
            usdc.balanceOf(address(backstop)),
            owedQuote + backstop.shieldTotalDeposits() + shieldFeesAllocated - shieldFeesPaid
                + backstop.treasuryAccrued() + donatedQuote,
            "USDC custody partition"
        );
        uint256 principal;
        uint256 pendingToken;
        uint256 pendingQuote;
        for (uint256 i; i < actors.length; ++i) {
            (uint256 dep, uint256 tg, uint256 qg,) = backstop.shieldPosition(actors[i]);
            principal += dep;
            pendingToken += tg;
            pendingQuote += qg;
            assertLe(dep + actorWithdrawn[actors[i]], actorDeposited[actors[i]], "principal created for actor");
        }
        assertLe(principal, backstop.shieldTotalDeposits(), "Shield principal insolvent");
        assertLe(pendingToken + shieldTokensPaid, shieldTokensAllocated, "Shield token gains insolvent");
        assertLe(pendingQuote + shieldFeesPaid, shieldFeesAllocated, "Shield fees insolvent");
        assertLe(owedToken + pendingToken, imd.balanceOf(address(backstop)), "IMD liabilities insolvent");
        assertLe(
            owedQuote + principal + pendingQuote + backstop.treasuryAccrued(),
            usdc.balanceOf(address(backstop)),
            "USDC liabilities insolvent"
        );
        assertGt(backstop.shieldP(), 0, "Shield product zero");
        assertEq(backstop.owner(), address(this), "unauthorized ownership change");
    }

    /// @notice Every sequence must be unwindable, including while entry is paused and the oracle is broken.
    function closeAll() external {
        backstop.setPaused(true);
        pool.setBroken(true);
        vm.warp(block.timestamp + 31 days);
        for (uint256 i = 1; i <= createdOffers; ++i) {
            if (!backstop.getOffer(i).settled) settle(i);
            if (!sellerPaid[i]) claimSeller(i);
        }
        for (uint256 i = 1; i <= createdBids; ++i) {
            if (!bidPaid[i]) claimBid(i);
        }
        for (uint256 i; i < actors.length; ++i) {
            claimGains(i);
            withdraw(i, 0, true);
        }
        treasury();
    }
}
