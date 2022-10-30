pragma solidity >=0.6.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IUniswapV2Router01.sol";
import "../Operator.sol";
import "../interfaces/ILaunchPad.sol";


contract FairLaunchPad is Operator, ILaunchPad, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    struct InvestorInfo {
        uint256 lpReturnAllocation; // Amount of Sell token user able to buy
        uint256 rTokenSpent; // Amount of Raise token to be spent by user
        uint256 rTokenUnSpent; // Amount of Raise token un-spent
    }

    mapping(address => uint256) public userCommitted; // Amount of raise token staked by user
    mapping(address => bool) private isClaimed; // Claim status of user
    mapping(address => InvestorInfo) public investorInfos;

    ERC20 public sToken; // Sell Token
    uint256 public sTokenAmount; // Total sToken to be sold

    ERC20 public rToken; // Fund raising Token
    uint256 public raiseAmount; // Amount of rToken to be raised
    uint256 public totalUnspentAmount;

    ERC20 public returnLp;
    uint256 public lpFormedAfterSale;

    uint256 public usdcHardCap;
    address public usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);

    uint256 public missing_decimal;

    uint256 public startTime;
    uint256 public endTime;
    uint256 public duration;

    uint256 public totalCommitted; // Total rToken committed

    uint256 public constant RATIO_PRECISION = 1e6;
    uint256 public percentFilled;

    // flags
    bool public isInitialized = false;
    bool public canClaim = false; // Allow user to claim after sale
    bool public devClaimed = false;
    bool public capturedRaisedAmount = false;
    bool public finalized = false;
    bool public canceled = false;

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event TokenCommitted(address indexed user, uint256 amount);
    event ClaimedToken(address indexed user, uint256 sTokenAllocation, uint256 rTokenLeft);
    event ReturnCommittedToken(address indexed user, uint256 amount);
    event UseRaisedFund(address indexed executor, uint256 amount);

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

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _sToken,
        address _rToken,
        address _returnLp,
        uint256 _startTime,
        uint256 _duration,
        uint256 _usdcHardCap
    ) public notInitialized onlyOperator {
        require(!isInitialized, "Already Initialized");
        sToken = ERC20(_sToken);
        rToken = ERC20(_rToken);
        returnLp = ERC20(_returnLp);
        startTime = _startTime;
        duration = _duration;
        endTime = startTime + duration;
        usdcHardCap = _usdcHardCap;
        missing_decimal = uint256(18).sub(rToken.decimals());
        isInitialized = true;

        emit Initialized(msg.sender, block.timestamp);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function calcUserAllocation(address _user) public view returns (uint256 _allocation) {
        uint256 committedAmt = userCommitted[_user];
        uint256 calcAllocation = 0;
        if (totalCommitted > 0) {
            calcAllocation = committedAmt.mul(lpFormedAfterSale).div(totalCommitted);
        }
        _allocation = floor(calcAllocation);
    }

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

    function getLpPrice() public view returns (uint256 _lpPrice) {
        IUniswapV2Pair lpToken = IUniswapV2Pair(address(rToken));
        bool isToken0Usdc = lpToken.token0() == usdc;
        uint256 usdcReserve = 0;
        (uint256 token0Reserve, uint256 token1Reserve,) = lpToken.getReserves();
        if (isToken0Usdc) {
            usdcReserve = token0Reserve;
        } else {
            usdcReserve = token1Reserve;
        }
        uint256 lpSupply = lpToken.totalSupply();
        _lpPrice = usdcReserve.mul(2).mul(10 ** 12).mul(10 ** 18).div(lpSupply);
    }

    function info() external view returns (
        uint256 _totalCommitted,
        uint256 _startTime,
        uint256 _endTime,
        bool _canClaim,
        bool _canceled
    ) {
        _totalCommitted = totalCommitted;
        _startTime = startTime;
        _endTime = endTime;
        _canClaim = canClaim;
        _canceled = canceled;
    }

    function getInvestorReturnValue(address _user) external view returns (uint256 _returnValue) {
        _returnValue = 0;
        if (totalCommitted > 0) {
            uint256 _raisedAmount = totalCommitted;
            if (totalCommitted > raiseAmount) {
                _raisedAmount = raiseAmount;
            }
            uint256 raiseTokenPrice = getLpPrice();
            uint256 _raisedValue = raiseTokenPrice.mul(_raisedAmount).div(1e18);
            uint256 _totalReturnValue = _raisedValue.mul(6).div(4);
            uint256 _committedAmount = userCommitted[_user];
            _returnValue = _totalReturnValue.mul(_committedAmount).div(totalCommitted);
        }
    }

    function capturingRaiseAmount() external onlyOperator {
        require(!capturedRaisedAmount, "Already did");
        capturedRaisedAmount = true;
        uint256 lpPrice = getLpPrice();
        uint256 _raiseAmount = usdcHardCap.mul(10 ** 12).mul(10 ** 18).div(lpPrice);
        raiseAmount = floor(_raiseAmount);
    }

    function commitToken(uint256 _amount) public override checkLaunchPadRunning initialized nonReentrant {
        require(_amount > 0, "Invalid amount");
        require(capturedRaisedAmount, "Not ready for start");
        uint256 _floor_amount = floor(_amount);
        totalCommitted = totalCommitted.add(_floor_amount);
        userCommitted[msg.sender] = userCommitted[msg.sender].add(_floor_amount);
        percentFilled = totalCommitted.mul(RATIO_PRECISION).div(raiseAmount);

        rToken.safeTransferFrom(msg.sender, address(this), _floor_amount);
        emit TokenCommitted(msg.sender, _floor_amount);
    }

    function claimToken() public override checkTimeEnd initialized nonReentrant {
        require(canClaim, "Can not claim now");
        require(userCommitted[msg.sender] > 0, "You were not participated in launchpad");
        require(!isClaimed[msg.sender], "Already Claimed");
        isClaimed[msg.sender] = true;
        if (!canceled) {
            require(finalized, "Not finalized");
            updateUserInfo(msg.sender);

            InvestorInfo storage investorInfo = investorInfos[msg.sender];

            // Stop user to claim twice
            if (investorInfo.rTokenUnSpent > 0) {
                uint256 rTokenBalance = rToken.balanceOf(address(this));
                if (investorInfo.rTokenUnSpent > rTokenBalance) {
                    rToken.safeTransfer(msg.sender, rTokenBalance);
                } else {
                    rToken.safeTransfer(msg.sender, investorInfo.rTokenUnSpent);
                }
            }

            ERC20(returnLp).safeTransfer(msg.sender, investorInfo.lpReturnAllocation);

            emit ClaimedToken(msg.sender, investorInfo.lpReturnAllocation, investorInfo.rTokenUnSpent);
        } else {
            uint256 committedAmount = userCommitted[msg.sender];
            rToken.safeTransfer(msg.sender, committedAmount);

            emit ReturnCommittedToken(msg.sender, committedAmount);
        }

    }

    // Send raised fund to dev
    function useRaisedFund() public override checkTimeEnd initialized onlyOperator nonReentrant {
        // Make sure dev can only claim once
        require(!devClaimed, "Dev already claimed");
        devClaimed = true;

        uint256 fundToTransfer = 0;

        // Make sure maximum fund to transfer <= fundToRaise
        if (totalCommitted > raiseAmount) {
            fundToTransfer = raiseAmount;
            totalUnspentAmount = totalCommitted.sub(raiseAmount);
        } else {
            fundToTransfer = totalCommitted;
        }

        rToken.safeTransfer(msg.sender, fundToTransfer);

        emit UseRaisedFund(msg.sender, fundToTransfer);
    }

    function finalizingTotalClaimAmount() external onlyOperator checkTimeEnd {
        require(!finalized, "Already did");
        finalized = true;
        lpFormedAfterSale = IUniswapV2Pair(address(returnLp)).balanceOf(msg.sender);
        ERC20(returnLp).safeTransferFrom(msg.sender, address(this), lpFormedAfterSale);
    }

    function calcUserInfo(address _user) public view returns (uint256 _spendAmount, uint256 _unSpendAmount) {
        uint256 committedAmt = userCommitted[_user];
        _spendAmount = 0;
        _unSpendAmount = 0;
        if (percentFilled >= RATIO_PRECISION) {
            _spendAmount = ceil(raiseAmount.mul(10 ** 18).div(totalCommitted).mul(committedAmt).div(10 ** 18));
            _unSpendAmount = committedAmt.sub(_spendAmount);
        } else {
            _spendAmount = committedAmt;
        }
    }

    function updateUserInfo(address _user) internal {
        require(_user != address(0), "Invalid address");
        uint256 committedAmt = userCommitted[_user];

        InvestorInfo storage investorInfo = investorInfos[_user];
        investorInfo.lpReturnAllocation = calcUserAllocation(_user);

        if (percentFilled >= RATIO_PRECISION) {
            uint256 spentAmount = raiseAmount.mul(10 ** 18).div(totalCommitted).mul(committedAmt).div(10 ** 18);
            investorInfo.rTokenSpent = ceil(spentAmount);
            investorInfo.rTokenUnSpent = committedAmt.sub(investorInfo.rTokenSpent);
        } else {
            investorInfo.rTokenSpent = committedAmt;
        }
    }

    function cancelLaunchpad() public onlyOperator checkTimeEnd {
        require(!canceled, "Already canceled");
        canceled = true;
    }

    function setEndTime(uint256 _endTime) public onlyOperator {
        endTime = _endTime;
    }

    function toggleClaim() public onlyOperator {
        canClaim = !canClaim;
    }

    function ceil(uint256 _amount) public view returns (uint256){
        return (_amount.add(1e10).sub(1)).div(1e10).mul(1e10);
    }

    function floor(uint256 _amount) public view returns (uint256){
        if (_amount == 0) {
            return 0;
        } else {
            return (_amount.div(1e10).mul(1e10));
        }
    }

}


