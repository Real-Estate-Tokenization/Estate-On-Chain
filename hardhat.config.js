require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-foundry");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 400
      },
      viaIR: true,
      evmVersion: "shanghai",
    }
  },

  defaultNetwork: "hardhat",
  networks: {
    hardhat: {},

    arbitrumSepolia: {
      url: "",
      accounts: [],
      chainId: 333,
      blockConfirmations: 3
    },
    avalancheFuji: {
      url: "",
      accounts: [],
      chainId: 122,
      blockConfirmations: 3
    }
  }
};
