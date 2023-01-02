# ImmortalX Protocol

ImmortalX is a decentralized perpetuals exchange with unique mechanisms and tokenomics on Celo, offering a variety of competitive features to Celo ecosystem users. ImmortalX provides multiple benefits for traders such as up to 50x leverage trading with minimal fees, deep liquidity layer with little slippage, self-custody of funds and etc.

More details can be found in the documentation: https://docs.immortalx.io/

## Contracts Overview

This repository contains the core smart contracts for the ImmortalX decentralized trading protocol.

```ml
contracts
├── access
│   └── Governable.sol
├── core
│   ├── Dex.sol
│   ├── Liquidator.sol
│   ├── OrderManager.sol
│   ├── PositionManager.sol
│   └── ReferralManager.sol
├── interfaces
│   ├── IDex.sol
│   ├── IMultiplierPoint.sol
│   ├── IOracle.sol
│   ├── IOrderManager.sol
│   ├── IReferralManager.sol
│   ├── IRewardDistributor.sol
│   ├── IRewardTracker.sol
│   ├── IVaultReward.sol
│   └── IVaultRewardRouter.sol
├── oracle
│   └── Oracle.sol
├── token
│   ├── IMTX.sol
│   ├── MultipliedStakedIMTX.sol
│   ├── MultiplierPoint.sol
│   ├── MultiplierPointDistributor.sol
│   ├── StakedIMTX.sol
│   └── StakingRewardRouter.sol
└── vault
    ├── VaultFeeRewardRouter.sol
    ├── VaultRewardRouter.sol
    └── VaultTokenRewardRouter.sol
```

## Getting Started

### Install dependencies

`npm install`

### Compile contracts

`npx hardhat compile`
