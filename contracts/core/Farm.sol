// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedSafeMath.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../libraries/SafeCast64.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IRewarder.sol";
import "../interfaces/IMigratorChef.sol";
import "../interfaces/ICHAOS.sol";

contract Farm is Ownable {
    using SafeMath for uint256;
    using SafeCast for int64;
    using SafeCast for uint64;
    using SafeCast for uint128;
    using SafeCast for int128;
    using SafeCast64 for uint256;
    using SafeERC20 for IERC20;
    using SignedSafeMath for int256;

    // Total CHAOS allocated to the pools
    uint256 private _totalSupplyAllocated;

    // Sum of the weights of all vaults
    uint8 private _totalWeight;

    /// @notice Info of each MCV2 user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of CHAOS entitled to the user.
    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
    }

    /// @notice Info of each MCV2 pool.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of CHAOS to distribute per block.
    struct PoolInfo {
        uint128 accChaosPerShare;
        uint64 lastRewardBlock;
        uint64 allocPoint;
        uint256 totalSupply; // CHAOS allocated to the pool
        uint8 weight; // Arbitrary weight for the pool
    }

    /// @notice Address of MCV1 contract.
    // ICHAOS public immutable CHAOS;
    /// @notice Address of CHAOS contract.
    IERC20 public immutable CHAOS_TOKEN;

    // /// @notice The index of MCV2 master pool in MCV1.
    // uint256 public immutable MASTER_PID;

    // @notice The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    /// @notice Info of each MCV2 pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each MCV2 pool.
    IERC20[] public lpToken;
    /// @notice Address of each `IRewarder` contract in MCV2.
    IRewarder[] public rewarder;

    /// @notice Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    // NEEDS TO BE PER POOL, PER BLOCK
    // uint256 private constant CHAOS_PER_BLOCK = 1e20;
    uint256 private constant ACC_CHAOS_PRECISION = 1e12;

    /// @param _reward The reward token contract address.
    constructor(IERC20 _reward) {
        CHAOS_TOKEN = _reward;
    }

    /// Allocate CHAOS to the farming contract.
    /// @param pid The pool ID to allocate the CHAOS to.
    /// @param amount Amount of CHAOS to allocate.
    function allocate(uint256 pid, uint256 amount) external {
        require(
            _totalSupplyAllocated.add(amount) <= CHAOS_TOKEN.balanceOf(address(this)),
            "Chaos: Insufficient CHAOS balance"
        );

        _totalSupplyAllocated += amount;
        poolInfo[pid].totalSupply += amount;
    }

    function setVaultWeight(uint256 pid, uint8 weight) external onlyOwner {
        if (weight == 0) {
            // Remove the pool
            _totalWeight -= poolInfo[pid].weight;
            poolInfo[pid].weight = 0;
        } else {
            // Calculate the new total weight delta
            uint8 delta = weight > poolInfo[pid].weight ? weight - poolInfo[pid].weight : poolInfo[pid].weight - weight;
            _totalWeight += delta;

            poolInfo[pid].weight = weight;
        }

        emit LogSetPoolWeight(pid, weight);
    }

    function getPoolWeightAsPercentage(uint256 pid) public view returns (uint8) {
        return (poolInfo[pid].weight * 100) / _totalWeight;
    }

    function setEmmisionsPerBlock(uint256 pid, uint128 amount) external onlyOwner {
        // Set the new emmisions per block
        poolInfo[pid].accChaosPerShare = amount;
    }

    /// @notice Returns the number of pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param allocPoint AP of the new pool.
    /// @param _lpToken Address of the LP ERC-20 token.
    /// @param _rewarder Address of the rewarder delegate.
    function add(uint256 allocPoint, IERC20 _lpToken, IRewarder _rewarder) public onlyOwner {
        uint256 lastRewardBlock = block.number;
        totalAllocPoint += allocPoint;
        lpToken.push(_lpToken);
        rewarder.push(_rewarder);

        poolInfo.push(
            PoolInfo({
                allocPoint: allocPoint.toUInt64(),
                lastRewardBlock: lastRewardBlock.toUInt64(),
                accChaosPerShare: 0,
                totalSupply: 0,
                weight: 0
            })
        );

        emit LogPoolAddition(lpToken.length.sub(1), allocPoint, _lpToken, _rewarder);
    }

    /// @notice Update the given pool's CHAOS allocation point and `IRewarder` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    /// @param _rewarder Address of the rewarder delegate.
    /// @param overwrite True if _rewarder should be `set`. Otherwise `_rewarder` is ignored.
    function set(uint256 _pid, uint256 _allocPoint, IRewarder _rewarder, bool overwrite) public onlyOwner {
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint.toUInt64();
        if (overwrite) {
            rewarder[_pid] = _rewarder;
        }
        emit LogSetPool(_pid, _allocPoint, overwrite ? _rewarder : rewarder[_pid], overwrite);
    }

    /// @notice Set the `migrator` contract. Can only be called by the owner.
    /// @param _migrator The contract address to set.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    /// @notice Migrate LP token to another LP contract through the `migrator` contract.
    /// @param _pid The index of the pool. See `poolInfo`.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "Chaos: no migrator set");
        IERC20 _lpToken = lpToken[_pid];
        uint256 bal = _lpToken.balanceOf(address(this));
        _lpToken.approve(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(_lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "Chaos: migrated balance must match");
        lpToken[_pid] = newLpToken;
    }

    /// @notice View function to see pending CHAOS on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending CHAOS reward for a given user.
    function pendingRewards(uint256 _pid, address _user) external view returns (uint256 pending) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        // TODO: NEED TO SET EMMISIONS PER BLOCK
        uint256 accChaosPerShare = pool.accChaosPerShare;

        // TODO: CHECK LOGIC ON THIS...
        uint256 lpSupply = lpToken[_pid].balanceOf(address(this));

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 blocks = block.number.sub(pool.lastRewardBlock);
            uint256 sushiReward = blocks.mul(rewardsPerBlock(_pid)).mul(pool.allocPoint) / totalAllocPoint;
            accChaosPerShare = accChaosPerShare.add(sushiReward.mul(ACC_CHAOS_PRECISION) / lpSupply);
        }

        pending = uint256(int256(user.amount.mul(accChaosPerShare) / ACC_CHAOS_PRECISION).sub(user.rewardDebt));
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Calculates and returns the `amount` of CHAOS per block.
    function rewardsPerBlock(uint256 pid) public view returns (uint256 amount) {
        // amount = uint256(CHAOS_PER_BLOCK).mul(CHAOS.poolInfo(MASTER_PID).allocPoint) / CHAOS.totalAllocPoint();

        amount = poolInfo[pid].accChaosPerShare;
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];

        if (block.number > pool.lastRewardBlock) {
            uint256 lpSupply = lpToken[pid].balanceOf(address(this));

            if (lpSupply > 0) {
                uint256 blocks = block.number.sub(pool.lastRewardBlock);
                uint256 sushiReward = blocks.mul(rewardsPerBlock(pid)).mul(pool.allocPoint) / totalAllocPoint;
                pool.accChaosPerShare += uint128(sushiReward.mul(ACC_CHAOS_PRECISION) / lpSupply);
            }

            pool.lastRewardBlock = block.number.toUInt64();
            poolInfo[pid] = pool;

            emit LogUpdatePool(pid, pool.lastRewardBlock, lpSupply, pool.accChaosPerShare);
        }
    }

    /// @notice Deposit LP tokens to MCV2 for CHAOS allocation.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to deposit.
    /// @param to The receiver of `amount` deposit benefit.
    function deposit(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][to];

        // Effects
        user.amount = user.amount.add(amount);
        user.rewardDebt = user.rewardDebt.add(int256(amount.mul(pool.accChaosPerShare) / ACC_CHAOS_PRECISION));

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onChaosReward(pid, to, to, 0, user.amount);
        }

        lpToken[pid].safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, pid, amount, to);
    }

    /// @notice Withdraw LP tokens from MCV2.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens.
    function withdraw(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];

        // Effects
        user.rewardDebt = user.rewardDebt.sub(int256(amount.mul(pool.accChaosPerShare) / ACC_CHAOS_PRECISION));
        user.amount = user.amount.sub(amount);

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onChaosReward(pid, msg.sender, to, 0, user.amount);
        }

        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of CHAOS rewards.
    function harvest(uint256 pid, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedSushi = int256(user.amount.mul(pool.accChaosPerShare) / ACC_CHAOS_PRECISION);
        uint256 _pendingSushi = uint256(accumulatedSushi.sub(user.rewardDebt));

        // Effects
        user.rewardDebt = accumulatedSushi;

        // Interactions
        if (_pendingSushi != 0) {
            CHAOS_TOKEN.safeTransfer(to, _pendingSushi);
        }

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onChaosReward(pid, msg.sender, to, _pendingSushi, user.amount);
        }

        emit Harvest(msg.sender, pid, _pendingSushi);
    }

    /// @notice Withdraw LP tokens from MCV2 and harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens and CHAOS rewards.
    function withdrawAndHarvest(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedSushi = int256(user.amount.mul(pool.accChaosPerShare) / ACC_CHAOS_PRECISION);
        uint256 _pendingSushi = uint256(accumulatedSushi.sub(user.rewardDebt)); // uint256 _pendingSushi = accumulatedSushi.sub(user.rewardDebt).toUInt256();

        // Effects
        user.rewardDebt = accumulatedSushi.sub(int256(amount.mul(pool.accChaosPerShare) / ACC_CHAOS_PRECISION));
        user.amount = user.amount.sub(amount);

        // Interactions
        CHAOS_TOKEN.safeTransfer(to, _pendingSushi);

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onChaosReward(pid, msg.sender, to, _pendingSushi, user.amount);
        }

        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
        emit Harvest(msg.sender, pid, _pendingSushi);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of the LP tokens.
    function emergencyWithdraw(uint256 pid, address to) public {
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onChaosReward(pid, msg.sender, to, 0, 0);
        }

        // Note: transfer can fail or succeed if `amount` is zero.
        lpToken[pid].safeTransfer(to, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount, to);
    }

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogPoolAddition(uint256 indexed pid, uint256 allocPoint, IERC20 indexed lpToken, IRewarder indexed rewarder);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint, IRewarder indexed rewarder, bool overwrite);
    event LogUpdatePool(uint256 indexed pid, uint64 lastRewardBlock, uint256 lpSupply, uint256 accChaosPerShare);
    event LogSetPoolWeight(uint256 indexed pid, uint8 weight);
}
