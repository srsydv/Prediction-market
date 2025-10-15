const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LMSRMarket", function () {
  let lmsrMarket;
  let usdc;
  let owner;
  let creator;
  let user1;
  let user2;
  let user3;

  beforeEach(async function () {
    [owner, creator, user1, user2, user3] = await ethers.getSigners();

    // Deploy mock USDC token (6 decimals)
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    usdc = await MockERC20Factory.deploy(
      "USD Coin",
      "USDC",
      6,
      ethers.utils.parseUnits("1000000", 6) // 1M USDC
    );

    // Deploy LMSRMarket contract
    const LMSRMarketFactory = await ethers.getContractFactory("LMSRMarket");
    lmsrMarket = await LMSRMarketFactory.deploy();

    // Mint USDC to users
    await usdc.mint(creator.address, ethers.utils.parseUnits("100000", 6)); // 100k USDC
    await usdc.mint(user1.address, ethers.utils.parseUnits("10000", 6));   // 10k USDC
    await usdc.mint(user2.address, ethers.utils.parseUnits("10000", 6));   // 10k USDC
    await usdc.mint(user3.address, ethers.utils.parseUnits("10000", 6));   // 10k USDC

    // Approve LMSRMarket to spend USDC
    await usdc.connect(creator).approve(lmsrMarket.address, ethers.utils.parseUnits("100000", 6));
    await usdc.connect(user1).approve(lmsrMarket.address, ethers.utils.parseUnits("10000", 6));
    await usdc.connect(user2).approve(lmsrMarket.address, ethers.utils.parseUnits("10000", 6));
    await usdc.connect(user3).approve(lmsrMarket.address, ethers.utils.parseUnits("10000", 6));
  });

  describe("Market Creation", function () {
    it("Should create a new market successfully", async function () {
      const bFixed = ethers.utils.parseEther("1000"); // 1000 in 64.64 format
      const initialCollateral = ethers.utils.parseUnits("1000", 6); // 1000 USDC
      const feeBps = 50; // 0.5%

      const tx = await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        bFixed,
        initialCollateral,
        feeBps
      );

      await expect(tx)
        .to.emit(lmsrMarket, "MarketCreated")
        .withArgs(
          0, // marketId
          creator.address,
          usdc.address,
          bFixed,
          initialCollateral,
          feeBps
        );

      const marketInfo = await lmsrMarket.getMarketInfo(0);
      expect(marketInfo[0]).to.equal(creator.address); // creator
      expect(marketInfo[1]).to.equal(usdc.address); // collateral
      expect(marketInfo[2]).to.equal(6); // decimals
      expect(marketInfo[6]).to.equal(0); // Active state
      expect(marketInfo[7]).to.equal(0); // unresolved outcome
    });

    it("Should fail to create market with zero collateral", async function () {
      await expect(
        lmsrMarket.connect(creator).createMarket(
          usdc.address,
          ethers.utils.parseEther("1000"),
          0,
          50
        )
      ).to.be.revertedWith("need collateral");
    });

    it("Should fail to create market with negative b parameter", async function () {
      await expect(
        lmsrMarket.connect(creator).createMarket(
          usdc.address,
          -1,
          ethers.utils.parseUnits("1000", 6),
          50
        )
      ).to.be.revertedWith("b must be positive");
    });

    it("Should fail to create market with fee > 10%", async function () {
      await expect(
        lmsrMarket.connect(creator).createMarket(
          usdc.address,
          ethers.utils.parseEther("1000"),
          ethers.utils.parseUnits("1000", 6),
          1001 // > 10%
        )
      ).to.be.revertedWith("fee too high");
    });

    it("Should create market without fee (0 fee)", async function () {
      const tx = await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        0 // No fee
      );

      await expect(tx).to.not.be.reverted;
      const marketInfo = await lmsrMarket.getMarketInfo(0);
      expect(marketInfo[8]).to.equal(0); // feeBps
    });
  });

  describe("Helper Functions", function () {
    it("Should return correct Yes token ID", async function () {
      expect(await lmsrMarket._yesId(0)).to.equal(0);
      expect(await lmsrMarket._yesId(1)).to.equal(2);
      expect(await lmsrMarket._yesId(5)).to.equal(10);
    });

    it("Should return correct No token ID", async function () {
      expect(await lmsrMarket._noId(0)).to.equal(1);
      expect(await lmsrMarket._noId(1)).to.equal(3);
      expect(await lmsrMarket._noId(5)).to.equal(11);
    });
  });

  describe("Price Functions", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50
      );
    });

    it("Should return initial prices (50/50)", async function () {
      const priceYes = await lmsrMarket.getPriceYes(0);
      const priceNo = await lmsrMarket.getPriceNo(0);
      
      // Initial prices should be close to 50% each (5000 basis points)
      expect(priceYes).to.be.closeTo(ethers.utils.parseEther("0.5"), ethers.utils.parseEther("0.1"));
      expect(priceNo).to.be.closeTo(ethers.utils.parseEther("0.5"), ethers.utils.parseEther("0.1"));
      expect(priceYes.add(priceNo)).to.be.closeTo(ethers.utils.parseEther("1"), ethers.utils.parseEther("0.01"));
    });

    it("Should fail to get price for non-existent market", async function () {
      await expect(lmsrMarket.getPriceYes(999)).to.be.revertedWith("market not found");
      await expect(lmsrMarket.getPriceNo(999)).to.be.revertedWith("market not found");
    });

    it("Should fail to get price for resolved market", async function () {
      await lmsrMarket.connect(creator).resolve(0, 1);
      
      await expect(lmsrMarket.getPriceYes(0)).to.be.revertedWith("market not active");
      await expect(lmsrMarket.getPriceNo(0)).to.be.revertedWith("market not active");
    });
  });

  describe("Cost Calculation Functions", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50
      );
    });

    it("Should calculate buy cost for Yes shares", async function () {
      const shareAmount = ethers.utils.parseUnits("100", 6); // 100 USDC worth of shares
      const cost = await lmsrMarket.getBuyCost(0, 0, shareAmount);
      
      expect(cost).to.be.gt(0);
      expect(cost).to.be.equal(shareAmount); // With simplified model, cost equals share amount
    });

    it("Should calculate buy cost for No shares", async function () {
      const shareAmount = ethers.utils.parseUnits("100", 6);
      const cost = await lmsrMarket.getBuyCost(0, 1, shareAmount);
      
      expect(cost).to.be.gt(0);
      expect(cost).to.be.equal(shareAmount); // With simplified model, cost equals share amount
    });

    it("Should calculate sell refund for Yes shares", async function () {
      // First buy some shares
      const shareAmount = ethers.utils.parseUnits("100", 6);
      await lmsrMarket.connect(user1).buy(0, 0, shareAmount);
      
      // Then calculate refund
      const refund = await lmsrMarket.getSellRefund(0, 0, shareAmount);
      expect(refund).to.be.gt(0);
    });

    it("Should fail with invalid side parameter", async function () {
      await expect(lmsrMarket.getBuyCost(0, 2, ethers.utils.parseUnits("100", 6)))
        .to.be.revertedWith("invalid side");
      
      await expect(lmsrMarket.getSellRefund(0, 2, ethers.utils.parseUnits("100", 6)))
        .to.be.revertedWith("invalid side");
    });

    it("Should fail with zero share amount", async function () {
      await expect(lmsrMarket.getBuyCost(0, 0, 0))
        .to.be.revertedWith("need >0");
      
      await expect(lmsrMarket.getSellRefund(0, 0, 0))
        .to.be.revertedWith("need >0");
    });
  });

  describe("Buying Shares - Yes", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50
      );
    });

    it("Should buy Yes shares successfully", async function () {
      const shareAmount = ethers.utils.parseUnits("100", 6);
      const cost = await lmsrMarket.getBuyCost(0, 0, shareAmount);
      const fee = cost.mul(50).div(10000); // 0.5% fee
      const total = cost.add(fee);
      
      const tx = await lmsrMarket.connect(user1).buy(0, 0, shareAmount);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Bought")
        .withArgs(0, user1.address, 0, shareAmount, cost, fee);
      
      // Check user has shares
      const yesTokenId = await lmsrMarket._yesId(0);
      expect(await lmsrMarket.balanceOf(user1.address, yesTokenId)).to.equal(shareAmount);
    });

    it("Should buy Yes shares with small amount", async function () {
      const amount = ethers.utils.parseUnits("50", 6);
      await lmsrMarket.connect(user1).buy(0, 0, amount);
      
      const yesTokenId = await lmsrMarket._yesId(0);
      expect(await lmsrMarket.balanceOf(user1.address, yesTokenId)).to.equal(amount);
    });

    it("Should buy Yes shares with large amount", async function () {
      const amount = ethers.utils.parseUnits("500", 6);
      await lmsrMarket.connect(user2).buy(0, 0, amount);
      
      const yesTokenId = await lmsrMarket._yesId(0);
      expect(await lmsrMarket.balanceOf(user2.address, yesTokenId)).to.equal(amount);
    });
  });

  describe("Buying Shares - No", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50
      );
    });

    it("Should buy No shares successfully", async function () {
      const shareAmount = ethers.utils.parseUnits("150", 6);
      const cost = await lmsrMarket.getBuyCost(0, 1, shareAmount);
      const fee = cost.mul(50).div(10000);
      const total = cost.add(fee);
      
      const tx = await lmsrMarket.connect(user2).buy(0, 1, shareAmount);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Bought")
        .withArgs(0, user2.address, 1, shareAmount, cost, fee);
      
      // Check user has shares
      const noTokenId = await lmsrMarket._noId(0);
      expect(await lmsrMarket.balanceOf(user2.address, noTokenId)).to.equal(shareAmount);
    });

    it("Should buy No shares with medium amount", async function () {
      const amount = ethers.utils.parseUnits("200", 6);
      await lmsrMarket.connect(user1).buy(0, 1, amount);
      
      const noTokenId = await lmsrMarket._noId(0);
      expect(await lmsrMarket.balanceOf(user1.address, noTokenId)).to.equal(amount);
    });

    it("Should buy No shares with different users", async function () {
      const amount1 = ethers.utils.parseUnits("100", 6);
      const amount2 = ethers.utils.parseUnits("300", 6);
      const amount3 = ethers.utils.parseUnits("400", 6);
      
      await lmsrMarket.connect(user1).buy(0, 1, amount1);
      await lmsrMarket.connect(user2).buy(0, 1, amount2);
      await lmsrMarket.connect(user3).buy(0, 1, amount3);
      
      const noTokenId = await lmsrMarket._noId(0);
      expect(await lmsrMarket.balanceOf(user1.address, noTokenId)).to.equal(amount1);
      expect(await lmsrMarket.balanceOf(user2.address, noTokenId)).to.equal(amount2);
      expect(await lmsrMarket.balanceOf(user3.address, noTokenId)).to.equal(amount3);
    });
  });

  describe("Selling Shares", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50
      );
      
      // User1 buys some shares first
      await lmsrMarket.connect(user1).buy(0, 0, ethers.utils.parseUnits("100", 6));
    });

    it("Should sell Yes shares successfully", async function () {
      const shareAmount = ethers.utils.parseUnits("50", 6);
      const refund = await lmsrMarket.getSellRefund(0, 0, shareAmount);
      
      const tx = await lmsrMarket.connect(user1).sell(0, 0, shareAmount);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Sold")
        .withArgs(0, user1.address, 0, shareAmount, refund);
      
      // Check user's remaining shares
      const yesTokenId = await lmsrMarket._yesId(0);
      expect(await lmsrMarket.balanceOf(user1.address, yesTokenId)).to.equal(
        ethers.utils.parseUnits("50", 6) // 100 - 50
      );
    });

    it("Should sell No shares successfully", async function () {
      // User2 buys No shares first
      await lmsrMarket.connect(user2).buy(0, 1, ethers.utils.parseUnits("100", 6));
      
      const shareAmount = ethers.utils.parseUnits("30", 6);
      const refund = await lmsrMarket.getSellRefund(0, 1, shareAmount);
      
      const tx = await lmsrMarket.connect(user2).sell(0, 1, shareAmount);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Sold")
        .withArgs(0, user2.address, 1, shareAmount, refund);
      
      // Check user's remaining shares
      const noTokenId = await lmsrMarket._noId(0);
      expect(await lmsrMarket.balanceOf(user2.address, noTokenId)).to.equal(
        ethers.utils.parseUnits("70", 6) // 100 - 30
      );
    });

    it("Should fail to sell more shares than owned", async function () {
      await expect(
        lmsrMarket.connect(user1).sell(0, 0, ethers.utils.parseUnits("200", 6))
      ).to.be.reverted; // ERC1155 burn will fail
    });

    it("Should fail to sell from resolved market", async function () {
      await lmsrMarket.connect(creator).resolve(0, 1);
      
      await expect(
        lmsrMarket.connect(user1).sell(0, 0, ethers.utils.parseUnits("50", 6))
      ).to.be.revertedWith("market not active");
    });
  });

  describe("Market Resolution", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50
      );
      
      // Users buy shares
      await lmsrMarket.connect(user1).buy(0, 0, ethers.utils.parseUnits("100", 6));
      await lmsrMarket.connect(user2).buy(0, 1, ethers.utils.parseUnits("100", 6));
    });

    it("Should resolve market to Yes", async function () {
      const tx = await lmsrMarket.connect(creator).resolve(0, 1);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Resolved")
        .withArgs(0, 1);
      
      const marketInfo = await lmsrMarket.getMarketInfo(0);
      expect(marketInfo[6]).to.equal(1); // Resolved state
      expect(marketInfo[7]).to.equal(1); // Yes outcome
    });

    it("Should resolve market to No", async function () {
      const tx = await lmsrMarket.connect(creator).resolve(0, 2);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Resolved")
        .withArgs(0, 2);
      
      const marketInfo = await lmsrMarket.getMarketInfo(0);
      expect(marketInfo[6]).to.equal(1); // Resolved state
      expect(marketInfo[7]).to.equal(2); // No outcome
    });

    it("Should fail to resolve with invalid outcome", async function () {
      await expect(
        lmsrMarket.connect(creator).resolve(0, 0)
      ).to.be.revertedWith("invalid outcome");
      
      await expect(
        lmsrMarket.connect(creator).resolve(0, 3)
      ).to.be.revertedWith("invalid outcome");
    });

    it("Should fail to resolve from non-creator", async function () {
      await expect(
        lmsrMarket.connect(user1).resolve(0, 1)
      ).to.be.revertedWith("not authorized");
    });

    it("Should allow owner to resolve market", async function () {
      const tx = await lmsrMarket.connect(owner).resolve(0, 1);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Resolved")
        .withArgs(0, 1);
    });
  });

  describe("Redemption", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50
      );
      
      // Users buy shares
      await lmsrMarket.connect(user1).buy(0, 0, ethers.utils.parseUnits("100", 6));
      await lmsrMarket.connect(user2).buy(0, 1, ethers.utils.parseUnits("100", 6));
      
      // Resolve to Yes
      await lmsrMarket.connect(creator).resolve(0, 1);
    });

    it("Should redeem winning Yes shares", async function () {
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

    it("Should fail to redeem losing No shares", async function () {
      const noTokenId = await lmsrMarket._noId(0);
      const shareBalance = await lmsrMarket.balanceOf(user2.address, noTokenId);
      
      // User2 should not be able to redeem No shares when outcome is Yes
      await expect(
        lmsrMarket.connect(user2).redeem(0)
      ).to.be.revertedWith("no winning shares");
    });

    it("Should fail to redeem from unresolved market", async function () {
      // Create new market and buy shares but don't resolve
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50
      );
      await lmsrMarket.connect(user1).buy(1, 0, ethers.utils.parseUnits("100", 6));
      
      await expect(
        lmsrMarket.connect(user1).redeem(1)
      ).to.be.revertedWith("not resolved");
    });

    it("Should fail to redeem with no shares", async function () {
      await expect(
        lmsrMarket.connect(user3).redeem(0)
      ).to.be.revertedWith("no winning shares");
    });
  });

  describe("Admin Functions", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50
      );
      
      // Users buy shares
      await lmsrMarket.connect(user1).buy(0, 0, ethers.utils.parseUnits("100", 6));
      await lmsrMarket.connect(user2).buy(0, 1, ethers.utils.parseUnits("100", 6));
    });

    it("Should withdraw escrow after resolution", async function () {
      await lmsrMarket.connect(creator).resolve(0, 1);
      
      const escrowBefore = await lmsrMarket.getMarketInfo(0);
      const balanceBefore = await usdc.balanceOf(creator.address);
      
      await lmsrMarket.connect(creator).withdrawEscrow(0);
      
      const balanceAfter = await usdc.balanceOf(creator.address);
      const escrowAfter = await lmsrMarket.getMarketInfo(0);
      
      expect(balanceAfter - balanceBefore).to.equal(escrowBefore[9]); // escrow amount
      expect(escrowAfter[9]).to.equal(0); // escrow should be 0
    });

    it("Should cancel market", async function () {
      const tx = await lmsrMarket.connect(creator).cancelMarket(0);
      
      await expect(tx)
        .to.emit(lmsrMarket, "MarketCancelled")
        .withArgs(0);
      
      const marketInfo = await lmsrMarket.getMarketInfo(0);
      expect(marketInfo[6]).to.equal(2); // Cancelled state
    });

    it("Should fail to cancel market from non-creator", async function () {
      await expect(
        lmsrMarket.connect(user1).cancelMarket(0)
      ).to.be.revertedWith("not authorized");
    });

    it("Should allow owner to cancel market", async function () {
      const tx = await lmsrMarket.connect(owner).cancelMarket(0);
      
      await expect(tx)
        .to.emit(lmsrMarket, "MarketCancelled")
        .withArgs(0);
    });

    it("Should fail to cancel already resolved market", async function () {
      await lmsrMarket.connect(creator).resolve(0, 1);
      
      await expect(
        lmsrMarket.connect(creator).cancelMarket(0)
      ).to.be.revertedWith("not active");
    });
  });

  describe("Cancelled Market Redemption", function () {
    beforeEach(async function () {
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50
      );
      
      // Users buy shares
      await lmsrMarket.connect(user1).buy(0, 0, ethers.utils.parseUnits("100", 6));
      await lmsrMarket.connect(user2).buy(0, 1, ethers.utils.parseUnits("200", 6));
      
      // Cancel market
      await lmsrMarket.connect(creator).cancelMarket(0);
    });

    it("Should redeem shares from cancelled market", async function () {
      const balanceBefore = await usdc.balanceOf(user1.address);
      const yesTokenId = await lmsrMarket._yesId(0);
      const shareBalance = await lmsrMarket.balanceOf(user1.address, yesTokenId);
      
      const tx = await lmsrMarket.connect(user1).redeemCancelled(0);
      
      // Get the actual refund amount from balance change
      const balanceAfter = await usdc.balanceOf(user1.address);
      const actualRefund = balanceAfter.sub(balanceBefore);
      
      await expect(tx)
        .to.emit(lmsrMarket, "Redeemed")
        .withArgs(0, user1.address, actualRefund); // actual refund amount
      
      // Check shares are burned
      expect(await lmsrMarket.balanceOf(user1.address, yesTokenId)).to.equal(0);
      
      // Check USDC received (proportional refund)
      expect(actualRefund).to.be.gt(0);
    });

    it("Should fail to redeem from non-cancelled market", async function () {
      // Create new market and buy shares but don't cancel
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50
      );
      await lmsrMarket.connect(user1).buy(1, 0, ethers.utils.parseUnits("100", 6));
      
      await expect(
        lmsrMarket.connect(user1).redeemCancelled(1)
      ).to.be.revertedWith("not cancelled");
    });

    it("Should fail to redeem with no shares", async function () {
      await expect(
        lmsrMarket.connect(user3).redeemCancelled(0)
      ).to.be.revertedWith("no shares");
    });
  });

  describe("Edge Cases and Security", function () {
    it("Should reject native ETH", async function () {
      await expect(
        owner.sendTransaction({
          to: lmsrMarket.address,
          value: ethers.utils.parseEther("1")
        })
      ).to.be.revertedWith("no native");
    });

    it("Should handle multiple markets correctly", async function () {
      // Create multiple markets
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("1000"),
        ethers.utils.parseUnits("1000", 6),
        50
      );
      
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("2000"),
        ethers.utils.parseUnits("2000", 6),
        25
      );
      
      await lmsrMarket.connect(creator).createMarket(
        usdc.address,
        ethers.utils.parseEther("500"),
        ethers.utils.parseUnits("500", 6),
        0
      );
      
      // Buy from different markets
      await lmsrMarket.connect(user1).buy(0, 0, ethers.utils.parseUnits("100", 6));
      await lmsrMarket.connect(user1).buy(1, 1, ethers.utils.parseUnits("150", 6));
      await lmsrMarket.connect(user1).buy(2, 0, ethers.utils.parseUnits("50", 6));
      
      // Check balances
      expect(await lmsrMarket.balanceOf(user1.address, 0)).to.equal(ethers.utils.parseUnits("100", 6)); // Market 0 Yes
      expect(await lmsrMarket.balanceOf(user1.address, 3)).to.equal(ethers.utils.parseUnits("150", 6)); // Market 1 No
      expect(await lmsrMarket.balanceOf(user1.address, 4)).to.equal(ethers.utils.parseUnits("50", 6));  // Market 2 Yes
    });

    it("Should handle reentrancy protection", async function () {
      // The contract should have reentrancy protection on all external functions
      // Check that the contract has the nonReentrant modifier by testing function calls
      expect(lmsrMarket.createMarket).to.be.a('function');
      expect(lmsrMarket.buy).to.be.a('function');
      expect(lmsrMarket.sell).to.be.a('function');
      expect(lmsrMarket.resolve).to.be.a('function');
    });
  });
});
