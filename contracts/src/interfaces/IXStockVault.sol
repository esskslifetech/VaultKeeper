// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IXStockVault — Interface for Tokenized Stock (xStock) Integration
/// @notice Defines the standard interface for xStock vaults that integrate with
///         the VaultKeeper protocol for borrow/lend/mint/redeem flows.
/// @dev This interface enables seamless integration between VaultKeeper vaults
///      and xStock protocols like Avalon's xStocks, allowing:
///      - Minting xStocks by depositing collateral
///      - Redeeming xStocks for underlying assets
///      - Borrowing against xStock positions
///      - Lending xStocks to earn yield
interface IXStockVault {
    // ═══════════════════════════════════════════════════════════════════════
    //  Structs
    // ═══════════════════════════════════════════════════════════════════════

    struct MintPosition {
        address user;
        address collateralAsset;
        uint256 collateralAmount;
        uint256 mintedXStock;
        uint256 mintTime;
        uint256 collateralRatio; // In bps (e.g., 15000 = 150%)
    }

    struct BorrowPosition {
        address user;
        address xStockCollateral;
        uint256 xStockAmount;
        address borrowedAsset;
        uint256 borrowedAmount;
        uint256 borrowTime;
        uint256 interestRate; // Annual rate in bps
        uint256 lastInterestAccrual;
    }

    struct RedeemInfo {
        address xStockAsset;
        uint256 xStockAmount;
        address targetAsset;
        uint256 minOutputAmount;
        uint256 redeemFee; // In bps
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    event XStockMinted(
        address indexed user,
        address indexed xStock,
        uint256 amount,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 collateralRatio
    );

    event XStockRedeemed(
        address indexed user,
        address indexed xStock,
        uint256 xStockAmount,
        address targetAsset,
        uint256 outputAmount,
        uint256 redeemFee
    );

    event XStockBorrowed(
        address indexed user,
        address indexed xStockCollateral,
        uint256 xStockAmount,
        address borrowedAsset,
        uint256 borrowedAmount,
        uint256 interestRate
    );

    event XStockRepaid(
        address indexed user,
        address indexed borrowedAsset,
        uint256 repaidAmount,
        uint256 interestPaid
    );

    event XStockLent(
        address indexed lender,
        address indexed xStock,
        uint256 amount,
        uint256 lendRate
    );

    event XStockWithdrawnFromLend(
        address indexed lender,
        address indexed xStock,
        uint256 amount,
        uint256 earnedInterest
    );

    event CollateralRatioUpdated(
        address indexed user,
        address indexed xStock,
        uint256 oldRatio,
        uint256 newRatio
    );

    event Liquidation(
        address indexed user,
        address indexed xStock,
        uint256 liquidatedAmount,
        address liquidator,
        uint256 collateralSeized
    );

    // ═══════════════════════════════════════════════════════════════════════
    //  Core xStock Operations
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Mint xStock tokens by depositing collateral
    /// @param collateralAsset The asset to use as collateral (e.g., USDC)
    /// @param collateralAmount Amount of collateral to deposit
    /// @param targetXStock The xStock token to mint (e.g., AAPL.x)
    /// @param minMintAmount Minimum amount of xStock to receive (slippage protection)
    /// @param targetCollateralRatio Desired collateral ratio in bps (e.g., 15000 = 150%)
    /// @return mintedAmount The actual amount of xStock minted
    function mintXStock(
        address collateralAsset,
        uint256 collateralAmount,
        address targetXStock,
        uint256 minMintAmount,
        uint256 targetCollateralRatio
    ) external returns (uint256 mintedAmount);

    /// @notice Redeem xStock tokens for underlying or another asset
    /// @param xStockAsset The xStock token to redeem
    /// @param xStockAmount Amount of xStock to redeem
    /// @param targetAsset The asset to receive (can be collateral or different asset)
    /// @param minOutputAmount Minimum output amount (slippage protection)
    /// @return outputAmount The actual amount received
    function redeemXStock(
        address xStockAsset,
        uint256 xStockAmount,
        address targetAsset,
        uint256 minOutputAmount
    ) external returns (uint256 outputAmount);

    /// @notice Borrow assets using xStock as collateral
    /// @param xStockCollateral The xStock token to use as collateral
    /// @param xStockAmount Amount of xStock to lock as collateral
    /// @param borrowAsset The asset to borrow
    /// @param borrowAmount Amount to borrow
    /// @param maxInterestRate Maximum acceptable interest rate in bps
    /// @return actualBorrowAmount The actual amount borrowed (may include fees)
    function borrowWithXStock(
        address xStockCollateral,
        uint256 xStockAmount,
        address borrowAsset,
        uint256 borrowAmount,
        uint256 maxInterestRate
    ) external returns (uint256 actualBorrowAmount);

    /// @notice Repay borrowed position and unlock xStock collateral
    /// @param borrowAsset The borrowed asset to repay
    /// @param repayAmount Amount to repay (use type(uint256).max for full repayment)
    /// @return actualRepaidAmount The actual amount repaid including accrued interest
    /// @return interestPaid The interest portion of the repayment
    function repayBorrow(
        address borrowAsset,
        uint256 repayAmount
    ) external returns (uint256 actualRepaidAmount, uint256 interestPaid);

    /// @notice Lend xStock tokens to earn yield from borrowers
    /// @param xStockAsset The xStock token to lend
    /// @param amount Amount to lend
    /// @param minLendRate Minimum acceptable lending rate in bps
    /// @return lendId Unique identifier for the lending position
    function lendXStock(
        address xStockAsset,
        uint256 amount,
        uint256 minLendRate
    ) external returns (uint256 lendId);

    /// @notice Withdraw lent xStock tokens plus earned interest
    /// @param lendId The lending position ID
    /// @param amount Amount to withdraw (use type(uint256).max for full withdrawal)
    /// @return withdrawnAmount The amount withdrawn
    /// @return earnedInterest The interest earned
    function withdrawLentXStock(
        uint256 lendId,
        uint256 amount
    ) external returns (uint256 withdrawnAmount, uint256 earnedInterest);

    // ═══════════════════════════════════════════════════════════════════════
    //  View Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get mint position details for a user
    function getMintPosition(address user, address xStock) external view returns (MintPosition memory);

    /// @notice Get borrow position details for a user
    function getBorrowPosition(address user, address borrowAsset) external view returns (BorrowPosition memory);

    /// @notice Get lending position details
    function getLendPosition(uint256 lendId) external view returns (
        address lender,
        address xStock,
        uint256 principal,
        uint256 accruedInterest,
        uint256 lendRate,
        uint256 startTime
    );

    /// @notice Calculate collateral ratio for a position
    function getCollateralRatio(address user, address xStock) external view returns (uint256 ratioBps);

    /// @notice Check if a position is eligible for liquidation
    function isLiquidatable(address user, address xStock) external view returns (bool);

    /// @notice Get current borrow interest rate for an asset
    function getBorrowRate(address borrowAsset) external view returns (uint256 rateBps);

    /// @notice Get current lend rate for an xStock
    function getLendRate(address xStockAsset) external view returns (uint256 rateBps);

    /// @notice Get total minted supply of an xStock through this vault
    function getTotalMinted(address xStock) external view returns (uint256);

    /// @notice Get total borrowed amount of an asset
    function getTotalBorrowed(address borrowAsset) external view returns (uint256);

    /// @notice Get total lent amount of an xStock
    function getTotalLent(address xStock) external view returns (uint256);

    /// @notice Get required collateral ratio (minimum)
    function getMinCollateralRatio() external view returns (uint256 ratioBps);

    /// @notice Get liquidation threshold ratio
    function getLiquidationThreshold() external view returns (uint256 ratioBps);

    /// @notice Get liquidation penalty in bps
    function getLiquidationPenalty() external view returns (uint256 penaltyBps);

    // ═══════════════════════════════════════════════════════════════════════
    //  Liquidation Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Liquidate an undercollateralized position
    /// @param user The user with the undercollateralized position
    /// @param xStock The xStock token in the position
    /// @param liquidateAmount Amount of xStock debt to liquidate
    /// @return collateralSeized Amount of collateral seized by liquidator
    function liquidate(
        address user,
        address xStock,
        uint256 liquidateAmount
    ) external returns (uint256 collateralSeized);

    // ═══════════════════════════════════════════════════════════════════════
    //  Administration
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set the minimum collateral ratio
    function setMinCollateralRatio(uint256 newRatioBps) external;

    /// @notice Set the liquidation threshold
    function setLiquidationThreshold(uint256 newThresholdBps) external;

    /// @notice Set the liquidation penalty
    function setLiquidationPenalty(uint256 newPenaltyBps) external;

    /// @notice Register a new xStock token
    function registerXStock(address xStock, address underlying, address priceFeed) external;

    /// @notice Register a borrowable asset
    function registerBorrowAsset(address asset, uint256 initialRateBps) external;

    /// @notice Pause all xStock operations
    function pauseXStockOperations() external;

    /// @notice Unpause xStock operations
    function unpauseXStockOperations() external;
}

/// @title IXStockToken — Interface for xStock ERC20 tokens
/// @notice Standard interface for tokenized stock tokens
interface IXStockToken is IERC20 {
    /// @notice Get the underlying stock symbol (e.g., "AAPL")
    function stockSymbol() external view returns (string memory);

    /// @notice Get the underlying asset per share
    function underlyingPerShare() external view returns (uint256);

    /// @notice Get the oracle price feed for this xStock
    function priceFeed() external view returns (address);

    /// @notice Get the collateral backing this token
    function getCollateralBalance() external view returns (uint256);

    /// @notice Mint new tokens (only callable by authorized minters)
    function mint(address to, uint256 amount) external;

    /// @notice Burn tokens (only callable by authorized burners)
    function burn(address from, uint256 amount) external;
}

/// @title IXStockPriceOracle — Interface for xStock price feeds
/// @notice Aggregates prices from multiple sources for xStock valuation
interface IXStockPriceOracle {
    /// @notice Get the current price of an xStock in USD
    function getXStockPrice(address xStock) external view returns (uint256 price, uint8 decimals);

    /// @notice Get the current price of an xStock in terms of another asset
    function getXStockPriceInAsset(address xStock, address asset) external view returns (uint256 price);

    /// @notice Check if price is fresh (not stale)
    function isPriceFresh(address xStock) external view returns (bool);

    /// @notice Get the last update timestamp
    function lastUpdate(address xStock) external view returns (uint256);

    /// @notice Get price confidence (for aggregated feeds)
    function getPriceConfidence(address xStock) external view returns (uint256 confidenceBps);
}
