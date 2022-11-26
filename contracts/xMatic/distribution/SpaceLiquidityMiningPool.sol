// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../../Operator.sol";

contract SpaceLiquidityMiningPool is Operator, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. space to distribute per block.
        uint256 lastRewardTime; // Last time that space distribution occurs.
        uint256 accSpacePerShare; // Accumulated space per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
        uint256 taxRate; // Pool's deposit fee
    }

    IERC20 public space;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The time when space mining starts.
    uint256 public poolStartTime;

    // The time when space mining ends.
    uint256 public poolEndTime;

    address public daoFund; //All Deposit Fee (if there is) will be sent to DaoFund
    uint256 public constant MIN_TAX_RATE = 0;
    uint256 public constant MAX_TAX_RATE = 400; // Max = 400/10000*100 = 4%

    uint256 public tokenPerSecond;
    uint256 public runningTime = 365 days; // 1 year
    uint256 public constant TOTAL_REWARDS = 56000 ether;

    bool public migrated = false;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event MigrateRewardPool(address indexed newRewardPool);

    constructor(
        address _space,
        uint256 _poolStartTime,
        address _daoFund
    ) public {
        require(_space != address(0), "!space" );
        space = IERC20(_space);
        poolStartTime = _poolStartTime;
        poolEndTime = poolStartTime + runningTime;
        tokenPerSecond = TOTAL_REWARDS.div(runningTime);
        daoFund = _daoFund;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "spaceRewardPool: existing pool?");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _token,
        bool _withUpdate,
        uint256 _lastRewardTime,
        uint256 _taxRate
    ) public onlyOperator {
        require(_taxRate >= MIN_TAX_RATE && _taxRate <= MAX_TAX_RATE, "Exceed tax rate range");
        checkPoolDuplicate(_token);
        if (_withUpdate) {
            massUpdatePools();
        }
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        bool _isStarted =
        (_lastRewardTime <= poolStartTime) ||
        (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({
        token : _token,
        allocPoint : _allocPoint,
        lastRewardTime : _lastRewardTime,
        accSpacePerShare : 0,
        isStarted : _isStarted,
        taxRate : _taxRate
        }));
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's space allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(
                _allocPoint
            );
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(tokenPerSecond);
            return poolEndTime.sub(_fromTime).mul(tokenPerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(tokenPerSecond);
            return _toTime.sub(_fromTime).mul(tokenPerSecond);
        }
    }

    // View function to see pending space on frontend.
    function pendingShare(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSpacePerShare = pool.accSpacePerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _spaceReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accSpacePerShare = accSpacePerShare.add(_spaceReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accSpacePerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _spaceReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accSpacePerShare = pool.accSpacePerShare.add(_spaceReward.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accSpacePerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeSpaceTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {

            uint256 _taxRate = pool.taxRate;
            uint256 _taxAmount = 0;
            if (_taxRate > 0) {
                _taxAmount = _amount.mul(_taxRate).div(10000);
            }
            uint256 _amount_post_fee = _amount.sub(_taxAmount);

            pool.token.safeTransferFrom(_sender, address(this), _amount_post_fee);
            pool.token.safeTransferFrom(_sender, daoFund, _taxAmount);
            user.amount = user.amount.add(_amount_post_fee);
        }
        user.rewardDebt = user.amount.mul(pool.accSpacePerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accSpacePerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeSpaceTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSpacePerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Migrating to new pool. In case poolV2 developed
    function migrate(address _newRewardPool) public onlyOperator {
        require(!migrated, "Already migrated");
        require(_newRewardPool != address(0), "Invalid address");

        migrated = true;
        tokenPerSecond = 0;
        safeSpaceTransfer(_newRewardPool, TOTAL_REWARDS);

        emit MigrateRewardPool(_newRewardPool);
    }

    // Safe space transfer function, just in case if rounding error causes pool to not have enough space.
    function safeSpaceTransfer(address _to, uint256 _amount) internal {
        uint256 _spaceBal = space.balanceOf(address(this));
        if (_spaceBal > 0) {
            if (_amount > _spaceBal) {
                space.safeTransfer(_to, _spaceBal);
            } else {
                space.safeTransfer(_to, _amount);
            }
        }
    }

    function updateSpacePerSec(uint256 _new_spacePerSec) public onlyOperator {
        require(_new_spacePerSec >= 0, "Invalid amount");
        tokenPerSecond = _new_spacePerSec;
    }

    function setPoolTaxRate(uint256 _pid, uint256 _new_tax_rate) public onlyOperator {
        require(_new_tax_rate >= MIN_TAX_RATE && _new_tax_rate <= MAX_TAX_RATE, "Out of range");
        PoolInfo storage pool = poolInfo[_pid];
        pool.taxRate = _new_tax_rate;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        if (block.timestamp < poolEndTime + 90 days) {
            // do not allow to drain core token (space or lps) if less than 90 days after pool ends
            require(_token != space, "space");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "pool.token");
            }
        }
        _token.safeTransfer(to, amount);
    }

    function setDaoFund(address _daoFund) external onlyOperator {
        require(_daoFund != address(0), "Invalid address");
        daoFund = _daoFund;
    }
}
