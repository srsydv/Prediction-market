const { ethers } = require("hardhat");
const { expect } = require("chai");

async function main() {
  console.log("🚀 Starting LMSRMarket Tests...");
  
  // Get signers
  const [owner, creator, user1, user2, user3] = await ethers.getSigners();
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

  // Mint USDC to users
  await usdc.mint(creator.address, ethers.parseUnits("100000", 6));
  await usdc.mint(user1.address, ethers.parseUnits("10000", 6));
  await usdc.mint(user2.address, ethers.parseUnits("10000", 6));
  await usdc.mint(user3.address, ethers.parseUnits("10000", 6));
  console.log("✅ Minted USDC to users");

  // Approve LMSRMarket to spend USDC
  await usdc.connect(creator).approve(lmsrMarket.target, ethers.parseUnits("100000", 6));
  await usdc.connect(user1).approve(lmsrMarket.target, ethers.parseUnits("10000", 6));
  await usdc.connect(user2).approve(lmsrMarket.target, ethers.parseUnits("10000", 6));
  await usdc.connect(user3).approve(lmsrMarket.target, ethers.parseUnits("10000", 6));
  console.log("✅ Approved USDC spending");

  // Test 1: Create Market
  console.log("\n🧪 Test 1: Creating Market");
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
  console.log("✅ Market created successfully");

  // Test 2: Buy Yes Shares
  console.log("\n🧪 Test 2: Buying Yes Shares");
  const shareAmount = ethers.parseUnits("100", 6);
  const cost = await lmsrMarket.getBuyCost(0, 0, shareAmount);
  const fee = (cost * 50n) / 10000n;
  
  const buyTx = await lmsrMarket.connect(user1).buy(0, 0, shareAmount);
  await buyTx.wait();
  
  const yesTokenId = await lmsrMarket._yesId(0);
  const balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
  console.log(`✅ User1 bought ${ethers.formatUnits(balance, 6)} Yes shares`);

  // Test 3: Buy No Shares
  console.log("\n🧪 Test 3: Buying No Shares");
  const noShareAmount = ethers.parseUnits("150", 6);
  const noCost = await lmsrMarket.getBuyCost(0, 1, noShareAmount);
  const noFee = (noCost * 50n) / 10000n;
  
  const buyNoTx = await lmsrMarket.connect(user2).buy(0, 1, noShareAmount);
  await buyNoTx.wait();
  
  const noTokenId = await lmsrMarket._noId(0);
  const noBalance = await lmsrMarket.balanceOf(user2.address, noTokenId);
  console.log(`✅ User2 bought ${ethers.formatUnits(noBalance, 6)} No shares`);

  // Test 4: Get Prices
  console.log("\n🧪 Test 4: Getting Prices");
  const priceYes = await lmsrMarket.getPriceYes(0);
  const priceNo = await lmsrMarket.getPriceNo(0);
  console.log(`✅ Price Yes: ${ethers.formatUnits(priceYes, 18)}`);
  console.log(`✅ Price No: ${ethers.formatUnits(priceNo, 18)}`);

  // Test 5: Resolve Market
  console.log("\n🧪 Test 5: Resolving Market to Yes");
  const resolveTx = await lmsrMarket.connect(creator).resolve(0, 1);
  await resolveTx.wait();
  console.log("✅ Market resolved to Yes");

  // Test 6: Redeem Winning Shares
  console.log("\n🧪 Test 6: Redeeming Winning Shares");
  const balanceBefore = await usdc.balanceOf(user1.address);
  const redeemTx = await lmsrMarket.connect(user1).redeem(0);
  await redeemTx.wait();
  
  const balanceAfter = await usdc.balanceOf(user1.address);
  const payout = balanceAfter - balanceBefore;
  console.log(`✅ User1 redeemed ${ethers.formatUnits(payout, 6)} USDC`);

  // Test 7: Multiple Markets
  console.log("\n🧪 Test 7: Creating Multiple Markets");
  await lmsrMarket.connect(creator).createMarket(
    usdc.target,
    ethers.parseEther("2000"),
    ethers.parseUnits("2000", 6),
    25
  );
  
  await lmsrMarket.connect(creator).createMarket(
    usdc.target,
    ethers.parseEther("500"),
    ethers.parseUnits("500", 6),
    0
  );
  console.log("✅ Created 2 additional markets");

  // Buy from different markets
  await lmsrMarket.connect(user1).buy(1, 1, ethers.parseUnits("100", 6));
  await lmsrMarket.connect(user3).buy(2, 0, ethers.parseUnits("50", 6));
  console.log("✅ Bought shares from different markets");

  console.log("\n🎉 All tests completed successfully!");
  console.log("\n📊 Test Summary:");
  console.log("- ✅ Market Creation");
  console.log("- ✅ Buy Yes Shares");
  console.log("- ✅ Buy No Shares");
  console.log("- ✅ Price Calculations");
  console.log("- ✅ Market Resolution");
  console.log("- ✅ Share Redemption");
  console.log("- ✅ Multiple Markets");
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
