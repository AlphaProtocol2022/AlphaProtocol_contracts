pragma solidity ^0.6.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./../interfaces/IUniswapV2Router01.sol";
import "./../interfaces/IMultiAssetPool.sol";
import "../Operator.sol";

contract TailGame is Operator, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    bool public initialized;
    bool public firstRoundInitialized;

    struct Round {
        address winner;
        uint256 prize;
        uint256 ticketPrice;
        uint256 roundStartTs;
        uint256 roundEndTs;
        uint256 totalTicketBought;
    }

    struct RoundHistory {
        address winner;
        uint256 prize;
        uint256 roundDuration;
    }

    struct InputToken {
        address mainLiqToken;
        address bridgeToken;
        uint256 discount;
        uint256 missingDecimal;
        bool isSynth;
        bool disabled;
    }

    // Active Round stats
    Round public activeRound;
    uint256 public nextRoundPrize;

    RoundHistory[] public history;

    mapping(address => InputToken) public inputTokens;
    address public rewardToken = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174); // USDC
    address public usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174); // USDC
    address public router = address(0x7E5E5957De93D00c352dF75159FbC37d5935f8bF); // polyMMF router
    address public pool = address(0x552fb9d2aB532E67a57834b9E3466a492f0F78B0); // polyMMF router

    uint256 public durationStep = 300;
    uint256 public initialDuration = 3600;
    uint256 public initialTicketValue = 1e18;
    uint256 public ticketStep = 100; //1%

    //Ticket Distribution
    uint256 public addToPrizePerc = 4500; //45%
    uint256 public reservePerc = 4500; // 45%
    uint256 public treasuryPerc = 1000; // 10%

    function initialized(
        address _rewardToken
    ) external onlyOperator {
        rewardToken = _rewardToken;
    }

    function resetRound(
        uint256 _prize,
        uint256 _startTs
    ) external onlyOperator {
        activeRound.prize = _prize;
        activeRound.roundStartTs = _startTs;
        activeRound.roundEndTs = _startTs.add(initialDuration);
        activeRound.winner = address(0);
        activeRound.ticketPrice = initialTicketValue;
        activeRound.totalTicketBought = 0;
    }

    function buyTicket(address _input_token) public nonReentrant {
        // Check if round ended
        // update winner
        // handle Ticket Amount:
        // update ticket price
        // add roundEndTs by durationStep
        // Add total ticket bought
    }

    function addInputToken(
        address _token,
        address _mainLiqToken,
        address _bridgeToken,
        uint256 _discount,
        uint256 _missing_decimals,
        bool _isSynth
    ) external onlyOperator {
        require(_token != address(0), "Invalid token");
        require(_mainLiqToken != address(0), "Invalid token");

        InputToken storage inputToken = inputTokens[_token];

        inputToken.mainLiqToken = _mainLiqToken;
        inputToken.bridgeToken = _bridgeToken;
        inputToken.discount = _discount;
        inputToken.isSynth = _isSynth;
        inputToken.missingDecimal = _missing_decimals;

        // Event Add new Input token
    }

    function getEntryAmount(address _token) public view returns (uint256 _require_amount) {
        uint256 _ticket_price = activeRound.ticketPrice;
        // get _token_price by router
        // get ticket price / _token_price
    }

    // To be internal
    function handleTicket(address _input_token) public {
        // swap to USDC if needed
        // record treasury fee
        // record reserve prize next round

        if (_input_token == usdc) {
            activeRound.prize = activeRound.prize.add()
        }
    }
}

