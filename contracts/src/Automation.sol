// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AutomationCompatibleInterface } from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Bytes } from "@openzeppelin/contracts/utils/Bytes.sol";
import { IVaultKeeper, IStockPriceFeed } from "./interfaces/IVaultKeeper.sol";
import { IXStocksProtocol } from "./interfaces/IXStocks.sol";

// ============================================================================
//  Automation.sol — Chainlink Automation keeper for VaultKeeper
// ============================================================================
//  Triggers:
//    • TIME_REBALANCE   — `rebalanceInterval` seconds have elapsed
//    • PRICE_DEVIATION  — a strategy leg has drifted more than `priceDeviationBps`
//    • LIQUIDATION      — an xStocks position is liquidatable (opt-in, see below)
//
//  Safety:
//    • Circuit breaker: after `maxConsecutiveFailures` failed upkeeps, `checkUpkeep`
//      stops requesting work so Automation does not burn gas on a broken setup.
//      The governor can clear it with `resetCircuitBreaker()`; a successful upkeep
//      clears it automatically.
//    • `checkUpkeep` also returns false when this contract is not authorised as the
//      vault's keeper, which is the failure mode that silently bricked the previous
//      implementation.
// ============================================================================

error AutomationPaused();
error Unauthorized(address caller, string role);
error InvalidVault();
error ZeroGovernor();
error InvalidInterval(uint256 requested, uint256 min, uint256 max);
error InvalidThreshold(string param, uint256 value, string reason);
error UnsupportedDataVersion(uint8 version);
error EmergencyWithdrawFailed(string reason);
error ZeroEmergencyTarget();
error ConsecutiveFailuresExceeded(uint256 failures, uint256 max);
error CircuitBreakerTripped(uint256 failures, uint256 max);
error KeeperNotAllowed(address keeper);
error VaultKeeperNotAuthorized(address automation, address vaultKeeper);
error LiquidationNotConfigured();
error ZeroAddress();

/// @title Automation
/// @notice Chainlink Automation-compatible keeper that drives {VaultKeeper} rebalances
///         and (optionally) xStocks liquidations.
contract Automation is AutomationCompatibleInterface, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────────────────────────────────────
    //  Constants
    // ────────────────────────────────────────────────────────────────────────

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Price scale used by the xStocks protocol (8-decimal USD).
    uint256 public constant XSTOCK_PRICE_DECIMALS = 8;

    uint256 public constant MIN_REBALANCE_INTERVAL = 300; // 5 minutes
    uint256 public constant MAX_REBALANCE_INTERVAL = 2_592_000; // 30 days
    uint256 public constant DEFAULT_PRICE_DEVIATION_BPS = 500; // 5%
    uint256 public constant DEFAULT_LIQUIDATION_SLIPPAGE_BPS = 200; // 2%
    uint256 public constant MAX_CHECK_ASSETS = 16;
    uint256 public constant MAX_LIQUIDATION_BATCH = 5;
    uint256 public constant DEFAULT_MAX_CONSECUTIVE_FAILURES = 3;
    /// @notice Oldest xStocks quote that may be used to size a liquidation.
    uint256 public constant XSTOCK_PRICE_MAX_AGE = 1 hours;
    uint8 public constant DATA_VERSION = 1;

    /// @notice Selector of the built-in `Error(string)` revert type.
    bytes4 public constant ERROR_STRING_SELECTOR = 0x08c379a0;

    /// @notice Trigger bits. Each trigger owns exactly one bit.
    uint256 public constant TRIGGER_TIME_REBALANCE = 1 << 0;
    uint256 public constant TRIGGER_PRICE_DEVIATION = 1 << 1;
    uint256 public constant TRIGGER_LIQUIDATION = 1 << 2;
    uint256 public constant TRIGGER_FEE_SWEEP = 1 << 3;

    // ────────────────────────────────────────────────────────────────────────
    //  Immutables
    // ────────────────────────────────────────────────────────────────────────

    IVaultKeeper public immutable vault;
    IXStocksProtocol public immutable xStocks;
    address public immutable governor;

    // ────────────────────────────────────────────────────────────────────────
    //  Configuration
    // ────────────────────────────────────────────────────────────────────────

    uint256 public rebalanceInterval;
    uint256 public lastRebalanceTimestamp;
    uint256 public priceDeviationBps;
    uint256 public liquidationSlippageBps;
    bool public liquidationEnabled;
    bool public paused;

    /// @notice Collateral asset seized during liquidations, and its oracle.
    /// @dev Liquidation stays disabled until both are configured, so the keeper can
    ///      never send a minimum-output value denominated in the wrong units.
    address public collateralAsset;
    IStockPriceFeed public collateralPriceFeed;

    // ────────────────────────────────────────────────────────────────────────
    //  Metrics & safety
    // ────────────────────────────────────────────────────────────────────────

    uint256 public totalRebalances;
    uint256 public totalLiquidations;
    uint256 public lastErrorTimestamp;
    string public lastError;
    address public emergencyWithdrawTarget;

    uint256 public consecutiveFailures;
    uint256 public maxConsecutiveFailures = DEFAULT_MAX_CONSECUTIVE_FAILURES;

    mapping(address => bool) public allowedKeepers;
    bool public useKeeperWhitelist;

    uint256 public totalGasUsed;
    uint256 public totalUpkeepCount;
    uint256 public totalSuccessfulUpkeeps;

    // ────────────────────────────────────────────────────────────────────────
    //  Events
    // ────────────────────────────────────────────────────────────────────────

    event RebalanceExecuted(uint256 timestamp, uint256 totalValue, uint8 triggerType);
    event LiquidationExecuted(uint256 timestamp, string stockSymbol, uint256 xStockAmount, uint256 collateralOut);
    event EmergencyWithdrawExecuted(uint256 timestamp, address asset, uint256 amount, address target);
    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);
    event TriggerToggled(uint8 triggerType, bool enabled);
    event PauseStateChanged(bool paused, string reason);
    event ErrorRecorded(uint256 timestamp, string error);
    event EmergencyTargetUpdated(address oldTarget, address newTarget);
    event KeeperWhitelistUpdated(address keeper, bool allowed);
    event MaxConsecutiveFailuresUpdated(uint256 oldValue, uint256 newValue);
    event UpkeepExecuted(uint256 timestamp, uint256 triggerBitmask, bool success, uint256 gasUsed);
    event CircuitBreakerReset(uint256 previousFailures, address by);
    event CollateralConfigured(address asset, address priceFeed);
    event FeeSweepExecuted(uint256 timestamp, uint256 amount);

    // ────────────────────────────────────────────────────────────────────────
    //  Constructor
    // ────────────────────────────────────────────────────────────────────────

    constructor(address vault_, address xStocks_, address governor_, uint256 rebalanceInterval_) {
        if (vault_ == address(0) || vault_.code.length == 0) revert InvalidVault();
        if (xStocks_ != address(0) && xStocks_.code.length == 0) revert InvalidVault();
        if (governor_ == address(0)) revert ZeroGovernor();
        if (rebalanceInterval_ < MIN_REBALANCE_INTERVAL || rebalanceInterval_ > MAX_REBALANCE_INTERVAL) {
            revert InvalidInterval(rebalanceInterval_, MIN_REBALANCE_INTERVAL, MAX_REBALANCE_INTERVAL);
        }

        vault = IVaultKeeper(vault_);
        xStocks = IXStocksProtocol(xStocks_);
        governor = governor_;
        rebalanceInterval = rebalanceInterval_;
        lastRebalanceTimestamp = block.timestamp;
        priceDeviationBps = DEFAULT_PRICE_DEVIATION_BPS;
        liquidationSlippageBps = DEFAULT_LIQUIDATION_SLIPPAGE_BPS;
        liquidationEnabled = xStocks_ != address(0);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Modifiers
    // ────────────────────────────────────────────────────────────────────────

    modifier onlyGovernor() {
        if (msg.sender != governor) revert Unauthorized(msg.sender, "GOVERNOR");
        _;
    }

    modifier onlyKeeper() {
        if (paused) revert AutomationPaused();
        if (useKeeperWhitelist && !allowedKeepers[msg.sender]) revert KeeperNotAllowed(msg.sender);
        _;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Views
    // ────────────────────────────────────────────────────────────────────────

    /// @notice True once failed upkeeps have hit the configured ceiling.
    function circuitBreakerTripped() public view returns (bool) {
        return consecutiveFailures >= maxConsecutiveFailures;
    }

    /// @notice True when this contract is the vault's keeper, or the vault owner.
    /// @dev When false, `performUpkeep` can never succeed — `checkUpkeep` reports it
    ///      and refuses to request work so the integration fails visibly instead of
    ///      burning gas forever.
    function vaultKeeperAuthorized() public view returns (bool) {
        try vault.keeper() returns (address vaultKeeper) {
            if (address(this) == vaultKeeper) return true;
        } catch {
            return false;
        }

        try vault.owner() returns (address vaultOwner) {
            return address(this) == vaultOwner;
        } catch {
            return false;
        }
    }

    function timeUntilNextRebalance() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastRebalanceTimestamp;
        return elapsed >= rebalanceInterval ? 0 : rebalanceInterval - elapsed;
    }

    /// @notice True when the vault is operational from the keeper's point of view.
    function isVaultHealthy() external view returns (bool) {
        return !paused && !circuitBreakerTripped() && vaultKeeperAuthorized();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Chainlink Automation interface
    // ────────────────────────────────────────────────────────────────────────

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        if (paused || circuitBreakerTripped()) return (false, "");

        // Never request work we are not authorised to perform.
        if (!vaultKeeperAuthorized()) return (false, "");

        uint256 triggerBitmask;
        uint256 context;

        if (_checkTimeRebalance()) triggerBitmask |= TRIGGER_TIME_REBALANCE;
        if (_checkPriceDeviation()) triggerBitmask |= TRIGGER_PRICE_DEVIATION;
        if (_checkFeeSweep()) triggerBitmask |= TRIGGER_FEE_SWEEP;

        if (liquidationEnabled && address(xStocks) != address(0) && collateralAsset != address(0)) {
            uint256 liqContext = _checkLiquidationOpportunity();
            if (liqContext != 0) {
                triggerBitmask |= TRIGGER_LIQUIDATION;
                context = liqContext;
            }
        }

        if (triggerBitmask != 0) {
            performData = abi.encode(DATA_VERSION, triggerBitmask, context);
            return (true, performData);
        }
        return (false, "");
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata performData) external override nonReentrant onlyKeeper {
        uint256 gasStart = gasleft();

        if (circuitBreakerTripped()) {
            revert ConsecutiveFailuresExceeded(consecutiveFailures, maxConsecutiveFailures);
        }

        (uint8 version, uint256 triggerBitmask, uint256 context) = _decodePerformData(performData);
        if (version != DATA_VERSION) revert UnsupportedDataVersion(version);

        bool anySuccess;

        // Exactly one rebalance per upkeep, even when several rebalance triggers fire.
        if (triggerBitmask & (TRIGGER_TIME_REBALANCE | TRIGGER_PRICE_DEVIATION) != 0) {
            if (_executeRebalance()) anySuccess = true;
        }

        if (triggerBitmask & TRIGGER_LIQUIDATION != 0) {
            if (_executeLiquidations(context)) anySuccess = true;
        }

        if (triggerBitmask & TRIGGER_FEE_SWEEP != 0) {
            if (_executeFeeSweep()) anySuccess = true;
        }

        uint256 gasUsed = gasStart - gasleft();
        totalGasUsed += gasUsed;
        ++totalUpkeepCount;

        if (anySuccess) {
            ++totalSuccessfulUpkeeps;
            consecutiveFailures = 0;
        } else {
            ++consecutiveFailures;
            _recordError("PERFORM_UPKEEP", _errorString("No action succeeded"));
        }

        emit UpkeepExecuted(block.timestamp, triggerBitmask, anySuccess, gasUsed);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Trigger checks
    // ────────────────────────────────────────────────────────────────────────

    /// @dev True when the vault has fees sitting idle and its sweep interval has elapsed.
    ///      Wrapped in try/catch so Automation also works against a vault revision that
    ///      predates the sweep API.
    function _checkFeeSweep() internal view returns (bool) {
        try vault.feesSweepDue() returns (bool due) {
            return due;
        } catch {
            return false;
        }
    }

    function _checkTimeRebalance() internal view returns (bool) {
        return (block.timestamp - lastRebalanceTimestamp) >= rebalanceInterval;
    }

    /// @dev Uses the vault's value-based weights, which are denominated in the same
    ///      basis-point space as `priceDeviationBps`.
    function _checkPriceDeviation() internal view returns (bool) {
        IVaultKeeper.StrategySnapshot[] memory snapshots;
        try vault.strategyBreakdown() returns (IVaultKeeper.StrategySnapshot[] memory s) {
            snapshots = s;
        } catch {
            return false;
        }

        for (uint256 i; i < snapshots.length; ++i) {
            uint256 target = snapshots[i].targetWeight;
            uint256 actual = snapshots[i].actualWeight;
            uint256 deviation = target > actual ? target - actual : actual - target;
            if (deviation > priceDeviationBps) return true;
        }
        return false;
    }

    /// @dev Returns a bitmask of liquidatable holdings, indexed by position in
    ///      `getSupportedStocks()`.
    function _checkLiquidationOpportunity() internal view returns (uint256 context) {
        if (address(xStocks) == address(0)) return 0;

        string[] memory stocks = xStocks.getSupportedStocks();
        uint256 len = stocks.length;
        if (len > MAX_CHECK_ASSETS) len = MAX_CHECK_ASSETS;

        for (uint256 i; i < len; ++i) {
            if (xStocks.xStockBalanceOf(address(vault), stocks[i]) == 0) continue;
            if (xStocks.isPositionLiquidatable(address(vault), stocks[i])) {
                context |= (1 << i);
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Execution
    // ────────────────────────────────────────────────────────────────────────

    function _executeRebalance() internal returns (bool) {
        try vault.rebalance() {
            lastRebalanceTimestamp = block.timestamp;
            ++totalRebalances;
            emit RebalanceExecuted(block.timestamp, vault.getPortfolioValue(), 0);
            return true;
        } catch (bytes memory reason) {
            _recordError("REBALANCE", reason);
            return false;
        }
    }

    /// @dev Permissionless on the vault side, so the keeper simply triggers it. The
    ///      interval check lives in the vault, which keeps this safe to run every upkeep.
    function _executeFeeSweep() internal returns (bool) {
        // forge-lint: disable-next-line(reentrancy-no-eth)
        try vault.sweepFees() returns (uint256 amount) {
            emit FeeSweepExecuted(block.timestamp, amount);
            return true;
        } catch (bytes memory reason) {
            _recordError("FEE_SWEEP", reason);
            return false;
        }
    }

    /// @param context Bitmask of holdings to liquidate, indexed by `getSupportedStocks()`.
    function _executeLiquidations(uint256 context) internal returns (bool anySuccess) {
        if (address(xStocks) == address(0)) return false;
        if (collateralAsset == address(0) || address(collateralPriceFeed) == address(0)) {
            revert LiquidationNotConfigured();
        }

        string[] memory stocks = xStocks.getSupportedStocks();
        uint256 len = stocks.length;
        if (len > MAX_LIQUIDATION_BATCH) len = MAX_LIQUIDATION_BATCH;

        for (uint256 i; i < len; ++i) {
            if ((context >> i) & 1 == 0) continue;

            string memory symbol = stocks[i];
            uint256 balance = xStocks.xStockBalanceOf(address(vault), symbol);
            if (balance == 0) continue;

            uint256 minCollateralOut = _minCollateralOut(balance, symbol);

            // performUpkeep is nonReentrant and governor/keeper gated; state below is
            // only accounting for the community keeper's report.
            // forge-lint: disable-next-line(reentrancy-no-eth)
            try xStocks.liquidate(address(vault), symbol, balance, minCollateralOut) returns (
                uint256 collateralSeized, uint256
            ) {
                ++totalLiquidations;
                emit LiquidationExecuted(block.timestamp, symbol, balance, collateralSeized);
                anySuccess = true;
            } catch (bytes memory reason) {
                _recordError(string.concat("LIQUIDATE_", symbol), reason);
            }
        }
    }

    /// @dev Minimum acceptable collateral, expressed in collateral-token units.
    ///      `balance` (18dp xStock) -> USD (8dp) -> less slippage -> collateral units.
    function _minCollateralOut(uint256 balance, string memory symbol) internal view returns (uint256) {
        (uint256 price, uint256 updatedAt) = xStocks.getStockPrice(symbol);
        if (price == 0) return 0;
        // A stale quote must not set the floor for a real liquidation: better to skip
        // (returning 0 makes the caller skip the position) than to accept too little.
        if (updatedAt != 0 && block.timestamp - updatedAt > XSTOCK_PRICE_MAX_AGE) return 0;

        uint256 valueUsd = Math.mulDiv(balance, price, 10 ** 18);
        uint256 minUsd = valueUsd - Math.mulDiv(valueUsd, liquidationSlippageBps, BPS_DENOMINATOR);

        uint256 collateralPrice = collateralPriceFeed.getPrice(collateralAsset);
        if (collateralPrice == 0) return 0;

        uint8 collateralDecimals = IERC20Metadata(collateralAsset).decimals();

        // minUsd is 8-decimal USD. Scale it to the collateral feed's precision, then
        // divide by the price to land in collateral-token units.
        uint256 valueAtPriceScale =
            Math.mulDiv(minUsd, 10 ** collateralPriceFeed.decimals(), 10 ** XSTOCK_PRICE_DECIMALS);
        return Math.mulDiv(valueAtPriceScale, 10 ** collateralDecimals, collateralPrice);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Encoding / error reporting
    // ────────────────────────────────────────────────────────────────────────

    function _decodePerformData(bytes calldata data)
        internal
        pure
        returns (uint8 version, uint256 triggerBitmask, uint256 context)
    {
        if (data.length == 0) return (0, 0, 0);
        (version, triggerBitmask, context) = abi.decode(data, (uint8, uint256, uint256));
    }

    /// @dev Wraps an internal note in the `Error(string)` ABI so the error recorder
    ///      decodes it back into readable text instead of a hex blob.
    function _errorString(string memory message) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ERROR_STRING_SELECTOR, message);
    }

    function _recordError(string memory operation, bytes memory reason) internal {
        lastError = string.concat(operation, ": ", _revertReason(reason));
        lastErrorTimestamp = block.timestamp;
        emit ErrorRecorded(block.timestamp, lastError);
    }

    /// @dev Decodes `Error(string)` reverts; falls back to a hex dump.
    function _revertReason(bytes memory reason) internal pure returns (string memory) {
        if (reason.length < 4) return "UNKNOWN";

        // `reason.length >= 4` is checked above, so the leading 4 bytes always exist.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (bytes4(reason) == ERROR_STRING_SELECTOR) {
            if (reason.length < 68) return "MALFORMED_ERROR";
            return abi.decode(Bytes.slice(reason, 4), (string));
        }
        return _bytesToHex(reason);
    }

    function _bytesToHex(bytes memory data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory out = new bytes(data.length * 2);
        for (uint256 i; i < data.length; ++i) {
            out[i * 2] = hexChars[uint8(data[i]) >> 4];
            out[i * 2 + 1] = hexChars[uint8(data[i]) & 0x0f];
        }
        return string(out);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Governance
    // ────────────────────────────────────────────────────────────────────────

    function setRebalanceInterval(uint256 newInterval) external onlyGovernor {
        if (newInterval < MIN_REBALANCE_INTERVAL || newInterval > MAX_REBALANCE_INTERVAL) {
            revert InvalidInterval(newInterval, MIN_REBALANCE_INTERVAL, MAX_REBALANCE_INTERVAL);
        }
        uint256 old = rebalanceInterval;
        rebalanceInterval = newInterval;
        emit ConfigUpdated("rebalanceInterval", old, newInterval);
    }

    function setPriceDeviationBps(uint256 newThreshold) external onlyGovernor {
        if (newThreshold == 0 || newThreshold > BPS_DENOMINATOR) {
            revert InvalidThreshold("priceDeviationBps", newThreshold, "EXCEEDS_MAX");
        }
        uint256 old = priceDeviationBps;
        priceDeviationBps = newThreshold;
        emit ConfigUpdated("priceDeviationBps", old, newThreshold);
    }

    function setLiquidationSlippageBps(uint256 newBps) external onlyGovernor {
        if (newBps > BPS_DENOMINATOR) {
            revert InvalidThreshold("liquidationSlippageBps", newBps, "EXCEEDS_MAX");
        }
        uint256 old = liquidationSlippageBps;
        liquidationSlippageBps = newBps;
        emit ConfigUpdated("liquidationSlippageBps", old, newBps);
    }

    function setLiquidationEnabled(bool enabled) external onlyGovernor {
        liquidationEnabled = enabled;
        emit TriggerToggled(2, enabled);
    }

    function setCollateralConfig(address asset, address priceFeed) external onlyGovernor {
        if (asset == address(0) || priceFeed == address(0)) revert ZeroAddress();
        collateralAsset = asset;
        collateralPriceFeed = IStockPriceFeed(priceFeed);
        emit CollateralConfigured(asset, priceFeed);
    }

    function setEmergencyTarget(address newTarget) external onlyGovernor {
        if (newTarget == address(0)) revert ZeroEmergencyTarget();
        address old = emergencyWithdrawTarget;
        emergencyWithdrawTarget = newTarget;
        emit EmergencyTargetUpdated(old, newTarget);
    }

    function setPaused(bool shouldPause, string calldata reason) external onlyGovernor {
        paused = shouldPause;
        emit PauseStateChanged(shouldPause, reason);
    }

    function setKeeperWhitelist(address keeper, bool allowed) external onlyGovernor {
        allowedKeepers[keeper] = allowed;
        emit KeeperWhitelistUpdated(keeper, allowed);
    }

    function setUseKeeperWhitelist(bool enable) external onlyGovernor {
        useKeeperWhitelist = enable;
    }

    function setMaxConsecutiveFailures(uint256 newMax) external onlyGovernor {
        if (newMax == 0) revert InvalidThreshold("maxConsecutiveFailures", newMax, "ZERO");
        uint256 old = maxConsecutiveFailures;
        maxConsecutiveFailures = newMax;
        emit MaxConsecutiveFailuresUpdated(old, newMax);
    }

    /// @notice Clears the circuit breaker so upkeeps resume.
    function resetCircuitBreaker() external onlyGovernor {
        uint256 previous = consecutiveFailures;
        consecutiveFailures = 0;
        emit CircuitBreakerReset(previous, msg.sender);
    }

    function emergencyWithdraw(address asset, uint256 amount) external onlyGovernor {
        if (emergencyWithdrawTarget == address(0)) revert ZeroEmergencyTarget();

        try vault.emergencyWithdraw(asset, amount, emergencyWithdrawTarget) {
            emit EmergencyWithdrawExecuted(block.timestamp, asset, amount, emergencyWithdrawTarget);
        } catch (bytes memory reason) {
            _recordError("EMERGENCY_WITHDRAW", reason);
            revert EmergencyWithdrawFailed(_revertReason(reason));
        }
    }

    function forceRebalance() external onlyGovernor returns (bool) {
        return _executeRebalance();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Snapshot
    // ────────────────────────────────────────────────────────────────────────

    struct AutomationSnapshot {
        address vaultAddress;
        address xStocksAddress;
        address governor;
        bool paused;
        bool circuitBreakerTripped;
        bool vaultKeeperAuthorized;
        uint256 rebalanceInterval;
        uint256 lastRebalance;
        uint256 priceDeviationBps;
        uint256 liquidationSlippageBps;
        bool liquidationEnabled;
        address collateralAsset;
        uint256 totalRebalances;
        uint256 totalLiquidations;
        string lastError;
        uint256 consecutiveFailures;
        uint256 maxConsecutiveFailures;
        uint256 totalUpkeepCount;
        uint256 totalSuccessfulUpkeeps;
        uint256 totalGasUsed;
    }

    function getSnapshot() external view returns (AutomationSnapshot memory) {
        return AutomationSnapshot({
            vaultAddress: address(vault),
            xStocksAddress: address(xStocks),
            governor: governor,
            paused: paused,
            circuitBreakerTripped: circuitBreakerTripped(),
            vaultKeeperAuthorized: vaultKeeperAuthorized(),
            rebalanceInterval: rebalanceInterval,
            lastRebalance: lastRebalanceTimestamp,
            priceDeviationBps: priceDeviationBps,
            liquidationSlippageBps: liquidationSlippageBps,
            liquidationEnabled: liquidationEnabled,
            collateralAsset: collateralAsset,
            totalRebalances: totalRebalances,
            totalLiquidations: totalLiquidations,
            lastError: lastError,
            consecutiveFailures: consecutiveFailures,
            maxConsecutiveFailures: maxConsecutiveFailures,
            totalUpkeepCount: totalUpkeepCount,
            totalSuccessfulUpkeeps: totalSuccessfulUpkeeps,
            totalGasUsed: totalGasUsed
        });
    }
}
