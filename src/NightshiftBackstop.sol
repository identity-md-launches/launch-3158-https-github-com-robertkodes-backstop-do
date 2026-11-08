// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {UniV3Math} from "./libraries/UniV3Math.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice The subset of a Uniswap v3 pool this contract reads.
interface IUniswapV3PoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @title NightshiftBackstop
/// @notice An EVM port of the BACKSTOP exit mechanic for an existing ERC-20 (IMD on Ethereum for the
/// NIGHTSHIFT project): instead of dumping on the pool, a seller escrows tokens as a time-limited offer
/// priced at the pool TWAP minus a counter-cyclical discount. Holders bid for whole lots in the quote
/// token (USDC); a pooled Shield of quote-token depositors takes a priority slice; whatever is not
/// absorbed is returned to the seller. Settlement is permissionless, claims are pull-based.
/// @dev See README.md for every parameter, formula, power and assumption.
contract NightshiftBackstop {
    // ---------------------------------------------------------------- constants (economic-spec defaults)
    uint256 public constant BPS = 10_000;
    /// @notice Lots per offer (BACKSTOP `lots_per_offer`).
    uint256 public constant LOTS_PER_OFFER = 100;
    /// @notice Bidding window of an offer.
    uint256 public constant OFFER_WINDOW = 1 hours;
    /// @notice Fee charged to the seller on absorbed lots (BACKSTOP `trade_fee_bps`).
    uint256 public constant TRADE_FEE_BPS = 300;
    /// @notice Share of the fee paid to Shield depositors (BACKSTOP chest 70 % + Shield 10 %); the rest is treasury.
    uint256 public constant SHIELD_FEE_SHARE_BPS = 8_000;
    uint256 public constant BASE_DISCOUNT_BPS = 500;
    uint256 public constant K_UP_BPS = 2_500;
    uint256 public constant K_DOWN_BPS = 1_500;
    uint256 public constant MIN_DISCOUNT_BPS = 200;
    uint256 public constant MAX_DISCOUNT_BPS = 1_200;
    /// @notice TWAP window used for the offer price.
    uint32 public constant TWAP_WINDOW = 30 minutes;
    /// @notice Momentum lookback: TWAP now vs. TWAP this long ago.
    uint32 public constant MOMENTUM_LOOKBACK = 1 hours;
    /// @notice Shield takes nothing from an offer created after a rise above this (pump filter).
    uint256 public constant SHIELD_MAX_PREMIUM_BPS = 2_000;
    /// @notice Shield takes at most this share of an offer's lots.
    uint256 public constant SHIELD_MAX_SHARE_BPS = 5_000;
    /// @notice Shield spends at most this share of its deposits on one offer (keeps the pool from emptying).
    uint256 public constant SHIELD_MAX_FUNDS_USE_BPS = 5_000;
    /// @notice A Shield deposit can be withdrawn this long after the depositor's last deposit.
    uint256 public constant SHIELD_MIN_LOCK = 30 days;
    /// @notice A replacement price source takes effect this long after the owner schedules it. It is longer
    /// than `SHIELD_MIN_LOCK`, so every deposit made before the change was announced can leave first.
    uint256 public constant PRICE_SOURCE_DELAY = SHIELD_MIN_LOCK + 7 days;

    uint256 internal constant P_PRECISION = 1e18;
    uint256 internal constant SCALE_FACTOR = 1e9;
    /// @dev Momentum reported when the older TWAP values a lot at zero quote units: the largest rise there is.
    int256 internal constant MOMENTUM_SATURATED = type(int128).max;

    // ---------------------------------------------------------------- immutables (constructor arguments)
    /// @notice The token being sold (IMD).
    address public immutable token;
    /// @notice The token bids and the Shield are denominated in (USDC).
    address public immutable quote;
    /// @notice Smallest escrow an offer may have, in token base units.
    uint256 public immutable minOfferSize;
    /// @notice Most quote the Shield spends on a single offer.
    uint256 public immutable shieldPerOfferCap;
    /// @notice Token balance a bidder must hold when bidding ("existing holders").
    uint256 public immutable minBidderHolding;

    // ---------------------------------------------------------------- admin state
    address public owner;
    address public pendingOwner;
    address public treasury;
    /// @notice Uniswap v3 token/quote pool whose TWAP prices offers. Unset until the owner sets it.
    address public priceSource;
    /// @notice Replacement price source scheduled by the owner; zero when no change is pending.
    address public pendingPriceSource;
    /// @notice Earliest time `applyPriceSource` may install `pendingPriceSource`.
    uint64 public priceSourceActivatesAt;
    bool public paused;

    // ---------------------------------------------------------------- offers
    struct Offer {
        address seller;
        uint64 deadline;
        uint16 discountBps;
        bool shieldEligible;
        bool settled;
        bool sellerClaimed;
        uint256 lotSize; // token per lot
        uint256 lotCost; // quote per lot
        uint256 bidCapacity; // total lots bid (C)
        uint256 shieldReservedLots; // lots the Shield committed to at creation (its capacity for this offer)
        uint256 shieldLots; // s, lots the Shield bought at settlement
        uint256 filledLots; // lots filled by bidders (F)
        uint256 sellerProceeds; // quote owed to the seller after fees
    }

    struct Bid {
        uint256 offerId;
        address bidder;
        uint64 lots; // c_i
        bool claimed;
        uint256 prefix; // Q_i, lots bid on this offer before this bid
    }

    uint256 public offerCount;
    uint256 public bidCount;
    mapping(uint256 => Offer) internal _offers;
    mapping(uint256 => Bid) internal _bids;

    // ---------------------------------------------------------------- Shield (Liquity stability-pool accounting)
    struct ShieldDeposit {
        uint256 initial;
        uint256 snapshotP;
        uint256 snapshotS;
        uint256 snapshotG;
        uint128 snapshotScale;
        uint64 lastDepositAt;
    }

    /// @notice Sum of compounded Shield deposits (quote units), dust included.
    uint256 public shieldTotalDeposits;
    /// @notice Quote the Shield has committed to unsettled offers. Never more than half of `shieldTotalDeposits`.
    uint256 public shieldReservedQuote;
    uint256 public shieldP = P_PRECISION;
    uint128 public shieldScale;
    /// @dev Token gain per unit deposit, scaled by P, per scale.
    mapping(uint128 => uint256) public shieldS;
    /// @dev Quote fee gain per unit deposit, scaled by P, per scale.
    mapping(uint128 => uint256) public shieldG;
    mapping(address => ShieldDeposit) internal _shield;

    /// @notice Quote owed to the treasury, withdrawn by `withdrawTreasury`.
    uint256 public treasuryAccrued;

    uint256 private _lock = 1;

    // ---------------------------------------------------------------- events
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TreasurySet(address indexed treasury);
    event PriceSourceSet(address indexed pool);
    event PriceSourceChangeScheduled(address indexed pool, uint256 activatesAt);
    event PriceSourceChangeCancelled(address indexed pool);
    event PausedSet(bool paused);
    event OfferCreated(
        uint256 indexed offerId,
        address indexed seller,
        uint256 escrowed,
        uint256 lotSize,
        uint256 lotCost,
        uint256 discountBps,
        int256 momentumBps,
        uint256 deadline
    );
    event BidPlaced(uint256 indexed bidId, uint256 indexed offerId, address indexed bidder, uint256 lots, uint256 paid);
    event OfferSettled(
        uint256 indexed offerId,
        uint256 shieldLots,
        uint256 filledLots,
        uint256 returnedLots,
        uint256 sellerProceeds,
        uint256 fee
    );
    event SellerClaimed(uint256 indexed offerId, address indexed seller, uint256 quoteAmount, uint256 tokenAmount);
    event BidClaimed(uint256 indexed bidId, address indexed bidder, uint256 lotsFilled, uint256 tokens, uint256 refund);
    event ShieldDeposited(address indexed account, uint256 amount, uint256 newDeposit);
    event ShieldWithdrawn(address indexed account, uint256 amount, uint256 newDeposit);
    event ShieldGainsPaid(address indexed account, uint256 tokenGain, uint256 quoteGain);
    event ShieldAbsorbed(uint256 indexed offerId, uint256 quoteSpent, uint256 tokensReceived);
    event TreasuryWithdrawn(address indexed treasury, uint256 amount);

    // ---------------------------------------------------------------- errors
    error ZeroAddress();
    error SameTokens();
    error ZeroValue();
    error NotOwner();
    error NotPendingOwner();
    error Paused();
    error Reentrancy();
    error PriceSourceNotConfigured();
    error PriceSourceMismatch();
    error NoPendingPriceSource();
    error PriceSourceDelayNotElapsed();
    error OfferExpired();
    error LotCostBelowMinimum();
    error ShieldFundsReserved();
    error OfferTooSmall();
    error ZeroLotCost();
    error UnknownOffer();
    error UnknownBid();
    error BiddingClosed();
    error BiddingOpen();
    error SelfBid();
    error NotHolder();
    error InvalidLots();
    error AlreadySettled();
    error NotSettled();
    error NotSeller();
    error NotBidder();
    error AlreadyClaimed();
    error TokenTransferFailed();
    error FeeOnTransferUnsupported();
    error ShieldLocked();
    error InsufficientShieldDeposit();
    error NothingToWithdraw();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    /// @param owner_ launch owner; also the initial treasury.
    /// @param token_ token being sold (IMD on Ethereum).
    /// @param quote_ quote token (USDC on Ethereum).
    /// @param minOfferSize_ minimum escrow per offer, token base units (must be >= LOTS_PER_OFFER).
    /// @param shieldPerOfferCap_ most quote the Shield spends on one offer.
    /// @param minBidderHolding_ token balance a bidder must hold (0 disables the holder check).
    constructor(
        address owner_,
        address token_,
        address quote_,
        uint256 minOfferSize_,
        uint256 shieldPerOfferCap_,
        uint256 minBidderHolding_
    ) {
        if (owner_ == address(0) || token_ == address(0) || quote_ == address(0)) {
            revert ZeroAddress();
        }
        if (token_ == quote_) revert SameTokens();
        if (minOfferSize_ < LOTS_PER_OFFER) revert ZeroValue();
        owner = owner_;
        treasury = owner_;
        token = token_;
        quote = quote_;
        minOfferSize = minOfferSize_;
        shieldPerOfferCap = shieldPerOfferCap_;
        minBidderHolding = minBidderHolding_;
        emit OwnershipTransferred(address(0), owner_);
        emit TreasurySet(owner_);
    }

    // ================================================================ admin

    /// @notice Starts a two-step ownership transfer; `newOwner` must call `acceptOwnership`.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Sets where the treasury share of fees is withdrawn to.
    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Sets the Uniswap v3 pool of `token` and `quote` whose TWAP prices offers.
    /// @dev The first call installs the pool at once: until then there are no offers and no Shield deposits.
    /// Every later call only schedules the change. `applyPriceSource` installs it after `PRICE_SOURCE_DELAY`,
    /// so offers in flight and locked Shield deposits are never repriced by a source they did not see coming.
    /// The pool needs enough observation cardinality for `TWAP_WINDOW + MOMENTUM_LOOKBACK`.
    function setPriceSource(address pool) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();
        address t0 = IUniswapV3PoolLike(pool).token0();
        address t1 = IUniswapV3PoolLike(pool).token1();
        if (!((t0 == token && t1 == quote) || (t0 == quote && t1 == token))) revert PriceSourceMismatch();
        if (priceSource == address(0)) {
            priceSource = pool;
            emit PriceSourceSet(pool);
            return;
        }
        uint256 activatesAt = block.timestamp + PRICE_SOURCE_DELAY;
        pendingPriceSource = pool;
        priceSourceActivatesAt = uint64(activatesAt);
        emit PriceSourceChangeScheduled(pool, activatesAt);
    }

    /// @notice Installs the scheduled price source once `PRICE_SOURCE_DELAY` has passed.
    function applyPriceSource() external onlyOwner {
        address pool = pendingPriceSource;
        if (pool == address(0)) revert NoPendingPriceSource();
        if (block.timestamp < priceSourceActivatesAt) revert PriceSourceDelayNotElapsed();
        priceSource = pool;
        pendingPriceSource = address(0);
        priceSourceActivatesAt = 0;
        emit PriceSourceSet(pool);
    }

    /// @notice Drops the scheduled price source change.
    function cancelPriceSourceChange() external onlyOwner {
        address pool = pendingPriceSource;
        if (pool == address(0)) revert NoPendingPriceSource();
        pendingPriceSource = address(0);
        priceSourceActivatesAt = 0;
        emit PriceSourceChangeCancelled(pool);
    }

    /// @notice Pauses new offers and Shield deposits. Bids on offers that are already open, settlement,
    /// claims and withdrawals never pause, so a pause cannot tilt or freeze an open offer.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Sends the accrued treasury share of fees to `treasury`. Anyone may call.
    function withdrawTreasury() external nonReentrant {
        uint256 amount = treasuryAccrued;
        if (amount == 0) revert NothingToWithdraw();
        treasuryAccrued = 0;
        address to = treasury;
        _send(quote, to, amount);
        emit TreasuryWithdrawn(to, amount);
    }

    // ================================================================ pricing

    /// @notice Current offer terms for an escrow of `lotSize` per lot: (lotCost, discountBps, momentumBps).
    function quoteLot(uint256 lotSize) public view returns (uint256 lotCost, uint256 discountBps, int256 momentumBps) {
        (uint256 priceNow, uint256 pricePast) = _twapValues(lotSize);
        if (pricePast == 0) {
            // A rise from nothing is the largest rise there is, not none: it must trip the pump filter.
            momentumBps = priceNow == 0 ? int256(0) : MOMENTUM_SATURATED;
        } else {
            momentumBps = (int256(priceNow) - int256(pricePast)) * int256(BPS) / int256(pricePast);
        }
        discountBps = _discount(momentumBps);
        // Round the lot cost up so every fill meets the frozen price.
        lotCost = UniV3Math.mulDiv(priceNow, BPS - discountBps, BPS);
        if (lotCost * BPS < priceNow * (BPS - discountBps)) lotCost += 1;
    }

    /// @notice Undiscounted quote value of `lotSize` tokens at the current `TWAP_WINDOW` mean price.
    function twapLotValue(uint256 lotSize) external view returns (uint256 value) {
        (value,) = _twapValues(lotSize);
    }

    /// @dev Quote value of `lotSize` tokens at the TWAP now and at the TWAP `MOMENTUM_LOOKBACK` ago.
    function _twapValues(uint256 lotSize) internal view returns (uint256 priceNow, uint256 pricePast) {
        address pool = priceSource;
        if (pool == address(0)) revert PriceSourceNotConfigured();
        if (lotSize == 0 || lotSize > type(uint128).max) revert OfferTooSmall();
        uint32[] memory ago = new uint32[](4);
        ago[0] = MOMENTUM_LOOKBACK + TWAP_WINDOW;
        ago[1] = MOMENTUM_LOOKBACK;
        ago[2] = TWAP_WINDOW;
        ago[3] = 0;
        (int56[] memory cum,) = IUniswapV3PoolLike(pool).observe(ago);
        int24 tickPast = UniV3Math.meanTick(cum[0], cum[1], TWAP_WINDOW);
        int24 tickNow = UniV3Math.meanTick(cum[2], cum[3], TWAP_WINDOW);
        uint128 base = uint128(lotSize);
        priceNow = UniV3Math.getQuoteAtTick(tickNow, base, token, quote);
        pricePast = UniV3Math.getQuoteAtTick(tickPast, base, token, quote);
    }

    function _discount(int256 momentumBps) internal pure returns (uint256) {
        int256 d = int256(BASE_DISCOUNT_BPS);
        if (momentumBps > 0) d += momentumBps * int256(K_UP_BPS) / int256(BPS);
        else d -= (-momentumBps) * int256(K_DOWN_BPS) / int256(BPS);
        if (d < int256(MIN_DISCOUNT_BPS)) return MIN_DISCOUNT_BPS;
        if (d > int256(MAX_DISCOUNT_BPS)) return MAX_DISCOUNT_BPS;
        return uint256(d);
    }

    // ================================================================ offers

    /// @notice Escrows `amount` (rounded down to whole lots) as an offer to holders. Cannot be cancelled.
    /// @dev Accepts whatever price the source reports in the mined block. A seller who sends this through a
    /// public mempool should use the overload below, which bounds the price and the inclusion time.
    function createOffer(uint256 amount) external nonReentrant whenNotPaused returns (uint256 offerId) {
        return _createOffer(amount, 0);
    }

    /// @notice As `createOffer(amount)`, but reverts unless the frozen price per lot (`amount / 100` tokens)
    /// is at least `minLotCost` quote and the transaction is mined no later than `validUntil`.
    function createOffer(uint256 amount, uint256 minLotCost, uint256 validUntil)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 offerId)
    {
        if (block.timestamp > validUntil) revert OfferExpired();
        return _createOffer(amount, minLotCost);
    }

    function _createOffer(uint256 amount, uint256 minLotCost) internal returns (uint256 offerId) {
        uint256 lotSize = amount / LOTS_PER_OFFER;
        uint256 escrow = lotSize * LOTS_PER_OFFER;
        if (escrow < minOfferSize || lotSize > type(uint128).max) revert OfferTooSmall();
        (uint256 lotCost, uint256 discountBps, int256 momentumBps) = quoteLot(lotSize);
        if (lotCost == 0) revert ZeroLotCost();
        if (lotCost < minLotCost) revert LotCostBelowMinimum();

        offerId = ++offerCount;
        Offer storage o = _offers[offerId];
        o.seller = msg.sender;
        o.deadline = uint64(block.timestamp + OFFER_WINDOW);
        o.discountBps = uint16(discountBps);
        o.lotSize = lotSize;
        o.lotCost = lotCost;
        if (momentumBps <= int256(SHIELD_MAX_PREMIUM_BPS)) {
            o.shieldEligible = true;
            // The Shield's slice is fixed here, from the deposits present now and not already committed to
            // other unsettled offers. A later deposit cannot enlarge it or displace bidders.
            uint256 reservedLots = _shieldLots(lotCost);
            if (reservedLots != 0) {
                o.shieldReservedLots = reservedLots;
                shieldReservedQuote += reservedLots * lotCost;
            }
        }

        _pullExact(token, escrow);
        emit OfferCreated(offerId, msg.sender, escrow, lotSize, lotCost, discountBps, momentumBps, o.deadline);
    }

    /// @notice Locks `lots * lotCost` quote as a bid for up to `lots` lots of offer `offerId`.
    /// @dev Not pausable: a pause must not shut holders out of an offer whose clock keeps running.
    function placeBid(uint256 offerId, uint256 lots) external nonReentrant returns (uint256 bidId) {
        Offer storage o = _offers[offerId];
        if (o.seller == address(0)) revert UnknownOffer();
        if (block.timestamp >= o.deadline) revert BiddingClosed();
        if (msg.sender == o.seller) revert SelfBid();
        if (lots == 0 || lots > LOTS_PER_OFFER) revert InvalidLots();
        if (minBidderHolding != 0 && IERC20Minimal(token).balanceOf(msg.sender) < minBidderHolding) {
            revert NotHolder();
        }
        uint256 paid = lots * o.lotCost;
        bidId = ++bidCount;
        _bids[bidId] =
            Bid({offerId: offerId, bidder: msg.sender, lots: uint64(lots), claimed: false, prefix: o.bidCapacity});
        o.bidCapacity += lots;
        _pullExact(quote, paid);
        emit BidPlaced(bidId, offerId, msg.sender, lots, paid);
    }

    /// @notice Settles an offer after its window. Permissionless and cannot be blocked by the price source:
    /// if the pool cannot be read, the Shield buys nothing and the bidders are settled as usual.
    function settle(uint256 offerId) external nonReentrant {
        Offer storage o = _offers[offerId];
        if (o.seller == address(0)) revert UnknownOffer();
        if (block.timestamp < o.deadline) revert BiddingOpen();
        if (o.settled) revert AlreadySettled();
        o.settled = true;

        uint256 lotCost = o.lotCost;
        uint256 s = o.shieldReservedLots;
        if (s != 0) {
            shieldReservedQuote -= s * lotCost;
            // Bidders chose this price; Shield depositors could not. The Shield therefore buys its reserved
            // lots only if the frozen price is still at or below the pool TWAP when it pays.
            try this.twapLotValue(o.lotSize) returns (uint256 value) {
                if (lotCost > value) s = 0;
            } catch {
                s = 0;
            }
        }
        uint256 remaining = LOTS_PER_OFFER - s;
        uint256 filled = o.bidCapacity < remaining ? o.bidCapacity : remaining;
        o.shieldLots = s;
        o.filledLots = filled;

        uint256 gross = (s + filled) * lotCost;
        uint256 fee = (gross * TRADE_FEE_BPS + BPS - 1) / BPS;
        o.sellerProceeds = gross - fee;

        // The Shield earns its fee share only on the lots it absorbed, so a deposit that absorbs nothing
        // (dust, 1 wei) earns nothing and its share goes to the treasury.
        uint256 shieldFee;
        if (s != 0) {
            _shieldAbsorb(s * lotCost, s * o.lotSize);
            emit ShieldAbsorbed(offerId, s * lotCost, s * o.lotSize);
            shieldFee = fee * SHIELD_FEE_SHARE_BPS / BPS * s / (s + filled);
            // After an absorption at least half of the deposits remain, so the divisor is a live base.
            shieldG[shieldScale] += UniV3Math.mulDiv(shieldFee, shieldP, shieldTotalDeposits);
        }
        treasuryAccrued += fee - shieldFee;

        emit OfferSettled(offerId, s, filled, remaining - filled, o.sellerProceeds, fee);
    }

    /// @dev Lots the Shield can commit to a new offer: half of its deposits, less what unsettled offers hold.
    function _shieldLots(uint256 lotCost) internal view returns (uint256 s) {
        s = LOTS_PER_OFFER * SHIELD_MAX_SHARE_BPS / BPS;
        uint256 byCap = shieldPerOfferCap / lotCost;
        if (byCap < s) s = byCap;
        uint256 usable = shieldTotalDeposits * SHIELD_MAX_FUNDS_USE_BPS / BPS;
        uint256 reserved = shieldReservedQuote;
        uint256 byFunds = usable > reserved ? (usable - reserved) / lotCost : 0;
        if (byFunds < s) s = byFunds;
    }

    /// @notice Pays the seller their net proceeds and returns the unabsorbed lots.
    function claimSeller(uint256 offerId) external nonReentrant {
        _claimSeller(offerId, msg.sender);
    }

    /// @notice As `claimSeller`, paid to `to`: the way out for a seller the quote token will not pay.
    function claimSellerTo(uint256 offerId, address to) external nonReentrant {
        _claimSeller(offerId, to);
    }

    function _claimSeller(uint256 offerId, address to) internal {
        if (to == address(0)) revert ZeroAddress();
        Offer storage o = _offers[offerId];
        if (!o.settled) revert NotSettled();
        if (msg.sender != o.seller) revert NotSeller();
        if (o.sellerClaimed) revert AlreadyClaimed();
        o.sellerClaimed = true;
        uint256 returnedLots = LOTS_PER_OFFER - o.shieldLots - o.filledLots;
        uint256 tokens = returnedLots * o.lotSize;
        uint256 proceeds = o.sellerProceeds;
        if (proceeds != 0) _send(quote, to, proceeds);
        if (tokens != 0) _send(token, to, tokens);
        emit SellerClaimed(offerId, msg.sender, proceeds, tokens);
    }

    /// @notice Lots filled for bid `bidId` once its offer is settled (0 before).
    function filledLotsOf(uint256 bidId) public view returns (uint256) {
        Bid storage b = _bids[bidId];
        Offer storage o = _offers[b.offerId];
        if (!o.settled || o.bidCapacity == 0) return 0;
        uint256 c = o.bidCapacity;
        uint256 f = o.filledLots;
        // Systematic allocation with a zero offset: each bid gets the floor or ceiling of its pro-rata
        // share and the shares telescope to exactly `f`.
        return _ceilDiv((b.prefix + b.lots) * f, c) - _ceilDiv(b.prefix * f, c);
    }

    /// @notice Delivers the filled lots of bid `bidId` and refunds the rest of its quote.
    function claimBid(uint256 bidId) external nonReentrant {
        _claimBid(bidId, msg.sender);
    }

    /// @notice As `claimBid`, paid to `to`: the way out for a bidder the quote token will not pay.
    function claimBidTo(uint256 bidId, address to) external nonReentrant {
        _claimBid(bidId, to);
    }

    function _claimBid(uint256 bidId, address to) internal {
        if (to == address(0)) revert ZeroAddress();
        Bid storage b = _bids[bidId];
        if (b.bidder == address(0)) revert UnknownBid();
        Offer storage o = _offers[b.offerId];
        if (!o.settled) revert NotSettled();
        if (msg.sender != b.bidder) revert NotBidder();
        if (b.claimed) revert AlreadyClaimed();
        b.claimed = true;
        uint256 n = filledLotsOf(bidId);
        uint256 tokens = n * o.lotSize;
        uint256 refund = (uint256(b.lots) - n) * o.lotCost;
        if (tokens != 0) _send(token, to, tokens);
        if (refund != 0) _send(quote, to, refund);
        emit BidClaimed(bidId, msg.sender, n, tokens, refund);
    }

    // ================================================================ Shield

    /// @notice Deposits quote into the Shield. Pays out pending gains and restarts the withdrawal lock.
    /// @dev Needs the price source: a deposit is never made before the source that will price it is public.
    function shieldDeposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroValue();
        if (priceSource == address(0)) revert PriceSourceNotConfigured();
        uint256 current = _payGainsAndCompound(msg.sender, msg.sender);
        uint256 updated = current + amount;
        shieldTotalDeposits += amount;
        _snapshot(msg.sender, updated);
        _shield[msg.sender].lastDepositAt = uint64(block.timestamp);
        _pullExact(quote, amount);
        emit ShieldDeposited(msg.sender, amount, updated);
    }

    /// @notice Withdraws `amount` of the caller's compounded Shield deposit after the lock; pays gains.
    /// @dev Reverts with `ShieldFundsReserved` if it would leave less than twice what the Shield has
    /// committed to unsettled offers; settle them (anyone can) or withdraw less.
    function shieldWithdraw(uint256 amount) external nonReentrant {
        _shieldWithdraw(amount, msg.sender);
    }

    /// @notice As `shieldWithdraw`, with the deposit and the gains paid to `to`.
    function shieldWithdrawTo(uint256 amount, address to) external nonReentrant {
        _shieldWithdraw(amount, to);
    }

    function _shieldWithdraw(uint256 amount, address to) internal {
        if (to == address(0)) revert ZeroAddress();
        ShieldDeposit storage d = _shield[msg.sender];
        if (d.initial == 0) revert InsufficientShieldDeposit();
        if (block.timestamp < uint256(d.lastDepositAt) + SHIELD_MIN_LOCK) revert ShieldLocked();
        uint256 current = _payGainsAndCompound(msg.sender, to);
        if (amount == 0 || amount > current) revert InsufficientShieldDeposit();
        uint256 updated = current - amount;
        uint256 total = amount > shieldTotalDeposits ? 0 : shieldTotalDeposits - amount;
        // Funds committed to open offers stay, and every absorption stays at or below half of the deposits.
        if (total * SHIELD_MAX_FUNDS_USE_BPS / BPS < shieldReservedQuote) revert ShieldFundsReserved();
        shieldTotalDeposits = total;
        _snapshot(msg.sender, updated);
        _send(quote, to, amount);
        emit ShieldWithdrawn(msg.sender, amount, updated);
    }

    /// @notice Pays the caller's absorbed tokens and fee rewards without touching the deposit or its lock.
    function shieldClaimGains() external nonReentrant {
        uint256 current = _payGainsAndCompound(msg.sender, msg.sender);
        _snapshot(msg.sender, current);
    }

    /// @notice As `shieldClaimGains`, paid to `to`.
    function shieldClaimGainsTo(address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 current = _payGainsAndCompound(msg.sender, to);
        _snapshot(msg.sender, current);
    }

    /// @notice (compounded deposit, pending token gain, pending quote gain) of `account`.
    function shieldPosition(address account)
        external
        view
        returns (uint256 deposit, uint256 tokenGain, uint256 quoteGain, uint256 unlocksAt)
    {
        ShieldDeposit storage d = _shield[account];
        deposit = _compounded(d);
        tokenGain = _gain(d, shieldS, d.snapshotS);
        quoteGain = _gain(d, shieldG, d.snapshotG);
        unlocksAt = d.initial == 0 ? 0 : uint256(d.lastDepositAt) + SHIELD_MIN_LOCK;
    }

    function _payGainsAndCompound(address account, address to) internal returns (uint256 current) {
        ShieldDeposit storage d = _shield[account];
        if (d.initial == 0) return 0;
        current = _compounded(d);
        uint256 tokenGain = _gain(d, shieldS, d.snapshotS);
        uint256 quoteGain = _gain(d, shieldG, d.snapshotG);
        // Snapshot before paying so a callback cannot claim twice.
        _snapshot(account, current);
        if (tokenGain != 0) _send(token, to, tokenGain);
        if (quoteGain != 0) _send(quote, to, quoteGain);
        if (tokenGain != 0 || quoteGain != 0) emit ShieldGainsPaid(account, tokenGain, quoteGain);
    }

    function _snapshot(address account, uint256 amount) internal {
        ShieldDeposit storage d = _shield[account];
        d.initial = amount;
        if (amount == 0) {
            d.snapshotP = 0;
            d.snapshotS = 0;
            d.snapshotG = 0;
            d.snapshotScale = 0;
            return;
        }
        uint128 scale = shieldScale;
        d.snapshotP = shieldP;
        d.snapshotS = shieldS[scale];
        d.snapshotG = shieldG[scale];
        d.snapshotScale = scale;
    }

    function _compounded(ShieldDeposit storage d) internal view returns (uint256) {
        if (d.initial == 0) return 0;
        uint256 diff = shieldScale - d.snapshotScale;
        if (diff == 0) return UniV3Math.mulDiv(d.initial, shieldP, d.snapshotP);
        if (diff == 1) return UniV3Math.mulDiv(d.initial, shieldP, d.snapshotP) / SCALE_FACTOR;
        return 0;
    }

    function _gain(ShieldDeposit storage d, mapping(uint128 => uint256) storage acc, uint256 snap)
        internal
        view
        returns (uint256)
    {
        if (d.initial == 0) return 0;
        uint128 scale = d.snapshotScale;
        uint256 first = acc[scale] - snap;
        uint256 second = acc[scale + 1] / SCALE_FACTOR;
        return UniV3Math.mulDiv(d.initial, first + second, d.snapshotP);
    }

    /// @dev Spends `debt` quote of the Shield for `coll` tokens. `debt <= deposits / 2`: reservations never
    /// exceed half of the deposits (`_shieldLots`) and withdrawals keep it so (`_shieldWithdraw`).
    function _shieldAbsorb(uint256 debt, uint256 coll) internal {
        uint256 total = shieldTotalDeposits;
        uint256 p = shieldP;
        shieldS[shieldScale] += UniV3Math.mulDiv(coll, p, total);
        uint256 newP = UniV3Math.mulDiv(p, total - debt, total);
        if (newP < SCALE_FACTOR) {
            newP *= SCALE_FACTOR;
            shieldScale += 1;
        }
        shieldP = newP;
        shieldTotalDeposits = total - debt;
    }

    // ================================================================ views

    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return _offers[offerId];
    }

    function getBid(uint256 bidId) external view returns (Bid memory) {
        return _bids[bidId];
    }

    // ================================================================ token helpers

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev Pulls exactly `amount` of `asset` from `msg.sender`; rejects fee-on-transfer behaviour.
    function _pullExact(address asset, uint256 amount) internal {
        uint256 before = IERC20Minimal(asset).balanceOf(address(this));
        _call(asset, abi.encodeCall(IERC20Minimal.transferFrom, (msg.sender, address(this), amount)));
        if (IERC20Minimal(asset).balanceOf(address(this)) - before != amount) revert FeeOnTransferUnsupported();
    }

    function _send(address asset, address to, uint256 amount) internal {
        _call(asset, abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
    }

    function _call(address asset, bytes memory data) internal {
        if (asset.code.length == 0) revert TokenTransferFailed();
        (bool ok, bytes memory ret) = asset.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenTransferFailed();
    }
}
