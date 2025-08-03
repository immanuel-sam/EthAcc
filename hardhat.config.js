require("@nomiclabs/hardhat-ethers");
require("dotenv").config();

module.exports = {
  solidity: "0.8.19",
  networks: {
    xlayer: {
      url: "https://xlayertestrpc.okx.com",
      accounts: [process.env.PRIVATE_KEY], // .env holds your wallet PK, never commit it!
      chainId: 195,
    },
  },
};
