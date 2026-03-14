const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("NodeToken", function () {
  let NodeToken;
  let nodeToken;
  let owner;
  let otherAccount;

  beforeEach(async function () {
    [owner, otherAccount] = await ethers.getSigners();

    NodeToken = await ethers.getContractFactory("NodeToken");
    nodeToken = await NodeToken.deploy();
    await nodeToken.waitForDeployment();
  });

  it("should have correct name and symbol", async function () {
    expect(await nodeToken.name()).to.equal("NodeToken");
    expect(await nodeToken.symbol()).to.equal("NT");
  });

  it("should mint initial supply to deployer", async function () {
    const decimals = await nodeToken.decimals();
    const expectedSupply = ethers.parseUnits("1000000", decimals);
    const ownerBalance = await nodeToken.balanceOf(owner.address);
    const totalSupply = await nodeToken.totalSupply();

    expect(ownerBalance).to.equal(expectedSupply);
    expect(totalSupply).to.equal(expectedSupply);
  });

  it("owner can mint new tokens", async function () {
    const decimals = await nodeToken.decimals();
    const mintAmount = ethers.parseUnits("1000", decimals);

    await expect(nodeToken.mint(otherAccount.address, mintAmount))
      .to.emit(nodeToken, "Transfer")
      .withArgs(ethers.ZeroAddress, otherAccount.address, mintAmount);

    const balance = await nodeToken.balanceOf(otherAccount.address);
    expect(balance).to.equal(mintAmount);
  });

  it("non-owner cannot mint", async function () {
    const decimals = await nodeToken.decimals();
    const mintAmount = ethers.parseUnits("1000", decimals);

    await expect(
      nodeToken.connect(otherAccount).mint(otherAccount.address, mintAmount)
    ).to.be.revertedWithCustomError(nodeToken, "OwnableUnauthorizedAccount");
  });
}
);
