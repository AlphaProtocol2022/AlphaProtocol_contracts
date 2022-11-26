// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./../../interfaces/ICurrencyReserve.sol";
import "../../Operator.sol";

contract XShareSinglePoolV2 is Operator, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Reward Distributor
    address public rewardReserve;
    uint256 public totalDeposited;
    // Info of each user.
    struct UserInfo {
        uint256 deposited; // How many LP tokens the user has provided.
        uint256 rewardClaimed; // Reward debt. See explanation below.
        uint256 xSharePerSec;
        uint256 maxReward;
        uint256 lastClaimedTs;
    }

    IERC20 public xShare;

    uint256 public maxRewardFactor = 2;
    uint256 public rewardRateDaily = 100; //1% daily

    // Info of each user that stakes LP tokens.
    mapping(address => UserInfo) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    bool public stopClaimed;
    bool public allowExit;
    bool public stopDeposit;
    uint256 public constant ONE_DAY = 24 hours;

    // The time when xShare mining starts.
    uint256 public poolStartTime;

    // The time when xShare mining ends.
    uint256 public poolEndTime;

    bool public migrated = false;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event Compound(address indexed user, uint256 amount);
    event MigrateRewardPool(address indexed newRewardPool);

    constructor(
        address _xshare,
        uint256 _poolStartTime
    ) public {
        require(_xshare != address(0), "!xShare");
        xShare = IERC20(_xshare);
        poolStartTime = _poolStartTime;
    }

    function setRewardRate(uint256 _reward_rate) public onlyOperator {
        rewardRateDaily = _reward_rate;
    }

    function setMaxRewardFactor(uint256 _max_factor) public onlyOperator {
        maxRewardFactor = _max_factor;
    }

    function reachedMaxReward(address _user) public view returns (bool _reached_max) {
        UserInfo storage user = userInfo[_user];
        return user.rewardClaimed == user.maxReward;
    }

    // View function to see pending xShares on frontend.
    function pendingShare(address _user) public view returns (uint256 _pending_reward) {
        UserInfo storage user = userInfo[_user];
        uint256 _since_last_claimed = block.timestamp.sub(user.lastClaimedTs);
        _pending_reward = user.xSharePerSec.mul(_since_last_claimed);

        if (user.rewardClaimed.add(_pending_reward) > user.maxReward) {
            _pending_reward = user.maxReward.sub(user.rewardClaimed);
        }
    }

    // Deposit LP tokens.
    function deposit(uint256 _amount) public nonReentrant {
        require(!stopDeposit, "Deposit stopped");
        UserInfo storage user = userInfo[msg.sender];
        // Get pending reward => send to user => update rewardClaimed;
        uint256 _pending_reward = pendingShare(msg.sender);

        if (_pending_reward > 0) {
            _compound(msg.sender);
        }

        if (_amount > 0) {
            xShare.safeTransferFrom(msg.sender, rewardReserve, _amount);
        }

        user.deposited = user.deposited.add(_amount);
        user.maxReward = user.deposited.mul(maxRewardFactor);
        user.xSharePerSec = user.deposited.mul(rewardRateDaily).div(10000).div(ONE_DAY);
        user.lastClaimedTs = block.timestamp;

        totalDeposited = totalDeposited.add(_amount);

        emit Deposit(msg.sender, _amount);
    }

    function compound() public nonReentrant {
        _compound(msg.sender);
    }

    function _compound(address _user) internal {
        UserInfo storage user = userInfo[msg.sender];

        require(user.deposited > 0, "not deposited");

        uint256 _pending_reward = pendingShare(msg.sender);

        user.deposited = user.deposited.add(_pending_reward);
        user.maxReward = user.deposited.mul(maxRewardFactor);
        user.xSharePerSec = user.deposited.mul(rewardRateDaily).div(10000).div(ONE_DAY);
        user.rewardClaimed = user.rewardClaimed.add(_pending_reward);
        user.lastClaimedTs = block.timestamp;

        totalDeposited = totalDeposited.add(_pending_reward);
        emit Compound(_user, _pending_reward);
    }

    // Withdraw LP tokens.
    function claimReward() public nonReentrant {
        require(!stopClaimed, "Reward stopped");

        UserInfo storage user = userInfo[msg.sender];

        uint256 _pending_reward = pendingShare(msg.sender);

        if (_pending_reward > 0) {
            safeXShareTransfer(msg.sender, _pending_reward);
            user.rewardClaimed = user.rewardClaimed.add(_pending_reward);
            user.lastClaimedTs = block.timestamp;
        }

        emit RewardPaid(msg.sender, _pending_reward);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw() public nonReentrant {
        require(allowExit, "Can not exit");
        UserInfo storage user = userInfo[msg.sender];
        safeXShareTransfer(msg.sender, user.deposited);
        user.deposited = 0;
        user.rewardClaimed = 0;
        user.maxReward = 0;
        user.xSharePerSec = 0;
        emit EmergencyWithdraw(msg.sender, user.deposited);
    }

    // Safe xShare transfer function, just in case if rounding error causes pool to not have enough xShares.
    function safeXShareTransfer(address _to, uint256 _amount) internal {
        uint256 _xshareBal = xShare.balanceOf(rewardReserve);
        if (_xshareBal > 0) {
            if (_amount > _xshareBal) {
                ICurrencyReserve(rewardReserve).transferTo(address(xShare), _to, _xshareBal);
            } else {
                ICurrencyReserve(rewardReserve).transferTo(address(xShare), _to, _amount);
            }
        }
    }

    // Migrating to new pool. In case poolV2 developed
    function migrate(address _newRewardPool) public onlyOperator {
        require(!migrated, "Already migrated");
        require(_newRewardPool != address(0), "Invalid address");

        migrated = true;
        uint256 remainReward = xShare.balanceOf(rewardReserve);
        safeXShareTransfer(_newRewardPool, remainReward);

        emit MigrateRewardPool(_newRewardPool);
    }

    function setRewardReserve(address _rewardReserve) external onlyOperator {
        require(_rewardReserve != address(0), "Invald address");
        rewardReserve = _rewardReserve;
    }

    function toggleAllowExit() external onlyOperator {
        allowExit = !allowExit;
    }

    function toggleClaimReward() external onlyOperator {
        stopClaimed = !stopClaimed;
    }

    function toggleStopDeposit() external onlyOperator {
        stopDeposit = !stopDeposit;
    }
}
