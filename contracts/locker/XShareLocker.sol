pragma solidity >=0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../interfaces/IXShareLocker.sol";
import "../Operator.sol";
import "../interfaces/IYShare.sol";

contract XShareLocker is Operator, IXShareLocker {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public xShare;
    address public yShare;

    uint256 public MIN_LOCK_AMOUNT = 1 ether;
    uint256 public MIN_LOCK_DURATION = 1 minutes; //Min 1 week lock
    uint256 public MAX_LOCK_DURATION = 208 minutes; //Max 288 weeks (~ 4 years) lock
    uint256 public LOCK_DURATION_STEP = 1 minutes; //Lock duration must be like 1, 2, 5, 10 weeks
    uint256 public MAX_YSHARE_MINTED_PER_XSHARE = 4 ether;
    uint256 public EXTRA_YSHARE_PER_WEEK = (MAX_YSHARE_MINTED_PER_XSHARE.sub(1 ether)).div(MAX_LOCK_DURATION).mul(MIN_LOCK_DURATION); //Extra yShare for every 1 week longer lock

    uint256 public totalXShareLocked;
    uint256 public totalYShareMinted;
    uint256 public averageLockDuration;

    struct UserInfo {
        uint256 lockedAmount;
        uint256 yShareMinted;
        uint256 lockStartTime;
        uint256 lockEndTime;
        uint256 lockDuration;
    }

    bool public initialized = false;
    bool public isUnlockAll = false; //Allow to unlock all without waiting lock end, use in emergency cases

    mapping(address => UserInfo) public userInfo;

    /* ========== MODIFIER ========== */

    modifier notInitialized() {
        require(!initialized, "Already Initialized");
        _;
    }

    modifier isInitialized() {
        require(initialized, "Not Initialized");
        _;
    }

    modifier validDuration(uint256 _duration) {
        require((_duration % MIN_LOCK_DURATION) == 0, "Invalid duration");
        require(_duration >= MIN_LOCK_DURATION && _duration <= MAX_LOCK_DURATION, "Min Lock 1 week and max lock 208 week");
        _;
    }

    modifier isAllowedUnlockAll() {
        require(isUnlockAll, "Not unlock all");
        _;
    }

    function info() public view returns (uint256 _totalXShareLocked, uint256 _totalYShareMinted, uint256 _averageLockDuration, uint256 _min_lock_duration, bool _isUnlockAll) {
        return (
            _totalXShareLocked = totalXShareLocked,
            _totalYShareMinted = totalYShareMinted,
            _averageLockDuration = averageLockDuration,
            _min_lock_duration = MIN_LOCK_DURATION,
             _isUnlockAll = isUnlockAll
        );
    }

    // Check where user had locked xShare or not
    function isLocked(address user) public view returns (bool) {
        return userInfo[user].lockEndTime > block.timestamp;
    }

    /* ========== IMMUTABLE FUNCTIONS ========== */

    function initialize(address _xShare, address _yShare) public notInitialized onlyOperator {
        require(_xShare != address(0), "Invalid address");
        require(_yShare != address(0), "Invalid address");
        xShare = _xShare;
        yShare = _yShare;
        initialized = true;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function lockXShare(uint256 amount, uint256 lockDuration) public override validDuration(lockDuration) {
        address _sender = msg.sender;
        UserInfo storage user = userInfo[_sender];
        require(amount >= MIN_LOCK_AMOUNT, "Min Lock 1 xShare");
        require(!isLocked(_sender), "Please use add more function");
        require(user.lockedAmount == 0, "Please Unlock/Add more");
        uint256 yShare_minting_amount = calculateYShareMintAmount(amount, lockDuration);

        IYShare(yShare).lockerMintFrom(msg.sender, yShare_minting_amount);
        IERC20(xShare).safeTransferFrom(msg.sender, address(this), amount);

        user.lockStartTime = block.timestamp;
        user.lockEndTime = block.timestamp.add(lockDuration);
        user.lockDuration = lockDuration;
        user.lockedAmount = user.lockedAmount.add(amount);
        user.yShareMinted = user.yShareMinted.add(yShare_minting_amount);

        totalXShareLocked = totalXShareLocked.add(amount);
        totalYShareMinted = totalYShareMinted.add(yShare_minting_amount);
        updateAverageLockDuration();

        emit LockXShare(_sender, amount);
    }

    //If use has locked some XShare before, user can use this function to add more xShare but still have the same lock duration and receive more yShare
    function addMoreXShare(uint256 amount) public override {
        address _sender = msg.sender;
        require(amount >= MIN_LOCK_AMOUNT, "Invalid Amount");
        require(isLocked(_sender), "Lock ended");

        UserInfo storage user = userInfo[_sender];
        uint256 yShare_minting_amount = calculateYShareMintAmount(amount, user.lockDuration);
        IERC20(xShare).safeTransferFrom(msg.sender, address(this), amount);
        IYShare(yShare).lockerMintFrom(msg.sender, yShare_minting_amount);

        user.lockedAmount = user.lockedAmount.add(amount);
        user.yShareMinted = user.yShareMinted.add(yShare_minting_amount);
        totalXShareLocked = totalXShareLocked.add(amount);
        totalYShareMinted = totalYShareMinted.add(yShare_minting_amount);
        updateAverageLockDuration();

        emit AddMoreXShare(_sender, amount);
    }

    //If User has locked XShare before, user can extend their lock duration to receive more yShare
    function extendLockDuration(uint256 extendLockDuration) public override validDuration(extendLockDuration) {
        address _sender = msg.sender;
        UserInfo storage user = userInfo[_sender];
        require(isLocked(_sender), "Lock ended");
        require(user.lockDuration.add(extendLockDuration) <= MAX_LOCK_DURATION, "Exceed max lock duration");

        uint256 currentLockedAmount = user.lockedAmount;
        uint256 totalYShareSupposedToMint = calculateYShareMintAmount(user.lockedAmount, user.lockDuration.add(extendLockDuration));
        uint256 extraYShareAmount = totalYShareSupposedToMint.sub(user.yShareMinted);

        IYShare(yShare).lockerMintFrom(msg.sender, extraYShareAmount);

        user.lockEndTime = user.lockEndTime.add(extendLockDuration);
        user.yShareMinted = user.yShareMinted.add(extraYShareAmount);
        user.lockDuration = user.lockDuration.add(extendLockDuration);
        totalYShareMinted = totalYShareMinted.add(extraYShareAmount);
        updateAverageLockDuration();

        emit ExtendLockDuration(_sender, extendLockDuration);
    }

    function unlockXShare(uint256 amount) public override {
        address _sender = msg.sender;
        require(amount > 0, "Invalid Amount");
        require(!isLocked(_sender), "Still in lock");
        unlockOperation(amount, _sender);
        emit UnlockXShare(_sender, amount);
    }

    function unlockAll() public {
        address _sender = msg.sender;
        require(!isLocked(_sender), "Still in lock");
        unlockOperation(userInfo[_sender].lockedAmount, _sender);
        emit UnlockAll(_sender);
    }

    function unlockOperation(uint256 _amount, address _user) internal {
        UserInfo storage user = userInfo[_user];
        require(user.lockedAmount >= _amount);
        uint256 require_yShare_balance = calculateYShareMintAmount(_amount, user.lockDuration);
        require(IERC20(yShare).balanceOf(msg.sender) >= require_yShare_balance, "Not enough yShare balance to unlock");

        IYShare(yShare).lockerBurnFrom(msg.sender, require_yShare_balance);
        IERC20(xShare).safeTransfer(msg.sender, _amount);

        totalXShareLocked = totalXShareLocked.sub(_amount);
        totalYShareMinted = totalYShareMinted.sub(require_yShare_balance);
        user.lockedAmount = user.lockedAmount.sub(_amount);
        user.yShareMinted = user.yShareMinted.sub(require_yShare_balance);
        if (user.lockedAmount == 0) {
            user.lockDuration = 0;
            user.lockStartTime = 0;
            user.lockEndTime = 0;
        }

        updateAverageLockDuration();
    }

    //In emergency cases, admin will allow user to unlock their xShare immediately
    function emergencyUnlockAll() public override isAllowedUnlockAll {
        address _sender = msg.sender;
        UserInfo storage user = userInfo[_sender];
        if (user.lockedAmount <= 0) revert("Not locked any xShare");

        IYShare(yShare).lockerBurnFrom(msg.sender, user.yShareMinted);
        IERC20(xShare).safeTransfer(msg.sender, user.lockedAmount);

        totalXShareLocked = totalXShareLocked.sub(user.lockedAmount);
        totalYShareMinted = totalYShareMinted.sub(user.yShareMinted);

        user.lockedAmount = 0;
        user.yShareMinted = 0;
        user.lockDuration = 0;
        user.lockStartTime = 0;
        user.lockEndTime = 0;

        updateAverageLockDuration();

        emit EmergencyUnlockAll(_sender);
    }

    function toggleUnlockAll() public onlyOperator {
        isUnlockAll = !isUnlockAll;
    }

    function updateAverageLockDuration() internal {
        if (totalXShareLocked == 0) {
            averageLockDuration = 0;
        } else {
            uint256 ySharePerXShareFactor = totalYShareMinted.mul(1e18).div(totalXShareLocked);
            averageLockDuration = (ySharePerXShareFactor.sub(1e18)).div(EXTRA_YSHARE_PER_WEEK).mul(MIN_LOCK_DURATION);
        }
    }

    function calculateYShareMintAmount(uint256 amount, uint256 lockDuration) internal view returns (uint256){
        uint256 boost_amount_factor = lockDuration.div(MIN_LOCK_DURATION);
        uint256 extra_yShare_per_xShare = EXTRA_YSHARE_PER_WEEK.mul(boost_amount_factor);
        uint256 actual_extra_yShare = amount.mul(extra_yShare_per_xShare).div(1e18);
        //To calculate factor for minting yShare
        uint256 yShare_minting_amount = amount.add(actual_extra_yShare);
        //To be mint yShare amount
        return ceil(yShare_minting_amount);
    }

    //Method to round up to 4 digit
    function ceil(uint256 _amount) internal pure returns (uint256){
        return (_amount.add(1e14).sub(1)).div(1e14).mul(1e14);
    }

    /* ========== EVENT ========== */

    event LockXShare(address indexed user, uint256 amount);
    event AddMoreXShare(address indexed user, uint256 amount);
    event ExtendLockDuration(address indexed user, uint256 extendDuration);
    event UnlockXShare(address indexed user, uint256 amount);
    event UnlockAll(address indexed user);
    event EmergencyUnlockAll(address indexed user);
}
