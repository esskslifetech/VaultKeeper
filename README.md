# VaultKeeper

**Automated Multi-Strategy Vault for Tokenized Equities**

[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-blue.svg)](https://soliditylang.org/)
[![Next.js](https://img.shields.io/badge/Next.js-14.2.22-black.svg)](https://nextjs.org/)
[![TypeScript](https://img.shields.io/badge/TypeScript-5.0-blue.svg)](https://www.typescriptlang.org/)
[![Foundry](https://img.shields.io/badge/Foundry-Forge-red.svg)](https://book.getfoundry.sh/)
[![wagmi](https://img.shields.io/badge/wagmi-3.x-green.svg)](https://wagmi.sh/)

---

## Overview

VaultKeeper is a production-grade DeFi vault that automates portfolio management for tokenized equities (xStocks). Users deposit USDC and the vault allocates capital across weighted strategies representing synthetic stocks like AAPL.x, MSFT.x, TSLA.x, and more.

**Key Innovation:** Chainlink Automation-compatible keeper system that triggers rebalancing based on time intervals, price deviations, and health factors—no manual intervention required.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        VaultKeeper                               │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    │
│  │   Web App    │◄──►│   API Routes │◄──►│   Contracts  │    │
│  │  (Next.js)   │    │   (Next.js)  │    │  (Foundry)   │    │
│  └──────────────┘    └──────────────┘    └──────────────┘    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Smart Contracts:                                               │
│  • VaultKeeper.sol — Main ERC-4626 vault with real Uniswap V3   │
│    swaps, share minting, and strategy allocation               │
│  • Automation.sol — Chainlink Automation keeper with circuit   │
│    breakers, gas optimization, and liquidation logic             │
│  • RebalanceProof.sol — Cryptographic proof system for         │
│    verifiable rebalancing operations                             │
│  • XStockIntegration.sol — Adapter for xStocks tokenized        │
│    equity protocol                                               │
│  • PriceFeed.sol — Multi-oracle price aggregation                │
│                                                                 │
│  Frontend:                                                      │
│  • Strategy selection with risk-based allocation                 │
│  • Real-time portfolio analytics and APY calculation             │
│  • Wallet integration (MetaMask, WalletConnect, Coinbase)        │
│  • Dark/Light mode with accessibility-first design               │
│  • Deposit/Withdraw with transaction status tracking             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Features

### Smart Contracts

| Feature | Description |
|---------|-------------|
| **Multi-Strategy Vault** | ERC-4626 compliant vault supporting up to 8 weighted strategies |
| **Auto-Rebalancing** | Chainlink Automation triggers rebalancing on price deviation (5% default) |
| **Real Swaps** | Uniswap V3 integration for actual token swaps during rebalancing |
| **Price Oracles** | Multi-oracle support (Chainlink, Pyth) with staleness protection |
| **Rebalance Proofs** | Cryptographic proofs for verifiable rebalancing operations |
| **Circuit Breakers** | Automatic pause on consecutive failures (max 3) |
| **Emergency Withdraw** | Governor-controlled emergency fund withdrawal |
| **Keeper Whitelist** | Optional access control for automation keepers |

### Frontend

| Feature | Description |
|---------|-------------|
| **Live Dashboard** | Real-time TVL, APY, user count from analytics endpoints |
| **Strategy Selector** | Risk-based allocation (Conservative/Balanced/Aggressive) with sliders |
| **Wallet Integration** | wagmi 3.6.0 + viem for multiple wallet connections |
| **Portfolio Analytics** | Deposit/withdraw history, yield tracking, rebalancing logs |
| **Health Monitoring** | System health status, network status, performance metrics |
| **Backtesting API** | Historical strategy performance simulation |
| **Responsive Design** | Mobile-first with fluid typography and animations |
| **Theme Toggle** | Dark/Light mode switching with system preference detection |
| **Error Boundaries** | Graceful error handling with retry mechanisms |
| **Offline Detection** | Network status monitoring with user notifications |

### API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /api/activity` | On-chain activity feed (deposits, withdrawals, rebalances) |
| `POST /api/backtest` | Strategy backtesting simulation |
| `GET /api/health` | System health check |
| `GET /api/market/volatility` | Market volatility metrics |
| `GET /api/portfolio/history` | User's portfolio transaction history |
| `GET /api/portfolio/stats` | Portfolio statistics and vault positions |
| `GET /api/rebalance-proof` | Rebalancing proof verification |
| `GET /api/strategies` | Available vault strategies |
| `GET /api/vaults/positions` | Current vault allocations and token balances |

---

## Technology Stack

### Backend (Smart Contracts)
- **Solidity 0.8.28** with custom errors and NatSpec documentation
- **Foundry** for testing, gas snapshots, and deployment
- **OpenZeppelin Contracts** for ERC-20, access control, reentrancy guards
- **Chainlink Automation** for decentralized keeper operations
- **Uniswap V3** for real token swaps

### Frontend
- **Next.js 14.2.22** with App Router and Server Components
- **TypeScript 5** with strict type checking
- **wagmi 3.6.0 + viem 2.47.6** for Ethereum interactions
- **@tanstack/react-query 5.96.0** for data fetching
- **Tailwind CSS 3.4.1** with custom CSS variables for theming
- **Framer Motion 12.38.0** for animations
- **Recharts 3.8.1** for data visualization
- **Lucide React** for icons
- **sonner** for toast notifications

### DevOps
- **ESLint** with Next.js config (clean lint, zero errors)
- **Foundry** for contract testing
- **Environment-based configuration** per chain

---

## Supported Assets

### Deposit Asset
- **USDC** (primary deposit token)

### Strategy Assets (xStocks)
- AAPL.x (Apple)
- MSFT.x (Microsoft)
- GOOGL.x (Alphabet)
- AMZN.x (Amazon)
- TSLA.x (Tesla)
- NVDA.x (NVIDIA)
- META.x (Meta)
- NKE.x (Nike)

---

## Quick Start

### Prerequisites

- Node.js 18+
- Foundry (for contracts)
- Local Ethereum node (Hardhat or Anvil)

### Installation

```bash
# Clone the repository
git clone <your-repo-url>
cd VaultKeeper

# Install contract dependencies
cd contracts
forge install
cd ..

# Install frontend dependencies
cd web
npm install
```

### Environment Setup

Create `web/.env.local`:

```bash
# Chain Configuration
NEXT_PUBLIC_CHAIN_ID=31337

# Contract Addresses (replace with your deployed addresses)
NEXT_PUBLIC_VAULT_ADDRESS_31337=0x...
NEXT_PUBLIC_USDC_ADDRESS_31337=0x...
NEXT_PUBLIC_AAPL_X_ADDRESS_31337=0x...
NEXT_PUBLIC_MSFT_X_ADDRESS_31337=0x...
NEXT_PUBLIC_NVDA_X_ADDRESS_31337=0x...
```

### Development

```bash
# Terminal 1: Start local Ethereum node
cd contracts
anvil

# Terminal 2: Deploy contracts
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY --broadcast

# Terminal 3: Start frontend
cd web
npm run dev
```

Open [http://localhost:3000](http://localhost:3000)

---

## Contract Deployment

```bash
cd contracts

# Test
forge test

# Deploy to local network
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

# Deploy to Sepolia
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast --verify
```

---

## Testing

### Contract Tests
```bash
cd contracts
forge test -vvv
```

### Frontend Lint
```bash
cd web
npm run lint  # Zero errors, 5 warnings (non-blocking)
```

---

## Project Structure

```
VaultKeeper/
├── contracts/           # Foundry-based smart contracts
│   ├── src/
│   │   ├── VaultKeeper.sol      # Main ERC-4626 vault contract
│   │   ├── Automation.sol       # Chainlink Automation keeper
│   │   ├── RebalanceProof.sol   # Cryptographic proof verification
│   │   ├── XStockIntegration.sol # xStocks protocol adapter
│   │   ├── PriceFeed.sol        # Multi-oracle price aggregation
│   │   ├── Counter.sol          # Additional vault utilities
│   │   ├── MockERC20.sol        # Test token mock
│   │   ├── MockPriceFeed.sol    # Test price oracle mock
│   │   └── interfaces/          # Contract interfaces
│   │       ├── IVaultKeeper.sol
│   │       ├── IRebalanceProof.sol
│   │       ├── IXStocks.sol
│   │       └── IXStockVault.sol
│   ├── test/            # Foundry tests
│   ├── script/          # Deployment scripts
│   ├── lib/             # Dependencies (OpenZeppelin, Chainlink)
│   └── foundry.toml     # Foundry configuration
│
├── web/                 # Next.js 14 frontend
│   ├── app/
│   │   ├── page.tsx     # Landing page
│   │   ├── layout.tsx   # Root layout with providers
│   │   ├── providers.tsx # wagmi and query providers
│   │   ├── globals.css  # Tailwind + custom CSS variables
│   │   ├── dashboard/   # Dashboard pages
│   │   │   ├── page.tsx
│   │   │   ├── layout.tsx
│   │   │   ├── strategy/
│   │   │   └── vaults/
│   │   └── api/         # API routes
│   │       ├── activity/
│   │       ├── backtest/
│   │       ├── health/
│   │       ├── market/volatility/
│   │       ├── portfolio/history/
│   │       ├── portfolio/stats/
│   │       ├── rebalance-proof/
│   │       ├── strategies/
│   │       └── vaults/
│   ├── components/    # React components
│   │   ├── StrategySelector.tsx
│   │   ├── VaultCard.tsx
│   │   ├── ErrorBoundary.tsx
│   │   ├── HealthIndicator.tsx
│   │   ├── HealthStatusProvider.tsx
│   │   ├── OfflineBanner.tsx
│   │   ├── PerformanceMonitor.tsx
│   │   └── ThemeToggle.tsx
│   ├── lib/             # Utilities & constants
│   ├── public/          # Static assets
│   └── package.json     # Dependencies
│
├── subgraph/            # The Graph subgraph schema
│   └── schema.graphql   # Comprehensive entity definitions
│
└── docs/                # Additional documentation
    └── XSTOCKS_INTEGRATION.md  # xStocks protocol integration guide
```

---

## Configuration

### Chain Support
- Ethereum Mainnet (1)
- Sepolia (11155111)
- Polygon (137)
- Arbitrum (42161)
- Optimism (10)
- Local Anvil (31337)

### Strategy Risk Profiles

| Profile | Description | Allocation Example |
|---------|-------------|-------------------|
| **Conservative** | Stable blue-chip stocks | 60% AAPL.x, 40% MSFT.x |
| **Balanced** | Diversified portfolio | 25% each across 4 assets |
| **Aggressive** | High-growth tech | 50% NVDA.x, 30% TSLA.x, 20% META.x |

---

## Security

- **ReentrancyGuard** on all state-changing functions
- **Access Control** with Ownable pattern
- **Circuit Breakers** on automation failures
- **Price Staleness Checks** (1 hour threshold)
- **Gas Limits** enforced on keeper operations
- **Slippage Protection** via Uniswap V3 minimum output

---

## Gas Optimization

- Immutable variables for gas savings
- Custom errors instead of revert strings
- Efficient storage packing
- Gas snapshots via `forge snapshot`

---

## License

MIT License - see [LICENSE](./LICENSE) for details

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## Acknowledgments

- Built with [Foundry](https://book.getfoundry.sh/)
- Frontend powered by [Next.js](https://nextjs.org/) and [wagmi](https://wagmi.sh/)
- UI components inspired by modern DeFi interfaces

---

## Disclaimer

This project is for educational and hackathon purposes. Do not use in production without proper auditing. Smart contracts involve significant risk—always verify and test thoroughly.

---

**Built with ❤️ for the DeFi community**
