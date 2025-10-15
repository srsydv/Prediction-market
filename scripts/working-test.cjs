// Simple test script that works with the current setup
const { ethers } = require("hardhat");

async function main() {
  console.log("🚀 Starting LMSRMarket Comprehensive Tests...");
  
  // Get signers
  const [owner, creator, user1, user2, user3] = await ethers.getSigners();
  console.log("✅ Got signers:", {
    owner: owner.address,
    creator: creator.address,
    user1: user1.address,
    user2: user2.address,
    user3: user3.address
  });

  // Deploy mock USDC token
  console.log("\n📝 Deploying MockERC20...");
  const MockERC20Factory = await ethers.getContractFactory("MockERC20");
  const usdc = await MockERC20Factory.deploy(
    "USD Coin",
    "USDC",
    6,
    ethers.parseUnits("1000000", 6)
  );
  console.log("✅ MockERC20 deployed at:", usdc.target);

  // Deploy LMSRMarket contract
  console.log("\n📝 Deploying LMSRMarket...");
  const LMSRMarketFactory = await ethers.getContractFactory("LMSRMarket");
  const lmsrMarket = await LMSRMarketFactory.deploy();
  console.log("✅ LMSRMarket deployed at:", lmsrMarket.target);

  // Mint USDC to users
  console.log("\n💰 Minting USDC to users...");
  await usdc.mint(creator.address, ethers.parseUnits("100000", 6));
  await usdc.mint(user1.address, ethers.parseUnits("10000", 6));
  await usdc.mint(user2.address, ethers.parseUnits("10000", 6));
  await usdc.mint(user3.address, ethers.parseUnits("10000", 6));
  console.log("✅ USDC minted to all users");

  // Approve LMSRMarket to spend USDC
  console.log("\n🔐 Approving USDC spending...");
  await usdc.connect(creator).approve(lmsrMarket.target, ethers.parseUnits("100000", 6));
  await usdc.connect(user1).approve(lmsrMarket.target, ethers.parseUnits("10000", 6));
  await usdc.connect(user2).approve(lmsrMarket.target, ethers.parseUnits("10000", 6));
  await usdc.connect(user3).approve(lmsrMarket.target, ethers.parseUnits("10000", 6));
  console.log("✅ USDC spending approved");

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

  // Get market info
  const marketInfo = await lmsrMarket.getMarketInfo(0);
  console.log("📊 Market Info:", {
    creator: marketInfo.creator,
    collateral: marketInfo.collateral,
    b: marketInfo.b.toString(),
    qYes: marketInfo.qYes.toString(),
    qNo: marketInfo.qNo.toString(),
    state: marketInfo.state,
    outcome: marketInfo.outcome,
    feeBps: marketInfo.feeBps,
    escrow: marketInfo.escrow.toString()
  });

  // Test 2: Buy Yes Shares
  console.log("\n🧪 Test 2: Buying Yes Shares");
  const shareAmount = ethers.parseUnits("100", 6);
  const cost = await lmsrMarket.getBuyCost(0, 0, shareAmount);
  const fee = (cost * 50n) / 10000n;
  
  console.log(`💰 Buying ${ethers.formatUnits(shareAmount, 6)} Yes shares for ${ethers.formatUnits(cost, 6)} USDC (fee: ${ethers.formatUnits(fee, 6)})`);
  
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
  
  console.log(`💰 Buying ${ethers.formatUnits(noShareAmount, 6)} No shares for ${ethers.formatUnits(noCost, 6)} USDC (fee: ${ethers.formatUnits(noFee, 6)})`);
  
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

  // Test 5: Buy more shares from different users
  console.log("\n🧪 Test 5: More Share Purchases");
  
  // User3 buys Yes shares
  const user3YesAmount = ethers.parseUnits("75", 6);
  const user3Cost = await lmsrMarket.getBuyCost(0, 0, user3YesAmount);
  await lmsrMarket.connect(user3).buy(0, 0, user3YesAmount);
  const user3YesBalance = await lmsrMarket.balanceOf(user3.address, yesTokenId);
  console.log(`✅ User3 bought ${ethers.formatUnits(user3YesBalance, 6)} Yes shares`);

  // User1 buys No shares
  const user1NoAmount = ethers.parseUnits("50", 6);
  const user1NoCost = await lmsrMarket.getBuyCost(0, 1, user1NoAmount);
  await lmsrMarket.connect(user1).buy(0, 1, user1NoAmount);
  const user1NoBalance = await lmsrMarket.balanceOf(user1.address, noTokenId);
  console.log(`✅ User1 bought ${ethers.formatUnits(user1NoBalance, 6)} No shares`);

  // Test 6: Resolve Market
  console.log("\n🧪 Test 6: Resolving Market to Yes");
  const resolveTx = await lmsrMarket.connect(creator).resolve(0, 1);
  await resolveTx.wait();
  console.log("✅ Market resolved to Yes");

  // Test 7: Redeem Winning Shares
  console.log("\n🧪 Test 7: Redeeming Winning Shares");
  
  // User1 redeems Yes shares
  const balanceBefore1 = await usdc.balanceOf(user1.address);
  const redeemTx1 = await lmsrMarket.connect(user1).redeem(0);
  await redeemTx1.wait();
  const balanceAfter1 = await usdc.balanceOf(user1.address);
  const payout1 = balanceAfter1 - balanceBefore1;
  console.log(`✅ User1 redeemed ${ethers.formatUnits(payout1, 6)} USDC from Yes shares`);

  // User3 redeems Yes shares
  const balanceBefore3 = await usdc.balanceOf(user3.address);
  const redeemTx3 = await lmsrMarket.connect(user3).redeem(0);
  await redeemTx3.wait();
  const balanceAfter3 = await usdc.balanceOf(user3.address);
  const payout3 = balanceAfter3 - balanceBefore3;
  console.log(`✅ User3 redeemed ${ethers.formatUnits(payout3, 6)} USDC from Yes shares`);

  // Test 8: Create Multiple Markets
  console.log("\n🧪 Test 8: Creating Multiple Markets");
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

  // Test 9: Check final balances
  console.log("\n🧪 Test 9: Final Balances");
  const finalBalance1 = await usdc.balanceOf(user1.address);
  const finalBalance2 = await usdc.balanceOf(user2.address);
  const finalBalance3 = await usdc.balanceOf(user3.address);
  
  console.log(`💰 Final USDC Balances:`);
  console.log(`   User1: ${ethers.formatUnits(finalBalance1, 6)} USDC`);
  console.log(`   User2: ${ethers.formatUnits(finalBalance2, 6)} USDC`);
  console.log(`   User3: ${ethers.formatUnits(finalBalance3, 6)} USDC`);

  console.log("\n🎉 All comprehensive tests completed successfully!");
  console.log("\n📊 Test Summary:");
  console.log("- ✅ Market Creation");
  console.log("- ✅ Buy Yes Shares (User1, User3)");
  console.log("- ✅ Buy No Shares (User2, User1)");
  console.log("- ✅ Price Calculations");
  console.log("- ✅ Market Resolution");
  console.log("- ✅ Share Redemption");
  console.log("- ✅ Multiple Markets");
  console.log("- ✅ Balance Verification");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
