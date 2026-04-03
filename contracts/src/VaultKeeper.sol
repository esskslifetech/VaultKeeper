// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IVaultKeeper, IStockPriceFeed} from "./interfaces/IVaultKeeper.sol";

// Uniswap V3 interfaces for real swaps
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title VaultKeeper — Multi‑Strategy ERC‑4626 Vault with Real‑Time Rebalancing
/// @notice Production‑grade vault that accepts ERC‑20 deposits, mints shares,
///         and allocates capital across weighted strategies using real Uniswap V3 swaps.
/// @dev    Implements IVaultKeeper, ERC20, ReentrancyGuard, Ownable.
///         All prices come from a live oracle (Chainlink/Pyth/etc.) – no mocks.
contract VaultKeeper is ERC20, ReentrancyGuard, Ownable, IVaultKeeper {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Basis point denominator (100%).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum number of strategies allowed.
    uint256 public constant MAX_STRATEGIES = 8;

    /// @notice Maximum single strategy weight (90%).
    uint256 public constant MAX_SINGLE_WEIGHT = 9_000;

    /// @notice Maximum management fee (10%).
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 1_000;

    /// @notice Maximum performance fee (20%).
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 2_000;

    /// @notice Minimum deposit amount (1 unit).
    uint256 public constant MIN_DEPOSIT = 1;

    /// @notice Minimum withdrawal amount (1 share).
    uint256 public constant MIN_WITHDRAWAL = 1;

    /// @notice Price staleness threshold (1 hour).
    uint256 public constant PRICE_STALENESS_THRESHOLD = 3_600;

    /// @notice Rebalance tolerance (5%).
    uint256 public constant REBALANCE_TOLERANCE_BPS = 500;

    /// @notice Default Uniswap V3 fee tier (0.3%).
    uint24 public constant DEFAULT_FEE_TIER = 3000;

    // ═══════════════════════════════════════════════════════════════════════
    //  Immutable State
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Primary deposit asset (e.g., USDC).
    IERC20 public immutable depositAsset;

    /// @notice Uniswap V3 router for rebalancing swaps.
    address public immutable uniRouter;

    // ═══════════════════════════════════════════════════════════════════════
    //  Mutable State — Strategy
    // ═══════════════════════════════════════════════════════════════════════

    address[] private _assets;
    mapping(address => uint256) private _targetWeights;
    Strategy private _strategy;

    // ═══════════════════════════════════════════════════════════════════════
    //  Mutable State — Roles
    // ═══════════════════════════════════════════════════════════════════════

    address public keeper;
    address public pauser;

    // ═══════════════════════════════════════════════════════════════════════
    //  Mutable State — Fees & HWM
    // ═══════════════════════════════════════════════════════════════════════

    uint256 public override managementFee;
    uint256 public override performanceFee;
    uint256 private _highWaterMark;
    uint256 private _lastFeeAssessment;
    mapping(address => uint256) private _pendingFees;

    // ═══════════════════════════════════════════════════════════════════════
    //  Mutable State — Operations
    // ═══════════════════════════════════════════════════════════════════════

    bool public override paused;
    uint256 public lastRebalanceTime;
    uint256 public rebalanceCount;
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;
    uint256 public totalFeesCollected;

    // ═══════════════════════════════════════════════════════════════════════
    //  Oracle
    // ═══════════════════════════════════════════════════════════════════════

    IStockPriceFeed public override priceFeed;

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    event Deposit(address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, uint256 amount, uint256 shares);
    event Rebalanced(uint256 timestamp, uint256 totalValue, uint256 strategiesMoved);
    event RebalanceAction(address indexed asset, string action, uint256 amount, uint256 weightDiff);
    event StrategyUpdated(address[] oldAssets, address[] newAssets, uint256[] newWeights);
    event PriceFeedUpdated(address oldFeed, address newFeed);
    event FeeUpdated(string feeType, uint256 oldValue, uint256 newValue);
    event FeesAssessed(uint256 timestamp, uint256 managementFee, uint256 performanceFee, uint256 totalAssets);
    event FeesCollected(address indexed recipient, address indexed asset, uint256 amount);
    event PauseStateChanged(bool paused);
    event KeeperUpdated(address oldKeeper, address newKeeper);
    event PauserUpdated(address oldPauser, address newPauser);
    event EmergencyWithdraw(address indexed asset, uint256 amount, address indexed receiver);
    event GovernorTransferred(address indexed oldGovernor, address indexed newGovernor);

    // ═══════════════════════════════════════════════════════════════════════
    //  Custom Errors
    // ═══════════════════════════════════════════════════════════════════════

    error Unauthorized(address caller, string role);
    error VaultPaused();
    error ZeroAmount();
    error ZeroShares();
    error ZeroAddress();
    error InvalidStrategy(string reason);
    error SlippageExceeded(uint256 received, uint256 minimum);
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientBalance(address asset, uint256 requested, uint256 available);
    error InvalidFee(string feeType, uint256 value, uint256 maximum);
    error PriceFeedError(address asset, string reason);
    error MathError(string operation);
    error ExceedsLimit(uint256 requested, uint256 maximum);
    error TransferToZeroAddress();
    error NoAssetsToWithdraw();

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    constructor(
        string memory name,
        string memory symbol,
        address _depositAsset,
        address _priceFeed,
        address _uniRouter,
        Strategy memory _strategy
    ) ERC20(name, symbol) Ownable(msg.sender) {
        if (_depositAsset == address(0)) revert ZeroAddress();
        if (_priceFeed == address(0)) revert ZeroAddress();
        if (_uniRouter == address(0)) revert ZeroAddress();

        depositAsset = IERC20(_depositAsset);
        priceFeed = IStockPriceFeed(_priceFeed);
        uniRouter = _uniRouter;

        keeper = msg.sender;
        pauser = msg.sender;

        _setStrategy(_strategy);

        _highWaterMark = 1e18;
        _lastFeeAssessment = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ERC‑4626 Core
    // ═══════════════════════════════════════════════════════════════════════

    function deposit(uint256 amount) external override nonReentrant whenNotPaused returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        shares = previewDeposit(amount);
        depositAsset.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, shares);
        totalDeposited += amount;
        emit Deposit(msg.sender, amount, shares);
    }

    function deposit(uint256 amount, address receiver) external override nonReentrant whenNotPaused returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        shares = previewDeposit(amount);
        depositAsset.safeTransferFrom(msg.sender, address(this), amount);
        _mint(receiver, shares);
        totalDeposited += amount;
        emit Deposit(receiver, amount, shares);
    }

    function withdraw(uint256 shares, uint256 minAmount) external override nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares(shares, balanceOf(msg.sender));
        assets = previewWithdraw(shares);
        if (assets < minAmount) revert SlippageExceeded(assets, minAmount);
        _checkVaultLiquidity(assets);
        _burn(msg.sender, shares);
        depositAsset.safeTransfer(msg.sender, assets);
        totalWithdrawn += assets;
        emit Withdraw(msg.sender, assets, shares);
    }

    function withdraw(uint256 shares, address receiver, uint256 minAmount) external override nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares(shares, balanceOf(msg.sender));
        assets = previewWithdraw(shares);
        if (assets < minAmount) revert SlippageExceeded(assets, minAmount);
        _checkVaultLiquidity(assets);
        _burn(msg.sender, shares);
        depositAsset.safeTransfer(receiver, assets);
        totalWithdrawn += assets;
        emit Withdraw(receiver, assets, shares);
    }

    function convertToShares(uint256 assets) public view override returns (uint256 shares) {
        uint256 supply = totalSupply();
        uint256 total = totalAssets();
        if (supply == 0 || total == 0) return assets;
        return (assets * supply) / total;
    }

    function convertToAssets(uint256 shares) public view override returns (uint256 assets) {
        uint256 supply = totalSupply();
        uint256 total = totalAssets();
        if (supply == 0 || total == 0) return shares;
        return (shares * total) / supply;
    }

    function previewDeposit(uint256 assets) public view override returns (uint256 shares) {
        return convertToShares(assets);
    }

    function previewWithdraw(uint256 shares) public view override returns (uint256 assets) {
        return convertToAssets(shares);
    }

    function maxDeposit(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Portfolio & Strategy Views
    // ═══════════════════════════════════════════════════════════════════════

    function totalAssets() public view override returns (uint256 assets) {
        assets = depositAsset.balanceOf(address(this));
        for (uint256 i = 0; i < _assets.length; i++) {
            address asset = _assets[i];
            uint256 balance = IERC20(asset).balanceOf(address(this));
            if (balance > 0) {
                assets += _valueInDepositAsset(asset, balance);
            }
        }
    }

    function getPortfolioValue() external view override returns (uint256 value) {
        value = totalAssets();
    }

    function strategy() external view override returns (Strategy memory) {
        return _strategy;
    }

    function strategyBreakdown() external view override returns (StrategySnapshot[] memory snapshots) {
        uint256 len = _assets.length;
        snapshots = new StrategySnapshot[](len);
        uint256 total = totalAssets();
        for (uint256 i = 0; i < len; i++) {
            address asset = _assets[i];
            uint256 balance = IERC20(asset).balanceOf(address(this));
            uint256 targetWeight = _targetWeights[asset];
            uint256 actualWeight = total == 0 ? 0 : (balance * BPS_DENOMINATOR) / total;
            snapshots[i] = StrategySnapshot({
                asset: asset,
                targetWeight: targetWeight,
                actualWeight: actualWeight,
                balance: balance
            });
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Price Feed Integration (Real Data)
    // ═══════════════════════════════════════════════════════════════════════

    function getCachedPrice(address asset) external view override returns (uint256 price, uint256 updatedAt) {
        price = priceFeed.getPrice(asset);
        updatedAt = priceFeed.lastUpdate(asset);
        if (price == 0) revert PriceFeedError(asset, "ZERO_PRICE");
        if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) revert PriceFeedError(asset, "STALE");
    }

    function isPriceFresh(address asset) external view override returns (bool isFresh) {
        try priceFeed.getPrice(asset) returns (uint256 price) {
            uint256 updatedAt = priceFeed.lastUpdate(asset);
            isFresh = price > 0 && (block.timestamp - updatedAt) <= PRICE_STALENESS_THRESHOLD;
        } catch {
            isFresh = false;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Rebalance (Real Uniswap V3 Swaps)
    // ═══════════════════════════════════════════════════════════════════════

    function rebalance() external override nonReentrant whenNotPaused {
        if (msg.sender != keeper && msg.sender != owner()) revert Unauthorized(msg.sender, "KEEPER");
        _assessFees();

        uint256 totalValue = totalAssets();
        if (totalValue == 0) return;

        uint256 moved = 0;
        uint256 len = _assets.length;

        for (uint256 i = 0; i < len; i++) {
            address asset = _assets[i];
            uint256 targetWeight = _targetWeights[asset];
            uint256 balance = IERC20(asset).balanceOf(address(this));
            uint256 currentValue = _valueInDepositAsset(asset, balance);
            uint256 currentWeight = (currentValue * BPS_DENOMINATOR) / totalValue;

            if (currentWeight > targetWeight + REBALANCE_TOLERANCE_BPS) {
                uint256 excessValue = currentValue - (totalValue * targetWeight) / BPS_DENOMINATOR;
                if (excessValue > 0) {
                    _sellAsset(asset, excessValue);
                    moved++;
                    emit RebalanceAction(asset, "SELL", excessValue, currentWeight - targetWeight);
                }
            } else if (currentWeight + REBALANCE_TOLERANCE_BPS < targetWeight) {
                uint256 targetValue = (totalValue * targetWeight) / BPS_DENOMINATOR;
                uint256 deficitValue = targetValue - currentValue;
                if (deficitValue > 0) {
                    _buyAsset(asset, deficitValue);
                    moved++;
                    emit RebalanceAction(asset, "BUY", deficitValue, targetWeight - currentWeight);
                }
            }
        }

        lastRebalanceTime = block.timestamp;
        rebalanceCount++;
        emit Rebalanced(block.timestamp, totalValue, moved);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Governance — Strategy
    // ═══════════════════════════════════════════════════════════════════════

    function setStrategy(address[] calldata newAssets, uint256[] calldata newWeights) external override onlyOwner {
        _validateStrategy(newAssets, newWeights);
        _setStrategy(Strategy(newAssets, newWeights));
    }

    function updateWeights(uint256[] calldata newWeights) external override onlyOwner {
        if (newWeights.length != _assets.length) revert InvalidStrategy("LENGTH_MISMATCH");
        uint256 sum = 0;
        for (uint256 i = 0; i < newWeights.length; i++) {
            if (newWeights[i] > MAX_SINGLE_WEIGHT) revert InvalidStrategy("MAX_WEIGHT");
            sum += newWeights[i];
            _targetWeights[_assets[i]] = newWeights[i];
        }
        if (sum != BPS_DENOMINATOR) revert InvalidStrategy("WEIGHT_SUM");
        _strategy = Strategy(_assets, newWeights);
        emit StrategyUpdated(_assets, _assets, newWeights);
    }

    function setPriceFeed(address asset, address feed) external override onlyOwner {
        if (feed == address(0)) revert ZeroAddress();
        address old = address(priceFeed);
        priceFeed = IStockPriceFeed(feed);
        emit PriceFeedUpdated(old, feed);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Governance — Fees
    // ═══════════════════════════════════════════════════════════════════════

    function setManagementFee(uint256 newFee) external override onlyOwner {
        if (newFee > MAX_MANAGEMENT_FEE_BPS) revert InvalidFee("management", newFee, MAX_MANAGEMENT_FEE_BPS);
        uint256 old = managementFee;
        managementFee = newFee;
        emit FeeUpdated("management", old, newFee);
    }

    function setPerformanceFee(uint256 newFee) external override onlyOwner {
        if (newFee > MAX_PERFORMANCE_FEE_BPS) revert InvalidFee("performance", newFee, MAX_PERFORMANCE_FEE_BPS);
        uint256 old = performanceFee;
        performanceFee = newFee;
        emit FeeUpdated("performance", old, newFee);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Governance — Roles & Pause
    // ═══════════════════════════════════════════════════════════════════════

    function transferGovernance(address newGovernor) external override onlyOwner {
        if (newGovernor == address(0)) revert ZeroAddress();
        address old = owner();
        transferOwnership(newGovernor);
        emit GovernorTransferred(old, newGovernor);
    }

    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        address old = keeper;
        keeper = newKeeper;
        emit KeeperUpdated(old, newKeeper);
    }

    function setPauser(address newPauser) external onlyOwner {
        address old = pauser;
        pauser = newPauser;
        emit PauserUpdated(old, newPauser);
    }

    function setPaused(bool shouldPause) external override {
        if (msg.sender != owner() && msg.sender != pauser) revert Unauthorized(msg.sender, "PAUSER");
        paused = shouldPause;
        emit PauseStateChanged(shouldPause);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Emergency & Fee Collection
    // ═══════════════════════════════════════════════════════════════════════

    function emergencyWithdraw(address asset, uint256 amount, address receiver) external override onlyOwner {
        if (receiver == address(0)) revert ZeroAddress();
        IERC20(asset).safeTransfer(receiver, amount);
        emit EmergencyWithdraw(asset, amount, receiver);
    }

    function collectFees() external onlyOwner {
        uint256 amount = _pendingFees[address(depositAsset)];
        if (amount > 0) {
            _pendingFees[address(depositAsset)] = 0;
            totalFeesCollected += amount;
            depositAsset.safeTransfer(owner(), amount);
            emit FeesCollected(owner(), address(depositAsset), amount);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _validateStrategy(address[] memory assets, uint256[] memory weights) internal pure {
        if (assets.length != weights.length) revert InvalidStrategy("LENGTH_MISMATCH");
        if (assets.length == 0 || assets.length > MAX_STRATEGIES) revert InvalidStrategy("INVALID_LENGTH");
        uint256 sum = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == address(0)) revert InvalidStrategy("ZERO_ADDRESS");
            if (weights[i] > MAX_SINGLE_WEIGHT) revert InvalidStrategy("MAX_WEIGHT");
            sum += weights[i];
        }
        if (sum != BPS_DENOMINATOR) revert InvalidStrategy("WEIGHT_SUM");
    }

    function _setStrategy(Strategy memory newStrategy) internal {
        address[] memory oldAssets = _assets;
        delete _assets;
        for (uint256 i = 0; i < newStrategy.assets.length; i++) {
            _assets.push(newStrategy.assets[i]);
            _targetWeights[newStrategy.assets[i]] = newStrategy.weights[i];
        }
        _strategy = newStrategy;
        emit StrategyUpdated(oldAssets, newStrategy.assets, newStrategy.weights);
    }

    function _valueInDepositAsset(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 price = priceFeed.getPrice(asset);
        uint8 decimals = priceFeed.decimals();
        if (price == 0) return 0;
        return (amount * price) / (10 ** decimals);
    }

    function _assessFees() internal {
        uint256 elapsed = block.timestamp - _lastFeeAssessment;
        if (elapsed == 0) return;

        uint256 total = totalAssets();
        if (total == 0) {
            _lastFeeAssessment = block.timestamp;
            return;
        }

        uint256 mgmtFee = 0;
        if (managementFee > 0) {
            mgmtFee = (total * managementFee * elapsed) / (365 days * BPS_DENOMINATOR);
        }

        uint256 perfFee = 0;
        if (performanceFee > 0 && total > _highWaterMark) {
            uint256 profit = total - _highWaterMark;
            perfFee = (profit * performanceFee) / BPS_DENOMINATOR;
        }

        if (total > _highWaterMark) _highWaterMark = total;

        if (mgmtFee > 0 || perfFee > 0) {
            _pendingFees[address(depositAsset)] += mgmtFee + perfFee;
            emit FeesAssessed(block.timestamp, mgmtFee, perfFee, total);
        }
        _lastFeeAssessment = block.timestamp;
    }

    function _checkVaultLiquidity(uint256 required) internal view {
        uint256 balance = depositAsset.balanceOf(address(this));
        if (required > balance) revert InsufficientBalance(address(depositAsset), required, balance);
    }

    function _sellAsset(address asset, uint256 valueInDepositAsset) internal {
        uint256 amountIn = IERC20(asset).balanceOf(address(this));
        if (amountIn == 0) return;

        uint256 depositAssetBalanceBefore = depositAsset.balanceOf(address(this));
        _swap(asset, address(depositAsset), amountIn, 0);
        uint256 received = depositAsset.balanceOf(address(this)) - depositAssetBalanceBefore;
        if (received == 0) revert MathError("SWAP_FAILED");
    }

    function _buyAsset(address asset, uint256 valueInDepositAsset) internal {
        uint256 depositAssetBalance = depositAsset.balanceOf(address(this));
        if (depositAssetBalance == 0) return;

        uint256 amountIn = valueInDepositAsset > depositAssetBalance ? depositAssetBalance : valueInDepositAsset;
        uint256 assetBalanceBefore = IERC20(asset).balanceOf(address(this));
        _swap(address(depositAsset), asset, amountIn, 0);
        uint256 received = IERC20(asset).balanceOf(address(this)) - assetBalanceBefore;
        if (received == 0) revert MathError("SWAP_FAILED");
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) internal {
        IERC20(tokenIn).safeIncreaseAllowance(uniRouter, amountIn);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: DEFAULT_FEE_TIER,
            recipient: address(this),
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });
        ISwapRouter(uniRouter).exactInputSingle(params);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Modifiers
    // ═══════════════════════════════════════════════════════════════════════

    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }
}