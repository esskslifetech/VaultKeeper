// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IStockPriceFeed
/// @notice Minimal oracle interface consumed by {VaultKeeper}.
/// @dev Prices are returned in `decimals()` fixed point, expressed in units of the
///      vault's deposit asset (i.e. USD for a USDC vault).
interface IStockPriceFeed {
    /// @notice Fixed-point scale of `getPrice` results (e.g. 8 or 18).
    function decimals() external view returns (uint8);

    /// @notice Price of `asset` denominated in the deposit asset.
    /// @dev MUST revert if no usable price exists. Consumers rely on this.
    function getPrice(address asset) external view returns (uint256 price);

    /// @notice Timestamp of the last successful price update for `asset`.
    function lastUpdate(address asset) external view returns (uint256 updatedAt);

    /// @notice Maximum age, in seconds, that a price may have before it is stale.
    function stalenessThreshold() external view returns (uint256);

    /// @notice True when `asset` has a non-zero, non-stale price.
    function isPriceFresh(address asset) external view returns (bool);
}

/// @title IVaultKeeper
/// @notice Vault-specific surface of {VaultKeeper}, on top of ERC-4626.
/// @dev Deliberately does NOT extend IERC4626: the ERC-4626 surface is inherited
///      from OpenZeppelin's {ERC4626} in the implementation, which keeps the
///      override graph unambiguous.
/// @notice Share-transfer policy. Minting, burning and vault flows are never gated.
enum TransferMode {
    /// @dev Any holder may transfer to any address. The default.
    UNRESTRICTED,
    /// @dev Only addresses flagged with `setTransferAllowlisted` may send or receive.
    ALLOWLIST_ONLY,
    /// @dev Holder-to-holder transfers are disabled entirely; shares only enter and exit via the vault.
    LOCKED
}

interface IVaultKeeper {
    // ────────────────────────────────────────────────────────────────────────
    //  Structs
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Target portfolio weights in basis points (must sum to 10_000).
    struct Strategy {
        address[] assets;
        uint256[] weights;
    }

    /// @notice Point-in-time view of one strategy leg.
    struct StrategySnapshot {
        address asset;
        uint256 targetWeight;
        uint256 actualWeight;
        uint256 balance;
        uint256 valueInDepositAsset;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Events
    // ────────────────────────────────────────────────────────────────────────

    event Rebalanced(uint256 timestamp, uint256 totalAssets, uint256 strategiesMoved);
    event RebalanceAction(address indexed asset, string action, uint256 amount, uint256 weightDiff);
    event StrategyUpdated(address[] oldAssets, uint256[] oldWeights, address[] newAssets, uint256[] newWeights);
    event FeesAssessed(uint256 timestamp, uint256 managementFee, uint256 performanceFee, uint256 totalAssets);
    event ManagementFeeUpdated(uint256 oldFee, uint256 newFee);
    event PerformanceFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeesCollected(address indexed recipient, uint256 amount);
    event FeesSwept(address indexed recipient, uint256 amount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeSweepIntervalUpdated(uint256 oldInterval, uint256 newInterval);
    event TransferModeUpdated(TransferMode oldMode, TransferMode newMode);
    event TransferAllowlistUpdated(address indexed account, bool allowed);
    event ShareLockUpdated(address indexed account, uint256 unlockTime);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event PauseStateChanged(bool paused);
    event PriceFeedUpdated(address indexed oldFeed, address indexed newFeed);
    event EmergencyWithdraw(address indexed asset, uint256 amount, address indexed receiver);
    event SwapFeeTierUpdated(uint24 oldTier, uint24 newTier);

    /// @notice Emitted when a per-leg Uniswap V3 fee tier override is set.
    /// @param asset Strategy leg whose tier changed.
    /// @param oldTier Previous override (0 = none, i.e. the global default applied).
    /// @param newTier New override (0 clears it).
    event FeeTierOverrideUpdated(address indexed asset, uint24 oldTier, uint24 newTier);
    event MaxSlippageUpdated(uint256 oldBps, uint256 newBps);
    event HighWaterMarkUpdated(uint256 oldMark, uint256 newMark);

    // ────────────────────────────────────────────────────────────────────────
    //  Views
    // ────────────────────────────────────────────────────────────────────────

    function depositAsset() external view returns (IERC20);

    function owner() external view returns (address);

    function keeper() external view returns (address);

    function pauser() external view returns (address);

    function priceFeed() external view returns (IStockPriceFeed);

    function managementFee() external view returns (uint256);

    function performanceFee() external view returns (uint256);

    /// @notice Fees earned but not yet withdrawn, denominated in the deposit asset.
    function accruedFees() external view returns (uint256);

    /// @notice Gross assets held (cash + strategy positions) before fee liability.
    function grossAssets() external view returns (uint256);

    function getPortfolioValue() external view returns (uint256);

    function strategy() external view returns (Strategy memory);

    function strategyBreakdown() external view returns (StrategySnapshot[] memory);

    function lastRebalanceTime() external view returns (uint256);

    function rebalanceCount() external view returns (uint256);

    // ────────────────────────────────────────────────────────────────────────
    //  Keeper
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Aligns the portfolio with its target weights using Uniswap V3 swaps.
    /// @dev Callable by `keeper` or the owner.
    function rebalance() external;

    // ────────────────────────────────────────────────────────────────────────
    //  Administration
    // ────────────────────────────────────────────────────────────────────────

    function setStrategy(address[] calldata newAssets, uint256[] calldata newWeights) external;

    function updateWeights(uint256[] calldata newWeights) external;

    function setPriceFeed(address newFeed) external;

    function setManagementFee(uint256 newFee) external;

    function setPerformanceFee(uint256 newFee) external;

    function setKeeper(address newKeeper) external;

    function setPauser(address newPauser) external;

    function setPaused(bool shouldPause) external;

    function setSwapFeeTier(uint24 newTier) external;

    /// @notice Sets the Uniswap V3 fee tier used for one strategy leg.
    /// @dev Real tokenised equities are listed in different pools at different fee tiers;
    ///      a single global tier can only ever serve one of them. Zero clears the override
    ///      and restores {swapFeeTier}.
    function setFeeTierOverride(address asset, uint24 fee) external;

    /// @notice Per-leg fee tier override; 0 means "use {swapFeeTier}".
    function feeTierOverride(address asset) external view returns (uint24);

    function setMaxSlippageBps(uint256 newBps) external;

    function resetHighWaterMark() external;

    function collectFees() external returns (uint256 amount);

    /// @notice Pays all accrued fees to {feeRecipient}. Callable by anyone, at most once per
    ///         {feeSweepInterval}. This is the automated counterpart to {collectFees}.
    function sweepFees() external returns (uint256 amount);

    function feesSweepDue() external view returns (bool);

    function feeRecipient() external view returns (address);

    function feeSweepInterval() external view returns (uint256);

    function lastFeeSweepTime() external view returns (uint256);

    function setFeeRecipient(address newRecipient) external;

    function setFeeSweepInterval(uint256 newInterval) external;

    function transferMode() external view returns (TransferMode);

    function setTransferMode(TransferMode mode) external;

    function setTransferAllowlisted(address account, bool allowed) external;

    function setSharesUnlockTime(address account, uint256 unlockTime) external;

    /// @notice Sends `amount` of `asset` held by this vault to `receiver`, bypassing the
    ///         strategy and bypassing fee accrual.
    /// @dev Callable by `keeper` or the owner.
    function emergencyWithdraw(address asset, uint256 amount, address receiver) external;
}
