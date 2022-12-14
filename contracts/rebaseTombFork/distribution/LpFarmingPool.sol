// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../../Operator.sol";

contract LpFarmingPool is Operator, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 depositTs;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. tokens to distribute per block.
        uint256 lastRewardTime; // Last time that token distribution occurs.
        uint256 accTokenPerShare; // Accumulated token per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
        uint256 taxRate; // Pool's deposit fee
        uint256 lockPeriod;
    }

    IERC20 public rewardToken;
    address public xIndexMinter;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The time when token mining starts.
    uint256 public poolStartTime;

    // The time when token mining ends.
    uint256 public poolEndTime = 1698854400;

    address public daoFund; //All Deposit Fee (if there is) will be sent to DaoFund
    uint256 public constant MIN_TAX_RATE = 0;
    uint256 public constant MAX_TAX_RATE = 400; // Max = 400/10000*100 = 4%

    bool initialized = false;
    uint256 public tokenPerSecond;
    uint256 public extraRewardFactor = 2;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event RewardAdded(uint256 amount);
    event ChangeLockPeriod(uint256 lockPeriod);

    modifier onlyXIndexMinterOrOperator() {
        require(msg.sender == xIndexMinter || msg.sender == operator(), "Not allowed");
        _;
    }

    function initialize(
        address _rewardToken,
        uint256 _poolStartTime,
        address _daoFund,
        address _xIndexMinter
    ) external onlyOperator {
        require(!initialized, "Already initialized");
        require(_rewardToken != address(0), "!token");
        require(_xIndexMinter != address(0), "!token");
        rewardToken = IERC20(_rewardToken);
        poolStartTime = _poolStartTime;
        daoFund = _daoFund;
        xIndexMinter = _xIndexMinter;
        initialized = true;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "tokenRewardPool: existing pool?");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _token,
        bool _withUpdate,
        uint256 _lastRewardTime,
        uint256 _taxRate,
        uint256 _lockPeriod
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
        accTokenPerShare : 0,
        isStarted : _isStarted,
        taxRate : _taxRate,
        lockPeriod : _lockPeriod
        }));
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's token allocation point. Can only be called by the owner.
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

    function setPoolLockPeriod(uint256 _lockPeriod, uint256 _pid) public onlyOperator {
        PoolInfo storage pool = poolInfo[_pid];
        pool.lockPeriod = _lockPeriod;
        emit ChangeLockPeriod(_lockPeriod);
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

    function setExtraRewardFactor(uint256 _newFactor) external onlyOperator {
        require(_newFactor <= 10, "Exceed max allow");
        extraRewardFactor = _newFactor;
    }

    // View function to see unlock timestamp
    function getUnlockTime(uint256 _pid, address _user) public view returns (uint256 _unlockTs) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][_user];
        return user.depositTs.add(pool.lockPeriod);
    }

    // View function to see pending token on frontend.
    function pendingShare(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _tokenReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accTokenPerShare = accTokenPerShare.add(_tokenReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accTokenPerShare).div(1e18).sub(user.rewardDebt);
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
            uint256 _tokenReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accTokenPerShare = pool.accTokenPerShare.add(_tokenReward.mul(1e18).div(tokenSupply));
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
            uint256 _pending = user.amount.mul(pool.accTokenPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeTokenTransfer(_sender, _pending);
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
            user.depositTs = block.timestamp;
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accTokenPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeTokenTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        // Can withdraw will be enabled to token pool only, the pool will lockup token and remove it from circulating supply
        if (_amount > 0) {
            require(user.depositTs.add(pool.lockPeriod) <= block.timestamp, "Still in lock");
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.depositTs.add(pool.lockPeriod) <= block.timestamp, "Still in lock");
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe token transfer function, just in case if rounding error causes pool to not have enough token.
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 _tokenBal = rewardToken.balanceOf(address(this));
        if (_tokenBal > 0) {
            if (_amount > _tokenBal) {
                rewardToken.safeTransfer(_to, _tokenBal);
            } else {
                rewardToken.safeTransfer(_to, _amount);
            }
        }
    }

    function addReward(uint256 _amount) external onlyXIndexMinterOrOperator {
        uint256 poolRunningTime = poolEndTime.sub(block.timestamp);
        uint256 extraRewardPerSec = _amount.div(poolRunningTime).mul(extraRewardFactor);
        tokenPerSecond = tokenPerSecond.add(extraRewardPerSec);
        emit RewardAdded(_amount);
    }

    function updateRewardPerSec(uint256 _new_xTokenPerSec) public onlyOperator {
        require(_new_xTokenPerSec >= 0, "Invalid amount");
        tokenPerSecond = _new_xTokenPerSec;
    }

    function setPoolTaxRate(uint256 _pid, uint256 _new_tax_rate) public onlyOperator {
        require(_new_tax_rate >= MIN_TAX_RATE && _new_tax_rate <= MAX_TAX_RATE, "Out of range");
        PoolInfo storage pool = poolInfo[_pid];
        pool.taxRate = _new_tax_rate;
    }

    function setDaoFund(address _daoFund) external onlyOperator {
        require(_daoFund != address(0), "Invalid address");
        daoFund = _daoFund;
    }
}
