pragma solidity >=0.6.12;

import "../../Operator.sol";

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PreSale is Operator, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    // Contract variables
    mapping(address => uint256) public userCommittedAmount;
    mapping(address => bool) public userClaimed;
    mapping(address => bool) public bonusClaimed;
    uint256 public totalCommitted;

    // Tokens
    address public usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    address public xShare;
    uint256 public missing_decimal = 12;

    uint256 public xSharePerUsdc = 10; // 1 USDC = 10 xSHARE

    // Presale timestamp config
    uint256 public startTime; // Presale start timestamp
    uint256 public endTime; // Presale end timestamp
    uint256 public duration = 60*60*24*2; // Presale duration: 2 Days

    // Post-presale timestamp config
    uint256 public claimTime; // Non-Bonus token claim time: after public sale done
    uint256 public claimBonusTime; // Bonus token claim time: 2 week claim time
    uint256 public endClaimBonusTime; // End of Bonus token claim time: after this, all unClaimed bonus token will be returned to treausry

    // User distribution rules
    uint256 public constant MIN_DISTRIBUTION = 10 ** 6; // Min buy 1 usdc
    uint256 public constant MAX_DISTRIBUTION = 5000 * (10 ** 6); // Max buy 5,000 usdc

    // Bonus Info
    uint256 public constant MIN_BONUS = 10e4; // 10% XSHARE Bonus if contribute 500 - 999 USDC
    uint256 public constant MEDIUM_BONUS = 15e4; // 15% XSHARE Bonus if contribute 1000 - 2499 USDC
    uint256 public constant MAX_BONUS = 25e4; // 25% XSHARE Bonus if contribute 2500 - 5000 USDC
    uint256 public constant RATIO_PRECISION = 1e6;
    uint256 public totalBonusClaimed;

    // XShare Amount Info
    uint256 public constant HARD_CAP = 50000 * (10 ** 6); // Hard cap = 50,000 USDC
    uint256 public constant XSHARE_SELL_AMOUNT = 500000 ether;
    uint256 public constant MAX_XSHARE_BONUS_AMOUNT = 125000 ether; // 25% of 500,000 xShare
    uint256 public totalClaimed;

    // Flags
    bool public initialized = false;
    bool public fundClaimed = false;
    bool public returnedUnClaimedBonus = false;

    // ***** Modifier ***** //

    modifier presaleStarted() {
        require(block.timestamp >= startTime, "Presale not yet started");
        require(block.timestamp < endTime, "Presale already ended");
        _;
    }

    modifier presaleEnded() {
        require(block.timestamp >= endTime, "Presale Not yet ended");
        _;
    }

    modifier nonContract() {
        require(tx.origin == msg.sender, "Contract is not able to interact");
        _;
    }

    modifier canClaim() {
        require(block.timestamp >= claimTime, "Can not claim now");
        _;
    }

    modifier canClaimBonus() {
        require(block.timestamp >= claimBonusTime, "Can not claim bonus now");
        require(block.timestamp < endClaimBonusTime, "Claim bonus time ended");
        _;
    }

    modifier isEndClaimBonusTime() {
        require(block.timestamp >= endClaimBonusTime, "Still in claim bonus time");
        _;
    }

    // ***** Initialize ***** //

    function initializing(
        uint256 _startTime,
        address _xShare,
        uint256 _claimTime
    ) public onlyOperator {
        require(!initialized, "Already initialized");
        require(_startTime > block.timestamp, "Invalid time");
        require(_claimTime > block.timestamp && _claimTime > _startTime.add(duration), "Invalid time");
        require(_xShare != address(0), "Invalid address");
        startTime = _startTime;
        endTime = _startTime.add(duration);
        claimTime = _claimTime;
        claimBonusTime = claimTime + 60 * 60 * 24 * 14; // 2 weeks after launch
        endClaimBonusTime = claimBonusTime + 60 * 60 * 24 * 7; // 1 week month to claim Bonus

        xShare = _xShare;
        initialized = true;
    }

    // ***** Public Function ***** //

    function buy(uint256 _usdcAmount) public nonReentrant presaleStarted nonContract {
        address _buyer = msg.sender;

        // Validation
        require(_usdcAmount >= MIN_DISTRIBUTION, "Under Min Distribution");
        require(totalCommitted.add(_usdcAmount) <= HARD_CAP, "Exceed Hard Cap");
        require(userCommittedAmount[_buyer].add(_usdcAmount) <= MAX_DISTRIBUTION, "Exceed max distribution");

        // Accounting user amount
        userCommittedAmount[_buyer] = userCommittedAmount[_buyer].add(_usdcAmount);
        totalCommitted = totalCommitted.add(_usdcAmount);

        ERC20(usdc).safeTransferFrom(msg.sender, address(this), _usdcAmount);

        emit BuyToken(msg.sender, _usdcAmount);
    }

    function claimToken() public nonReentrant canClaim nonContract {
        uint256 committed_amount = userCommittedAmount[msg.sender];

        // Validation
        require(committed_amount > 0, "User not entered the presale");
        require(!userClaimed[msg.sender], "User already claimed");

        // Calculating xShare claimable;
        uint256 xShare_claimable = committed_amount.mul(10 ** missing_decimal).mul(xSharePerUsdc);
        totalClaimed = totalClaimed.add(xShare_claimable);
        userClaimed[msg.sender] = true;

        ERC20(xShare).safeTransfer(msg.sender, xShare_claimable);
        emit ClaimToken(msg.sender, xShare_claimable);
    }

    function claimRaisedFund() public presaleEnded onlyOperator {
        // Validation
        require(!fundClaimed, "Fund already been claimed");

        // Transfer raised fund to dev address
        ERC20(usdc).safeTransfer(msg.sender, totalCommitted);

        fundClaimed = true;
        emit DevClaimFund(msg.sender, totalCommitted);
    }

    function claimBonus() public nonReentrant canClaimBonus nonContract {
        uint256 committed_amount = userCommittedAmount[msg.sender];

        //Validation
        require(committed_amount > 500 * (10**6), "Not required for bonus");
        require(!bonusClaimed[msg.sender], "User already claimed bonus");

        //Calculate bonus amount.
        uint256 bonusAmount = calcBonus(committed_amount);
        totalBonusClaimed = totalBonusClaimed.add(bonusAmount);

        bonusClaimed[msg.sender] = true;

        ERC20(xShare).safeTransfer(msg.sender, bonusAmount);
        emit ClaimBonusToken(msg.sender, bonusAmount);
    }

    function returnUnclaimedBonusToken(address _daoFund) public isEndClaimBonusTime onlyOperator {
        // Validation
        require(!returnedUnClaimedBonus, "Already returned");
        require(_daoFund != address(0), "invalid treasury");

        // Calculate unclaimed bonus = TOTAL BONUS - claimed Bonus
        uint256 unclaimed_bonus_xShare = MAX_XSHARE_BONUS_AMOUNT.sub(totalBonusClaimed);
        returnedUnClaimedBonus = true;

        ERC20(xShare).safeTransfer(_daoFund, unclaimed_bonus_xShare);
        emit ReturnUnclaimedBonusXShare(_daoFund, unclaimed_bonus_xShare);
    }

    function calcBonus(uint256 _user_committed_amount) internal view returns (uint256 _xShare_bonus) {
        uint256 committed_amount_18dec = _user_committed_amount.mul(10 ** missing_decimal);
        uint256 xShareBoughtAmount = committed_amount_18dec.mul(xSharePerUsdc);

        _xShare_bonus = 0;

        if (committed_amount_18dec >= 2500 ether) {
            _xShare_bonus = xShareBoughtAmount.mul(MAX_BONUS).div(RATIO_PRECISION);
        } else if (committed_amount_18dec >= 1000 ether) {
            _xShare_bonus = xShareBoughtAmount.mul(MEDIUM_BONUS).div(RATIO_PRECISION);
        } else if (committed_amount_18dec >= 500 ether) {
            _xShare_bonus = xShareBoughtAmount.mul(MIN_BONUS).div(RATIO_PRECISION);
        }
    }

    event BuyToken(address indexed user, uint256 amount);
    event ClaimToken(address indexed user, uint256 amount);
    event ClaimBonusToken(address indexed user, uint256 amount);
    event DevClaimFund(address indexed dev, uint256 amount);
    event ReturnUnclaimedBonusXShare(address indexed treasury, uint256 amount);
}
