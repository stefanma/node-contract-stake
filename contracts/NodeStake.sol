pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// 节点质押合约，用于用户质押代币获得奖励
contract NodeStake is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    bytes32 public constant ADMIN_ROLE = keccak256("admin_role");
    bytes32 public constant UPGRADE_ROLE = keccak256("upgrade_role");

    uint256 public constant ETH_PID = 0; //ETH 池

    struct UnstakeRequest {
        // Request withdraw amount 请求提现数量
        uint256 amount; // 用户取消质押的代币数量，要取出多少个 token
        // The blocks when the request withdraw amount can be released
        uint256 unlockBlock; // 解质押的区块高度
    }

    struct User {
        uint256 stAmount; // 用户在当前资金池，质押的代币数量
        uint256 finishedNode; // 用户在当前资金池，已经领取的 代币 数量
        uint256 pendingNode; // 用户在当前资金池，当前可领取的 代币 数量
        UnstakeRequest[] requests; // 用户在当前资金池，当前的解质押请求
    }

    struct Pool {
        address stTokenAddress; // 质押代币的地址
        uint256 poolWeight; // 不同资金池所占的权重
        uint256 lastRewardBlock; // 上次发放奖励的区块高度
        uint256 accNodePerST; // 质押 1个代币经过1个区块高度，能拿到 n 个Node代币
        uint256 stTokenAmount; // 质押的代币数量
        uint256 minDepositAmount; // 最小质押数量
        uint256 unstakeLockedBlocks; // 解质押锁定的区块高度
    }

    uint256 public startBlock; // 质押开始区块高度
    uint256 public endBlock; // 质押结束区块高度
    uint256 public nodePerBlock; // 每个区块高度，Node代币的奖励数量

    bool public withdrawPaused; // 是否暂停提现
    bool public claimPaused; // 是否暂停领取

    IERC20 public NodeToken; // NodeToken 代币地址

    uint256 public totalPoolWeight; // 所有资金池的权重总和
    Pool[] public pool; // 资金池列表

    // pool id => user address => user info
    mapping(uint256 => mapping(address => User)) public user; // 资金池 id => 用户地址 => 用户信息

    event SetNodeToken(IERC20 indexed NodeToken);

    event PauseWithdraw();

    event UnpauseWithdraw();

    event PauseClaim();

    event UnpauseClaim();

    event SetStartBlock(uint256 indexed startBlock);

    event SetEndBlock(uint256 indexed endBlock);

    event SetNodePerBlock(uint256 indexed nodePerBlock);

    event AddPool(
        address indexed stTokenAddress, // 质押代币的地址
        uint256 indexed poolWeight, // 不同资金池所占的权重
        uint256 indexed lastRewardBlock, // 上次发放奖励的区块高度
        uint256 minDepositAmount, // 最小质押数量
        uint256 unstakeLockedBlocks // 解质押锁定的区块高度
    );

    event UpdatePoolInfo(
        uint256 indexed poolId, // 资金池 id
        uint256 indexed minDepositAmount, // 最小质押数量
        uint256 indexed unstakeLockedBlocks // 解质押锁定的区块高度
    );

    event SetPoolWeight(
        uint256 indexed poolId, // 资金池 id
        uint256 indexed poolWeight, // 不同资金池所占的权重
        uint256 totalPoolWeight // 所有资金池的权重总和
    );

    event UpdatePool(
        uint256 indexed poolId, // 资金池 id
        uint256 indexed lastRewardBlock, // 上次发放奖励的区块高度
        uint256 totalNodeToken // 资金池中，Node代币的总数量
    );

    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);

    event RequestUnstake(
        address indexed user, // 用户地址
        uint256 indexed poolId, // 资金池 id
        uint256 amount // 用户提现的代币数量
    );

    event Withdraw(
        address indexed user, // 用户地址
        uint256 indexed poolId, // 资金池 id
        uint256 amount, // 用户提现的代币数量
        uint256 indexed blockNumber // 提现的区块高度
    );

    event Claim(
        address indexed user,
        uint256 indexed poolId,
        uint256 nodeRewardAmount // 用户领取的 Node代币数量
    );

    // ************************************** MODIFIER **************************************

    modifier checkPid(uint256 _pid) {
        require(_pid < pool.length, "invalid pid");
        _;
    }

    modifier whenNotClaimPaused() {
        require(!claimPaused, "claim is paused");
        _;
    }

    modifier whenNotWithdrawPaused() {
        require(!withdrawPaused, "withdraw is paused");
        _;
    }

    /**
     * @notice Set Node token address. Set basic info when deploying.
     */
    function initialize(
        IERC20 _NodeToken,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _NodePerBlock
    ) public initializer {
        require(
            _startBlock <= _endBlock && _NodePerBlock > 0,
            "invalid parameters"
        );
        __AccessControl_init();
        __Pausable_init();
        // 初始化角色
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADE_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        //初始化逻辑
        setNodeToken(_NodeToken);
        // 设置开始区块
        startBlock = _startBlock;
        // 设置结束区块
        endBlock = _endBlock;
        // 设置每个区块的奖励数量
        nodePerBlock = _NodePerBlock;
    }

    /**
     * 授权升级
     * @param newImplementation 升级后的合约地址，需要有 UPGRADE_ROLE 权限
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADE_ROLE) {}

    // ************************************** ADMIN FUNCTION **************************************
    /**
     * @notice Set Node token address. Can only be called by admin
     */
    function setNodeToken(IERC20 _NodeToken) public onlyRole(ADMIN_ROLE) {
        NodeToken = _NodeToken;

        emit SetNodeToken(_NodeToken);
    }

    /**
     * @notice Pause withdraw. Can only be called by admin.
     */
    function pauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(!withdrawPaused, "withdraw has been already paused");

        withdrawPaused = true;

        emit PauseWithdraw();
    }

    /**
     * @notice Unpause withdraw. Can only be called by admin.
     */
    function unpauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(withdrawPaused, "withdraw has been already unpaused");

        withdrawPaused = false;

        emit UnpauseWithdraw();
    }

    /**
     * @notice Pause claim. Can only be called by admin.
     */
    function pauseClaim() public onlyRole(ADMIN_ROLE) {
        require(!claimPaused, "claim has been already paused");

        claimPaused = true;

        emit PauseClaim();
    }

    /**
     * @notice Unpause claim. Can only be called by admin.
     */
    function unpauseClaim() public onlyRole(ADMIN_ROLE) {
        require(claimPaused, "claim has been already unpaused");

        claimPaused = false;

        emit UnpauseClaim();
    }

    /**
     * @notice Update staking start block. Can only be called by admin.
     */
    function setStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE) {
        require(
            _startBlock <= endBlock,
            "start block must be smaller than end block"
        );

        startBlock = _startBlock;

        emit SetStartBlock(_startBlock);
    }

    /**
     * @notice Update staking end block. Can only be called by admin.
     */
    function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
        require(
            startBlock <= _endBlock,
            "start block must be smaller than end block"
        );

        endBlock = _endBlock;

        emit SetEndBlock(_endBlock);
    }

    /**
     * @notice Update the Node reward amount per block. Can only be called by admin.
     */
    function setNodePerBlock(
        uint256 _NodePerBlock
    ) public onlyRole(ADMIN_ROLE) {
        require(_NodePerBlock > 0, "invalid parameter");
        nodePerBlock = _NodePerBlock;

        emit SetNodePerBlock(_NodePerBlock);
    }

    /**
     * @notice Add a new staking to pool. Can only be called by admin
     * DO NOT add the same staking token more than once. Node rewards will be messed up if you do
     */
    function addPool(
        address _stTokenAddress,
        uint256 _poolWeight,
        uint256 _minDepositAmount,
        uint256 _unstakeLockedBlocks,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) {
        // Default the first pool to be ETH pool, so the first pool must be added with stTokenAddress = address(0x0)
        if (pool.length > 0) {
            require(
                _stTokenAddress != address(0x0),
                "invalid staking token address"
            );
        } else {
            require(
                _stTokenAddress == address(0x0),
                "invalid staking token address"
            );
        }
        // allow the min deposit amount equal to 0
        //require(_minDepositAmount > 0, "invalid min deposit amount");
        require(_unstakeLockedBlocks > 0, "invalid withdraw locked blocks");
        require(block.number < endBlock, "Already ended");

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalPoolWeight = totalPoolWeight + _poolWeight;

        pool.push(
            Pool({
                stTokenAddress: _stTokenAddress,
                poolWeight: _poolWeight,
                lastRewardBlock: lastRewardBlock,
                accNodePerST: 0,
                stTokenAmount: 0,
                minDepositAmount: _minDepositAmount,
                unstakeLockedBlocks: _unstakeLockedBlocks
            })
        );

        emit AddPool(
            _stTokenAddress,
            _poolWeight,
            lastRewardBlock,
            _minDepositAmount,
            _unstakeLockedBlocks
        );
    }

    /**
     * @notice Update the given pool's info (minDepositAmount and unstakeLockedBlocks). Can only be called by admin.
     */
    function updatePool(
        uint256 _pid,
        uint256 _minDepositAmount,
        uint256 _unstakeLockedBlocks
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        pool[_pid].minDepositAmount = _minDepositAmount;
        pool[_pid].unstakeLockedBlocks = _unstakeLockedBlocks;

        emit UpdatePoolInfo(_pid, _minDepositAmount, _unstakeLockedBlocks);
    }

    /**
     * @notice Update the given pool's weight. Can only be called by admin.
     */
    function setPoolWeight(
        uint256 _pid,
        uint256 _poolWeight,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        require(_poolWeight > 0, "invalid pool weight");

        if (_withUpdate) {
            massUpdatePools();
        }

        totalPoolWeight = totalPoolWeight - pool[_pid].poolWeight + _poolWeight;
        pool[_pid].poolWeight = _poolWeight;

        emit SetPoolWeight(_pid, _poolWeight, totalPoolWeight);
    }

    // ************************************** QUERY FUNCTION **************************************

    /**
     * @notice Get the length/amount of pool
     */
    function poolLength() external view returns (uint256) {
        return pool.length;
    }

    /**
     * @notice Return reward multiplier over given _from to _to block. [_from, _to)
     *
     * @param _from    From block number (included)
     * @param _to      To block number (exluded)
     * getMultiplier(pool_.lastRewardBlock, block.number).tryMul(pool_.poolWeight);
     */
    function getMultiplier(
        uint256 _from,
        uint256 _to
    ) public view returns (uint256 multiplier) {
        require(_from <= _to, "invalid block");
        if (_from < startBlock) {
            _from = startBlock;
        }
        if (_to > endBlock) {
            _to = endBlock;
        }
        require(_from <= _to, "end block must be greater than start block");
        bool success;
        (success, multiplier) = (_to - _from).tryMul(nodePerBlock);
        require(success, "multiplier overflow");
    }

    /**
     * @notice Get pending Node amount of user in pool
     */
    function pendingNode(
        uint256 _pid,
        address _user
    ) external view checkPid(_pid) returns (uint256) {
        return pendingNodeByBlockNumber(_pid, _user, block.number);
    }

    /**
     * @notice Get pending Node amount of user by block number in pool
     */
    function pendingNodeByBlockNumber(
        uint256 _pid,
        address _user,
        uint256 _blockNumber
    ) public view checkPid(_pid) returns (uint256) {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][_user];
        uint256 accNodePerST = pool_.accNodePerST;
        uint256 stSupply = pool_.stTokenAmount;

        if (_blockNumber > pool_.lastRewardBlock && stSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool_.lastRewardBlock,
                _blockNumber
            );
            uint256 NodeForPool = (multiplier * pool_.poolWeight) /
                totalPoolWeight;
            accNodePerST = accNodePerST + (NodeForPool * (1 ether)) / stSupply;
        }

        return
            (user_.stAmount * accNodePerST) /
            (1 ether) -
            user_.finishedNode +
            user_.pendingNode;
    }

    /**
     * @notice Get the staking amount of user
     */
    function stakingBalance(
        uint256 _pid,
        address _user
    ) external view checkPid(_pid) returns (uint256) {
        return user[_pid][_user].stAmount;
    }

    /**
     * @notice Get the withdraw amount info, including the locked unstake amount and the unlocked unstake amount
     */
    function withdrawAmount(
        uint256 _pid,
        address _user
    )public view checkPid(_pid) returns (uint256 requestAmount, uint256 pendingWithdrawAmount) {
        User storage user_ = user[_pid][_user];

        for (uint256 i = 0; i < user_.requests.length; i++) {
            if (user_.requests[i].unlockBlock <= block.number) {
                pendingWithdrawAmount =
                    pendingWithdrawAmount +
                    user_.requests[i].amount;
            }
            requestAmount = requestAmount + user_.requests[i].amount;
        }
    }

    /**
     * @notice Update reward variables of the given pool to be up-to-date.
     */
    function updatePool(uint256 _pid) public checkPid(_pid) {
        Pool storage pool_ = pool[_pid];

        if (block.number <= pool_.lastRewardBlock) {
            return;
        }

        (bool success1, uint256 totalNode) = getMultiplier(
            pool_.lastRewardBlock,
            block.number
        ).tryMul(pool_.poolWeight);
        require(success1, "overflow");

        (success1, totalNode) = totalNode.tryDiv(totalPoolWeight);
        require(success1, "overflow");

        uint256 stSupply = pool_.stTokenAmount;
        if (stSupply > 0) {
            (bool success2, uint256 totalNode_) = totalNode.tryMul(1 ether);
            require(success2, "overflow");

            (success2, totalNode_) = totalNode_.tryDiv(stSupply);
            require(success2, "overflow");

            (bool success3, uint256 accNodePerST) = pool_.accNodePerST.tryAdd(
                totalNode_
            );
            require(success3, "overflow");
            pool_.accNodePerST = accNodePerST;
        }

        pool_.lastRewardBlock = block.number;

        emit UpdatePool(_pid, pool_.lastRewardBlock, totalNode);
    }

    /**
     * @notice Update reward variables for all pools. Be careful of gas spending!
     */
    function massUpdatePools() public {
        uint256 length = pool.length;
        for (uint256 pid = 0; pid < length; pid++) {
            updatePool(pid);
        }
    }

    /**
     * @notice Deposit staking ETH for Node rewards
     */
    function depositETH() public payable whenNotPaused {
        Pool storage pool_ = pool[ETH_PID];
        require(
            pool_.stTokenAddress == address(0x0),
            "invalid staking token address"
        );

        uint256 _amount = msg.value;
        require(
            _amount >= pool_.minDepositAmount,
            "deposit amount is too small"
        );

        _deposit(ETH_PID, _amount);
    }

    /**
     * @notice Deposit staking token for Node rewards
     * Before depositing, user needs approve this contract to be able to spend or transfer their staking tokens
     *
     * @param _pid       Id of the pool to be deposited to
     * @param _amount    Amount of staking tokens to be deposited
     */
    function deposit(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) {
        require(_pid != 0, "deposit not support ETH staking");
        Pool storage pool_ = pool[_pid];
        require(
            _amount > pool_.minDepositAmount,
            "deposit amount is too small"
        );

        if (_amount > 0) {
            // 需要用户提前执行 approve
            IERC20(pool_.stTokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
        }

        _deposit(_pid, _amount);
    }

    /**
     * @notice Unstake staking tokens
     *
     * @param _pid       Id of the pool to be withdrawn from
     * @param _amount    amount of staking tokens to be withdrawn
     */
    function unstake(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        require(user_.stAmount >= _amount, "Not enough staking token balance");

        updatePool(_pid);

        uint256 pendingNode_ = (user_.stAmount * pool_.accNodePerST) /
            (1 ether) -
            user_.finishedNode;

        if (pendingNode_ > 0) {
            user_.pendingNode = user_.pendingNode + pendingNode_;
        }

        if (_amount > 0) {
            user_.stAmount = user_.stAmount - _amount;
            user_.requests.push(
                UnstakeRequest({
                    amount: _amount,
                    unlockBlock: block.number + pool_.unstakeLockedBlocks
                })
            );
        }

        pool_.stTokenAmount = pool_.stTokenAmount - _amount;
        user_.finishedNode = (user_.stAmount * pool_.accNodePerST) / (1 ether);

        emit RequestUnstake(msg.sender, _pid, _amount);
    }

    /**
     * @notice Withdraw the unlock unstake amount
     *
     * @param _pid       Id of the pool to be withdrawn from
     */
    function withdraw(
        uint256 _pid
    ) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        uint256 pendingWithdraw_;
        uint256 popNum_;
        for (uint256 i = 0; i < user_.requests.length; i++) {
            if (user_.requests[i].unlockBlock > block.number) {
                break;
            }
            pendingWithdraw_ = pendingWithdraw_ + user_.requests[i].amount;
            popNum_++;
        }

        for (uint256 i = 0; i < user_.requests.length - popNum_; i++) {
            user_.requests[i] = user_.requests[i + popNum_];
        }

        for (uint256 i = 0; i < popNum_; i++) {
            user_.requests.pop();
        }

        if (pendingWithdraw_ > 0) {
            if (pool_.stTokenAddress == address(0x0)) {
                _safeETHTransfer(msg.sender, pendingWithdraw_);
            } else {
                IERC20(pool_.stTokenAddress).safeTransfer(
                    msg.sender,
                    pendingWithdraw_
                );
            }
        }

        emit Withdraw(msg.sender, _pid, pendingWithdraw_, block.number);
    }

    /**
     * @notice Claim Node tokens reward
     *
     * @param _pid       Id of the pool to be claimed from
     */
    function claim(
        uint256 _pid
    ) public whenNotPaused checkPid(_pid) whenNotClaimPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        updatePool(_pid);

        uint256 pendingNode_ = (user_.stAmount * pool_.accNodePerST) /
            (1 ether) -
            user_.finishedNode +
            user_.pendingNode;

        if (pendingNode_ > 0) {
            user_.pendingNode = 0;
            _safeNodeTransfer(msg.sender, pendingNode_);
        }

        user_.finishedNode = (user_.stAmount * pool_.accNodePerST) / (1 ether);

        emit Claim(msg.sender, _pid, pendingNode_);
    }

    // ************************************** INTERNAL FUNCTION **************************************

    /**
     * @notice Deposit staking token for Node rewards
     *
     * @param _pid       Id of the pool to be deposited to
     * @param _amount    Amount of staking tokens to be deposited
     */
    function _deposit(uint256 _pid, uint256 _amount) internal {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        updatePool(_pid);

        if (user_.stAmount > 0) {
            // uint256 accST = user_.stAmount.mulDiv(pool_.accNodePerST, 1 ether);
            (bool success1, uint256 accST) = user_.stAmount.tryMul(
                pool_.accNodePerST
            );
            require(success1, "user stAmount mul accNodePerST overflow");
            (success1, accST) = accST.tryDiv(1 ether);
            require(success1, "accST div 1 ether overflow");

            (bool success2, uint256 pendingNode_) = accST.trySub(
                user_.finishedNode
            );
            require(success2, "accST sub finishedNode overflow");

            if (pendingNode_ > 0) {
                (bool success3, uint256 _pendingNode) = user_
                    .pendingNode
                    .tryAdd(pendingNode_);
                require(success3, "user pendingNode overflow");
                user_.pendingNode = _pendingNode;
            }
        }

        if (_amount > 0) {
            (bool success4, uint256 stAmount) = user_.stAmount.tryAdd(_amount);
            require(success4, "user stAmount overflow");
            user_.stAmount = stAmount;
        }

        (bool success5, uint256 stTokenAmount) = pool_.stTokenAmount.tryAdd(
            _amount
        );
        require(success5, "pool stTokenAmount overflow");
        pool_.stTokenAmount = stTokenAmount;

        // user_.finishedNode = user_.stAmount.mulDiv(pool_.accNodePerST, 1 ether);
        (bool success6, uint256 finishedNode) = user_.stAmount.tryMul(
            pool_.accNodePerST
        );
        require(success6, "user stAmount mul accNodePerST overflow");

        (success6, finishedNode) = finishedNode.tryDiv(1 ether);
        require(success6, "finishedNode div 1 ether overflow");

        user_.finishedNode = finishedNode;

        emit Deposit(msg.sender, _pid, _amount);
    }

    /**
     * @notice Safe Node transfer function, just in case if rounding error causes pool to not have enough Nodes
     *
     * @param _to        Address to get transferred Nodes
     * @param _amount    Amount of Node to be transferred
     */
    function _safeNodeTransfer(address _to, uint256 _amount) internal {
        uint256 NodeBal = NodeToken.balanceOf(address(this));

        if (_amount > NodeBal) {
            NodeToken.transfer(_to, NodeBal);
        } else {
            NodeToken.transfer(_to, _amount);
        }
    }

    /**
     * @notice Safe ETH transfer function
     *
     * @param _to        Address to get transferred ETH
     * @param _amount    Amount of ETH to be transferred
     */
    function _safeETHTransfer(address _to, uint256 _amount) internal {
        (bool success, bytes memory data) = address(_to).call{value: _amount}(
            ""
        );

        require(success, "ETH transfer call failed");
        if (data.length > 0) {
            require(
                abi.decode(data, (bool)),
                "ETH transfer operation did not succeed"
            );
        }
    }
}
