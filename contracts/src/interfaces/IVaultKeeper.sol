// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVaultKeeper {
    struct Strategy {
        address[] assets;
        uint256[] weights; // basis points, sum to 10_000
    }

    struct StrategySnapshot {
        address asset;
        uint256 targetWeight; // bps
        uint256 actualWeight; // bps (approx)
        uint256 balance;      // raw token balance
    }

    function deposit(uint256 amount) external returns (uint256 shares);
    function deposit(uint256 amount, address receiver) external returns (uint256 shares);
    function withdraw(uint256 shares, uint256 minAmount) external returns (uint256 assets);
    function withdraw(uint256 shares, address receiver, uint256 minAmount) external returns (uint256 assets);

    function rebalance() external;

    // ERC-4626 style previews
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function previewWithdraw(uint256 shares) external view returns (uint256 assets);
    function maxDeposit(address owner) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);

    // Portfolio views
    function totalAssets() external view returns (uint256 assets);
    function getPortfolioValue() external view returns (uint256 value);
    function strategy() external view returns (Strategy memory);
    function strategyBreakdown() external view returns (StrategySnapshot[] memory);

    function paused() external view returns (bool);
    function managementFee() external view returns (uint256);
    function performanceFee() external view returns (uint256);

    // Oracle integration
    function priceFeed() external view returns (IStockPriceFeed);
    function getCachedPrice(address asset) external view returns (uint256 price, uint256 updatedAt);
    function isPriceFresh(address asset) external view returns (bool);

    // Admin / configuration
    function setStrategy(address[] calldata newAssets, uint256[] calldata newWeights) external;
    function updateWeights(uint256[] calldata newWeights) external;
    function setPriceFeed(address asset, address feed) external;
    function setManagementFee(uint256 newFee) external;
    function setPerformanceFee(uint256 newFee) external;
    function transferGovernance(address newGovernor) external;
    function setPaused(bool shouldPause) external;
    function emergencyWithdraw(address asset, uint256 amount, address receiver) external;
}

interface IStockPriceFeed {
    function decimals() external view returns (uint8);
    function getPrice(address asset) external view returns (uint256 price);
    function lastUpdate(address asset) external view returns (uint256 updatedAt);
    function stalenessThreshold() external view returns (uint256);
    function isPriceFresh(address asset) external view returns (bool);
}

// Uniswap V3 router interface (real data)
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