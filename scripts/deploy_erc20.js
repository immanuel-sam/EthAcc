async function main() {
  const [deployer] = await ethers.getSigners();
  const Token = await ethers.getContractFactory("TestToken");
  // Name, Symbol, InitialSupply
  const token = await Token.deploy("TestToken", "TT", "1000000");
  await token.deployed();
  console.log("TestToken deployed at:", token.address);
}
main().catch((error) => {console.error(error); process.exit(1);});
