import { expect } from "chai";
import hre from "hardhat";

describe("LMSRMarket Simple Tests", function () {
  let lmsrMarket: any;
  let usdc: any;
  let owner: any;
  let creator: any;
  let user1: any;

  before(async function () {
    const { ethers } = hre;
    [owner, creator, user1] = await ethers.getSigners();

    // Deploy mock USDC token (6 decimals)
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    usdc = await MockERC20Factory.deploy(
      "USD Coin",
      "USDC",
      6,
      ethers.parseUnits("1000000", 6) // 1M USDC
    );

    // Deploy LMSRMarket contract
    const LMSRMarketFactory = await ethers.getContractFactory("LMSRMarket");
    lmsrMarket = await LMSRMarketFactory.deploy();

    // Mint USDC to users
    await usdc.mint(creator.address, ethers.parseUnits("100000", 6)); // 100k USDC
    await usdc.mint(user1.address, ethers.parseUnits("10000", 6));   // 10k USDC

    // Approve LMSRMarket to spend USDC
    await usdc.connect(creator).approve(lmsrMarket.target, ethers.parseUnits("100000", 6));
    await usdc.connect(user1).approve(lmsrMarket.target, ethers.parseUnits("10000", 6));
  });

  describe("Market Creation", function () {
    it("Should create a new market successfully", async function () {
      const { ethers } = hre;
      const bFixed = ethers.parseEther("1000"); // 1000 in 64.64 format
      const initialCollateral = ethers.parseUnits("1000", 6); // 1000 USDC
      const feeBps = 50; // 0.5%

      const tx = await lmsrMarket.connect(creator).createMarket(
        usdc.target,
        bFixed,
        initialCollateral,
        feeBps
      );

      await expect(tx)
        .to.emit(lmsrMarket, "MarketCreated")
        .withArgs(
          0, // marketId
          creator.address,
          usdc.target,
          bFixed,
          initialCollateral,
          feeBps
        );

      const marketInfo = await lmsrMarket.getMarketInfo(0);
      expect(marketInfo[0]).to.equal(creator.address); // creator
      expect(marketInfo[1]).to.equal(usdc.target); // collateral
      expect(marketInfo[2]).to.equal(6); // decimals
      expect(marketInfo[6]).to.equal(0); // Active state
      expect(marketInfo[7]).to.equal(0); // unresolved outcome
    });

    it("Should fail to create market with zero collateral", async function () {
      const { ethers } = hre;
      await expect(
        lmsrMarket.connect(creator).createMarket(
          usdc.target,
          ethers.parseEther("1000"),
          0,
          50
        )
      ).to.be.revertedWith("need collateral");
    });
  });

  describe("Buying Shares", function () {
    beforeEach(async function () {
      const { ethers } = hre;
      await lmsrMarket.connect(creator).createMarket(
        usdc.target,
        ethers.parseEther("1000"),
        ethers.parseUnits("1000", 6),
        50
      );
    });

    it("Should buy Yes shares successfully", async function () {
      const { ethers } = hre;
      const shareAmount = ethers.parseUnits("100", 6);
      const cost = await lmsrMarket.getBuyCost(0, 0, shareAmount);
      const fee = (cost * 50n) / 10000n; // 0.5% fee
      
      const tx = await lmsrMarket.connect(user1).buy(0, 0, shareAmount);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Bought")
        .withArgs(0, user1.address, 0, shareAmount, cost, fee);
      
      // Check user has shares
      const yesTokenId = await lmsrMarket._yesId(0);
      expect(await lmsrMarket.balanceOf(user1.address, yesTokenId)).to.equal(shareAmount);
    });

    it("Should buy No shares successfully", async function () {
      const { ethers } = hre;
      const shareAmount = ethers.parseUnits("150", 6);
      const cost = await lmsrMarket.getBuyCost(0, 1, shareAmount);
      const fee = (cost * 50n) / 10000n;
      
      const tx = await lmsrMarket.connect(user1).buy(0, 1, shareAmount);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Bought")
        .withArgs(0, user1.address, 1, shareAmount, cost, fee);
      
      // Check user has shares
      const noTokenId = await lmsrMarket._noId(0);
      expect(await lmsrMarket.balanceOf(user1.address, noTokenId)).to.equal(shareAmount);
    });

    it("Should buy Yes shares with different amounts", async function () {
      const { ethers } = hre;
      // User buys small amount
      const amount1 = ethers.parseUnits("50", 6);
      await lmsrMarket.connect(user1).buy(0, 0, amount1);
      
      // Check user has shares
      const yesTokenId = await lmsrMarket._yesId(0);
      expect(await lmsrMarket.balanceOf(user1.address, yesTokenId)).to.equal(amount1);
    });
  });

  describe("Market Resolution and Redemption", function () {
    beforeEach(async function () {
      const { ethers } = hre;
      await lmsrMarket.connect(creator).createMarket(
        usdc.target,
        ethers.parseEther("1000"),
        ethers.parseUnits("1000", 6),
        50
      );
      
      // User buys shares
      await lmsrMarket.connect(user1).buy(0, 0, ethers.parseUnits("100", 6));
    });

    it("Should resolve market to Yes", async function () {
      const { ethers } = hre;
      const tx = await lmsrMarket.connect(creator).resolve(0, 1);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Resolved")
        .withArgs(0, 1);
      
      const marketInfo = await lmsrMarket.getMarketInfo(0);
      expect(marketInfo[6]).to.equal(1); // Resolved state
      expect(marketInfo[7]).to.equal(1); // Yes outcome
    });

    it("Should redeem winning Yes shares", async function () {
      const { ethers } = hre;
      await lmsrMarket.connect(creator).resolve(0, 1);
      
      const balanceBefore = await usdc.balanceOf(user1.address);
      const yesTokenId = await lmsrMarket._yesId(0);
      const shareBalance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      
      const tx = await lmsrMarket.connect(user1).redeem(0);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Redeemed")
        .withArgs(0, user1.address, shareBalance);
      
      // Check shares are burned
      expect(await lmsrMarket.balanceOf(user1.address, yesTokenId)).to.equal(0);
      
      // Check USDC received
      const balanceAfter = await usdc.balanceOf(user1.address);
      expect(balanceAfter - balanceBefore).to.equal(shareBalance);
    });
  });
});
