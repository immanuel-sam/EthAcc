async function main() {
  const [deployer] = await ethers.getSigners();
  const okxRouter = "0xd30D8CA2E7715eE6804a287eB86FAfC0839b1380"; // X Layer Testnet OKX router
  const AgentDEX = await ethers.getContractFactory("AIAgentLeasingDEX");
  const contract = await AgentDEX.deploy(okxRouter);
  await contract.deployed();
  console.log("AIAgentLeasingDEX deployed at:", contract.address);
  console.log("AccessPass contract at:", await contract.getAccessPassContract());
}
main().catch((error) => {console.error(error); process.exit(1);});
