const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("NodeStake", function () {
  let deployer;
  let user;
  let other;
  let nodeToken;
  let nodeStake;
  let stakingToken;

  beforeEach(async function () {
    [deployer, user, other] = await ethers.getSigners();

    // Deploy reward token
    const NodeToken = await ethers.getContractFactory("NodeToken");
    nodeToken = await NodeToken.deploy();
    await nodeToken.waitForDeployment();

    // Deploy staking contract (implementation style, direct call to initialize)
    const NodeStake = await ethers.getContractFactory("NodeStake");
    nodeStake = await NodeStake.deploy();
    await nodeStake.waitForDeployment();

    const currentBlock = await ethers.provider.getBlockNumber();
    const startBlock = currentBlock;
    const endBlock = currentBlock + 1000n;
    const nodePerBlock = 1n;

    await nodeStake.initialize(
      await nodeToken.getAddress(),
      startBlock,
      endBlock,
      nodePerBlock
    );

    // Deploy an ERC20 staking token for non-ETH pools
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    stakingToken = await MockERC20.deploy("StakeToken", "STK");
    await stakingToken.waitForDeployment();
  });

  it("initializes basic state and roles correctly", async function () {
    expect(await nodeStake.NodeToken()).to.equal(await nodeToken.getAddress());

    const currentBlock = await ethers.provider.getBlockNumber();
    const startBlock = await nodeStake.startBlock();
    const endBlock = await nodeStake.endBlock();
    const nodePerBlock = await nodeStake.nodePerBlock();

    expect(startBlock).to.be.lte(endBlock);
    expect(endBlock).to.be.gt(currentBlock - 1n);
    expect(nodePerBlock).to.equal(1n);

    const DEFAULT_ADMIN_ROLE = await nodeStake.DEFAULT_ADMIN_ROLE();
    const ADMIN_ROLE = await nodeStake.ADMIN_ROLE();
    const UPGRADE_ROLE = await nodeStake.UPGRADE_ROLE();

    expect(await nodeStake.hasRole(DEFAULT_ADMIN_ROLE, deployer.address)).to.be
      .true;
    expect(await nodeStake.hasRole(ADMIN_ROLE, deployer.address)).to.be.true;
    expect(await nodeStake.hasRole(UPGRADE_ROLE, deployer.address)).to.be.true;
  });

  it("only admin can set Node token", async function () {
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const otherToken = await MockERC20.deploy("Other", "OTH");
    await otherToken.waitForDeployment();

    await expect(
      nodeStake.connect(user).setNodeToken(await otherToken.getAddress())
    ).to.be.revertedWithCustomError(
      nodeStake,
      "AccessControlUnauthorizedAccount"
    );

    await nodeStake.setNodeToken(await otherToken.getAddress());
    expect(await nodeStake.NodeToken()).to.equal(
      await otherToken.getAddress()
    );
  });

  it("admin can add ETH pool as first pool", async function () {
    const poolWeight = 100n;
    const minDepositAmount = ethers.parseEther("0.1");
    const unstakeLockedBlocks = 10n;

    await nodeStake.addPool(
      ethers.ZeroAddress,
      poolWeight,
      minDepositAmount,
      unstakeLockedBlocks,
      false
    );

    const length = await nodeStake.poolLength();
    expect(length).to.equal(1n);

    const poolInfo = await nodeStake.pool(0);
    expect(poolInfo.stTokenAddress).to.equal(ethers.ZeroAddress);
    expect(poolInfo.poolWeight).to.equal(poolWeight);
    expect(poolInfo.minDepositAmount).to.equal(minDepositAmount);
    expect(poolInfo.unstakeLockedBlocks).to.equal(unstakeLockedBlocks);
  });

  it("admin can add ERC20 staking pool and user can deposit", async function () {
    // First add ETH pool (pid 0)
    await nodeStake.addPool(
      ethers.ZeroAddress,
      100n,
      0n,
      10n,
      false
    );

    // Then add ERC20 pool (pid 1)
    const poolWeight = 200n;
    const minDepositAmount = ethers.parseUnits("100", 18);
    const unstakeLockedBlocks = 20n;

    await nodeStake.addPool(
      await stakingToken.getAddress(),
      poolWeight,
      minDepositAmount,
      unstakeLockedBlocks,
      false
    );

    // Mint staking tokens to user and approve
    const depositAmount = ethers.parseUnits("1000", 18);
    await stakingToken.mint(user.address, depositAmount);
    await stakingToken.connect(user).approve(
      await nodeStake.getAddress(),
      depositAmount
    );

    await expect(
      nodeStake.connect(user).deposit(1, depositAmount)
    ).to.emit(nodeStake, "Deposit");

    const stBalance = await nodeStake.stakingBalance(1, user.address);
    expect(stBalance).to.equal(depositAmount);
  });

  it("pause and unpause withdraw / claim work only for admin", async function () {
    await expect(nodeStake.connect(user).pauseWithdraw()).to.be.revertedWithCustomError(
      nodeStake,
      "AccessControlUnauthorizedAccount"
    );

    await nodeStake.pauseWithdraw();
    expect(await nodeStake.withdrawPaused()).to.equal(true);

    await nodeStake.unpauseWithdraw();
    expect(await nodeStake.withdrawPaused()).to.equal(false);

    await expect(nodeStake.connect(user).pauseClaim()).to.be.revertedWithCustomError(
      nodeStake,
      "AccessControlUnauthorizedAccount"
    );

    await nodeStake.pauseClaim();
    expect(await nodeStake.claimPaused()).to.equal(true);

    await nodeStake.unpauseClaim();
    expect(await nodeStake.claimPaused()).to.equal(false);
  });
});

