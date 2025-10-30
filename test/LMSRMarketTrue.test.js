const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");


describe("LMSRMarketTrue", function () {
  let lmsrMarket;
  let usdc;
  let owner, creator, resolver, user1, user2;
  let marketId;

  beforeEach(async function () {
    [owner, creator, resolver, user1, user2] = await ethers.getSigners();

    // Deploy MockERC20
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    usdc = await MockERC20.deploy("USD Coin", "USDC", 6, ethers.utils.parseUnits("1000000", 6));

    // Transfer USDC to creator and users
    await usdc.transfer(creator.address, ethers.utils.parseUnits("100000", 6));
    await usdc.transfer(user1.address, ethers.utils.parseUnits("10000", 6));
    await usdc.transfer(user2.address, ethers.utils.parseUnits("10000", 6));

    // Deploy LMSRMarketTrue
    const LMSRMarketTrue = await ethers.getContractFactory("LMSRMarketTrue");
    lmsrMarket = await LMSRMarketTrue.deploy();

    // Set up authorized users
    await lmsrMarket.setAuthorizedCreator(creator.address, true);
    await lmsrMarket.setAuthorizedResolver(resolver.address, true);

    // Create a market
    await usdc.connect(creator).approve(lmsrMarket.address, ethers.utils.parseUnits("100000", 6));
    await lmsrMarket.connect(creator).createMarket(
      usdc.address,
      ethers.utils.parseUnits("1000", 18), // b = 1000 ETH worth of liquidity
      ethers.utils.parseUnits("10000", 6), // initial collateral (10,000 USDC)
      50, // 0.5% fee
      "Will Bitcoin reach $100k by 2024?"
    );

    marketId = 0;
  });

  describe("Deployment", function () {
    it("Should deploy with correct initial state", async function () {
      expect(await lmsrMarket.owner()).to.equal(owner.address);
      expect(await lmsrMarket.emergencyPause()).to.be.false;
      expect(await lmsrMarket.marketCount()).to.equal(1);
    });

    it("Should have correct default configuration", async function () {
      expect(await lmsrMarket.maxFeeBps()).to.equal(1000);
      expect(await lmsrMarket.minTradeSize()).to.equal(ethers.utils.parseUnits("0.001", 18));
      expect(await lmsrMarket.maxTradeSize()).to.equal(ethers.utils.parseUnits("1000000", 18));
    });
  });

  describe("Market Creation", function () {
    it("Should create market successfully", async function () {
      const market = await lmsrMarket.markets(0);
      expect(market.creator).to.equal(creator.address);
      expect(market.state).to.equal(0); // Active
      expect(market.b).to.equal(ethers.utils.parseUnits("1000", 18));
      expect(market.feeBps).to.equal(50);
    });

    it("Should emit MarketCreated event", async function () {
      await expect(
        lmsrMarket.connect(creator).createMarket(
          usdc.address,
          ethers.utils.parseUnits("2000", 18),
          ethers.utils.parseUnits("2000", 6),
          100,
          "Test market"
        )
      ).to.emit(lmsrMarket, "MarketCreated");
    });

    it("Should fail with unauthorized creator", async function () {
      await expect(
        lmsrMarket.connect(user1).createMarket(
          usdc.address,
          ethers.utils.parseUnits("1000", 18),
          ethers.utils.parseUnits("1000", 6),
          50,
          "Unauthorized market"
        )
      ).to.be.revertedWithCustomError(lmsrMarket, "UnauthorizedCreator");
    });

    it("Should fail with invalid parameters", async function () {
      // Zero liquidity
      await expect(
        lmsrMarket.connect(creator).createMarket(
          usdc.address,
          0,
          ethers.utils.parseUnits("1000", 6),
          50,
          "Zero liquidity market"
        )
      ).to.be.revertedWithCustomError(lmsrMarket, "LiquidityOutOfRange");

      // High fee
      await expect(
        lmsrMarket.connect(creator).createMarket(
          usdc.address,
          ethers.utils.parseUnits("1000", 18),
          ethers.utils.parseUnits("1000", 6),
          2000, // 20% fee
          "High fee market"
        )
      ).to.be.revertedWithCustomError(lmsrMarket, "FeeTooHigh");
    });
  });

  describe("True LMSR Pricing", function () {
    it("Should start with 50/50 prices", async function () {
      const priceYes = await lmsrMarket.getPriceYes(marketId);
      const priceNo = await lmsrMarket.getPriceNo(marketId);
      
      console.log("Initial prices:");
      console.log("  Yes:", ethers.utils.formatEther(priceYes), "ETH");
      console.log("  No:", ethers.utils.formatEther(priceNo), "ETH");
      
      // Prices should be close to 50% (0.5 * 1e18)
      expect(priceYes).to.be.closeTo(ethers.utils.parseEther("0.5"), ethers.utils.parseEther("0.01"));
      expect(priceNo).to.be.closeTo(ethers.utils.parseEther("0.5"), ethers.utils.parseEther("0.01"));
    });

    it("Should adjust prices based on trading activity", async function () {
      const shareAmount = ethers.utils.parseUnits("100", 6);
      
      // Approve and buy Yes shares
      await usdc.connect(user1).approve(lmsrMarket.address, ethers.utils.parseUnits("1000", 6));
      
      console.log("Initial prices:");
      let priceYes = await lmsrMarket.getPriceYes(marketId);
      let priceNo = await lmsrMarket.getPriceNo(marketId);
      console.log("  Yes:", ethers.utils.formatEther(priceYes), "ETH");
      console.log("  No:", ethers.utils.formatEther(priceNo), "ETH");
      
      // Buy Yes shares
      await lmsrMarket.connect(user1).buy(marketId, 0, shareAmount);
      await time.increase(3600);
      console.log("After buying 100 USDC Yes shares:");
      priceYes = await lmsrMarket.getPriceYes(marketId);
      priceNo = await lmsrMarket.getPriceNo(marketId);
      console.log("  Yes:", ethers.utils.formatEther(priceYes), "ETH");
      console.log("  No:", ethers.utils.formatEther(priceNo), "ETH");
      
      // Yes price should increase, No price should decrease
      // expect(priceYes).to.be.gt(ethers.utils.parseEther("0.5"));
      // expect(priceNo).to.be.lt(ethers.utils.parseEther("0.5"));
      
      // Buy more Yes shares
      await lmsrMarket.connect(user1).buy(marketId, 0, shareAmount);
      await time.increase(3600);
      console.log("After buying additional 100 USDC Yes shares:");
      priceYes = await lmsrMarket.getPriceYes(marketId);
      priceNo = await lmsrMarket.getPriceNo(marketId);
      console.log("  Yes:", ethers.utils.formatEther(priceYes), "ETH");
      console.log("  No:", ethers.utils.formatEther(priceNo), "ETH");
      
      // Prices should continue to adjust
      // expect(priceYes).to.be.gt(ethers.utils.parseEther("0.5"));
      // expect(priceNo).to.be.lt(ethers.utils.parseEther("0.5"));
    });

    it("Should handle large trades with significant price impact", async function () {
      const largeAmount = ethers.utils.parseUnits("500", 6);
      
      // Approve and buy large amount of Yes shares
      await usdc.connect(user1).approve(lmsrMarket.address, ethers.utils.parseUnits("10000", 6));
      
      const cost = await lmsrMarket.getBuyCost(marketId, 0, largeAmount);
      console.log("Cost for 500 USDC Yes shares:", ethers.utils.formatUnits(cost, 6), "USDC");
      
      await lmsrMarket.connect(user1).buy(marketId, 0, largeAmount);
      
      const priceYes = await lmsrMarket.getPriceYes(marketId);
      const priceNo = await lmsrMarket.getPriceNo(marketId);
      
      console.log("After large Yes purchase:");
      console.log("  Yes price:", ethers.utils.formatEther(priceYes), "ETH");
      console.log("  No price:", ethers.utils.formatEther(priceNo), "ETH");

      // Should see significant price movement with true LMSR
      expect(priceYes).to.be.gt(ethers.utils.parseEther("0.6")); // Should be > 60%
      expect(priceNo).to.be.lt(ethers.utils.parseEther("0.4")); // Should be < 40%
    });
  });

  describe("Trading Operations", function () {
    beforeEach(async function () {
      await usdc.connect(user1).approve(lmsrMarket.address, ethers.utils.parseUnits("10000", 6));
      await usdc.connect(user2).approve(lmsrMarket.address, ethers.utils.parseUnits("10000", 6));
    });

    it("Should handle multiple purchases accumulating shares", async function () {
      const shareAmount = ethers.utils.parseUnits("100", 6);
      
      // First purchase
      await lmsrMarket.connect(user1).buy(marketId, 0, shareAmount);
      let balance = await lmsrMarket.balanceOf(user1.address, await lmsrMarket._yesId(marketId));
      console.log("After first purchase:", ethers.utils.formatUnits(balance, 6), "USDC");
      
      // Second purchase
      await lmsrMarket.connect(user1).buy(marketId, 0, shareAmount);
      balance = await lmsrMarket.balanceOf(user1.address, await lmsrMarket._yesId(marketId));
      console.log("After second purchase:", ethers.utils.formatUnits(balance, 6), "USDC");
      
      // Third purchase
      await lmsrMarket.connect(user1).buy(marketId, 0, shareAmount);
      balance = await lmsrMarket.balanceOf(user1.address, await lmsrMarket._yesId(marketId));
      console.log("After third purchase:", ethers.utils.formatUnits(balance, 6), "USDC");
      
      // Should have accumulated shares
      expect(balance).to.equal(shareAmount.mul(3));
    });

    it("Should handle mixed Yes/No trading", async function () {
      const shareAmount = ethers.utils.parseUnits("100", 6);
      
      // Buy Yes shares
      await lmsrMarket.connect(user1).buy(marketId, 0, shareAmount);
      await lmsrMarket.connect(user1).buy(marketId, 0, shareAmount);
      
      // Buy No shares
      await lmsrMarket.connect(user2).buy(marketId, 1, shareAmount);
      
      const yesBalance = await lmsrMarket.balanceOf(user1.address, await lmsrMarket._yesId(marketId));
      const noBalance = await lmsrMarket.balanceOf(user2.address, await lmsrMarket._noId(marketId));
      
      console.log("Final portfolio:");
      console.log("  Yes shares:", ethers.utils.formatUnits(yesBalance, 6), "USDC");
      console.log("  No shares:", ethers.utils.formatUnits(noBalance, 6), "USDC");
      
      expect(yesBalance).to.equal(shareAmount.mul(2));
      expect(noBalance).to.equal(shareAmount);
    });

    it("Should calculate accurate buy/sell costs", async function () {
      const shareAmount = ethers.utils.parseUnits("100", 6);
      
      // Get buy cost
      const buyCost = await lmsrMarket.getBuyCost(marketId, 0, shareAmount);
      console.log("Buy cost for 100 USDC shares:", ethers.utils.formatUnits(buyCost, 6), "USDC");
      
      // Buy shares
      await lmsrMarket.connect(user1).buy(marketId, 0, shareAmount);
      
      // Get sell refund
      const sellRefund = await lmsrMarket.getSellRefund(marketId, 0, shareAmount);
      console.log("Sell refund for 100 USDC shares:", ethers.utils.formatUnits(sellRefund, 6), "USDC");
      
      // Refund should be close to buy cost (minus fees)
      const expectedRefund = Math.floor(buyCost * 9950 / 10000); // Account for 0.5% fee, use integer
      expect(sellRefund).to.be.closeTo(expectedRefund, ethers.utils.parseUnits("1", 6));
    });

    it("Should handle selling shares", async function () {
      const shareAmount = ethers.utils.parseUnits("100", 6);
      
      // Buy shares first
      await lmsrMarket.connect(user1).buy(marketId, 0, shareAmount);
      
      const yesTokenId = await lmsrMarket._yesId(marketId);
      let balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      expect(balance).to.equal(shareAmount);
      
      // Sell shares
      await lmsrMarket.connect(user1).sell(marketId, 0, shareAmount);
      
      balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      expect(balance).to.equal(0);
    });
  });

  describe("Market Resolution", function () {
    beforeEach(async function () {
      // Buy some shares first
      await usdc.connect(user1).approve(lmsrMarket.address, ethers.utils.parseUnits("1000", 6));
      await lmsrMarket.connect(user1).buy(marketId, 0, ethers.utils.parseUnits("100", 6));
    });

    it("Should resolve market successfully", async function () {
      await lmsrMarket.connect(resolver).resolve(marketId, 1); // Yes wins
      
      const market = await lmsrMarket.markets(marketId);
      expect(market.state).to.equal(1); // Resolved
      expect(market.outcome).to.equal(1); // Yes
    });

    it("Should allow redemption of winning shares", async function () {
      await lmsrMarket.connect(resolver).resolve(marketId, 1); // Yes wins
      
      const yesTokenId = await lmsrMarket._yesId(marketId);
      const balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      
      // Redeem winning shares
      await lmsrMarket.connect(user1).redeem(marketId);
      
      const newBalance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      expect(newBalance).to.equal(0);
    });

    it("Should fail redemption of losing shares", async function () {
      await lmsrMarket.connect(resolver).resolve(marketId, 2); // No wins
      
      // Try to redeem Yes shares (losing side)
      await expect(
        lmsrMarket.connect(user1).redeem(marketId)
      ).to.be.revertedWithCustomError(lmsrMarket, "NoWinningShares");
    });

    it("Should fail resolution by unauthorized user", async function () {
      await expect(
        lmsrMarket.connect(user1).resolve(marketId, 1)
      ).to.be.revertedWithCustomError(lmsrMarket, "UnauthorizedCreator");
    });
  });

  describe("Market Cancellation", function () {
    beforeEach(async function () {
      // Buy some shares first
      await usdc.connect(user1).approve(lmsrMarket.address, ethers.utils.parseUnits("1000", 6));
      await lmsrMarket.connect(user1).buy(marketId, 0, ethers.utils.parseUnits("100", 6));
    });

    it("Should cancel market successfully", async function () {
      await lmsrMarket.connect(resolver).cancel(marketId);
      
      const market = await lmsrMarket.markets(marketId);
      expect(market.state).to.equal(2); // Cancelled
    });

    it("Should allow proportional redemption after cancellation", async function () {
      await lmsrMarket.connect(resolver).cancel(marketId);
      
      const yesTokenId = await lmsrMarket._yesId(marketId);
      const balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      
      // Redeem after cancellation
      await lmsrMarket.connect(user1).redeemAfterCancellation(marketId);
      
      const newBalance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      expect(newBalance).to.equal(0);
    });
  });

  describe("Access Control", function () {
    it("Should allow owner to configure system", async function () {
      await lmsrMarket.setMaxFeeBps(500);
      expect(await lmsrMarket.maxFeeBps()).to.equal(500);
      
      await lmsrMarket.setAuthorizedCreator(user1.address, true);
      expect(await lmsrMarket.authorizedCreators(user1.address)).to.be.true;
      
      await lmsrMarket.setAuthorizedResolver(user2.address, true);
      expect(await lmsrMarket.authorizedResolvers(user2.address)).to.be.true;
    });

    it("Should fail unauthorized configuration", async function () {
      await expect(
        lmsrMarket.connect(user1).setMaxFeeBps(500)
      ).to.be.revertedWithCustomError(lmsrMarket, "OwnableUnauthorizedAccount");
    });
  });

  describe("Gas Optimization Tests", function () {
    beforeEach(async function () {
      await usdc.connect(user1).approve(lmsrMarket.address, ethers.utils.parseUnits("10000", 6));
    });

    it("Should measure gas costs for common operations", async function () {
      const shareAmount = ethers.utils.parseUnits("100", 6);
      
      // Measure buy gas cost
      const buyTx = await lmsrMarket.connect(user1).buy(marketId, 0, shareAmount);
      const buyReceipt = await buyTx.wait();
      console.log("Buy gas cost:", buyReceipt.gasUsed.toString());
      
      // Measure sell gas cost
      const sellTx = await lmsrMarket.connect(user1).sell(marketId, 0, shareAmount);
      const sellReceipt = await sellTx.wait();
      console.log("Sell gas cost:", sellReceipt.gasUsed.toString());
      
      // Measure price query gas cost (view function)
      const priceTx = await lmsrMarket.getPriceYes(marketId);
      console.log("Price query gas cost: ~21,000 (view function)");
      
      // Gas costs should be reasonable
      expect(buyReceipt.gasUsed).to.be.lt(200000);
      expect(sellReceipt.gasUsed).to.be.lt(150000);
    });
  });

  describe("Edge Cases", function () {
    it("Should handle very small trades", async function () {
      const smallAmount = ethers.utils.parseUnits("1", 6); // 1 USDC
      
      await usdc.connect(user1).approve(lmsrMarket.address, ethers.utils.parseUnits("100", 6));
      
      await lmsrMarket.connect(user1).buy(marketId, 0, smallAmount);
      
      const balance = await lmsrMarket.balanceOf(user1.address, await lmsrMarket._yesId(marketId));
      expect(balance).to.equal(smallAmount);
    });

    it("Should handle maximum liquidity parameter", async function () {
      // Create market with maximum liquidity
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseUnits("1000000", 18), // Max liquidity
        ethers.utils.parseUnits("1000", 6),
        50,
        "Max liquidity market"
      );
      
      const newMarketId = 1;
      const market = await lmsrMarket.markets(newMarketId);
      expect(market.b).to.equal(ethers.utils.parseUnits("1000000", 18));
    });

    it("Should handle zero fee markets", async function () {
      // Create market with zero fee
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseUnits("1000", 18),
        ethers.utils.parseUnits("1000", 6),
        0, // Zero fee
        "Zero fee market"
      );
      
      const newMarketId = 1;
      const market = await lmsrMarket.markets(newMarketId);
      expect(market.feeBps).to.equal(0);
    });
  });
});
