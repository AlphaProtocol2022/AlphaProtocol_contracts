pragma solidity >=0.6.12;


import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Operator.sol";

contract VestingContract is Operator{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Locker {
        uint256 totalReward; // Total vesting amount
        uint256 startTime; // Vesting start time
        uint256 endTime; // Vesting end time
        uint256 lastClaimedTime; // Last claim time
        uint256 rewardRate; // Reward per second
        uint256 totalClaimed;
        bool canClaim; // Flag
    }

    address public rewardToken = address(0x9f64D1aAcb129B844500119B50938c57aa9aD6E5); // XSHARE
    uint256 public constant VESTING_DURATION = 365 days;
    uint256 public constant TOTAL_REWARD = 2000000 ether;
    uint256 public totalRewardVesting;

    mapping(address => Locker) public locker;

    event AddLocker(address indexed beneficiary, uint256 totalReward);
    event ClaimReward(address indexed beneficiary, uint256 amount);

    function addLocker(
        address _beneficiary,
        uint256 _totalReward,
        uint256 _startTime
    ) public onlyOperator {
        require(_beneficiary != address(0), "Invalid Address");
        require(_startTime >= block.timestamp, "Invalid Timestamp");
        require(_totalReward > 0, "Invalid reward amount");
        require(totalRewardVesting.add(_totalReward) <= TOTAL_REWARD, "Exceed total vesting amount");

        totalRewardVesting = totalRewardVesting.add(_totalReward);

        Locker storage _locker = locker[_beneficiary];
        _locker.totalReward = _locker.totalReward.add(_totalReward);
        _locker.startTime = _startTime;
        _locker.endTime = _startTime.add(VESTING_DURATION);
        _locker.lastClaimedTime = _startTime;
        _locker.canClaim = true;
        _locker.rewardRate = _totalReward.div(VESTING_DURATION);

        emit AddLocker(_beneficiary, _totalReward);
    }

    function claimReward() public {
        address _beneficiary = msg.sender;
        Locker storage _locker = locker[_beneficiary];
        require(_locker.totalReward > 0, "Locker doesn't exist");
        require(_locker.canClaim, "Can not claim");

        uint256 _pendingReward = getPendingReward(_beneficiary);
        if (_pendingReward > 0) {
            emit ClaimReward(_beneficiary, _pendingReward);
            IERC20(rewardToken).safeTransfer(_beneficiary, _pendingReward);
        }
        _locker.totalClaimed = _locker.totalClaimed.add(_pendingReward);
        _locker.lastClaimedTime = block.timestamp;
    }

    function getPendingReward(address _beneficiary) public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        Locker memory _locker = locker[_beneficiary];
        if (_now > _locker.endTime) _now = _locker.endTime;
        if (_locker.lastClaimedTime >= _now) return 0;
        _pending = _now.sub(_locker.lastClaimedTime).mul(_locker.rewardRate);
    }

    function toggleClaim(address _beneficiary) public onlyOperator {
        Locker storage _locker = locker[_beneficiary];
        _locker.canClaim = !_locker.canClaim;
    }
}
