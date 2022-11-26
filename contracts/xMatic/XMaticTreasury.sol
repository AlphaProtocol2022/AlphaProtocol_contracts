// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "../lib/Babylonian.sol";
import "../Operator.sol";
import "../utils/ContractGuard.sol";
import "../interfaces/IBasisAsset.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IBoardroom.sol";
import "../interfaces/IMainToken.sol";

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract XMaticTreasury is ContractGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */
    uint256 public constant PERIOD = 21600;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;
    // flags
    bool public initialized;
    // epoch
    uint256 public startTime;
    uint256 public epoch;
    uint256 public previousEpoch;
    uint256 public epochSupplyContractionLeft;
    uint256 public bootstrapEpochs = 28;
    uint256 public bootstrapSupplyExpansionPercent = 300;

    address public mainToken;
    address public shareToken;
    address public boardroom;
    address public oracle;

    // price
    uint256 public mainTokenPriceOne;
    uint256 public mainTokenPriceCeiling;
    uint256 public mainTokenPriceRebase;
    uint256 public consecutiveEpochHasPriceBelowOne;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    /*===== Rebase ====*/
    uint256 public numberOfEpochBelowOneCondition = 1;
    uint256 private constant DECIMALS = 18;
    uint256 private constant ONE = uint256(10 ** DECIMALS);
    // Due to the expression in computeSupplyDelta(), MAX_RATE * MAX_SUPPLY must fit into an int256.
    // Both are 18 decimals fixed point numbers.
    uint256 private constant MAX_RATE = 10 ** 18 * 10 ** DECIMALS;
    // MAX_SUPPLY = MAX_INT256 / MAX_RATE
    uint256 private constant MAX_SUPPLY = uint256(type(int256).max) / MAX_RATE;

    bool public rebaseStarted;

    uint256 private constant midpointRounding = 10 ** (DECIMALS - 7);

    uint256 public previousEpochMainPrice;

    uint256 public constant minMainSupplyToExpansion = 10000 ether;

    /*===== End Rebase ====*/

    uint256 public constant daoFundSharedPercent = 20; // 20%
    address public daoFund;
    uint256 public constant devFundSharedPercent = 5; // 5%
    address public devFund;

    uint256 private constant minPercentExpansionTier = 10; // 0.1%
    uint256 private constant maxPercentExpansionTier = 1000; // 10%

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);
    event LogRebase(
        uint256 indexed epoch,
        uint256 supplyDelta,
        uint256 newPrice,
        uint256 oldPrice,
        uint256 newTotalSupply,
        uint256 oldTotalSupply,
        uint256 timestampSec
    );
    event SetOperator(address indexed account, address newOperator);
    event SetBoardroom(address indexed account, address newBoardroom);
    event SetMainTokenPriceCeiling(uint256 newValue);
    event SetSupplyTiersEntry(uint8 _index, uint256 _value);
    event SetMaxExpansionTiersEntry(uint8 _index, uint256 _value);
    event TransactionExecuted(address indexed target, uint256 value, string signature, bytes data);

    function __Upgradeable_Init() external onlyOperator {
        initialized = false;
        epoch = 0;
        previousEpoch = 0;
        epochSupplyContractionLeft = 0;
        consecutiveEpochHasPriceBelowOne = 0;
        rebaseStarted = false;
        previousEpochMainPrice = 0;
    }

    function setNumberOfEpochToRebase(uint256 _numberOfEpoc) public onlyOperator {
        numberOfEpochBelowOneCondition = _numberOfEpoc;
    }

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition() {
        require(block.timestamp >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch() {
        require(block.timestamp >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
    }

    modifier checkOperator() {
        require(
            IBasisAsset(mainToken).operator() == address(this) &&
            Operator(boardroom).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized() {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() external view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getMainTokenPrice() public view returns (uint256) {
        try IOracle(oracle).consult(mainToken, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult MainToken price from the oracle");
        }
    }

    function getTwapPrice() external view returns (uint256) {
        try IOracle(oracle).twap(mainToken, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to twap MainToken price from the oracle");
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _mainToken,
        address _shareToken,
        address _oracle,
        address _boardroom,
        address _daoFund,
        address _devFund,
        uint256 _startTime
    ) external notInitialized {
        require(_mainToken != address(0), "!_mainToken");
        require(_shareToken != address(0), "!_shareToken");
        require(_oracle != address(0), "!_oracle");
        require(_boardroom != address(0), "!_boardroom");
        require(_daoFund != address(0), "!_boardroom");
        require(_devFund != address(0), "!_boardroom");

        mainToken = _mainToken;
        shareToken = _shareToken;
        oracle = _oracle;
        boardroom = _boardroom;
        daoFund = _daoFund;
        devFund = _devFund;
        startTime = _startTime;

        mainTokenPriceOne = 10 ** 18;
        // This is to allow a PEG of 1 MainToken per USDC
        mainTokenPriceRebase = 85 * 10 ** 16;
        // 0.85 USDC
        mainTokenPriceCeiling = mainTokenPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 500000 ether, 2000000 ether, 4000000 ether, 8000000 ether, 20000000 ether];
        maxExpansionTiers = [300, 250, 200, 150, 125, 100];

        IMainToken(mainToken).grantRebaseExclusion(address(this));
        IMainToken(mainToken).grantRebaseExclusion(address(boardroom));

        initialized = true;
        operator = msg.sender;

        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
        emit SetOperator(msg.sender, _operator);
    }

    function setBoardroom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
        emit SetBoardroom(msg.sender, _boardroom);
    }

    function setBootstrapEpoch(uint256 _bootstrapEpoch) external onlyOperator {
        require(_bootstrapEpoch <= 56, "Exceed allowed");
        bootstrapEpochs = _bootstrapEpoch;
    }

    function grantRebaseExclusion(address who) external onlyOperator {
        IMainToken(mainToken).grantRebaseExclusion(who);
    }

    function setMainTokenPriceCeiling(uint256 _mainTokenPriceCeiling) external onlyOperator {
        require(_mainTokenPriceCeiling >= mainTokenPriceOne && _mainTokenPriceCeiling <= mainTokenPriceOne.mul(120).div(100), "out of range");
        // [$1.0, $1.2]
        mainTokenPriceCeiling = _mainTokenPriceCeiling;
        emit SetMainTokenPriceCeiling(_mainTokenPriceCeiling);
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < supplyTiers.length, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        emit SetSupplyTiersEntry(_index, _value);
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < maxExpansionTiers.length, "Index has to be lower than count of tiers");
        require(_value >= minPercentExpansionTier && _value <= maxPercentExpansionTier, "_value: out of range");
        // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        emit SetMaxExpansionTiersEntry(_index, _value);
        return true;
    }

    /* ========== MUTABLE FUNCTIONS ========== */
    function syncPrice() public {
        try IOracle(oracle).sync() {} catch {
            revert("Treasury: failed to sync price from the oracle");
        }
    }

    function _updatePrice() internal {
        try IOracle(oracle).update() {} catch {
            revert("Treasury: failed to update price from the oracle");
        }
    }

    function getMainTokenCirculatingSupply() public view returns (uint256) {
        return IMainToken(mainToken).rebaseSupply();
    }

    function getEstimatedReward() external view returns (uint256) {
        uint256 mainTokenTotalSupply = IMainToken(mainToken).totalSupply();
        if (mainTokenTotalSupply < minMainSupplyToExpansion) {
            mainTokenTotalSupply = minMainSupplyToExpansion;
        }

        uint256 percentage = calculateMaxSupplyExpansionPercent(mainTokenTotalSupply);
        uint256 estimatedReward = mainTokenTotalSupply.mul(percentage).div(10000);

        uint256 _daoFundSharedAmount = estimatedReward.mul(daoFundSharedPercent).div(100);
        uint256 _devFundSharedAmount = estimatedReward.mul(devFundSharedPercent).div(100);

        return estimatedReward.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);
    }

    function _sendToBoardroom(uint256 _amount) internal {
        IMainToken mainTokenErc20 = IMainToken(mainToken);
        mainTokenErc20.mint(address(this), _amount);

        uint256 _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(100);
        mainTokenErc20.transfer(daoFund, _daoFundSharedAmount);
        emit DaoFundFunded(block.timestamp, _daoFundSharedAmount);

        uint256 _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(100);
        mainTokenErc20.transfer(devFund, _devFundSharedAmount);
        emit DevFundFunded(block.timestamp, _devFundSharedAmount);

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);
        IERC20(mainToken).safeApprove(boardroom, 0);
        IERC20(mainToken).safeApprove(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_amount);
        emit BoardroomFunded(block.timestamp, _amount);
    }

    function calculateMaxSupplyExpansionPercent(uint256 _mainTokenSupply) public view returns (uint256) {
        uint256 maxSupplyExpansionPercent;
        uint256 supplyTierLength = supplyTiers.length;
        uint256 maxExpansionTiersLength = maxExpansionTiers.length;
        require(supplyTierLength == maxExpansionTiersLength, "SupplyTier data invalid");

        for (uint256 tierId = supplyTierLength - 1; tierId >= 0; --tierId) {
            if (_mainTokenSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }

        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updatePrice();
        previousEpochMainPrice = getMainTokenPrice();
        uint256 mainTokenTotalSupply = IMainToken(mainToken).rebaseSupply();
        if (epoch < bootstrapEpochs) {
            _sendToBoardroom(mainTokenTotalSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochMainPrice > mainTokenPriceCeiling) {
                // Expansion
                if (mainTokenTotalSupply < minMainSupplyToExpansion) {
                    mainTokenTotalSupply = minMainSupplyToExpansion;
                }
                uint256 _percentage = calculateMaxSupplyExpansionPercent(mainTokenTotalSupply);
                uint256 _savedForBoardroom = mainTokenTotalSupply.mul(_percentage).div(10000);
                if (_savedForBoardroom > 0) {
                    uint256 boardRoomAmount = IBoardroom(boardroom).totalSupply();
                    if (boardRoomAmount > 0) {
                        _sendToBoardroom(_savedForBoardroom);
                    } else {
                        // mint to DAOFund
                        IMainToken(mainToken).mint(daoFund, _savedForBoardroom);
                    }
                }
            }

            // Rebase
            if (previousEpochMainPrice < mainTokenPriceOne) {
                consecutiveEpochHasPriceBelowOne = consecutiveEpochHasPriceBelowOne.add(1);
            } else {
                consecutiveEpochHasPriceBelowOne = 0;
            }

            if (rebaseStarted && previousEpochMainPrice < mainTokenPriceOne) {
                _rebase(mainTokenPriceOne);
                consecutiveEpochHasPriceBelowOne = 0;
            } else {
                rebaseStarted = false;
                // twap <= 0.85 MATIC => rebase
                // {consecutiveEpochHasPriceBelowOne} consecutive epoch has twap < 1 MATIC => rebase
                if (previousEpochMainPrice <= mainTokenPriceRebase || consecutiveEpochHasPriceBelowOne == numberOfEpochBelowOneCondition) {
                    _rebase(mainTokenPriceOne);
                    consecutiveEpochHasPriceBelowOne = 0;
                }
            }
        }

    }

    function boardroomAllocateSeigniorage(uint256 amount) external onlyOperator {
        IBoardroom(boardroom).allocateSeigniorage(amount);
    }

    function computeSupplyDelta() public view returns (bool negative, uint256 supplyDelta, uint256 targetRate) {
        require(previousEpochMainPrice > 0, "previousEpochMainPrice invalid");
        targetRate = 10 ** DECIMALS;
        uint256 rate = previousEpochMainPrice.mul(10 ** DECIMALS).div(10 ** 18);
        negative = rate < targetRate;
        uint256 rebasePercentage = ONE;
        if (negative) {
            rebasePercentage = targetRate.sub(rate).mul(ONE).div(targetRate);
        } else {
            rebasePercentage = rate.sub(targetRate).mul(ONE).div(targetRate);
        }

        supplyDelta = mathRound(getMainTokenCirculatingSupply().mul(rebasePercentage).div(ONE));
    }

    function mathRound(uint256 _value) internal pure returns (uint256) {
        uint256 valueFloor = _value.div(midpointRounding).mul(midpointRounding);
        uint256 delta = _value.sub(valueFloor);
        if (delta >= midpointRounding.div(2)) {
            return valueFloor.add(midpointRounding);
        } else {
            return valueFloor;
        }
    }

    function _rebase(uint256 _oldPrice) internal onlyOperator {
        require(epoch >= previousEpoch, "cannot rebase");
        (bool negative, uint256 supplyDelta, uint256 targetRate) = computeSupplyDelta();

        uint256 oldTotalSupply = IERC20(mainToken).totalSupply();
        uint256 newTotalSupply = oldTotalSupply;
        if (supplyDelta > 0) {
            rebaseStarted = true;
            if (oldTotalSupply.add(uint256(supplyDelta)) > MAX_SUPPLY) {
                supplyDelta = MAX_SUPPLY.sub(oldTotalSupply);
            }

            newTotalSupply = IMainToken(mainToken).rebase(epoch, supplyDelta, negative);
            require(newTotalSupply <= MAX_SUPPLY, "newTotalSupply <= MAX_SUPPLY");
            previousEpoch = epoch;
            syncPrice();
        }

        emit LogRebase(epoch, supplyDelta, targetRate, _oldPrice, newTotalSupply, oldTotalSupply, block.timestamp);
    }

    //==========END REBASE===========

    function executeTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data
    ) public onlyOperator returns (bytes memory) {
        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }
        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call{value : value}(callData);
        require(success, string("Treasury::executeTransaction: Transaction execution reverted."));
        emit TransactionExecuted(target, value, signature, data);
        return returnData;
    }

    receive() external payable {}
}