// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IStockPriceFeed } from "./interfaces/IVaultKeeper.sol";

contract MockPriceFeed is IStockPriceFeed {
    mapping(address => uint256) public price;
    mapping(address => uint256) public updatedAt;
    uint8 public immutable override decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setPrice(address asset, uint256 p) external {
        price[asset] = p;
        updatedAt[asset] = block.timestamp;
    }

    function getPrice(address asset) external view override returns (uint256) {
        return price[asset];
    }

    function lastUpdate(address asset) external view override returns (uint256) {
        return updatedAt[asset];
    }

    function priceValidity(address asset) external view override returns (uint256, uint256) {
        uint256 observedAt = updatedAt[asset];
        return (observedAt, observedAt == 0 ? 0 : observedAt + 365 days);
    }

    function stalenessThreshold() external pure override returns (uint256) {
        return 365 days;
    }

    function isPriceFresh(address asset) external view override returns (bool) {
        return price[asset] > 0 && updatedAt[asset] > 0 && block.timestamp <= updatedAt[asset] + 365 days;
    }
}

