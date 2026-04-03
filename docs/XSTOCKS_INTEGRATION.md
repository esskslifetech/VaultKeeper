# xStocks Protocol Integration

## Overview
VaultKeeper integrates with the **xStocks Protocol** to enable automated portfolio management of tokenized equities (AAPL.x, MSFT.x, TSLA.x, etc.) on-chain.

## Integration Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     VaultKeeper.sol                         │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              xStocks Integration Layer               │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │   │
│  │  │  mintXStock │  │ redeemXStock│  │ PriceFeed │ │   │
│  │  └─────────────┘  └─────────────┘  └───────────┘ │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                            │
                    ┌───────┴───────┐
                    ▼               ▼
            ┌───────────────┐  ┌───────────────┐
            │ xStocks Core  │  │  Chainlink    │
            │   Protocol    │  │   Oracles     │
            └───────────────┘  └───────────────┘
```

## Key Integration Points

### 1. Mint xStocks (Buy Strategy)
When the vault needs to increase exposure to an underweight asset:
- Calls `IXStocksProtocol.mintXStock()` with:
  - `stockSymbol`: e.g., "AAPL.x"
  - `amount`: Number of xStock tokens to mint
  - `collateralAsset`: USDC or other stablecoin
  - `maxCollateral`: Maximum collateral willing to deposit

### 2. Redeem xStocks (Sell Strategy)
When rebalancing requires reducing exposure to an overweight asset:
- Calls `IXStocksProtocol.redeemXStock()` with:
  - `stockSymbol`: e.g., "MSFT.x"
  - `amount`: Amount to redeem
  - `minCollateralOut`: Slippage protection

### 3. Price Oracles
- Uses xStocks internal price feeds for real-time equity pricing
- Collateral requirements calculated dynamically based on:
  - Current stock price
  - Collateral ratio (typically 150%)
  - Vault's total collateral balance

## Supported xStocks

| Symbol | Description | Collateral Ratio |
|--------|-------------|------------------|
| AAPL.x | Apple Inc. | 150% |
| MSFT.x | Microsoft Corp | 150% |
| GOOGL.x | Alphabet Inc | 150% |
| AMZN.x | Amazon.com | 150% |
| TSLA.x | Tesla Inc | 160% |
| NVDA.x | NVIDIA Corp | 160% |
| META.x | Meta Platforms | 150% |
| NKE.x | Nike Inc | 150% |

## Rebalancing Logic with xStocks

```solidity
function rebalance() external {
    // 1. Calculate current vs target allocations
    for each asset in portfolio:
        currentWeight = assetValue / totalValue
        targetWeight = strategy.allocation[asset]
    
    // 2. Identify deviations > 5% threshold
    if currentWeight > targetWeight + 5%:
        // OVERWEIGHT: Redeem xStocks
        excessAmount = calculateExcess(asset)
        xStocks.redeemXStock(asset.symbol, excessAmount, minOut)
    
    else if currentWeight < targetWeight - 5%:
        // UNDERWEIGHT: Mint xStocks
        deficitAmount = calculateDeficit(asset)
        xStocks.mintXStock(asset.symbol, deficitAmount, USDC, maxCollateral)
}
```

## Risk Management

### Collateralization Requirements
- Minimum 150% collateral ratio for most stocks
- Higher ratio (160%) for volatile assets (TSLA, NVDA)
- Automatic liquidation protection at 120% ratio

### Slippage Protection
- `maxCollateral` parameter prevents excessive collateral use
- `minCollateralOut` ensures minimum return on redemption
- 1% slippage tolerance on all rebalancing operations

## Frontend Integration

### Displaying xStock Holdings
```typescript
// Get user's xStock holdings through vault
const holdings = await vaultContract.getHoldings(assetAddress)
const stockPrice = await xStocksProtocol.getStockPrice("AAPL.x")
const positionValue = holdings * stockPrice / 1e8
```

### Rebalance Notifications
- Listen for `RebalanceAction` events
- Display real-time portfolio changes
- Show transaction history with xStock mints/redeems

## Contract Addresses (Example)

| Network | xStocks Protocol | VaultKeeper |
|---------|------------------|-------------|
| Ethereum | 0x... | 0x... |
| Polygon | 0x... | 0x... |
| Arbitrum | 0x... | 0x... |

## Future Enhancements

1. **Cross-margin Efficiency**: Share collateral across multiple xStock positions
2. **Yield Optimization**: Lend idle xStocks in money markets while maintaining exposure
3. **Automated Hedging**: Use options markets to protect downside risk
4. **Social Trading**: Allow users to copy vault strategies with one-click

## References

- `IXStocks.sol`: Interface definitions in `/contracts/src/interfaces/`
- `VaultKeeper.sol`: Main vault contract in `/contracts/src/`
- Frontend components: `web/components/VaultCard.tsx`
