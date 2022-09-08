pragma solidity >=0.6.12;

import "../Operator.sol";

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PreSale is Operator, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    mapping(address => uint256) public userCommittedAmount;
    mapping(address => bool) public userClaimed;
    uint256 public totalCommitted;

    address public usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    address public xShare;
    uint256 public xSharePerUsdc = 10; // 1 USDC = 10 xSHARE

    uint256 public startTime;
    uint256 public endTime;
    uint256 public claimTime;
    uint256 public duration = 420;

    uint256 public missing_decimal = 12;

    uint256 public constant MIN_DISTRIBUTION = 10 ** 5; // Min buy 1 usdc
    uint256 public constant MAX_DISTRIBUTION = 5 * 10 ** 6; // Max buy 5,000 usdc

    uint256 public constant HARD_CAP = 8 * 10 ** 6; // Hard cap = 50,000 USDC
    uint256 public constant XSHARE_SELL_AMOUNT = 80 ether;

    bool public initialized = false;
    bool public fundClaimed = false;

    // ***** Modifier ***** //

    modifier presaleStarted() {
        require(block.timestamp >= startTime, "Presale Not yet started");
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
        xShare = _xShare;
        initialized = true;
    }

    // ***** Public Function ***** //

    function buy(uint256 _usdcAmount) public nonReentrant presaleStarted nonContract{
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

    function claimToken() public nonReentrant canClaim nonContract{
        uint256 committed_amount = userCommittedAmount[msg.sender];

        // Validation
        require(committed_amount > 0, "User not entered the presale");
        require(!userClaimed[msg.sender], "User already claimed");

        // Calculating xShare claimable;
        uint256 xShare_claimable = committed_amount.mul(10 ** missing_decimal).mul(xSharePerUsdc);
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
    }

    event BuyToken(address indexed user, uint256 amount);
    event ClaimToken(address indexed user, uint256 amount);
    event UseRaisedUsdc(address indexed dev, uint256 amount);
}
