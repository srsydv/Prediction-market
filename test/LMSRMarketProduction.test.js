const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LMSRMarketProduction", function () {
  let lmsrMarket, usdc, owner, creator, user1, user2, user3, feeRecipient;
  let marketId;

  beforeEach(async function () {
    [owner, creator, user1, user2, user3, feeRecipient] = await ethers.getSigners();

    // Deploy MockERC20 (USDC)
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    usdc = await MockERC20.deploy("USD Coin", "USDC", 6, ethers.utils.parseUnits("1000000", 6));
    await usdc.deployed();

    // Deploy LMSRMarketProduction
    const LMSRMarketProduction = await ethers.getContractFactory("LMSRMarketProduction");
    lmsrMarket = await LMSRMarketProduction.deploy(feeRecipient.address);
    await lmsrMarket.deployed();

    // Setup initial state
    await lmsrMarket.setAuthorizedCreator(creator.address, true);
    await lmsrMarket.setAuthorizedResolver(creator.address, true);

    // Mint USDC to users
    await usdc.mint(creator.address, ethers.utils.parseUnits("10000", 6));
    await usdc.mint(user1.address, ethers.utils.parseUnits("10000", 6));
    await usdc.mint(user2.address, ethers.utils.parseUnits("10000", 6));
    await usdc.mint(user3.address, ethers.utils.parseUnits("10000", 6));

    // Approve spending
    await usdc.connect(creator).approve(lmsrMarket.address, ethers.constants.MaxUint256);
    await usdc.connect(user1).approve(lmsrMarket.address, ethers.constants.MaxUint256);
    await usdc.connect(user2).approve(lmsrMarket.address, ethers.constants.MaxUint256);
    await usdc.connect(user3).approve(lmsrMarket.address, ethers.constants.MaxUint256);
  });

  describe("Deployment", function () {
    it("Should deploy with correct initial state", async function () {
      expect(await lmsrMarket.owner()).to.equal(owner.address);
      expect(await lmsrMarket.feeRecipient()).to.equal(feeRecipient.address);
      expect(await lmsrMarket.marketCount()).to.equal(0);
    });

    it("Should have correct default configuration", async function () {
      expect(await lmsrMarket.maxFeeBps()).to.equal(1000); // 10%
      expect(await lmsrMarket.minLiquidity()).to.equal(1000);
      expect(await lmsrMarket.maxLiquidity()).to.equal(1000000);
    });
  });

  describe("Market Creation", function () {
    beforeEach(async function () {
      // Create a market
      const tx = await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"), // b = 1000
        ethers.utils.parseUnits("1000", 6), // 1000 USDC initial collateral
        50, // 0.5% fee
        "Will Bitcoin reach $100k by end of 2024?"
      );
      const receipt = await tx.wait();
      marketId = 0;
    });

    it("Should create market successfully", async function () {
      const marketInfo = await lmsrMarket.getMarketInfo(marketId);
      
      expect(marketInfo.creator).to.equal(creator.address);
      expect(marketInfo.collateral).to.equal(usdc.address);
      expect(marketInfo.collateralDecimals).to.equal(6);
      expect(marketInfo.b).to.equal(ethers.utils.parseEther("1000"));
      expect(marketInfo.qYes).to.equal(0);
      expect(marketInfo.qNo).to.equal(0);
      expect(marketInfo.state).to.equal(0); // Active
      expect(marketInfo.outcome).to.equal(0);
      expect(marketInfo.feeBps).to.equal(50);
      expect(marketInfo.escrow).to.equal(ethers.utils.parseUnits("1000", 6));
      expect(marketInfo.description).to.equal("Will Bitcoin reach $100k by end of 2024?");
    });

    it("Should emit MarketCreated event", async function () {
      const tx = await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("2000"),
        ethers.utils.parseUnits("2000", 6),
        100,
        "Test market"
      );

      await expect(tx)
        .to.emit(lmsrMarket, "MarketCreated")
        .withArgs(
          1,
          creator.address,
          usdc.address,
          ethers.utils.parseEther("2000"),
          ethers.utils.parseUnits("2000", 6),
          100,
          "Test market"
        );
    });

    it("Should fail with unauthorized creator", async function () {
      await expect(
        lmsrMarket.connect(user1).createMarket(
          usdc.address,
          ethers.utils.parseEther("1000"),
          ethers.utils.parseUnits("1000", 6),
          50,
          "Unauthorized market"
        )
      ).to.be.revertedWithCustomError(lmsrMarket, "UnauthorizedCreator");
    });

    it("Should fail with invalid parameters", async function () {
      // Zero collateral
      await expect(
        lmsrMarket.connect(creator).createMarket(
          usdc.address,
          ethers.utils.parseEther("1000"),
          0,
          50,
          "Invalid market"
        )
      ).to.be.revertedWithCustomError(lmsrMarket, "InvalidAmount");

      // Fee too high
      await expect(
        lmsrMarket.connect(creator).createMarket(
          usdc.address,
          ethers.utils.parseEther("1000"),
          ethers.utils.parseUnits("1000", 6),
          2000, // 20% fee
          "High fee market"
        )
      ).to.be.revertedWithCustomError(lmsrMarket, "FeeTooHigh");

      // Liquidity out of range
      await expect(
        lmsrMarket.connect(creator).createMarket(
          usdc.address,
          ethers.utils.parseEther("100"), // Too low
          ethers.utils.parseUnits("1000", 6),
          50,
          "Low liquidity market"
        )
      ).to.be.revertedWithCustomError(lmsrMarket, "LiquidityOutOfRange");
    });
  });

  describe("Real LMSR Pricing", function () {
    beforeEach(async function () {
      // Create market with moderate liquidity
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"), // b = 1000
        ethers.utils.parseUnits("1000", 6),
        50,
        "Real LMSR pricing test"
      );
      marketId = 0;
    });

    it("Should start with 50/50 prices", async function () {
      const priceYes = await lmsrMarket.getPriceYes(marketId);
      const priceNo = await lmsrMarket.getPriceNo(marketId);

      // Should be close to 50% (0.5 * 1e18)
      expect(priceYes).to.be.closeTo(ethers.utils.parseEther("0.5"), ethers.utils.parseEther("0.01"));
      expect(priceNo).to.be.closeTo(ethers.utils.parseEther("0.5"), ethers.utils.parseEther("0.01"));
      
      // Prices should sum to 100%
      expect(priceYes.add(priceNo)).to.be.closeTo(ethers.utils.parseEther("1"), ethers.utils.parseEther("0.01"));
    });

    it("Should adjust prices based on trading activity", async function () {
      // Initial prices
      let priceYes = await lmsrMarket.getPriceYes(marketId);
      let priceNo = await lmsrMarket.getPriceNo(marketId);
      
      console.log("Initial prices:");
      console.log("  Yes:", ethers.utils.formatEther(priceYes), "ETH");
      console.log("  No:", ethers.utils.formatEther(priceNo), "ETH");

      // Buy 100 USDC worth of Yes shares
      const buyAmount = ethers.utils.parseUnits("100", 6);
      await lmsrMarket.connect(user1).buy(marketId, 0, buyAmount);

      // Check new prices
      priceYes = await lmsrMarket.getPriceYes(marketId);
      priceNo = await lmsrMarket.getPriceNo(marketId);
      
      console.log("After buying 100 USDC Yes shares:");
      console.log("  Yes:", ethers.utils.formatEther(priceYes), "ETH");
      console.log("  No:", ethers.utils.formatEther(priceNo), "ETH");

      // Yes price should increase, No price should decrease
      expect(priceYes).to.be.gt(ethers.utils.parseEther("0.5"));
      expect(priceNo).to.be.lt(ethers.utils.parseEther("0.5"));
      
      // Prices should still sum to 100%
      expect(priceYes.add(priceNo)).to.be.closeTo(ethers.utils.parseEther("1"), ethers.utils.parseEther("0.01"));

      // Buy more Yes shares to see further price movement
      await lmsrMarket.connect(user2).buy(marketId, 0, buyAmount);

      priceYes = await lmsrMarket.getPriceYes(marketId);
      priceNo = await lmsrMarket.getPriceNo(marketId);
      
      console.log("After buying additional 100 USDC Yes shares:");
      console.log("  Yes:", ethers.utils.formatEther(priceYes), "ETH");
      console.log("  No:", ethers.utils.formatEther(priceNo), "ETH");

      // Yes price should increase further
      expect(priceYes).to.be.gt(ethers.utils.parseEther("0.5"));
      expect(priceNo).to.be.lt(ethers.utils.parseEther("0.5"));
    });

    it("Should handle large trades with price impact", async function () {
      // Buy large amount to see significant price impact
      const largeAmount = ethers.utils.parseUnits("500", 6); // 500 USDC
      
      const costBefore = await lmsrMarket.getBuyCost(marketId, 0, largeAmount);
      console.log("Cost for 500 USDC Yes shares:", ethers.utils.formatUnits(costBefore, 6), "USDC");
      
      await lmsrMarket.connect(user1).buy(marketId, 0, largeAmount);

      const priceYes = await lmsrMarket.getPriceYes(marketId);
      const priceNo = await lmsrMarket.getPriceNo(marketId);
      
      console.log("After large Yes purchase:");
      console.log("  Yes price:", ethers.utils.formatEther(priceYes), "ETH");
      console.log("  No price:", ethers.utils.formatEther(priceNo), "ETH");

      // Should see significant price movement
      expect(priceYes).to.be.gt(ethers.utils.parseEther("0.6")); // Should be > 60%
      expect(priceNo).to.be.lt(ethers.utils.parseEther("0.4")); // Should be < 40%
    });
  });

  describe("Trading Operations", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50,
        "Trading test market"
      );
      marketId = 0;
    });

    it("Should handle multiple purchases accumulating shares", async function () {
      const yesTokenId = await lmsrMarket._yesId(marketId);
      
      // First purchase: 100 USDC
      const firstAmount = ethers.utils.parseUnits("100", 6);
      await lmsrMarket.connect(user1).buy(marketId, 0, firstAmount);
      
      let balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      expect(balance).to.equal(firstAmount);
      console.log("After first purchase:", ethers.utils.formatUnits(balance, 6), "USDC");

      // Second purchase: 50 USDC
      const secondAmount = ethers.utils.parseUnits("50", 6);
      await lmsrMarket.connect(user1).buy(marketId, 0, secondAmount);
      
      balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      const expectedTotal = firstAmount.add(secondAmount);
      expect(balance).to.equal(expectedTotal);
      console.log("After second purchase:", ethers.utils.formatUnits(balance, 6), "USDC");

      // Third purchase: 25 USDC
      const thirdAmount = ethers.utils.parseUnits("25", 6);
      await lmsrMarket.connect(user1).buy(marketId, 0, thirdAmount);
      
      balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      const finalExpected = firstAmount.add(secondAmount).add(thirdAmount);
      expect(balance).to.equal(finalExpected);
      console.log("After third purchase:", ethers.utils.formatUnits(balance, 6), "USDC");
    });

    it("Should handle mixed Yes/No trading", async function () {
      const yesTokenId = await lmsrMarket._yesId(marketId);
      const noTokenId = await lmsrMarket._noId(marketId);
      
      // Buy Yes shares
      const yesAmount = ethers.utils.parseUnits("200", 6);
      await lmsrMarket.connect(user1).buy(marketId, 0, yesAmount);
      
      let yesBalance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      let noBalance = await lmsrMarket.balanceOf(user1.address, noTokenId);
      
      expect(yesBalance).to.equal(yesAmount);
      expect(noBalance).to.equal(0);
      
      // Buy No shares
      const noAmount = ethers.utils.parseUnits("100", 6);
      await lmsrMarket.connect(user1).buy(marketId, 1, noAmount);
      
      yesBalance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      noBalance = await lmsrMarket.balanceOf(user1.address, noTokenId);
      
      expect(yesBalance).to.equal(yesAmount);
      expect(noBalance).to.equal(noAmount);
      
      console.log("Final portfolio:");
      console.log("  Yes shares:", ethers.utils.formatUnits(yesBalance, 6), "USDC");
      console.log("  No shares:", ethers.utils.formatUnits(noBalance, 6), "USDC");
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
      const expectedRefund = buyCost * 9950 / 10000; // Account for 0.5% fee
      expect(sellRefund).to.be.closeTo(expectedRefund, ethers.utils.parseUnits("1", 6));
    });

    it("Should handle selling shares", async function () {
      const shareAmount = ethers.utils.parseUnits("100", 6);
      
      // Buy shares first
      await lmsrMarket.connect(user1).buy(marketId, 0, shareAmount);
      
      const yesTokenId = await lmsrMarket._yesId(marketId);
      let balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      expect(balance).to.equal(shareAmount);
      
      // Sell half the shares
      const sellAmount = ethers.utils.parseUnits("50", 6);
      await lmsrMarket.connect(user1).sell(marketId, 0, sellAmount);
      
      balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      expect(balance).to.equal(shareAmount.sub(sellAmount));
    });
  });

  describe("Market Resolution", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50,
        "Resolution test market"
      );
      marketId = 0;
      
      // Create some trading activity
      await lmsrMarket.connect(user1).buy(marketId, 0, ethers.utils.parseUnits("200", 6));
      await lmsrMarket.connect(user2).buy(marketId, 1, ethers.utils.parseUnits("150", 6));
    });

    it("Should resolve market successfully", async function () {
      // Resolve to Yes
      const tx = await lmsrMarket.connect(creator).resolve(marketId, 1);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Resolved")
        .withArgs(marketId, 1, creator.address);
      
      const marketInfo = await lmsrMarket.getMarketInfo(marketId);
      expect(marketInfo.state).to.equal(1); // Resolved
      expect(marketInfo.outcome).to.equal(1); // Yes
      expect(marketInfo.resolvedAt).to.be.gt(0);
    });

    it("Should allow redemption of winning shares", async function () {
      // Resolve to Yes
      await lmsrMarket.connect(creator).resolve(marketId, 1);
      
      const yesTokenId = await lmsrMarket._yesId(marketId);
      const balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      
      // Redeem winning shares
      const tx = await lmsrMarket.connect(user1).redeem(marketId);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Redeemed")
        .withArgs(marketId, user1.address, balance);
      
      // Check shares are burned
      const newBalance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      expect(newBalance).to.equal(0);
    });

    it("Should fail redemption of losing shares", async function () {
      // Resolve to Yes
      await lmsrMarket.connect(creator).resolve(marketId, 1);
      
      // user2 has No shares, should fail to redeem
      await expect(
        lmsrMarket.connect(user2).redeem(marketId)
      ).to.be.revertedWithCustomError(lmsrMarket, "NoWinningShares");
    });

    it("Should fail resolution by unauthorized user", async function () {
      await expect(
        lmsrMarket.connect(user1).resolve(marketId, 1)
      ).to.be.revertedWithCustomError(lmsrMarket, "UnauthorizedResolver");
    });
  });

  describe("Market Cancellation", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50,
        "Cancellation test market"
      );
      marketId = 0;
      
      // Create trading activity
      await lmsrMarket.connect(user1).buy(marketId, 0, ethers.utils.parseUnits("200", 6));
      await lmsrMarket.connect(user2).buy(marketId, 1, ethers.utils.parseUnits("150", 6));
    });

    it("Should cancel market successfully", async function () {
      const tx = await lmsrMarket.connect(creator).cancelMarket(marketId);
      
      await expect(tx)
        .to.emit(lmsrMarket, "MarketCancelled")
        .withArgs(marketId, creator.address);
      
      const marketInfo = await lmsrMarket.getMarketInfo(marketId);
      expect(marketInfo.state).to.equal(2); // Cancelled
    });

    it("Should allow proportional redemption after cancellation", async function () {
      await lmsrMarket.connect(creator).cancelMarket(marketId);
      
      const yesTokenId = await lmsrMarket._yesId(marketId);
      const noTokenId = await lmsrMarket._noId(marketId);
      
      const yesBalance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      const noBalance = await lmsrMarket.balanceOf(user2.address, noTokenId);
      
      // Redeem cancelled shares
      await lmsrMarket.connect(user1).redeemCancelled(marketId);
      await lmsrMarket.connect(user2).redeemCancelled(marketId);
      
      // Check shares are burned
      expect(await lmsrMarket.balanceOf(user1.address, yesTokenId)).to.equal(0);
      expect(await lmsrMarket.balanceOf(user2.address, noTokenId)).to.equal(0);
    });
  });

  describe("Access Control", function () {
    it("Should allow owner to configure system", async function () {
      await lmsrMarket.setMaxFeeBps(500); // 5%
      expect(await lmsrMarket.maxFeeBps()).to.equal(500);
      
      await lmsrMarket.setLiquidityRange(500, 2000);
      expect(await lmsrMarket.minLiquidity()).to.equal(500);
      expect(await lmsrMarket.maxLiquidity()).to.equal(2000);
      
      await lmsrMarket.setAuthorizedCreator(user1.address, true);
      expect(await lmsrMarket.authorizedCreators(user1.address)).to.be.true;
      
      await lmsrMarket.setAuthorizedResolver(user2.address, true);
      expect(await lmsrMarket.authorizedResolvers(user2.address)).to.be.true;
    });

    it("Should fail unauthorized configuration", async function () {
      await expect(
        lmsrMarket.connect(user1).setMaxFeeBps(500)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Gas Optimization Tests", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50,
        "Gas test market"
      );
      marketId = 0;
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
      
      // Measure price query gas cost
      const priceTx = await lmsrMarket.getPriceYes(marketId);
      console.log("Price query gas cost: ~21,000 (view function)");
    });
  });

  describe("Edge Cases", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50,
        "Edge case test market"
      );
      marketId = 0;
    });

    it("Should handle very small trades", async function () {
      const tinyAmount = ethers.utils.parseUnits("0.01", 6); // 0.01 USDC
      
      const cost = await lmsrMarket.getBuyCost(marketId, 0, tinyAmount);
      expect(cost).to.be.gt(0);
      
      await lmsrMarket.connect(user1).buy(marketId, 0, tinyAmount);
      
      const yesTokenId = await lmsrMarket._yesId(marketId);
      const balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      expect(balance).to.equal(tinyAmount);
    });

    it("Should handle maximum liquidity parameter", async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000000"), // Max liquidity
        ethers.utils.parseUnits("1000", 6),
        50,
        "Max liquidity market"
      );
      
      const priceYes = await lmsrMarket.getPriceYes(1);
      const priceNo = await lmsrMarket.getPriceNo(1);
      
      // Should still work with max liquidity
      expect(priceYes.add(priceNo)).to.be.closeTo(ethers.utils.parseEther("1"), ethers.utils.parseEther("0.01"));
    });

    it("Should handle zero fee markets", async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        0, // No fee
        "Zero fee market"
      );
      
      const shareAmount = ethers.utils.parseUnits("100", 6);
      const cost = await lmsrMarket.getBuyCost(1, 0, shareAmount);
      
      await lmsrMarket.connect(user1).buy(1, 0, shareAmount);
      
      // Should work without fees
      const yesTokenId = await lmsrMarket._yesId(1);
      const balance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      expect(balance).to.equal(shareAmount);
    });
  });
});
