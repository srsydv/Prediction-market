const { ethers } = require("hardhat");

async function main() {
  console.log("🚀 Starting Simple Test...");
  
  // Get signers
  const [owner, creator, user1] = await ethers.getSigners();
  console.log("✅ Got signers");

  // Deploy mock USDC token
  const MockERC20Factory = await ethers.getContractFactory("MockERC20");
  const usdc = await MockERC20Factory.deploy(
    "USD Coin",
    "USDC",
    6,
    ethers.parseUnits("1000000", 6)
  );
  console.log("✅ Deployed MockERC20 at:", usdc.target);

  // Deploy LMSRMarket contract
  const LMSRMarketFactory = await ethers.getContractFactory("LMSRMarket");
  const lmsrMarket = await LMSRMarketFactory.deploy();
  console.log("✅ Deployed LMSRMarket at:", lmsrMarket.target);

  // Mint USDC to creator
  await usdc.mint(creator.address, ethers.parseUnits("100000", 6));
  console.log("✅ Minted USDC to creator");

  // Approve LMSRMarket to spend USDC
  await usdc.connect(creator).approve(lmsrMarket.target, ethers.parseUnits("100000", 6));
  console.log("✅ Approved USDC spending");

  // Create Market
  console.log("\n🧪 Creating Market...");
  const bFixed = ethers.parseEther("1000");
  const initialCollateral = ethers.parseUnits("1000", 6);
  const feeBps = 50;

  const tx = await lmsrMarket.connect(creator).createMarket(
    usdc.target,
    bFixed,
    initialCollateral,
    feeBps
  );
  
  await tx.wait();
  console.log("✅ Market created successfully!");

  console.log("\n🎉 Basic test completed successfully!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
