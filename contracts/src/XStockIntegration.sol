// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IXStockVault, IXStockToken, IXStockPriceOracle } from "./interfaces/IXStockVault.sol";
import { IStockPriceFeed } from "./interfaces/IVaultKeeper.sol";

/// @title XStockIntegration — Production xStocks Protocol Integration
/// @notice Implements full borrow/lend/mint/redeem flows for xStock tokens
/// @dev Integrates with external xStock protocols (Avalon, etc.) for tokenized equities
// Helper interface for ERC20 with decimals
interface IERC20Metadata {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}

contract XStockIntegration is IXStockVault, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════════════

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MAX_INTEREST_RATE = 5000; // 50% max APR
    uint256 public constant MIN_COLLATERAL_RATIO = 12_000; // 120% minimum
    uint256 public constant LIQUIDATION_THRESHOLD_DEFAULT = 11_000; // 110%
    uint256 public constant LIQUIDATION_PENALTY_DEFAULT = 500; // 5%
    uint256 public constant DEFAULT_STALENESS_THRESHOLD = 1 hours;

    // ═══════════════════════════════════════════════════════════════════════
    //  State Variables
    // ═══════════════════════════════════════════════════════════════════════

    // xStock token configurations
    struct XStockConfig {
        address underlying;
        address priceFeed;
        bool isRegistered;
        uint256 totalMinted;
        uint256 totalLent;
        uint256 currentLendRate;
    }

    // Borrowable asset configurations
    struct BorrowAssetConfig {
        bool isRegistered;
        uint256 totalBorrowed;
        uint256 currentBorrowRate;
        uint256 interestRateModel; // 0 = fixed, 1 = dynamic based on utilization
    }

    // User positions
    mapping(address => mapping(address => MintPosition)) private _mintPositions;
    mapping(address => mapping(address => BorrowPosition)) private _borrowPositions;

    // Global state
    mapping(address => XStockConfig) public xStockConfigs;
    mapping(address => BorrowAssetConfig) public borrowConfigs;
    mapping(uint256 => LendingPosition) private _lendPositions;

    uint256 private _nextLendId = 1;
    uint256 public minCollateralRatio;
    uint256 public liquidationThreshold;
    uint256 public liquidationPenalty;
    address public priceOracle;

    // ═══════════════════════════════════════════════════════════════════════
    //  Structs
    // ═══════════════════════════════════════════════════════════════════════

    struct LendingPosition {
        address lender;
        address xStock;
        uint256 principal;
        uint256 accruedInterest;
        uint256 lendRate;
        uint256 startTime;
        uint256 lastUpdate;
        bool isActive;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Events (additional to interface)
    // ═══════════════════════════════════════════════════════════════════════

    event InterestAccrued(address indexed user, address indexed asset, uint256 interestAmount, uint256 newTotalDebt);

    event RatesUpdated(address indexed xStock, uint256 newLendRate, address indexed borrowAsset, uint256 newBorrowRate);

    // Additional events for admin functions
    event AssetRegistered(address indexed asset);
    event PauseStateChanged(bool paused, string reason);

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error InvalidXStock(address xStock);
    error InvalidCollateralRatio(uint256 provided, uint256 minimum);
    error InsufficientCollateral(uint256 required, uint256 available);
    error PositionNotFound(address user, address xStock);
    error BorrowPositionNotFound(address user, address asset);
    error LendPositionNotFound(uint256 lendId);
    error InterestRateTooHigh(uint256 requested, uint256 maximum);
    error PositionNotLiquidatable(address user, address xStock);
    error SlippageExceeded(uint256 expected, uint256 received);
    error PriceFeedUnavailable(address xStock);
    error PriceFeedStale(address xStock, uint256 updatedAt);
    error InvalidAmount();
    error AssetNotRegistered(address asset);
    error NoActiveLendPosition();
    error UnauthorizedLiquidator();

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    constructor(address _priceOracle, address initialOwner) Ownable(initialOwner) {
        if (_priceOracle == address(0)) revert InvalidXStock(address(0));
        priceOracle = _priceOracle;
        minCollateralRatio = MIN_COLLATERAL_RATIO;
        liquidationThreshold = LIQUIDATION_THRESHOLD_DEFAULT;
        liquidationPenalty = LIQUIDATION_PENALTY_DEFAULT;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Core xStock Operations
    // ═══════════════════════════════════════════════════════════════════════

    function mintXStock(
        address collateralAsset,
        uint256 collateralAmount,
        address targetXStock,
        uint256 minMintAmount,
        uint256 targetCollateralRatio
    ) external override nonReentrant whenNotPaused returns (uint256 mintedAmount) {
        if (!xStockConfigs[targetXStock].isRegistered) revert InvalidXStock(targetXStock);
        if (collateralAmount == 0) revert InvalidAmount();
        if (targetCollateralRatio < minCollateralRatio) {
            revert InvalidCollateralRatio(targetCollateralRatio, minCollateralRatio);
        }

        // Transfer collateral from user
        IERC20(collateralAsset).safeTransferFrom(msg.sender, address(this), collateralAmount);

        // Calculate mint amount based on collateral value
        uint256 collateralValue = _getCollateralValue(collateralAsset, collateralAmount);
        uint256 xStockPrice = _getXStockPrice(targetXStock);

        // mintAmount = (collateralValue * BPS) / (targetRatio * xStockPrice)
        mintedAmount = (collateralValue * BPS_DENOMINATOR) / (targetCollateralRatio * xStockPrice / 1e8);

        if (mintedAmount < minMintAmount) revert SlippageExceeded(minMintAmount, mintedAmount);

        // Update state
        xStockConfigs[targetXStock].totalMinted += mintedAmount;
        _mintPositions[msg.sender][targetXStock] = MintPosition({
            user: msg.sender,
            collateralAsset: collateralAsset,
            collateralAmount: collateralAmount,
            mintedXStock: mintedAmount,
            mintTime: block.timestamp,
            collateralRatio: targetCollateralRatio
        });

        // Mint xStock tokens to user
        IXStockToken(targetXStock).mint(msg.sender, mintedAmount);

        emit XStockMinted(
            msg.sender, targetXStock, mintedAmount, collateralAsset, collateralAmount, targetCollateralRatio
        );
    }

    function redeemXStock(address xStockAsset, uint256 xStockAmount, address targetAsset, uint256 minOutputAmount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 outputAmount)
    {
        MintPosition storage position = _mintPositions[msg.sender][xStockAsset];
        if (position.mintedXStock == 0) revert PositionNotFound(msg.sender, xStockAsset);
        if (xStockAmount == 0 || xStockAmount > position.mintedXStock) revert InvalidAmount();

        // Calculate redemption value
        uint256 xStockPrice = _getXStockPrice(xStockAsset);
        uint256 redemptionValue = (xStockAmount * xStockPrice) / 1e8;

        // Apply redemption fee (0.5%). Fee basis points are an immutable constant here,
        // so folding the multiply into the divide loses nothing.
        uint256 redeemFee = Math.mulDiv(redemptionValue, 50, BPS_DENOMINATOR);
        outputAmount = redemptionValue - redeemFee;

        if (outputAmount < minOutputAmount) revert SlippageExceeded(minOutputAmount, outputAmount);

        // Update position
        position.mintedXStock -= xStockAmount;
        uint256 collateralToReturn = (position.collateralAmount * xStockAmount) / (position.mintedXStock + xStockAmount); // Original total
        position.collateralAmount -= collateralToReturn;

        xStockConfigs[xStockAsset].totalMinted -= xStockAmount;

        // Burn xStock tokens. The position has already been debited above and this
        // entrypoint is nonReentrant, so the external call cannot re-enter with a
        // half-updated position.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IXStockToken(xStockAsset).burn(msg.sender, xStockAmount);

        // Return collateral
        IERC20(targetAsset).safeTransfer(msg.sender, collateralToReturn);

        emit XStockRedeemed(msg.sender, xStockAsset, xStockAmount, targetAsset, outputAmount, redeemFee);

        // Clean up position if fully redeemed
        if (position.mintedXStock == 0) {
            delete _mintPositions[msg.sender][xStockAsset];
        }
    }

    function borrowWithXStock(
        address xStockCollateral,
        uint256 xStockAmount,
        address borrowAsset,
        uint256 borrowAmount,
        uint256 maxInterestRate
    ) external override nonReentrant whenNotPaused returns (uint256 actualBorrowAmount) {
        if (!xStockConfigs[xStockCollateral].isRegistered) {
            revert InvalidXStock(xStockCollateral);
        }
        if (!borrowConfigs[borrowAsset].isRegistered) revert AssetNotRegistered(borrowAsset);

        uint256 currentBorrowRate = getBorrowRate(borrowAsset);
        if (currentBorrowRate > maxInterestRate) {
            revert InterestRateTooHigh(currentBorrowRate, maxInterestRate);
        }

        // Transfer xStock collateral
        IERC20(xStockCollateral).safeTransferFrom(msg.sender, address(this), xStockAmount);

        // Calculate collateral value and borrowing limit
        uint256 collateralValue = _getXStockValue(xStockCollateral, xStockAmount);
        uint256 maxBorrow = (collateralValue * BPS_DENOMINATOR) / minCollateralRatio;

        if (borrowAmount > maxBorrow) revert InsufficientCollateral(maxBorrow, borrowAmount);

        actualBorrowAmount = borrowAmount;

        // Update borrow position
        _borrowPositions[msg.sender][borrowAsset] = BorrowPosition({
            user: msg.sender,
            xStockCollateral: xStockCollateral,
            xStockAmount: xStockAmount,
            borrowedAsset: borrowAsset,
            borrowedAmount: actualBorrowAmount,
            borrowTime: block.timestamp,
            interestRate: currentBorrowRate,
            lastInterestAccrual: block.timestamp
        });

        borrowConfigs[borrowAsset].totalBorrowed += actualBorrowAmount;

        // Transfer borrowed assets
        IERC20(borrowAsset).safeTransfer(msg.sender, actualBorrowAmount);

        emit XStockBorrowed(
            msg.sender, xStockCollateral, xStockAmount, borrowAsset, actualBorrowAmount, currentBorrowRate
        );
    }

    function repayBorrow(address borrowAsset, uint256 repayAmount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 actualRepaidAmount, uint256 interestPaid)
    {
        BorrowPosition storage position = _borrowPositions[msg.sender][borrowAsset];
        if (position.borrowedAmount == 0) revert BorrowPositionNotFound(msg.sender, borrowAsset);

        // Accrue interest
        uint256 interest = _calculateAccruedInterest(msg.sender, borrowAsset);

        uint256 totalOwed = position.borrowedAmount + interest;
        actualRepaidAmount = repayAmount == type(uint256).max ? totalOwed : repayAmount;

        if (actualRepaidAmount > totalOwed) actualRepaidAmount = totalOwed;

        interestPaid = interest;
        uint256 principalRepaid = actualRepaidAmount > interest ? actualRepaidAmount - interest : 0;

        // Update position
        position.borrowedAmount -= principalRepaid;
        position.lastInterestAccrual = block.timestamp;

        borrowConfigs[borrowAsset].totalBorrowed -= principalRepaid;

        // Transfer repayment
        IERC20(borrowAsset).safeTransferFrom(msg.sender, address(this), actualRepaidAmount);

        // Return collateral if fully repaid
        if (position.borrowedAmount == 0) {
            IERC20(position.xStockCollateral).safeTransfer(msg.sender, position.xStockAmount);
            emit XStockWithdrawnFromLend(msg.sender, position.xStockCollateral, position.xStockAmount, 0);
            delete _borrowPositions[msg.sender][borrowAsset];
        }

        emit XStockRepaid(msg.sender, borrowAsset, actualRepaidAmount, interestPaid);
    }

    function lendXStock(address xStockAsset, uint256 amount, uint256 minLendRate)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 lendId)
    {
        if (!xStockConfigs[xStockAsset].isRegistered) revert InvalidXStock(xStockAsset);
        if (amount == 0) revert InvalidAmount();

        uint256 currentLendRate = getLendRate(xStockAsset);
        if (currentLendRate < minLendRate) revert InterestRateTooHigh(minLendRate, currentLendRate);

        lendId = _nextLendId++;

        // Transfer xStock from lender
        IERC20(xStockAsset).safeTransferFrom(msg.sender, address(this), amount);

        // Create lending position
        _lendPositions[lendId] = LendingPosition({
            lender: msg.sender,
            xStock: xStockAsset,
            principal: amount,
            accruedInterest: 0,
            lendRate: currentLendRate,
            startTime: block.timestamp,
            lastUpdate: block.timestamp,
            isActive: true
        });

        xStockConfigs[xStockAsset].totalLent += amount;

        emit XStockLent(msg.sender, xStockAsset, amount, currentLendRate);
    }

    function withdrawLentXStock(uint256 lendId, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 withdrawnAmount, uint256 earnedInterest)
    {
        LendingPosition storage position = _lendPositions[lendId];
        if (!position.isActive) revert LendPositionNotFound(lendId);
        if (position.lender != msg.sender) revert UnauthorizedLiquidator();

        // Accrue interest
        earnedInterest = _calculateLendInterest(lendId);
        position.accruedInterest += earnedInterest;

        uint256 totalAvailable = position.principal + position.accruedInterest;
        withdrawnAmount = amount == type(uint256).max ? totalAvailable : amount;

        if (withdrawnAmount > totalAvailable) revert InsufficientCollateral(totalAvailable, withdrawnAmount);

        // Update position
        if (withdrawnAmount >= position.accruedInterest) {
            uint256 principalWithdrawn = withdrawnAmount - position.accruedInterest;
            position.principal -= principalWithdrawn;
            position.accruedInterest = 0;
        } else {
            position.accruedInterest -= withdrawnAmount;
        }

        position.lastUpdate = block.timestamp;

        // Update global state
        xStockConfigs[position.xStock].totalLent -= withdrawnAmount > position.principal + position.accruedInterest
            ? position.principal
            : withdrawnAmount;

        // Close position if fully withdrawn
        if (position.principal == 0) {
            position.isActive = false;
        }

        // Transfer funds
        IERC20(position.xStock).safeTransfer(msg.sender, withdrawnAmount);

        emit XStockWithdrawnFromLend(msg.sender, position.xStock, withdrawnAmount, earnedInterest);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Liquidation
    // ═══════════════════════════════════════════════════════════════════════

    function liquidate(address user, address xStock, uint256 liquidateAmount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 collateralSeized)
    {
        if (!isLiquidatable(user, xStock)) revert PositionNotLiquidatable(user, xStock);

        MintPosition storage position = _mintPositions[user][xStock];

        // Calculate liquidation amount and penalty
        uint256 xStockPrice = _getXStockPrice(xStock);
        uint256 liquidationValue = (liquidateAmount * xStockPrice) / 1e8;

        // Liquidator gets collateral + penalty
        collateralSeized = liquidationValue + Math.mulDiv(liquidationValue, liquidationPenalty, BPS_DENOMINATOR);

        // Burn liquidated xStock. Position updated first; `liquidate` is nonReentrant.
        position.mintedXStock -= liquidateAmount;
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IXStockToken(xStock).burn(user, liquidateAmount);

        // Transfer seized collateral to liquidator
        IERC20(position.collateralAsset).safeTransfer(msg.sender, collateralSeized);

        // Update remaining position
        uint256 remainingCollateral =
            (position.collateralAmount * position.mintedXStock) / (position.mintedXStock + liquidateAmount);
        position.collateralAmount = remainingCollateral;

        emit Liquidation(user, xStock, liquidateAmount, msg.sender, collateralSeized);

        if (position.mintedXStock == 0) {
            delete _mintPositions[user][xStock];
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  View Functions
    // ═══════════════════════════════════════════════════════════════════════

    function getMintPosition(address user, address xStock) external view override returns (MintPosition memory) {
        return _mintPositions[user][xStock];
    }

    function getBorrowPosition(address user, address borrowAsset)
        external
        view
        override
        returns (BorrowPosition memory)
    {
        return _borrowPositions[user][borrowAsset];
    }

    function getLendPosition(uint256 lendId)
        external
        view
        override
        returns (
            address lender,
            address xStock,
            uint256 principal,
            uint256 accruedInterest,
            uint256 lendRate,
            uint256 startTime
        )
    {
        LendingPosition storage pos = _lendPositions[lendId];
        return (pos.lender, pos.xStock, pos.principal, pos.accruedInterest, pos.lendRate, pos.startTime);
    }

    function getCollateralRatio(address user, address xStock) external view override returns (uint256 ratioBps) {
        MintPosition memory position = _mintPositions[user][xStock];
        if (position.mintedXStock == 0) return 0;

        uint256 collateralValue = _getCollateralValue(position.collateralAsset, position.collateralAmount);
        uint256 xStockValue = _getXStockValue(xStock, position.mintedXStock);

        if (xStockValue == 0) return type(uint256).max;
        return (collateralValue * BPS_DENOMINATOR) / xStockValue;
    }

    function isLiquidatable(address user, address xStock) public view override returns (bool) {
        uint256 ratio = this.getCollateralRatio(user, xStock);
        return ratio > 0 && ratio < liquidationThreshold;
    }

    function getBorrowRate(address borrowAsset) public view override returns (uint256 rateBps) {
        BorrowAssetConfig memory config = borrowConfigs[borrowAsset];
        if (!config.isRegistered) return 0;

        if (config.interestRateModel == 0) {
            return config.currentBorrowRate;
        } else {
            // Dynamic rate based on utilization
            uint256 utilization = getUtilization(borrowAsset);
            // Base rate + (utilization * multiplier)
            return config.currentBorrowRate + (utilization * 2000) / BPS_DENOMINATOR;
        }
    }

    function getLendRate(address xStockAsset) public view override returns (uint256 rateBps) {
        return xStockConfigs[xStockAsset].currentLendRate;
    }

    function getTotalMinted(address xStock) external view override returns (uint256) {
        return xStockConfigs[xStock].totalMinted;
    }

    function getTotalBorrowed(address borrowAsset) external view override returns (uint256) {
        return borrowConfigs[borrowAsset].totalBorrowed;
    }

    function getTotalLent(address xStock) external view override returns (uint256) {
        return xStockConfigs[xStock].totalLent;
    }

    function getMinCollateralRatio() external view override returns (uint256 ratioBps) {
        return minCollateralRatio;
    }

    function getLiquidationThreshold() external view override returns (uint256 ratioBps) {
        return liquidationThreshold;
    }

    function getLiquidationPenalty() external view override returns (uint256 penaltyBps) {
        return liquidationPenalty;
    }

    function getUtilization(address asset) public view returns (uint256 utilizationBps) {
        uint256 totalLent = xStockConfigs[asset].totalLent;
        uint256 totalBorrowed = borrowConfigs[asset].totalBorrowed;
        if (totalLent == 0) return 0;
        return (totalBorrowed * BPS_DENOMINATOR) / totalLent;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Admin Functions
    // ═══════════════════════════════════════════════════════════════════════

    function setMinCollateralRatio(uint256 newRatioBps) external override onlyOwner {
        require(newRatioBps >= 11_000 && newRatioBps <= 20_000, "Invalid ratio");
        minCollateralRatio = newRatioBps;
        emit ConfigUpdated("minCollateralRatio", minCollateralRatio, newRatioBps);
    }

    function setLiquidationThreshold(uint256 newThresholdBps) external override onlyOwner {
        require(newThresholdBps >= 10_500 && newThresholdBps <= minCollateralRatio, "Invalid threshold");
        liquidationThreshold = newThresholdBps;
        emit ConfigUpdated("liquidationThreshold", liquidationThreshold, newThresholdBps);
    }

    function setLiquidationPenalty(uint256 newPenaltyBps) external override onlyOwner {
        require(newPenaltyBps <= 1000, "Penalty too high");
        liquidationPenalty = newPenaltyBps;
        emit ConfigUpdated("liquidationPenalty", liquidationPenalty, newPenaltyBps);
    }

    function registerXStock(address xStock, address underlying, address priceFeed) external override onlyOwner {
        xStockConfigs[xStock] = XStockConfig({
            underlying: underlying,
            priceFeed: priceFeed,
            isRegistered: true,
            totalMinted: 0,
            totalLent: 0,
            currentLendRate: 500 // 5% default lend rate
        });
        emit AssetRegistered(xStock);
    }

    function registerBorrowAsset(address asset, uint256 initialRateBps) external override onlyOwner {
        borrowConfigs[asset] = BorrowAssetConfig({
            isRegistered: true,
            totalBorrowed: 0,
            currentBorrowRate: initialRateBps,
            interestRateModel: 1 // Dynamic by default
        });
        emit AssetRegistered(asset);
    }

    function pauseXStockOperations() external override onlyOwner {
        _pause();
        emit PauseStateChanged(true, "Admin pause");
    }

    function unpauseXStockOperations() external override onlyOwner {
        _unpause();
        emit PauseStateChanged(false, "");
    }

    function setLendRate(address xStock, uint256 newRateBps) external onlyOwner {
        require(xStockConfigs[xStock].isRegistered, "XStock not registered");
        xStockConfigs[xStock].currentLendRate = newRateBps;
        emit RatesUpdated(xStock, newRateBps, address(0), 0);
    }

    function setBorrowRate(address borrowAsset, uint256 newRateBps) external onlyOwner {
        require(borrowConfigs[borrowAsset].isRegistered, "Asset not registered");
        borrowConfigs[borrowAsset].currentBorrowRate = newRateBps;
        emit RatesUpdated(address(0), 0, borrowAsset, newRateBps);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _getXStockPrice(address xStock) internal view returns (uint256 price) {
        address feed = xStockConfigs[xStock].priceFeed;
        if (feed == address(0)) {
            // Fallback to the legacy price oracle. Its quote carries an `updatedAt`, so
            // reject a stale one instead of valuing a position off an old print.
            uint256 updatedAt;
            (price, updatedAt) = IXStockPriceOracle(priceOracle).getXStockPrice(xStock);
            if (price == 0) revert PriceFeedUnavailable(xStock);
            if (updatedAt != 0 && block.timestamp - updatedAt > DEFAULT_STALENESS_THRESHOLD) {
                revert PriceFeedStale(xStock, updatedAt);
            }
        } else {
            price = IStockPriceFeed(feed).getPrice(xStock);
        }
    }

    function _getCollateralValue(address collateral, uint256 amount) internal view returns (uint256 value) {
        // Convert collateral to USD value
        uint8 decimals = IERC20Metadata(collateral).decimals();
        value = amount * (10 ** (18 - decimals)); // Normalize to 18 decimals
    }

    function _getXStockValue(address xStock, uint256 amount) internal view returns (uint256 value) {
        uint256 price = _getXStockPrice(xStock);
        value = (amount * price) / 1e8; // Price feed is typically 8 decimals
    }

    function _calculateAccruedInterest(address user, address borrowAsset) internal view returns (uint256 interest) {
        BorrowPosition memory position = _borrowPositions[user][borrowAsset];
        if (position.borrowedAmount == 0) return 0;

        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;

        // ratePerSecond = rate * 1e18 / (year * BPS); interest = principal * ratePerSecond
        // * elapsed / 1e18. Doing it in one mulDiv avoids dividing first (which rounded the
        // per-second rate down to zero for small rates) and avoids the 3-factor overflow.
        // forge-lint: disable-next-line(divide-before-multiply)
        interest = Math.mulDiv(
            position.borrowedAmount * timeElapsed, position.interestRate, SECONDS_PER_YEAR * BPS_DENOMINATOR
        );
    }

    function _calculateLendInterest(uint256 lendId) internal view returns (uint256 interest) {
        LendingPosition memory position = _lendPositions[lendId];
        if (!position.isActive) return 0;

        uint256 timeElapsed = block.timestamp - position.lastUpdate;

        // Same single-mulDiv treatment as {_calculateAccruedInterest}.
        // forge-lint: disable-next-line(divide-before-multiply)
        interest = Math.mulDiv(position.principal * timeElapsed, position.lendRate, SECONDS_PER_YEAR * BPS_DENOMINATOR);
    }

    // Additional event for config updates
    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);
}
