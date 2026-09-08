// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { LelantosToken } from "../governance/LelantosToken.sol";

/// `FeeConfig.sweep` on any pool this burner is the treasury of.
interface IFeeSweeper {
    function sweep(IERC20 token) external returns (uint256);
}

/// Collects protocol fees and burns the governance token.
///
/// The burner is the address `MASP.treasury` and `SwapWrapper.treasury` point at.
/// All three fee paths — `FeeConfig.sweep`, `YieldOps.sweepNormalized` and the
/// wrapper's slippage-dust push — are permissionless `safeTransfer`s to that
/// address, so no protocol contract requires modification and this contract holds
/// no allowances.
///
/// ## Auction rather than swap
///
/// Swapping a known balance at a predictable time is a sandwich target, and
/// pricing the swap requires an oracle, which this protocol does not use.
///
/// The trade is therefore inverted: the burner sells fee tokens for GOV at a
/// price decaying from a seed until a bidder takes it. Bidders pay GOV, which is
/// burned. No router, oracle, route configuration or slippage parameter is
/// involved, and no external call can revert the sale.
///
/// `priceOf` reads no external state. It is a pure function of `(startPrice,
/// startedAt, halfLife, block.timestamp)`, so there is no reserve to skew and no
/// oracle to poison, and every caller in a block sees the same price. Bidders may
/// flash-borrow GOV to pay: the full amount is still received and burned.
///
/// Absent a GOV market the auction receives no bids and fee tokens accumulate
/// here until one exists.
contract FeeBurner is Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// GOV wei per one base unit of the fee token, scaled by 1e18.
    uint256 public constant PRICE_SCALE = 1e18;
    uint16 public constant BPS = 10_000;

    LelantosToken public immutable GOV;

    /// `enabled`, `startedAt` and `minLot` total 23 bytes and share one slot, so
    /// a lot occupies three slots and `priceOf` reads one fewer.
    struct Lot {
        bool enabled;
        uint48 startedAt;
        /// Dust floor. A fill below this is refused unless it clears the balance,
        /// so the tail can always be swept.
        uint128 minLot;
        /// Price at `startedAt`, before any decay.
        uint256 startPrice;
        /// Decay floor. The curve never goes below this, so an unsold lot is stuck
        /// rather than free.
        uint256 minPrice;
    }

    mapping(IERC20 token => Lot) public lots;

    /// Seconds per halving of the asking price.
    uint32 public halfLife;
    /// Halvings after which decay stops. Bounded decay is what keeps an unsold lot
    /// from eventually costing nothing.
    uint8 public maxHalvings;
    /// Ratchet applied to a full fill, in bps of the clearing price. Partial fills
    /// scale it down proportionally; see `buy`. Bounded to `[BPS, 50_000]` — it
    /// must never lower the price, and an unbounded multiplier could ratchet a
    /// seed into uselessness in a few fills.
    uint16 public restartMultBps;
    /// Share of GOV proceeds burned. `BPS` burns everything.
    uint16 public burnBps;
    /// Receives the unburned remainder when `burnBps < BPS`.
    address public secondaryTreasury;
    bool public paused;

    /// Pools whose permissionless `sweep` `harvest` will call.
    address[] private _pools;

    event LotConfigured(IERC20 indexed token, bool enabled, uint256 startPrice, uint256 minPrice, uint128 minLot);
    event LotSold(
        IERC20 indexed token,
        address indexed buyer,
        address indexed to,
        uint256 amountOut,
        uint256 govIn,
        uint256 burned,
        uint256 clearingPrice
    );
    event GovBurned(uint256 amount);
    event DecayParamsSet(uint32 halfLife, uint8 maxHalvings, uint16 restartMultBps);
    event BurnBpsSet(uint16 burnBps);
    event SecondaryTreasurySet(address indexed treasury);
    event PausedSet(bool paused);
    event PoolsSet(address[] pools);
    event Rescued(IERC20 indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error LotDisabled();
    error CannotAuctionGov();
    error BadAmount();
    error BelowMinLot(uint256 amountOut, uint256 minLot);
    error PriceTooLow();
    error PriceAboveMax(uint256 govIn, uint256 maxGovIn);
    error IsPaused();
    error BadDecayParams();
    error BadBurnBps();
    error BadLotPrices();
    error NothingToBurn();

    constructor(
        LelantosToken gov_,
        address owner_,
        uint32 halfLife_,
        uint8 maxHalvings_,
        uint16 restartMultBps_,
        uint16 burnBps_,
        address secondaryTreasury_
    ) Ownable(owner_) {
        if (address(gov_) == address(0)) revert ZeroAddress();
        GOV = gov_;
        _setDecayParams(halfLife_, maxHalvings_, restartMultBps_);
        _setBurnPolicy(burnBps_, secondaryTreasury_);
    }

    // ============== Pricing ==================================================

    /// Current asking price for `token`, in GOV wei per base unit, scaled by
    /// `PRICE_SCALE`. Zero for an unconfigured or disabled lot.
    ///
    /// Pure function of stored lot state and `block.timestamp`. It reads nothing
    /// external, which is what makes the auction unsandwichable.
    function priceOf(IERC20 token) public view returns (uint256) {
        // `_priceOf` only reads its argument, so the storage-to-memory copy is the
        // point: there is no write here that could fail to reach storage.
        // aderyn-fp-next-line(storage-array-memory-edit)
        return _priceOf(lots[token]);
    }

    function _priceOf(Lot memory l) private view returns (uint256) {
        if (!l.enabled) return 0;
        // Both live in the same packed slot; pulling them into locals keeps the
        // decay arithmetic from re-reading storage three times.
        uint256 period = halfLife;
        uint256 maxHalvings_ = maxHalvings;

        uint256 elapsed = block.timestamp - uint256(l.startedAt);
        uint256 periods = elapsed / period;
        uint256 p;
        if (periods >= maxHalvings_) {
            // Clamped: stop decaying rather than interpolating past the floor.
            p = l.startPrice >> maxHalvings_;
        } else {
            p = l.startPrice >> periods;
            // Linear inside the period, from p down to p/2, so the curve is
            // continuous across a halving boundary.
            //
            // Position within the current half-life, not a source of
            // randomness: the curve is deterministic.
            // slither-disable-next-line weak-prng
            uint256 rem = elapsed % period;
            p -= Math.mulDiv(p >> 1, rem, period);
        }
        return p < l.minPrice ? l.minPrice : p;
    }

    // ============== Auction ==================================================

    /// Buys `amountOut` of `token` for GOV at the current price. The GOV is
    /// burned and the fee tokens are sent to `to`.
    ///
    /// `maxGovIn` bounds what the bidder pays. The price only decays with time,
    /// so it can move only in the bidder's favour before mining.
    ///
    /// The ratchet is weighted by fill size: a size-blind ratchet would let
    /// repeated dust fills raise the price and restart the clock, preventing a lot
    /// from clearing. Weighting by fill fraction makes a dust fill move the price
    /// proportionally.
    ///
    /// Follows CEI: the lot is re-priced before any transfer, since `token` is a
    /// governance-registered ERC-20 that may re-enter.
    function buy(IERC20 token, uint256 amountOut, uint256 maxGovIn, address to)
        external
        nonReentrant
        returns (uint256 govIn)
    {
        if (paused) revert IsPaused();
        if (to == address(0)) revert ZeroAddress();

        Lot storage lot = lots[token];
        Lot memory l = lot;
        if (!l.enabled) revert LotDisabled();

        uint256 price = _priceOf(l);
        // `buy` is `nonReentrant` and prices the lot before this read, so a
        // re-entering token cannot land between the read and the ratchet write.
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 bal = token.balanceOf(address(this));
        if (amountOut == 0 || amountOut > bal) revert BadAmount();
        // Dust floor, with an escape so the final remainder is always sellable.
        if (amountOut < l.minLot && amountOut != bal) revert BelowMinLot(amountOut, l.minLot);

        // Rounds toward the protocol, matching `YieldOps.sweepNormalized`
        // ("rounding points away from the treasury").
        govIn = Math.mulDiv(amountOut, price, PRICE_SCALE, Math.Rounding.Ceil);
        // Unreachable as written: rounding up means any non-zero `amountOut` at
        // a non-zero price costs at least 1 wei, and an enabled lot prices above
        // zero because `setLot` requires `minPrice > 0`. Retained so a change to
        // those bounds cannot make a lot free.
        //
        // Zero here is a presence test on a value this contract just computed,
        // not arithmetic on an attacker-movable quantity.
        // slither-disable-next-line incorrect-equality
        if (govIn == 0) revert PriceTooLow();
        if (govIn > maxGovIn) revert PriceAboveMax(govIn, maxGovIn);

        // --- effects, before any external call -------------------------------
        uint256 fillBps = Math.mulDiv(amountOut, BPS, bal);
        uint256 mult = uint256(BPS) + Math.mulDiv(uint256(restartMultBps) - BPS, fillBps, BPS);
        lot.startPrice = Math.mulDiv(price, mult, BPS);
        lot.startedAt = uint48(block.timestamp);

        // --- interactions ----------------------------------------------------
        IERC20(address(GOV)).safeTransferFrom(msg.sender, address(this), govIn);
        uint256 burned = Math.mulDiv(govIn, burnBps, BPS);
        if (burned != 0) GOV.burn(burned);
        uint256 remainder = govIn - burned;
        if (remainder != 0) IERC20(address(GOV)).safeTransfer(secondaryTreasury, remainder);
        token.safeTransfer(to, amountOut);

        emit LotSold(token, msg.sender, to, amountOut, govIn, burned, price);
    }

    /// Burns any GOV held by this contract. `buy` leaves no balance, so a
    /// resting balance is fee income or a donation.
    function burnAccruedGov() external nonReentrant returns (uint256 amount) {
        amount = GOV.balanceOf(address(this));
        // Zero is the "nothing to do" sentinel. A balance either is or is not
        // present; there is no threshold to be gamed by dusting, since any
        // non-zero amount is simply burned.
        // slither-disable-next-line incorrect-equality
        if (amount == 0) revert NothingToBurn();
        GOV.burn(amount);
        emit GovBurned(amount);
    }

    /// Pulls `token` fees from every registered pool. Each `sweep` is already
    /// permissionless, so this grants no authority and only saves a transaction.
    ///
    /// Uses a low-level call: a high-level call to an address without code fails
    /// Solidity's `extcodesize` check, and that revert occurs outside the region
    /// `try/catch` protects, so one EOA in `_pools` would block the loop. Every
    /// outcome is ignored here instead.
    function harvest(IERC20 token) external {
        uint256 n = _pools.length;
        for (uint256 i = 0; i < n; ++i) {
            // slither-disable-next-line low-level-calls,unused-return,calls-loop
            (bool ok,) = _pools[i].call(abi.encodeCall(IFeeSweeper.sweep, (token)));
            ok; // outcome intentionally ignored
        }
    }

    function pools() external view returns (address[] memory) {
        return _pools;
    }

    // ============== Governance (owner = Timelock) ============================

    /// Seeds or reconfigures one lot. Seed high: an excessive seed only delays
    /// the first clear, while an insufficient one under-prices a single fill
    /// before the ratchet corrects.
    function setLot(IERC20 token, bool enabled, uint256 startPrice, uint256 minPrice, uint128 minLot)
        external
        onlyOwner
    {
        if (address(token) == address(0)) revert ZeroAddress();
        // Auctioning GOV for GOV is meaningless and would corrupt the ratchet.
        // GOV arriving as a fee is handled by `burnAccruedGov`.
        if (address(token) == address(GOV)) revert CannotAuctionGov();
        if (enabled && (startPrice == 0 || minPrice == 0 || minPrice > startPrice)) revert BadLotPrices();

        lots[token] = Lot({
            enabled: enabled,
            startedAt: uint48(block.timestamp),
            minLot: minLot,
            startPrice: startPrice,
            minPrice: minPrice
        });
        emit LotConfigured(token, enabled, startPrice, minPrice, minLot);
    }

    function setDecayParams(uint32 halfLife_, uint8 maxHalvings_, uint16 restartMultBps_) external onlyOwner {
        _setDecayParams(halfLife_, maxHalvings_, restartMultBps_);
    }

    function setBurnBps(uint16 burnBps_) external onlyOwner {
        _setBurnPolicy(burnBps_, secondaryTreasury);
    }

    function setSecondaryTreasury(address treasury_) external onlyOwner {
        _setBurnPolicy(burnBps, treasury_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setPools(address[] calldata pools_) external onlyOwner {
        _pools = pools_;
        emit PoolsSet(pools_);
    }

    /// Governance escape hatch. Confers no additional trust, since governance
    /// already holds `setTreasury` on both the pool and the wrapper.
    ///
    /// Covers rebasing or fee-on-transfer tokens that break the accounting,
    /// tokens with no market, and moving fees to the chain where GOV exists.
    function rescue(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ============== Internals ================================================

    function _setDecayParams(uint32 halfLife_, uint8 maxHalvings_, uint16 restartMultBps_) private {
        // `halfLife == 0` divides by zero in `_priceOf`; the ratchet must not be
        // able to *lower* the price, and an unbounded multiplier could overflow a
        // seed into uselessness.
        if (halfLife_ == 0) revert BadDecayParams();
        if (maxHalvings_ == 0 || maxHalvings_ > 32) revert BadDecayParams();
        // Ceiling is 5x. `restartMultBps` is a uint16, so anything above 65_535 is
        // unrepresentable and a higher bound would be dead code.
        if (restartMultBps_ < BPS || restartMultBps_ > 50_000) revert BadDecayParams();
        halfLife = halfLife_;
        maxHalvings = maxHalvings_;
        restartMultBps = restartMultBps_;
        emit DecayParamsSet(halfLife_, maxHalvings_, restartMultBps_);
    }

    /// Burn share and remainder destination are set together: any share not
    /// burned requires a destination, and separate setters could leave the two
    /// inconsistent.
    function _setBurnPolicy(uint16 burnBps_, address treasury_) private {
        if (burnBps_ > BPS) revert BadBurnBps();
        // Anything not burned must have somewhere to go.
        if (burnBps_ < BPS && treasury_ == address(0)) revert ZeroAddress();
        burnBps = burnBps_;
        secondaryTreasury = treasury_;
        emit BurnBpsSet(burnBps_);
        emit SecondaryTreasurySet(treasury_);
    }
}
