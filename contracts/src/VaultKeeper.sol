// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IVaultKeeper, IStockPriceFeed, TransferMode } from "./interfaces/IVaultKeeper.sol";
import { IUniswapV3SwapRouter } from "./interfaces/IUniswapV3SwapRouter.sol";

/// @title VaultKeeper
/// @notice ERC-4626 vault that manages a weighted portfolio of tokenised equities,
///         rebalancing through Uniswap V3 swaps and valuing positions through an oracle.
///
/// @dev Accounting model
///      ─────────────────
///      `totalAssets()` (net) = grossAssets() - accruedFees.
///      `grossAssets()`       = idle deposit asset + Σ strategy positions valued in the deposit asset.
///      Fees therefore reduce the share price the moment they are assessed, instead of
///      being taken out of the pool as a retroactive haircut at collection time.
///
///      Unit handling
///      ─────────────
///      Three different decimal scales meet in this contract and are converted
///      explicitly, never implicitly:
///        • deposit asset  — e.g. 6 for USDC       (`depositDecimals`)
///        • strategy asset — e.g. 18 for a token    (`_assetDecimals[asset]`)
///        • oracle price   — e.g. 8 or 18           (`priceFeed.decimals()`)
///      All conversions go through {_valueInDepositAsset} / {_depositValueToAssetAmount},
///      both of which use `Math.mulDiv` so intermediate products cannot overflow.
///
///      Inflation (donation) attack
///      ───────────────────────────
///      {_decimalsOffset} returns a non-zero offset, so the vault always has virtual
///      shares backing it. Round-tripping a donation attack costs the attacker more than
///      it can extract; see `test_DonationAttackIsUnprofitable`.
contract VaultKeeper is ERC4626, ReentrancyGuard, Ownable2Step, IVaultKeeper {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Basis-point denominator (100%).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum number of strategy legs.
    uint256 public constant MAX_STRATEGIES = 8;

    /// @notice Maximum weight for a single leg (90%).
    uint256 public constant MAX_SINGLE_WEIGHT = 9_000;

    /// @notice Maximum management fee (10% per year).
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 1_000;

    /// @notice Maximum performance fee (20% of profit).
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 2_000;

    /// @notice Maximum configurable swap slippage tolerance (10%).
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;

    /// @notice Default swap slippage tolerance (1%).
    uint256 public constant DEFAULT_MAX_SLIPPAGE_BPS = 100;

    /// @notice Minimum deposit, in deposit-asset units.
    uint256 public constant MIN_DEPOSIT = 1;

    /// @notice Rebalance is skipped while a leg is within this band of its target (5%).
    uint256 public constant REBALANCE_TOLERANCE_BPS = 500;

    /// @notice Default Uniswap V3 pool fee tier (0.30%).
    uint24 public constant DEFAULT_FEE_TIER = 3_000;

    /// @notice Highest fee tier {setFeeTierOverride} will accept (Uniswap's own ceiling).
    uint24 public constant MAX_FEE_TIER = 1_000_000;

    /// @notice Virtual share offset. See contract-level note on the inflation attack.
    uint256 public constant SHARE_DECIMALS_OFFSET = 6;

    /// @notice Upper bound accepted from `priceFeed.decimals()`.
    uint8 public constant MAX_PRICE_DECIMALS = 36;

    // ═══════════════════════════════════════════════════════════════════════
    //  Immutable configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deposit asset (e.g. USDC).
    IERC20 public immutable depositAsset;

    /// @notice Uniswap V3 SwapRouter used by {rebalance} and withdrawal liquidity.
    IUniswapV3SwapRouter public immutable uniRouter;

    /// @notice Decimals of the deposit asset, cached at construction.
    uint8 public immutable depositDecimals;

    // ═══════════════════════════════════════════════════════════════════════
    //  Strategy state
    // ═══════════════════════════════════════════════════════════════════════

    address[] private _assets;
    mapping(address => uint256) private _targetWeights;
    mapping(address => uint8) private _assetDecimals;
    Strategy private _strategy;

    // ═══════════════════════════════════════════════════════════════════════
    //  Roles
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Address allowed to call {rebalance} alongside the owner.
    address public keeper;

    /// @notice Address allowed to pause alongside the owner.
    address public pauser;

    /// @notice Whether deposits, withdrawals and rebalances are halted.
    bool public paused;

    // ═══════════════════════════════════════════════════════════════════════
    //  Oracle
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Oracle used to value every strategy leg.
    IStockPriceFeed public priceFeed;

    // ═══════════════════════════════════════════════════════════════════════
    //  Fees
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Annual management fee, in basis points of net assets.
    uint256 public managementFee;

    /// @notice Performance fee, in basis points of profit above the high-water mark.
    uint256 public performanceFee;

    /// @notice Fees earned but not yet collected, in deposit-asset units.
    uint256 public accruedFees;

    /// @notice Assets-per-share high-water mark, scaled by 1e18. 0 means "unset".
    uint256 private _highWaterMark;

    uint256 private _lastFeeAssessment;

    // ═══════════════════════════════════════════════════════════════════════
    //  Execution configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Uniswap V3 fee tier used for every swap.
    uint24 public swapFeeTier = DEFAULT_FEE_TIER;

    /// @notice Per-leg Uniswap V3 fee tier override (0 = use {swapFeeTier}).
    /// @dev Liquidity for one tokenised equity is routinely concentrated at one tier
    ///      (TSLAon's live USDC pool is deepest at 1%, SPYon's at 0.3%), so a portfolio of
    ///      them cannot be traded from a single global tier.
    mapping(address => uint24) public feeTierOverride;

    /// @notice Slippage tolerance applied to every swap, in basis points.
    uint256 public maxSlippageBps = DEFAULT_MAX_SLIPPAGE_BPS;

    // ═══════════════════════════════════════════════════════════════════════
    //  Statistics
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Timestamp of the last successful {rebalance}.
    uint256 public lastRebalanceTime;

    /// @notice Number of successful {rebalance} calls.
    uint256 public rebalanceCount;

    /// @notice Lifetime deposit-asset inflow.
    uint256 public totalDeposited;

    /// @notice Lifetime deposit-asset outflow to withdrawers.
    uint256 public totalWithdrawn;

    /// @notice Lifetime fees transferred to the fee recipient.
    uint256 public totalFeesCollected;

    // ═══════════════════════════════════════════════════════════════════════
    //  Fees — recipient and automatic sweeping
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Account that receives collected fees. Defaults to the owner.
    address public feeRecipient;

    /// @notice Minimum delay between permissionless {sweepFees} calls.
    uint256 public feeSweepInterval = 1 days;

    /// @notice Timestamp of the last fee sweep.
    uint256 public lastFeeSweepTime;

    // ═══════════════════════════════════════════════════════════════════════
    //  Share transfer policy
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice How share transfers are gated. Minting and burning are never gated.
    TransferMode public transferMode;

    /// @notice Accounts permitted to send or receive shares in ALLOWLIST_ONLY mode.
    mapping(address account => bool allowed) public transferAllowlist;

    /// @notice Per-account timestamp before which that account may not transfer shares.
    mapping(address account => uint256 unlockTime) public sharesUnlockTime;

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error Unauthorized(address caller, string role);
    error VaultPaused();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidStrategy(string reason);
    error InsufficientLiquidity(uint256 required, uint256 available);
    error SlippageExceeded(uint256 received, uint256 minimum);
    error InvalidFee(string feeType, uint256 value, uint256 maximum);
    error InvalidParameter(string param, uint256 value);
    error UnknownStrategyAsset(address asset);
    error PriceUnavailable(address asset);
    error StalePrice(address asset, uint256 updatedAt, uint256 threshold);
    error SwapFailed(address tokenIn, address tokenOut, uint256 amountIn);
    error NoPool(address tokenIn, address tokenOut);
    error NoFeeSweepDue();
    error TransfersDisabled();
    error TransferNotAllowed(address from, address to);
    error SharesLocked(address account, uint256 unlockTime);

    // ═══════════════════════════════════════════════════════════════════════
    //  Modifiers
    // ═══════════════════════════════════════════════════════════════════════

    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert Unauthorized(msg.sender, "KEEPER");
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    /// @param name_ ERC-20 name of the share token.
    /// @param symbol_ ERC-20 symbol of the share token.
    /// @param depositAsset_ Deposit asset; must expose `decimals()`.
    /// @param priceFeed_ Oracle used to value strategy legs.
    /// @param uniRouter_ Uniswap V3 SwapRouter.
    /// @param strategy_ Initial strategy; weights must sum to 10_000.
    constructor(
        string memory name_,
        string memory symbol_,
        address depositAsset_,
        address priceFeed_,
        address uniRouter_,
        Strategy memory strategy_,
        address initialOwner
    ) ERC20(name_, symbol_) ERC4626(IERC20(depositAsset_)) Ownable(initialOwner) {
        if (depositAsset_ == address(0) || priceFeed_ == address(0) || uniRouter_ == address(0)) {
            revert ZeroAddress();
        }
        if (uniRouter_.code.length == 0) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        IStockPriceFeed feed = IStockPriceFeed(priceFeed_);
        if (feed.decimals() > MAX_PRICE_DECIMALS) revert InvalidParameter("feedDecimals", feed.decimals());

        depositAsset = IERC20(depositAsset_);
        depositDecimals = IERC20Metadata(depositAsset_).decimals();
        priceFeed = feed;
        uniRouter = IUniswapV3SwapRouter(uniRouter_);

        keeper = initialOwner;
        pauser = initialOwner;
        feeRecipient = initialOwner;
        _lastFeeAssessment = block.timestamp;
        lastFeeSweepTime = block.timestamp;

        _setStrategy(strategy_);
    }

    /// @dev Resolves the `owner()` collision between {Ownable} and {IVaultKeeper}.
    function owner() public view override(Ownable, IVaultKeeper) returns (address) {
        return super.owner();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ERC-4626 — accounting
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ERC4626
    function asset() public view override(ERC4626) returns (address) {
        return address(depositAsset);
    }

    /// @dev Virtual shares: mitigates the first-depositor / donation inflation attack.
    ///      See https://docs.openzeppelin.com/contracts/5.x/erc4626#the-empty-vault-problem
    function _decimalsOffset() internal pure override returns (uint8) {
        // SHARE_DECIMALS_OFFSET is the literal 6, so this narrowing cast is checked at
        // compile time and cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(SHARE_DECIMALS_OFFSET);
    }

    /// @notice Net assets under management: gross assets less accrued, uncollected fees.
    function totalAssets() public view virtual override(ERC4626) returns (uint256) {
        uint256 gross = grossAssets();
        uint256 fees = accruedFees;
        unchecked {
            return gross > fees ? gross - fees : 0;
        }
    }

    /// @inheritdoc IVaultKeeper
    function grossAssets() public view returns (uint256 gross) {
        gross = depositAsset.balanceOf(address(this));

        uint256 len = _assets.length;
        for (uint256 i; i < len; ++i) {
            address asset_ = _assets[i];
            uint256 balance = IERC20(asset_).balanceOf(address(this));
            if (balance != 0) gross += _valueInDepositAsset(asset_, balance);
        }
    }

    /// @inheritdoc IVaultKeeper
    function getPortfolioValue() external view returns (uint256) {
        return totalAssets();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ERC-4626 — limits
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view virtual override(ERC4626) returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    /// @inheritdoc ERC4626
    function maxMint(address) public view virtual override(ERC4626) returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    /// @inheritdoc ERC4626
    function maxWithdraw(address owner_) public view virtual override(ERC4626) returns (uint256) {
        if (paused) return 0;
        return super.maxWithdraw(owner_);
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner_) public view virtual override(ERC4626) returns (uint256) {
        if (paused) return 0;
        return super.maxRedeem(owner_);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ERC-4626 — user flows
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ERC4626
    function deposit(uint256 assets, address receiver)
        public
        virtual
        override(ERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets < MIN_DEPOSIT) revert ZeroAmount();
        _assessFees();
        shares = super.deposit(assets, receiver);
        totalDeposited += assets;
    }

    /// @inheritdoc ERC4626
    function mint(uint256 shares, address receiver)
        public
        virtual
        override(ERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        _assessFees();
        assets = super.mint(shares, receiver);
        totalDeposited += assets;
    }

    /// @inheritdoc ERC4626
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        virtual
        override(ERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        _assessFees();
        shares = super.withdraw(assets, receiver, owner_);
        totalWithdrawn += assets;
    }

    /// @inheritdoc ERC4626
    function redeem(uint256 shares, address receiver, address owner_)
        public
        virtual
        override(ERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        _assessFees();
        assets = super.redeem(shares, receiver, owner_);
        totalWithdrawn += assets;
    }

    /// @dev Seeds the performance-fee high-water mark at first funding. Doing it here
    ///      (rather than lazily inside {_assessFees}) means a gain that occurs before
    ///      the first time-elapsed assessment is still measured against the entry price.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        virtual
        override(ERC4626)
    {
        super._deposit(caller, receiver, assets, shares);
        _seedHighWaterMark();
    }

    /// @dev Seeds the performance-fee high-water mark the first time the vault is funded.
    ///      Kept separate from {_deposit} because a claim-based (ERC-7540) deposit mints
    ///      shares without going through the ERC-4626 asset-transfer path.
    function _seedHighWaterMark() internal virtual {
        if (_highWaterMark == 0 && totalSupply() != 0) {
            uint256 seeded = Math.mulDiv(1e18, totalAssets() + 1, totalSupply() + 10 ** SHARE_DECIMALS_OFFSET);
            _highWaterMark = seeded;
            emit HighWaterMarkUpdated(0, seeded);
        }
    }

    /// @dev Cash the rebalancer must not spend. The base vault only rings-fences uncollected
    ///      fees; an asynchronous vault also holds assets on behalf of pending claimants.
    function _reservedCash() internal view virtual returns (uint256) {
        return accruedFees;
    }

    /// @dev Withdrawals must always be serviceable, so the vault liquidates strategy
    ///      positions into the deposit asset before paying out.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        virtual
        override(ERC4626)
    {
        _ensureLiquidity(assets);
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Valuation (the unit-conversion core)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Converts `amount` of `asset` into deposit-asset units.
    /// @dev `amount [assetDecimals] -> price [priceDecimals] -> USD -> deposit [depositDecimals]`.
    ///      Reverts rather than silently returning a wrong value when the oracle is unusable.
    function _valueInDepositAsset(address asset_, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 price = _priceOf(asset_);

        uint256 usdValue = Math.mulDiv(amount, price, 10 ** priceFeed.decimals());
        return Math.mulDiv(usdValue, 10 ** depositDecimals, 10 ** _assetDecimals[asset_]);
    }

    /// @notice Converts a deposit-asset value into an amount of `asset`, rounding down.
    /// @dev Exact inverse of {_valueInDepositAsset}.
    function _depositValueToAssetAmount(address asset_, uint256 valueInDepositAsset) internal view returns (uint256) {
        return _depositValueToAssetAmount(asset_, valueInDepositAsset, Math.Rounding.Floor);
    }

    /// @notice Converts a deposit-asset value into an amount of `asset` with explicit rounding.
    /// @dev `Ceil` is what a caller wants when it must raise *at least* a given amount of
    ///      cash: a floored input can be worth strictly less than the target after the
    ///      token's granularity is applied, which makes a correctly enforced
    ///      `amountOutMinimum` unsatisfiable.
    function _depositValueToAssetAmount(address asset_, uint256 valueInDepositAsset, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        if (valueInDepositAsset == 0) return 0;
        uint256 price = _priceOf(asset_);

        uint256 usdValue = Math.mulDiv(valueInDepositAsset, 10 ** priceFeed.decimals(), 10 ** depositDecimals);
        return Math.mulDiv(usdValue, 10 ** _assetDecimals[asset_], price, rounding);
    }

    /// @dev Fetches a price and enforces freshness locally, so the vault does not
    ///      depend on the oracle implementation to police staleness.
    function _priceOf(address asset_) internal view returns (uint256) {
        IStockPriceFeed feed = priceFeed;
        uint256 price = feed.getPrice(asset_);
        if (price == 0) revert PriceUnavailable(asset_);

        uint256 updatedAt = feed.lastUpdate(asset_);
        uint256 threshold = feed.stalenessThreshold();
        if (updatedAt == 0 || block.timestamp - updatedAt > threshold) {
            revert StalePrice(asset_, updatedAt, threshold);
        }
        return price;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Strategy views
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVaultKeeper
    function strategy() external view returns (Strategy memory) {
        return _strategy;
    }

    /// @inheritdoc IVaultKeeper
    function strategyBreakdown() external view returns (StrategySnapshot[] memory snapshots) {
        uint256 len = _assets.length;
        snapshots = new StrategySnapshot[](len);

        uint256 total = totalAssets();
        for (uint256 i; i < len; ++i) {
            address asset_ = _assets[i];
            uint256 balance = IERC20(asset_).balanceOf(address(this));
            uint256 value = balance == 0 ? 0 : _valueInDepositAsset(asset_, balance);

            snapshots[i] = StrategySnapshot({
                asset: asset_,
                targetWeight: _targetWeights[asset_],
                actualWeight: total == 0 ? 0 : Math.mulDiv(value, BPS_DENOMINATOR, total),
                balance: balance,
                valueInDepositAsset: value
            });
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Rebalancing
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVaultKeeper
    /// @dev Trades only the *excess* or *deficit* of each leg, and re-reads `totalAssets()`
    ///      at the start of every iteration so later legs are measured against post-trade state.
    function rebalance() external nonReentrant whenNotPaused onlyKeeperOrOwner {
        _assessFees();

        uint256 len = _assets.length;
        uint256 moved;

        for (uint256 i; i < len; ++i) {
            address asset_ = _assets[i];
            uint256 totalValue = totalAssets();
            if (totalValue == 0) break;

            uint256 targetWeight = _targetWeights[asset_];
            uint256 balance = IERC20(asset_).balanceOf(address(this));
            uint256 currentValue = balance == 0 ? 0 : _valueInDepositAsset(asset_, balance);
            uint256 currentWeight = Math.mulDiv(currentValue, BPS_DENOMINATOR, totalValue);

            if (currentWeight > targetWeight + REBALANCE_TOLERANCE_BPS) {
                uint256 targetValue = Math.mulDiv(totalValue, targetWeight, BPS_DENOMINATOR);
                uint256 excessValue = currentValue - targetValue;
                uint256 sellAmount = _depositValueToAssetAmount(asset_, excessValue);
                if (sellAmount > balance) sellAmount = balance;

                if (sellAmount != 0) {
                    uint256 minOut = excessValue - Math.mulDiv(excessValue, maxSlippageBps, BPS_DENOMINATOR);
                    _swap(asset_, address(depositAsset), sellAmount, minOut);
                    emit RebalanceAction(asset_, "SELL", sellAmount, currentWeight - targetWeight);
                    ++moved;
                }
            } else if (currentWeight + REBALANCE_TOLERANCE_BPS < targetWeight) {
                uint256 targetValue = Math.mulDiv(totalValue, targetWeight, BPS_DENOMINATOR);
                uint256 deficitValue = targetValue - currentValue;

                // Never spend cash that is earmarked for uncollected fees.
                uint256 cash = depositAsset.balanceOf(address(this));
                uint256 reserved = _reservedCash();
                uint256 spendable = cash > reserved ? cash - reserved : 0;
                uint256 spend = deficitValue < spendable ? deficitValue : spendable;

                if (spend != 0) {
                    uint256 expectedOut = _depositValueToAssetAmount(asset_, spend);
                    uint256 minOut = expectedOut - Math.mulDiv(expectedOut, maxSlippageBps, BPS_DENOMINATOR);
                    _swap(address(depositAsset), asset_, spend, minOut);
                    emit RebalanceAction(asset_, "BUY", spend, targetWeight - currentWeight);
                    ++moved;
                }
            }
        }

        lastRebalanceTime = block.timestamp;
        ++rebalanceCount;
        emit Rebalanced(block.timestamp, totalAssets(), moved);
    }

    /// @dev Sells strategy positions until at least `required` deposit asset is idle.
    function _ensureLiquidity(uint256 required) internal {
        uint256 cash = depositAsset.balanceOf(address(this));
        if (cash >= required) return;

        uint256 shortfall = required - cash;
        uint256 len = _assets.length;

        for (uint256 i; i < len && shortfall != 0; ++i) {
            address asset_ = _assets[i];
            uint256 balance = IERC20(asset_).balanceOf(address(this));
            if (balance == 0) continue;

            uint256 positionValue = _valueInDepositAsset(asset_, balance);
            // Gross the sale up by the slippage allowance. A real venue can pay a little
            // less than the oracle mark (a live tokenised-equity pool sits a few bps off
            // its feed, before price impact), so selling exactly the marked shortfall can
            // still leave the vault short of `required` and revert a healthy redemption.
            uint256 sellValue = Math.mulDiv(shortfall, BPS_DENOMINATOR, BPS_DENOMINATOR - maxSlippageBps);
            if (sellValue > positionValue) sellValue = positionValue;
            // Round the input up: a floored amount can be worth less than the minimum the
            // swap must return, which turns a dust-sized shortfall into a hard revert.
            uint256 sellAmount = _depositValueToAssetAmount(asset_, sellValue, Math.Rounding.Ceil);
            if (sellAmount > balance) sellAmount = balance;
            if (sellAmount == 0) continue;

            uint256 minOut = sellValue - Math.mulDiv(sellValue, maxSlippageBps, BPS_DENOMINATOR);
            uint256 received = _swap(asset_, address(depositAsset), sellAmount, minOut);
            shortfall = received >= shortfall ? 0 : shortfall - received;
        }

        uint256 available = depositAsset.balanceOf(address(this));
        if (available < required) revert InsufficientLiquidity(required, available);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Swaps
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Executes an exact-input swap through the configured Uniswap V3 router.
    ///      `minOut` is derived from the oracle price minus `maxSlippageBps`; the router
    ///      enforces it on-chain as well, so a bad fill reverts here rather than being
    ///      silently accepted.
    /// @dev Fee tier to use for a swap: the override on the strategy leg involved, else
    ///      the global {swapFeeTier}. One side of every vault swap is the deposit asset.
    function _feeTierFor(address tokenIn, address tokenOut) internal view returns (uint24) {
        address leg = tokenIn == address(depositAsset) ? tokenOut : tokenIn;
        uint24 override_ = feeTierOverride[leg];
        return override_ == 0 ? swapFeeTier : override_;
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;
        if (uniRouter == IUniswapV3SwapRouter(address(0))) revert NoPool(tokenIn, tokenOut);

        IERC20(tokenIn).forceApprove(address(uniRouter), 0);
        IERC20(tokenIn).forceApprove(address(uniRouter), amountIn);

        amountOut = uniRouter.exactInputSingle(
            IUniswapV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: _feeTierFor(tokenIn, tokenOut),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );

        if (amountOut < minOut) revert SlippageExceeded(amountOut, minOut);
        if (amountOut == 0) revert SwapFailed(tokenIn, tokenOut, amountIn);

        IERC20(tokenIn).forceApprove(address(uniRouter), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Fees
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Accrues management and performance fees into {accruedFees}. Because
    ///      {totalAssets} subtracts that figure, the share price drops immediately and
    ///      collection later is not dilutive.
    function _assessFees() internal {
        uint256 elapsed = block.timestamp - _lastFeeAssessment;
        if (elapsed == 0) return;
        // Internal fee-accrual cursor: it is a clock, not a balance, and every value
        // derived from it is reported by FeesAssessed / HighWaterMarkUpdated below.
        // forge-lint: disable-next-line(missing-events-arithmetic)
        _lastFeeAssessment = block.timestamp;

        if (managementFee == 0 && performanceFee == 0) return;

        uint256 total = totalAssets();
        uint256 supply = totalSupply();
        if (total == 0 || supply == 0) return;

        uint256 feeAssets;

        if (managementFee != 0) {
            feeAssets += Math.mulDiv(total, managementFee * elapsed, 365 days * BPS_DENOMINATOR);
        }

        if (performanceFee != 0) {
            uint256 pps = Math.mulDiv(1e18, total + 1, supply + 10 ** SHARE_DECIMALS_OFFSET);
            if (_highWaterMark == 0) {
                _highWaterMark = pps;
            } else if (pps > _highWaterMark) {
                uint256 profitPerShare = pps - _highWaterMark;
                uint256 profit = Math.mulDiv(profitPerShare, supply, 1e18);
                feeAssets += Math.mulDiv(profit, performanceFee, BPS_DENOMINATOR);
                uint256 previousMark = _highWaterMark;
                _highWaterMark = pps;
                emit HighWaterMarkUpdated(previousMark, pps);
            }
        }

        if (feeAssets != 0) {
            accruedFees += feeAssets;
            emit FeesAssessed(block.timestamp, managementFee, performanceFee, total);
        }
    }

    /// @inheritdoc IVaultKeeper
    /// @dev Owner-initiated, interval-agnostic: the escape hatch for a fee recipient
    ///      that wants its fees now. `sweepFees` is the automated counterpart.
    function collectFees() external nonReentrant onlyOwner returns (uint256 amount) {
        return _payFees(owner());
    }

    /// @inheritdoc IVaultKeeper
    /// @dev Permissionless and interval-bounded, so a Chainlink upkeep (or anyone) can
    ///      keep fees flowing without the owner having to transact at all.
    function sweepFees() external nonReentrant returns (uint256 amount) {
        if (!feesSweepDue()) revert NoFeeSweepDue();
        return _payFees(feeRecipient);
    }

    /// @inheritdoc IVaultKeeper
    function feesSweepDue() public view returns (bool) {
        return accruedFees != 0 && block.timestamp >= lastFeeSweepTime + feeSweepInterval;
    }

    /// @dev Pays out everything accrued so far to `recipient`. The fee assets are already
    ///      excluded from {totalAssets}, so this is a pure cash movement.
    function _payFees(address recipient) internal returns (uint256 amount) {
        amount = accruedFees;
        if (amount == 0) return 0;

        accruedFees = 0;
        lastFeeSweepTime = block.timestamp;
        _ensureLiquidity(amount);

        totalFeesCollected += amount;
        depositAsset.safeTransfer(recipient, amount);
        emit FeesCollected(recipient, amount);
        emit FeesSwept(recipient, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Governance — fees and share transfer policy
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVaultKeeper
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /// @inheritdoc IVaultKeeper
    function setFeeSweepInterval(uint256 newInterval) external onlyOwner {
        if (newInterval > 30 days) revert InvalidParameter("feeSweepInterval", newInterval);
        uint256 old = feeSweepInterval;
        feeSweepInterval = newInterval;
        emit FeeSweepIntervalUpdated(old, newInterval);
    }

    /// @inheritdoc IVaultKeeper
    function setTransferMode(TransferMode mode) external onlyOwner {
        TransferMode old = transferMode;
        transferMode = mode;
        emit TransferModeUpdated(old, mode);
    }

    /// @inheritdoc IVaultKeeper
    function setTransferAllowlisted(address account, bool allowed) external onlyOwner {
        transferAllowlist[account] = allowed;
        emit TransferAllowlistUpdated(account, allowed);
    }

    /// @inheritdoc IVaultKeeper
    /// @dev Per-account vesting lock. Setting `unlockTime` in the past clears it.
    function setSharesUnlockTime(address account, uint256 unlockTime) external onlyOwner {
        sharesUnlockTime[account] = unlockTime;
        emit ShareLockUpdated(account, unlockTime);
    }

    /// @dev Mints and burns bypass the policy, so deposits, withdrawals, redemptions and
    ///      fee accrual keep working in every mode; only holder-to-holder transfers are
    ///      gated. The lock is checked on the sender only, so a locked account can still
    ///      be a recipient.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            TransferMode mode = transferMode;
            if (mode == TransferMode.LOCKED) revert TransfersDisabled();
            if (mode == TransferMode.ALLOWLIST_ONLY && (!transferAllowlist[from] || !transferAllowlist[to])) {
                revert TransferNotAllowed(from, to);
            }
            uint256 unlockTime = sharesUnlockTime[from];
            if (unlockTime != 0 && block.timestamp < unlockTime) revert SharesLocked(from, unlockTime);
        }
        super._update(from, to, value);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Governance — strategy
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVaultKeeper
    function setStrategy(address[] calldata newAssets, uint256[] calldata newWeights) external onlyOwner {
        _setStrategy(Strategy({ assets: newAssets, weights: newWeights }));
    }

    /// @inheritdoc IVaultKeeper
    function updateWeights(uint256[] calldata newWeights) external onlyOwner {
        uint256 len = _assets.length;
        if (newWeights.length != len) revert InvalidStrategy("LENGTH_MISMATCH");

        uint256[] memory oldWeights = new uint256[](len);
        uint256 sum;
        for (uint256 i; i < len; ++i) {
            oldWeights[i] = _targetWeights[_assets[i]];
            if (newWeights[i] > MAX_SINGLE_WEIGHT) revert InvalidStrategy("MAX_WEIGHT");
            sum += newWeights[i];
            _targetWeights[_assets[i]] = newWeights[i];
        }
        if (sum != BPS_DENOMINATOR) revert InvalidStrategy("WEIGHT_SUM");

        _strategy.weights = newWeights;
        emit StrategyUpdated(_assets, oldWeights, _assets, newWeights);
    }

    function _setStrategy(Strategy memory newStrategy) internal {
        address[] memory oldAssets = _assets;
        uint256[] memory oldWeights = new uint256[](oldAssets.length);
        for (uint256 i; i < oldAssets.length; ++i) {
            oldWeights[i] = _targetWeights[oldAssets[i]];
            delete _targetWeights[oldAssets[i]];
        }

        _validateStrategy(newStrategy.assets, newStrategy.weights);

        delete _assets;
        uint256 len = newStrategy.assets.length;
        for (uint256 i; i < len; ++i) {
            address asset_ = newStrategy.assets[i];
            _assets.push(asset_);
            _targetWeights[asset_] = newStrategy.weights[i];
            _assetDecimals[asset_] = _readDecimals(asset_);

            // Fail fast: an unpriceable leg would make totalAssets() revert, which
            // would brick deposits, withdrawals and rebalances.
            _priceOf(asset_);
        }

        _strategy = newStrategy;
        emit StrategyUpdated(oldAssets, oldWeights, newStrategy.assets, newStrategy.weights);
    }

    function _validateStrategy(address[] memory assets_, uint256[] memory weights) internal pure {
        uint256 len = assets_.length;
        if (len != weights.length) revert InvalidStrategy("LENGTH_MISMATCH");
        if (len == 0 || len > MAX_STRATEGIES) revert InvalidStrategy("INVALID_LENGTH");

        uint256 sum;
        for (uint256 i; i < len; ++i) {
            if (assets_[i] == address(0)) revert InvalidStrategy("ZERO_ADDRESS");
            if (weights[i] > MAX_SINGLE_WEIGHT) revert InvalidStrategy("MAX_WEIGHT");
            for (uint256 j = i + 1; j < len; ++j) {
                if (assets_[i] == assets_[j]) revert InvalidStrategy("DUPLICATE_ASSET");
            }
            sum += weights[i];
        }
        if (sum != BPS_DENOMINATOR) revert InvalidStrategy("WEIGHT_SUM");
    }

    /// @dev Reads `decimals()` defensively: tokens that do not implement it are
    ///      treated as 18-decimal, matching the ecosystem convention.
    function _readDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            if (d > 36) revert InvalidParameter("assetDecimals", d);
            return d;
        } catch {
            return 18;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Governance — oracle, fees, execution, roles
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVaultKeeper
    function setPriceFeed(address newFeed) external onlyOwner {
        if (newFeed == address(0)) revert ZeroAddress();
        if (IStockPriceFeed(newFeed).decimals() > MAX_PRICE_DECIMALS) revert InvalidParameter("feedDecimals", 0);

        address old = address(priceFeed);
        priceFeed = IStockPriceFeed(newFeed);

        // Re-validate every leg against the new oracle.
        uint256 len = _assets.length;
        for (uint256 i; i < len; ++i) {
            _priceOf(_assets[i]);
        }

        emit PriceFeedUpdated(old, newFeed);
    }

    /// @inheritdoc IVaultKeeper
    function setManagementFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_MANAGEMENT_FEE_BPS) revert InvalidFee("management", newFee, MAX_MANAGEMENT_FEE_BPS);
        _assessFees();
        uint256 old = managementFee;
        managementFee = newFee;
        emit ManagementFeeUpdated(old, newFee);
    }

    /// @inheritdoc IVaultKeeper
    function setPerformanceFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_PERFORMANCE_FEE_BPS) revert InvalidFee("performance", newFee, MAX_PERFORMANCE_FEE_BPS);
        _assessFees();
        uint256 old = performanceFee;
        performanceFee = newFee;
        emit PerformanceFeeUpdated(old, newFee);
    }

    /// @inheritdoc IVaultKeeper
    function setSwapFeeTier(uint24 newTier) external onlyOwner {
        uint24 old = swapFeeTier;
        swapFeeTier = newTier;
        emit SwapFeeTierUpdated(old, newTier);
    }

    /// @inheritdoc IVaultKeeper
    function setFeeTierOverride(address asset, uint24 fee) external onlyOwner {
        if (fee > MAX_FEE_TIER) revert InvalidParameter("feeTier", fee);
        if (fee != 0 && _targetWeights[asset] == 0) revert UnknownStrategyAsset(asset);
        uint24 old = feeTierOverride[asset];
        feeTierOverride[asset] = fee;
        emit FeeTierOverrideUpdated(asset, old, fee);
    }

    /// @inheritdoc IVaultKeeper
    function setMaxSlippageBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_SLIPPAGE_BPS) revert InvalidParameter("maxSlippageBps", newBps);
        uint256 old = maxSlippageBps;
        maxSlippageBps = newBps;
        emit MaxSlippageUpdated(old, newBps);
    }

    /// @inheritdoc IVaultKeeper
    function resetHighWaterMark() external onlyOwner {
        _assessFees();
        uint256 supply = totalSupply();
        uint256 pps = supply == 0 ? 0 : Math.mulDiv(1e18, totalAssets() + 1, supply + 10 ** SHARE_DECIMALS_OFFSET);
        uint256 previousMark = _highWaterMark;
        _highWaterMark = pps;
        emit HighWaterMarkUpdated(previousMark, pps);
    }

    /// @inheritdoc IVaultKeeper
    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        address old = keeper;
        keeper = newKeeper;
        emit KeeperUpdated(old, newKeeper);
    }

    /// @inheritdoc IVaultKeeper
    function setPauser(address newPauser) external onlyOwner {
        if (newPauser == address(0)) revert ZeroAddress();
        address old = pauser;
        pauser = newPauser;
        emit PauserUpdated(old, newPauser);
    }

    /// @inheritdoc IVaultKeeper
    function setPaused(bool shouldPause) external {
        if (msg.sender != owner() && msg.sender != pauser) revert Unauthorized(msg.sender, "PAUSER");
        paused = shouldPause;
        emit PauseStateChanged(shouldPause);
    }

    /// @inheritdoc IVaultKeeper
    /// @dev Callable by the keeper or the owner: `Automation` routes its governor-gated
    ///      `emergencyWithdraw` through this function, so an owner-only gate here would
    ///      make that recovery path permanently unreachable.
    function emergencyWithdraw(address token, uint256 amount, address receiver)
        external
        nonReentrant
        onlyKeeperOrOwner
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(receiver, amount);
        emit EmergencyWithdraw(token, amount, receiver);
    }
}
