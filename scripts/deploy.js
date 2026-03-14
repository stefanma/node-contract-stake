import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying contracts with account:", deployer.address);

  // 1. Deploy reward token NodeToken
  const NodeToken = await ethers.getContractFactory("NodeToken");
  const nodeToken = await NodeToken.deploy();
  await nodeToken.waitForDeployment();

  const nodeTokenAddress = await nodeToken.getAddress();
  console.log("NodeToken deployed to:", nodeTokenAddress);

  // 2. Deploy staking contract NodeStake (implementation contract)
  const NodeStake = await ethers.getContractFactory("NodeStake");
  const nodeStake = await NodeStake.deploy();
  await nodeStake.waitForDeployment();

  const nodeStakeAddress = await nodeStake.getAddress();
  console.log("NodeStake (implementation) deployed to:", nodeStakeAddress);

  // 3. Initialize NodeStake
  const currentBlock = await ethers.provider.getBlockNumber();
  const startBlock = BigInt(currentBlock);       // start from current block
  const endBlock = startBlock + 100000n;         // run for 100000 blocks
  const nodePerBlock = 1n;                       // 1 NT per block (scaled by 1e0)

  console.log(
    `Initializing NodeStake with startBlock=${startBlock}, endBlock=${endBlock}, nodePerBlock=${nodePerBlock}`
  );

  const initTx = await nodeStake.initialize(
    nodeTokenAddress,
    startBlock,
    endBlock,
    nodePerBlock
  );
  await initTx.wait();
  console.log("NodeStake initialized");

  // 4. Optionally fund NodeStake with reward tokens
  const rewardAmount = ethers.parseUnits("500000", 18); // 50 万 NT 奖励
  const fundTx = await nodeToken.transfer(nodeStakeAddress, rewardAmount);
  await fundTx.wait();
  console.log(
    `Transferred ${rewardAmount.toString()} NodeToken to NodeStake for rewards`
  );

  // 5. (可选) 添加一个默认 ETH 质押池
  const poolWeight = 100n;
  const minDepositAmount = ethers.parseEther("0.1");
  const unstakeLockedBlocks = 100n;

  const addPoolTx = await nodeStake.addPool(
    ethers.ZeroAddress,      // ETH 池
    poolWeight,
    minDepositAmount,
    unstakeLockedBlocks,
    false                     // 不在这里 massUpdatePools
  );
  await addPoolTx.wait();

  console.log("Added default ETH staking pool (pid 0)");
}

await main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

