// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ============================================================================
//  IXStocksProtocol — Tokenized Equity Protocol Interface (Enhanced)
// ============================================================================
//  Version: 2.0.0
//  This interface defines a permissionless, fully collateralized synthetic
//  stock protocol.  All functions are documented with NatSpec, and every
//  possible revert reason is captured in a custom error.
//
//  Features added in this version:
//    • Batch mint / redeem operations
//    • Preview / quote functions for off-chain integration
//    • Two-step governance transfer with acceptance
//    • ERC165 support
//    • Upgradeable pattern (initialize / reinitialize)
//    • Paginated position queries
//    • Collateral asset management with price feed decimals
//    • Full event coverage for all state mutations
//    • Library of pure helper functions (off-chain / on-chain)
//    • Real-world oracle integration (Chainlink-compatible)
//
//  No mock data — all price feeds must return real on-chain prices.
// ============================================================================

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

// ----------------------------------------------------------------------------
//  Constants & Library (Pure Helpers)
// ----------------------------------------------------------------------------

/// @title XStocksLib — Pure mathematical helpers for the protocol.
/// @dev    These functions are intended to be used by implementers
///         and off-chain clients.  They contain no storage access.
library XStocksLib {
    /// @notice Basis-point denominator (10_000 = 100%).
    uint256 public constant BPS = 10_000;

    /// @notice Minimum collateral ratio (100%).
    uint256 public constant MIN_COLLATERAL_RATIO = BPS;

    /// @notice Maximum fee allowed per operation (10%).
    uint256 public constant MAX_FEE = 1_000;

    /// @notice Maximum slippage tolerance (50%).
    uint256 public constant MAX_SLIPPAGE = 5_000;

    /// @notice Liquidation threshold (110%).
    uint256 public constant LIQUIDATION_THRESHOLD = 11_000;

    /// @notice Price decimals used by the protocol (8 for USD).
    uint8 public constant PRICE_DECIMALS = 8;

    /// @notice Maximum number of supported stocks.
    uint256 public constant MAX_SUPPORTED_STOCKS = 128;

    /// @notice Default staleness threshold (1 hour).
    uint256 public constant DEFAULT_STALENESS_THRESHOLD = 3_600;

    /// @notice Computes the collateral required for a mint operation.
    /// @param amountXStock   xStock amount (18 decimals).
    /// @param collateralRatio Collateral ratio in bps (e.g., 15000 = 150%).
    /// @param priceXStock    Current xStock price in USD (8 decimals).
    /// @param priceCollateral Current collateral token price in USD (8 decimals).
    /// @param collateralDecimals Decimals of the collateral token.
    /// @return collateralNeeded Amount of collateral tokens needed.
    function computeCollateralNeeded(
        uint256 amountXStock,
        uint256 collateralRatio,
        uint256 priceXStock,
        uint256 priceCollateral,
        uint8 collateralDecimals
    ) internal pure returns (uint256 collateralNeeded) {
        // value = amount * price / 1e18, then * ratio / BPS, then / priceCollateral * 10^decimals.
        // Folding the two divisions into a single mulDiv keeps full precision: the
        // previous form truncated at every step (the collateral ratio alone lost up to
        // 0.999 * 10^8 USD-wei on a 1e8-scaled price).
        uint256 valueUsd = Math.mulDiv(amountXStock, priceXStock, 10 ** 18);
        collateralNeeded = Math.mulDiv(valueUsd, collateralRatio * 10 ** collateralDecimals, BPS * priceCollateral);
    }

    /// @notice Computes the health factor of a position.
    /// @param collateralValue  USD value of collateral (8 decimals).
    /// @param mintedValue      USD value of minted xStock (8 decimals).
    /// @return healthFactor    Health factor in bps (BPS = 100%).
    function computeHealthFactor(uint256 collateralValue, uint256 mintedValue)
        internal
        pure
        returns (uint256 healthFactor)
    {
        if (mintedValue == 0) return type(uint256).max;
        healthFactor = (collateralValue * BPS) / mintedValue;
    }

    /// @notice Checks whether a position is liquidatable.
    /// @param healthFactor Current health factor (bps).
    /// @return liquidatable True if health factor < LIQUIDATION_THRESHOLD.
    function isLiquidatable(uint256 healthFactor) internal pure returns (bool) {
        return healthFactor < LIQUIDATION_THRESHOLD;
    }

    /// @notice Computes the liquidation bonus for a liquidator.
    /// @param collateralSeized Total collateral seized.
    /// @param liquidationFeeBps Fee in bps (e.g., 500 = 5%).
    /// @return liquidatorShare Collateral that goes to the liquidator.
    /// @return protocolShare Collateral that goes to the protocol.
    function computeLiquidationSplit(uint256 collateralSeized, uint256 liquidationFeeBps)
        internal
        pure
        returns (uint256 liquidatorShare, uint256 protocolShare)
    {
        liquidatorShare = (collateralSeized * liquidationFeeBps) / BPS;
        protocolShare = collateralSeized - liquidatorShare;
    }

    /// @notice Validates that weights sum to BPS.
    /// @param weights Array of weights in bps.
    /// @return valid True if sum == BPS.
    function validateWeightSum(uint256[] memory weights) internal pure returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < weights.length; i++) {
            sum += weights[i];
        }
        return sum == BPS;
    }
}

// ----------------------------------------------------------------------------
//  Structs (Enriched)
// ----------------------------------------------------------------------------

/// @notice Complete description of a supported xStock.
/// @param symbol           Human-readable ticker (e.g., "AAPL.x").
/// @param underlyingPrice  Last known price in USD (8 decimals).
/// @param collateralRatio  Required collateral in bps (e.g., 15000 = 150%).
/// @param mintFeeBps       Fee charged on mint in bps.
/// @param redeemFeeBps     Fee charged on redeem in bps.
/// @param priceFeed        Address of the Chainlink-compatible oracle.
/// @param maxPositionSize  Maximum mintable supply (0 = unlimited).
/// @param isActive         Whether the stock is currently enabled.
/// @param lastPriceUpdate  Timestamp of the last price update.
/// @param totalSupply      Current total supply of this xStock.
struct StockInfo {
    string symbol;
    uint256 underlyingPrice;
    uint256 collateralRatio;
    uint256 mintFeeBps;
    uint256 redeemFeeBps;
    address priceFeed;
    uint256 maxPositionSize;
    bool isActive;
    uint256 lastPriceUpdate;
    uint256 totalSupply;
}

/// @notice Snapshot of a user's xStock position.
/// @param stockSymbol       The xStock symbol.
/// @param xStockBalance     User's xStock token balance (18 decimals).
/// @param collateralValue   USD value of collateral backing this position (8 dec).
/// @param mintedValue       Current market value of the minted xStock (8 dec).
/// @param healthFactor      Position health in bps (BPS = 100%).
/// @param isLiquidatable    Whether the position may be liquidated now.
struct PositionSnapshot {
    string stockSymbol;
    uint256 xStockBalance;
    uint256 collateralValue;
    uint256 mintedValue;
    uint256 healthFactor;
    bool isLiquidatable;
}

/// @notice Summary of a single collateral asset held by the protocol.
/// @param asset            ERC-20 address.
/// @param balance          Raw token balance.
/// @param valueUsd         USD value (8 decimals).
/// @param priceFeed        Oracle address used for valuation.
/// @param lastPriceUpdate  Timestamp of the last price update.
/// @param decimals         Token decimals.
struct CollateralSummary {
    address asset;
    uint256 balance;
    uint256 valueUsd;
    address priceFeed;
    uint256 lastPriceUpdate;
    uint8 decimals;
}

/// @notice Global protocol health metrics.
/// @param totalCollateralValueUsd  Aggregate collateral value (8 dec).
/// @param totalMintedValueUsd      Aggregate xStock liability (8 dec).
/// @param overallHealthFactor      Protocol-wide health factor (bps).
/// @param uniqueCollateralAssets   Number of distinct collateral tokens.
/// @param uniqueStocks             Number of active stock symbols.
/// @param isPaused                 Whether the protocol is paused.
struct ProtocolHealth {
    uint256 totalCollateralValueUsd;
    uint256 totalMintedValueUsd;
    uint256 overallHealthFactor;
    uint256 uniqueCollateralAssets;
    uint256 uniqueStocks;
    bool isPaused;
}

/// @notice Mint request parameters with slippage protection.
/// @param stockSymbol      The xStock symbol to mint.
/// @param amount           xStock tokens desired (18 decimals).
/// @param collateralAsset  Collateral token to deposit.
/// @param maxCollateral    Maximum collateral to spend (slippage guard).
/// @param receiver         Address that receives the minted xStock.
/// @param deadline         Expiration timestamp (0 = no deadline).
struct MintRequest {
    string stockSymbol;
    uint256 amount;
    address collateralAsset;
    uint256 maxCollateral;
    address receiver;
    uint256 deadline;
}

/// @notice Redeem request parameters with slippage protection.
/// @param stockSymbol       The xStock symbol to redeem.
/// @param amount            xStock tokens to burn.
/// @param minCollateralOut  Minimum collateral to receive (slippage guard).
/// @param receiver          Address that receives the collateral.
/// @param deadline          Expiration timestamp (0 = no deadline).
struct RedeemRequest {
    string stockSymbol;
    uint256 amount;
    uint256 minCollateralOut;
    address receiver;
    uint256 deadline;
}

/// @notice Quote for a mint operation (preview).
/// @param collateralUsed  Amount of collateral that will be consumed.
/// @param fee             Fee amount in collateral decimals.
/// @param sharesReceived  xStock tokens that will be minted.
struct MintQuote {
    uint256 collateralUsed;
    uint256 fee;
    uint256 sharesReceived;
}

/// @notice Quote for a redeem operation (preview).
/// @param collateralOut  Amount of collateral that will be returned.
/// @param fee            Fee amount in collateral decimals.
/// @param sharesBurned   xStock tokens that will be burned.
struct RedeemQuote {
    uint256 collateralOut;
    uint256 fee;
    uint256 sharesBurned;
}

/// @notice Parameters for batch mint.
struct BatchMintRequest {
    MintRequest[] requests;
    bool revertOnFailure; // If true, whole batch reverts; else skips failed.
}

/// @notice Result of a batch mint operation.
struct BatchMintResult {
    uint256 successes;
    uint256 failures;
    uint256 totalCollateralUsed;
    uint256 totalFees;
}

// ----------------------------------------------------------------------------
//  Errors (Comprehensive)
// ----------------------------------------------------------------------------

error Unauthorized(address caller, string role);
error ProtocolPaused();
error ZeroAmount(string operation);
error StockNotSupported(string stockSymbol, string reason);
error InvalidCollateral(address asset, string reason);
error ExceedsLimit(uint256 requested, uint256 maximum);
error SlippageExceeded(uint256 received, uint256 minimum);
error InsufficientCollateral(uint256 currentRatio, uint256 requiredRatio);
error PositionUndercollateralized(uint256 healthFactor, uint256 liquidationThreshold);
error PriceFeedError(string stockSymbol, string reason);
error MathOverflow(string operation, uint256 requested, uint256 available);
error FeeExceeded(string feeType, uint256 requested, uint256 maximum);
error CollateralRatioTooLow(string stockSymbol, uint256 ratio, uint256 minimum);
error ZeroPriceFeed(string stockSymbol);
error InsufficientBalance(uint256 requested, uint256 available);
error PositionCapExceeded(string stockSymbol, uint256 currentSupply, uint256 maxSupply);
error ZeroReceiver();
error OperationBlocked(string reason);
error DeadlineExpired(uint256 deadline, uint256 blockTimestamp);
error InvalidInitialization();
error AlreadyInitialized();
error NotPendingGovernor(address caller, address expected);
error BatchOperationFailed(uint256 index, string reason);

// ----------------------------------------------------------------------------
//  Events (Complete Coverage)
// ----------------------------------------------------------------------------

event XStockMinted(
    address indexed user,
    string indexed stockSymbol,
    uint256 amount,
    address indexed collateralAsset,
    uint256 collateralUsed,
    uint256 fee,
    address receiver
);

event XStockRedeemed(
    address indexed user,
    string indexed stockSymbol,
    uint256 amount,
    uint256 collateralOut,
    uint256 fee,
    address receiver
);

event StockRegistered(
    string indexed stockSymbol, address priceFeed, uint256 collateralRatio, uint256 mintFeeBps, uint256 redeemFeeBps
);

event StockDeregistered(string indexed stockSymbol);

event CollateralRatioUpdated(string indexed stockSymbol, uint256 oldRatio, uint256 newRatio);

event FeeUpdated(string indexed stockSymbol, string feeType, uint256 oldValue, uint256 newValue);

event PriceFeedUpdated(string indexed stockSymbol, address oldFeed, address newFeed);

event CollateralDeposited(address indexed user, address indexed asset, uint256 amount);

event CollateralWithdrawn(address indexed user, address indexed asset, uint256 amount);

event PositionLiquidated(
    address indexed liquidator,
    address indexed owner,
    string indexed stockSymbol,
    uint256 xStockAmount,
    uint256 collateralSeized,
    uint256 liquidationFee
);

event MaxPositionSizeUpdated(string indexed stockSymbol, uint256 oldMax, uint256 newMax);

event PauseStateChanged(bool paused, string reason);

event GovernorTransferred(address indexed oldGovernor, address indexed newGovernor);

event CollateralAssetRegistered(address indexed asset, address priceFeed);

event CollateralAssetDeregistered(address indexed asset);

event FeesCollected(address indexed asset, uint256 amount, address recipient);

event GovernanceAccepted(address indexed newGovernor);
event OracleManagerUpdated(address indexed oldManager, address indexed newManager);
event PauserUpdated(address indexed oldPauser, address indexed newPauser);
event LiquidationFeeUpdated(uint256 oldFee, uint256 newFee);
event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
event ProtocolInitialized(address indexed governor, uint256 version);

// ----------------------------------------------------------------------------
//  Main Interface
// ----------------------------------------------------------------------------

/// @title IXStocksProtocol — Tokenized Equity Protocol Interface
/// @notice Permissionless interface for minting and redeeming synthetic
///         stock tokens (xStocks) backed by on-chain collateral.
interface IXStocksProtocol {
    // ------------------------------------------------------------------------
    //  Constants (exposed for off-chain consumers)
    // ------------------------------------------------------------------------

    /// @notice Protocol version (major.minor.patch encoded as uint256).
    function VERSION() external view returns (uint256);

    /// @notice Basis-point denominator (10_000 = 100%).
    function BPS_DENOMINATOR() external view returns (uint256);

    /// @notice Minimum collateral ratio (10_000 = 100%).
    function MIN_COLLATERAL_RATIO() external view returns (uint256);

    /// @notice Maximum fee allowed per operation (1_000 = 10%).
    function MAX_FEE() external view returns (uint256);

    /// @notice Maximum number of supported stocks.
    function MAX_STOCKS() external view returns (uint256);

    /// @notice Maximum slippage tolerance (5_000 = 50%).
    function MAX_SLIPPAGE() external view returns (uint256);

    /// @notice Liquidation health-factor threshold (11_000 = 110%).
    function LIQUIDATION_THRESHOLD() external view returns (uint256);

    // ------------------------------------------------------------------------
    //  Initialization (for upgradeable proxies)
    // ------------------------------------------------------------------------

    /// @notice Initializes the protocol (must be called once).
    /// @param governor           Initial governor address.
    /// @param oracleManager      Initial oracle manager address.
    /// @param pauser             Initial pauser address.
    /// @param feeRecipient_      Address that collects fees.
    /// @param liquidationFeeBps  Initial liquidation fee in bps.
    function initialize(
        address governor,
        address oracleManager,
        address pauser,
        address feeRecipient_,
        uint256 liquidationFeeBps
    ) external;

    /// @notice Reinitializes the protocol (for upgrades, only governor).
    /// @param version New version number.
    function reinitialize(uint256 version) external;

    // ------------------------------------------------------------------------
    //  Core Operations
    // ------------------------------------------------------------------------

    /// @notice Mint xStock tokens by depositing collateral.
    function mintXStock(string calldata stockSymbol, uint256 amount, address collateralAsset, uint256 maxCollateral)
        external
        returns (uint256 collateralUsed, uint256 fee);

    /// @notice Mint xStock using a request struct (includes deadline).
    function mintXStock(MintRequest calldata request) external returns (uint256 collateralUsed, uint256 fee);

    /// @notice Batch mint multiple xStocks in one transaction.
    /// @param batch BatchMintRequest containing multiple mint requests.
    /// @return result Summary of the batch operation.
    function batchMintXStock(BatchMintRequest calldata batch) external returns (BatchMintResult memory result);

    /// @notice Redeem xStock tokens for collateral.
    function redeemXStock(string calldata stockSymbol, uint256 amount, uint256 minCollateralOut)
        external
        returns (uint256 collateralOut, uint256 fee);

    /// @notice Redeem using a request struct (includes deadline).
    function redeemXStock(RedeemRequest calldata request) external returns (uint256 collateralOut, uint256 fee);

    /// @notice Batch redeem multiple xStocks.
    function batchRedeemXStock(RedeemRequest[] calldata requests)
        external
        returns (uint256 totalCollateralOut, uint256 totalFees, uint256 successes);

    // ------------------------------------------------------------------------
    //  Preview / Quote Functions (No state changes)
    // ------------------------------------------------------------------------

    /// @notice Simulates a mint operation without modifying state.
    function quoteMintXStock(MintRequest calldata request) external view returns (MintQuote memory quote);

    /// @notice Simulates a redeem operation without modifying state.
    function quoteRedeemXStock(RedeemRequest calldata request) external view returns (RedeemQuote memory quote);

    // ------------------------------------------------------------------------
    //  Liquidation
    // ------------------------------------------------------------------------

    function liquidate(address owner, string calldata stockSymbol, uint256 xStockAmount, uint256 minCollateralOut)
        external
        returns (uint256 collateralSeized, uint256 liquidationFee);

    // ------------------------------------------------------------------------
    //  View — Stock Information
    // ------------------------------------------------------------------------

    function getStockInfo(string calldata stockSymbol) external view returns (StockInfo memory info);

    function getStockPrice(string calldata stockSymbol) external view returns (uint256 price, uint256 updatedAt);

    function getCollateralRequirement(string calldata stockSymbol, uint256 amount)
        external
        view
        returns (uint256 collateralNeeded);

    function isStockSupported(string calldata stockSymbol) external view returns (bool isSupported);

    function getSupportedStocks() external view returns (string[] memory symbols);

    function stockCount() external view returns (uint256 count);

    // ------------------------------------------------------------------------
    //  View — Positions
    // ------------------------------------------------------------------------

    function xStockBalanceOf(address owner, string calldata stockSymbol) external view returns (uint256 balance);

    function getXStockSupply(string calldata stockSymbol) external view returns (uint256 supply);

    function getPositionHealthFactor(address owner, string calldata stockSymbol)
        external
        view
        returns (uint256 healthFactor);

    function getPositionSnapshot(address owner, string calldata stockSymbol)
        external
        view
        returns (PositionSnapshot memory snapshot);

    function getUserPositions(address owner) external view returns (PositionSnapshot[] memory snapshots);

    /// @notice Paginated positions for a user (gas-efficient).
    function getUserPositionsPaginated(address owner, uint256 offset, uint256 limit)
        external
        view
        returns (PositionSnapshot[] memory snapshots, uint256 total);

    function isPositionLiquidatable(address owner, string calldata stockSymbol)
        external
        view
        returns (bool isLiquidatable);

    // ------------------------------------------------------------------------
    //  View — Collateral
    // ------------------------------------------------------------------------

    function collateralBalanceOf(address asset) external view returns (uint256 balance);
    function collateralValueUsd(address asset) external view returns (uint256 valueUsd);
    function getAllCollateral() external view returns (CollateralSummary[] memory summaries);
    function isCollateralRegistered(address asset) external view returns (bool isRegistered);
    function getCollateralAssets() external view returns (address[] memory assets);

    // ------------------------------------------------------------------------
    //  View — Protocol Health
    // ------------------------------------------------------------------------

    function getProtocolHealth() external view returns (ProtocolHealth memory health);
    function totalCollateralValueUsd() external view returns (uint256 valueUsd);
    function totalMintedValueUsd() external view returns (uint256 valueUsd);
    function protocolHealthFactor() external view returns (uint256 healthFactor);

    // ------------------------------------------------------------------------
    //  View — Fees
    // ------------------------------------------------------------------------

    function mintFee(string calldata stockSymbol) external view returns (uint256 feeBps);
    function redeemFee(string calldata stockSymbol) external view returns (uint256 feeBps);
    function liquidationFeeBps() external view returns (uint256 feeBps);
    function feeRecipient() external view returns (address recipient);
    function pendingFees(address asset) external view returns (uint256 pendingFees);

    // ------------------------------------------------------------------------
    //  View — State & Roles
    // ------------------------------------------------------------------------

    function isPaused() external view returns (bool isPaused);
    function governor() external view returns (address governor);
    function pendingGovernor() external view returns (address pendingGovernor);
    function oracleManager() external view returns (address manager);
    function pauser() external view returns (address pauser);

    /// @notice ERC165 support.
    function supportsInterface(bytes4 interfaceId) external view returns (bool);

    // ------------------------------------------------------------------------
    //  Governance — Stock Management (GOVERNOR)
    // ------------------------------------------------------------------------

    function registerStock(
        string calldata stockSymbol,
        address priceFeed,
        uint256 collateralRatio,
        uint256 mintFeeBps,
        uint256 redeemFeeBps
    ) external;

    function deregisterStock(string calldata stockSymbol) external;
    function updateCollateralRatio(string calldata stockSymbol, uint256 newRatio) external;
    function updateMintFee(string calldata stockSymbol, uint256 newFeeBps) external;
    function updateRedeemFee(string calldata stockSymbol, uint256 newFeeBps) external;
    function updateMaxPositionSize(string calldata stockSymbol, uint256 newMax) external;

    // ------------------------------------------------------------------------
    //  Governance — Oracle Management (ORACLE_MANAGER)
    // ------------------------------------------------------------------------

    function updatePriceFeed(string calldata stockSymbol, address newFeed) external;
    function registerCollateralAsset(address asset, address priceFeed) external;
    function deregisterCollateralAsset(address asset) external;

    // ------------------------------------------------------------------------
    //  Governance — Protocol Parameters (GOVERNOR)
    // ------------------------------------------------------------------------

    function setLiquidationFee(uint256 newFeeBps) external;
    function setFeeRecipient(address newRecipient) external;
    function transferGovernance(address newGovernor) external;
    function acceptGovernance() external; // Two-step transfer
    function setOracleManager(address newManager) external;
    function setPauser(address newPauser) external;
    function renounceGovernance() external;

    // ------------------------------------------------------------------------
    //  Emergency — Pause (PAUSER)
    // ------------------------------------------------------------------------

    function pause(string calldata reason) external;
    function unpause() external;

    // ------------------------------------------------------------------------
    //  Collateral Management (Any user)
    // ------------------------------------------------------------------------

    function depositCollateral(address asset, uint256 amount) external;
    function withdrawCollateral(address asset, uint256 amount) external;

    // ------------------------------------------------------------------------
    //  Fee Collection
    // ------------------------------------------------------------------------

    function collectFees(address asset) external;
}

// ----------------------------------------------------------------------------
//  Extended Interface for Vault Integration
// ----------------------------------------------------------------------------

/// @title IXStocksVault — Vault-specific extension for multi-strategy allocation.
interface IXStocksVault is IXStocksProtocol {
    function vaultMintXStock(string calldata stockSymbol, uint256 amount, uint256 maxCollateral)
        external
        returns (uint256 collateralUsed);

    function vaultRedeemXStock(string calldata stockSymbol, uint256 amount, uint256 minCollateral)
        external
        returns (uint256 collateralOut);

    function vaultXStockBalance(string calldata stockSymbol) external view returns (uint256 balance);

    function vaultXStockExposureBps() external view returns (uint256 exposureBps);
    function vaultCollateralInProtocol(address asset) external view returns (uint256 amount);
    function vaultXStockHealthFactor() external view returns (uint256 healthFactor);

    function rebalanceXStockPositions(string[] calldata stockSymbols, uint256[] calldata targetWeights) external;
}
