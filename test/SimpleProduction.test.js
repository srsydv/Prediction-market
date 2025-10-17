const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Simple Production Test", function () {
  let lmsrMarket, owner, feeRecipient;

  beforeEach(async function () {
    [owner, feeRecipient] = await ethers.getSigners();

    // Deploy LMSRMarketProduction
    const LMSRMarketProduction = await ethers.getContractFactory("LMSRMarketProduction");
    console.log("Deploying contract...");
    lmsrMarket = await LMSRMarketProduction.deploy(feeRecipient.address);
    await lmsrMarket.deployed();
    console.log("Contract deployed at:", lmsrMarket.address);
  });

  it("Should deploy successfully", async function () {
    expect(await lmsrMarket.owner()).to.equal(owner.address);
    expect(await lmsrMarket.feeRecipient()).to.equal(feeRecipient.address);
    expect(await lmsrMarket.marketCount()).to.equal(0);
  });
});
