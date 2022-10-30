pragma solidity >=0.6.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../Operator.sol";
import "../interfaces/ILaunchPad.sol";

contract LaunchPad is Operator, ILaunchPad, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    struct InvestorInfo {
        uint256 sTokenAllocation; // Amount of Sell token user able to buy
        uint256 rTokenToBeSpent; // Amount of Raise token to be spent by user
        uint256 rTokenUnSpent; // Amount of Raise token un-spent
    }

    mapping(address => uint256) private userCommitted; // Amount of raise token staked by user
    mapping(address => bool) private isClaimed; // Claim status of user
    mapping(address => InvestorInfo) public investorInfos;

    ERC20 public sToken; // Sell Token
    uint256 public sTokenAmount; // Total sToken to be sold

    ERC20 public rToken; // Fund raising Token
    uint256 public fundToRaise; // Amount of rToken to be raised

    uint256 public missing_decimal;

    uint256 public priceDenominator = 10000;
    uint256 public priceNumerator; // 1 sToken = {priceNumerator/priceDenominator} rToken. ex: priceNumerator = 5000 => 1 sToken = 5000/10000 = 0.5 rToken

    uint256 public startTime;
    uint256 public endTime;
    uint256 public duration;

    uint256 public allocationPerCommit; // sToken be able to buy per 1 rToken committed
    uint256 public totalCommitted; // Total rToken committed

    // flags
    bool public isInitialized = false;
    bool public canClaim = false; // Allow user to claim after sale
    bool public devClaimed = false;
    /* ========== Modifiers =============== */

    modifier notInitialized {
        require(!isInitialized, "Launchpad is initialized");
        _;
    }

    modifier initialized {
        require(isInitialized, "Launchpad is not initialized");
        _;
    }

    modifier checkLaunchPadRunning {
        require(block.timestamp > startTime && block.timestamp < endTime, "Launchpad is not started");
        _;
    }

    modifier checkTimeEnd {
        require(block.timestamp > endTime, "Launchpad is not ended");
        _;
    }

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event TokenCommitted(address indexed user, uint256 amount);
    event ClaimedToken(address indexed user, uint256 sTokenAllocation, uint256 rTokenLeft);
    event UseRaisedFund(address indexed executor, uint256 amount);

    /* ========== VIEW FUNCTIONS ========== */

    function getInvestorInfo(address investor) external view returns (
        uint256 _committed,
        uint256 _sTokenAllocation,
        bool _claimed,
        uint256 _rTokenUnspent
    ) {
        return (
        _committed = userCommitted[investor],
        _sTokenAllocation = calcUserAllocation(investor),
        _claimed = isClaimed[investor],
        _rTokenUnspent = investorInfos[investor].rTokenUnSpent
        );
    }

    function info() external view returns (
        uint256 _totalCommitted,
        uint256 _allocationPerCommit,
        uint256 _startTime,
        uint256 _endTime,
        bool _canClaim
    ) {
        _totalCommitted = totalCommitted;
        _allocationPerCommit = allocationPerCommit;
        _startTime = startTime;
        _endTime = endTime;
        _canClaim = canClaim;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _sToken,
        address _rToken,
        uint256 _startTime,
        uint256 _priceNumerator,
        uint256 _sTokenAmount,
        uint256 _duration
    ) public notInitialized onlyOperator {
        require(!isInitialized, "Already Initialized");
        sToken = ERC20(_sToken);
        rToken = ERC20(_rToken);
        startTime = _startTime;
        duration = _duration;
        endTime = startTime + duration;
        priceNumerator = _priceNumerator;
        sTokenAmount = _sTokenAmount;
        missing_decimal = uint256(18).sub(rToken.decimals());
        fundToRaise = _sTokenAmount.mul(priceNumerator).div(priceDenominator).div(10 ** missing_decimal);
        isInitialized = true;
        allocationPerCommit = sTokenAmount.mul(1e18).div(fundToRaise).div(10 ** missing_decimal);

        emit Initialized(msg.sender, block.timestamp);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function commitToken(uint256 _amount) public override checkLaunchPadRunning initialized nonReentrant {
        require(_amount > 0, "Invalid amount");

        totalCommitted = totalCommitted.add(_amount);
        userCommitted[msg.sender] = userCommitted[msg.sender].add(_amount);
        updateAllocationPerShare();

        rToken.safeTransferFrom(msg.sender, address(this), _amount);
        emit TokenCommitted(msg.sender, _amount);
    }

    function claimToken() public override checkTimeEnd initialized nonReentrant {
        require(userCommitted[msg.sender] > 0, "You were not participated in launchpad");
        require(canClaim, "Can not claim now");
        updateInvestorInfo(msg.sender);

        InvestorInfo memory investorInfo = investorInfos[msg.sender];

        // Stop user to claim twice
        require(!isClaimed[msg.sender], "Already Claimed");
        isClaimed[msg.sender] = true;

        rToken.safeTransfer(msg.sender, investorInfo.rTokenUnSpent);
        sToken.safeTransfer(msg.sender, investorInfo.sTokenAllocation);

        emit ClaimedToken(msg.sender, investorInfo.sTokenAllocation, investorInfo.rTokenUnSpent);
    }

    // Send raised fund to dev
    function useRaisedFund() public override checkTimeEnd initialized onlyOperator nonReentrant  {
        // Make sure dev can only claim once
        require(!devClaimed, "Dev already claimed");
        devClaimed = true;

        uint256 fundToTransfer = 0;

        // Make sure maximum fund to transfer <= fundToRaise
        if (totalCommitted > fundToRaise) {
            fundToTransfer = fundToRaise;
        } else {
            fundToTransfer = totalCommitted;
        }

        rToken.safeTransfer(msg.sender, fundToTransfer);

        emit UseRaisedFund(msg.sender, fundToTransfer);
    }

    // Update investor info after launchpad
    function updateInvestorInfo(address investor) internal {
        require(investor != address(0), "investor is invalid");
        InvestorInfo memory investorInfo = investorInfos[investor];
        investorInfo.sTokenAllocation = calcUserAllocation(investor);
        investorInfo.rTokenToBeSpent = investorInfo.sTokenAllocation.mul(priceNumerator).div(priceDenominator).div(10 ** missing_decimal);
        investorInfo.rTokenUnSpent = userCommitted[investor].sub(investorInfo.rTokenToBeSpent);
        investorInfos[investor] = investorInfo;
    }

    // calculate user's sell token allocation
    function calcUserAllocation(address investor) internal view returns (uint256) {
        uint256 investorCommitted = userCommitted[investor];
        uint256 allocation = investorCommitted.mul(10 ** missing_decimal).mul(allocationPerCommit).div(1e18);
        return ceil(allocation);
    }

    function updateAllocationPerShare() internal {
        if (totalCommitted > fundToRaise) {
            allocationPerCommit = sTokenAmount.mul(1e18).div(totalCommitted.mul(10 ** missing_decimal));
            allocationPerCommit = ceil(allocationPerCommit);
        }
    }

    function setEndTime(uint256 _endTime) public onlyOperator {
        endTime = _endTime;
    }

    function toggleClaim() public onlyOperator {
        canClaim = !canClaim;
    }

    //Method to round up to 4 digit
    function ceil(uint256 _amount) internal view returns (uint256){
        return (_amount.add(1e14).sub(1)).div(1e14).mul(1e14);
    }
}
