require("@nomicfoundation/hardhat-toolbox");
require("hardhat-contract-sizer");
require("hardhat-tracer");
// require("hardhat-deploy");
require("dotenv").config();

module.exports = {
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      // forking: {
      //   url: "https://rpc.ankr.com/eth",
      //   blockNumber: 16161000,
      // },
    },
    celo: {
      url: "https://forno.celo.org",
      chainId: 42220,
      gasPrice: 1000000000,
      accounts: [process.env.GOVKEY],
    },
    polygon: {
      url: "https://polygon-rpc.com",
      gasPrice: 100000000000,
      chainId: 137,
      accounts: [process.env.TESTKEY],
    },
    bnbtestnet: {
      url: "https://data-seed-prebsc-1-s1.binance.org:8545",
      gasPrice: 100000000000,
      chainId: 97,
      accounts: [process.env.TESTKEY],
    },
    avaxtestnet: {
      url: "https://rpc.ankr.com/avalanche_fuji",
      gasPrice: 100000000000,
      chainId: 43113,
      accounts: [process.env.TESTKEY],
    },
    celotestnet: {
      url: "https://alfajores-forno.celo-testnet.org",
      gasPrice: 100000000000,
      chainId: 44787,
      accounts: [process.env.TESTKEY],
    },
  },
  solidity: {
    compilers: [
      {
        version: "0.8.16",
        settings: {
          optimizer: {
            enabled: true,
            runs: 800,
          },
        },
      },
    ],
  },
  gasReporter: {
    enabled: true,
    outputFile: "gas-report.txt",
    noColors: true,
  },
};
