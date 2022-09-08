pragma solidity >=0.6.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IInvestmentController.sol";
import "./interfaces/IAssetController.sol";
import "./interfaces/IGeneralStrategy.sol";
import "./interfaces/IMultiAssetTreasury.sol";
import "./interfaces/IInvestmentController.sol";
import "./Operator.sol";

contract InvestmentController is IInvestmentController, Operator {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Strategy {
        address contractAddress; // Smart contract of strategy
        address rewardToken; // Each strategy will be accounted profit in 1 token
        uint256 assetId; // Each Strategy can manage only 1 collateral of 1 asset
        uint256 investedAmount; // Amount invested for Strategy
        uint256 receivedReward; // Profits that received from Strategy
        uint256 totalDistributedReward; // Profits that distributed
        bool paused;// Total Profits that acquired to
    }

    Strategy[] strategies;

    //TODO function add strategy => done

    //Collateral reserve threshold
    mapping(uint256 => uint256) assetCrt; // asset collateral reserve threshold (crt = collateralReserve / target collateral)
    uint256 public MINIMUM_CRT = 250000; // Minimum crt is 25%, if crt < 25%, collateral will be sent from strategy to collateral fund
    uint256 public RATIO_PRECISION = 1e6; // TODO fixed to 1e6 => done/not deployed => done
    uint256 private constant PRICE_PRECISION = 1e6;

    // Profits distribution ratio
    uint256 public constant DEV_FUND_ALLOCATION_RATIO = 40000; // => 40% rewards to dev fund
    uint256 public constant REWARD_TO_HOLDER_RATIO = 60000; // => 60% rewards to alpha protocol's users

    address public treasury;
    address public assetController;
    address public daoFund;
    address public devFund;
    address public collateralFund;
    address public rewardDistributor;

    bool initialized = false;

    function initializing(
        address _treasury,
        address _assetController,
        address _daoFund,
        address _collateralFund
    ) public onlyOperator {
        require(!initialized, "Already initialized");
        require(_treasury != address(0), "Invalid Address");
        require(_assetController != address(0), "Invalid Address");
        require(_daoFund != address(0), "Invalid Address");
        require(_collateralFund != address(0), "Invalid Address");
        treasury = _treasury;
        assetController = _assetController;
        daoFund = _daoFund;
        collateralFund = _collateralFund;
        initialized = true;
    }

    function getStrategyInfo(uint256 _sid) public view returns (
        address _contractAddress,
        address _rewardToken,
        uint256 _investedAmount,
        uint256 _receivedReward,
        uint256 _totalDistributedReward,
        bool _paused,
        uint256 _unclaimedReward
    ) {
        Strategy memory strategy = strategies[_sid];
        _contractAddress = strategy.contractAddress;
        _rewardToken = strategy.rewardToken;
        _investedAmount = strategy.investedAmount;
        _receivedReward = strategy.receivedReward;
        _totalDistributedReward = strategy.totalDistributedReward;
        _paused = strategy.paused;
        _unclaimedReward = getStrategyUnclaimedReward(_sid);
    }

    function tokenBalance(address _token) public view returns (uint256 _balance) {
        _balance = IERC20(_token).balanceOf(address(this));
    }

    function calcCrt(uint256 _assetId) public view returns (uint256 _crt, bool _isUnderThreshold, uint256 _underAmount) {
        address _collateral = IAssetController(assetController).getCollateral(_assetId);
        address _asset = IAssetController(assetController).getAsset(_assetId);

        uint256 _current_collateral_reserve = IERC20(_collateral).balanceOf(collateralFund);
        uint256 _asset_total_supply = IERC20(_asset).totalSupply();
        (,,,uint256 _asset_tcr,,,,) = IMultiAssetTreasury(treasury).info(_assetId);
        uint256 _target_collateral_reserve = _asset_tcr.mul(_asset_total_supply).div(PRICE_PRECISION);
        //crt = collateral reserved / target collateral
        _crt = _current_collateral_reserve.mul(RATIO_PRECISION).div(_target_collateral_reserve);
        _isUnderThreshold = _crt < MINIMUM_CRT;
        _underAmount = 0;
        if (_isUnderThreshold) {
            _underAmount = _target_collateral_reserve.mul(MINIMUM_CRT).div(RATIO_PRECISION).sub(_current_collateral_reserve);
        }
    }

    function refreshCrt() public {
        uint256 asset_count = IAssetController(assetController).assetCount();
        for (uint256 aid; aid < asset_count; aid++) {
            (uint256 _crt, ,) = calcCrt(aid);
            assetCrt[aid] = _crt;
        }
    }

    function coverCollateralThreshold(uint256 _assetId, uint256 _strategyId) public override onlyOperator {
        (, bool _isUnderCrt, uint256 _underAmount) = calcCrt(_assetId);
        require(_isUnderCrt, "No need to cover collateral threshold");
        require(strategies[_strategyId].investedAmount >= _underAmount, "Strategy not enough balance to retrieve");
        address _strategy_contract = strategies[_strategyId].contractAddress;
        IGeneralStrategy(_strategy_contract).coverCollateralThreshold(_underAmount);
    }

    function getUnDistributedReward(uint256 _sid) public override view returns (uint256 _unDistributedReward, address _rewardToken) {
        Strategy storage strategy = strategies[_sid];
        _unDistributedReward = strategy.receivedReward;
        _rewardToken = strategy.rewardToken;
    }

    function getStrategyUnclaimedReward(uint256 _sid) public override view returns (uint256 _unclaimedReward) {
        Strategy storage strategy = strategies[_sid];
        _unclaimedReward = IGeneralStrategy(strategy.contractAddress).getTotalEstimateReward();
    }

    function getInvestedAmount(address _strategyContract) public override view returns (uint256 _investedAmount) {
        (uint256 sid, bool hasPool) = getStrategyByContract(_strategyContract);
        _investedAmount = 0;
        if (hasPool) {
            _investedAmount = strategies[sid].investedAmount;
        }
    }

    // Calculated Collateral had been transferred out
    function collateralBalance(uint256 _assetId) public override view returns (uint256 _collateralBalance) {
        _collateralBalance = 0;
        address collateral = IAssetController(assetController).getCollateral(_assetId);
        for (uint256 _sid; _sid < strategies.length; _sid++) {
            Strategy memory strategy = strategies[_sid];
            if (strategy.assetId == _assetId) {
                _collateralBalance = _collateralBalance.add(strategy.investedAmount).sub(strategy.receivedReward);
            }
        }
        _collateralBalance = _collateralBalance.add(IERC20(collateral).balanceOf(address(this)));
    }

    function invest(uint256 _strategyId, uint256 _amount) public override onlyOperator {
        require(_strategyId < strategies.length, "Strategy not existed");
        require(!strategies[_strategyId].paused, "Strategy paused");
        Strategy storage strategy = strategies[_strategyId];
        uint256 _assetId = strategy.assetId;
        address _collateral = IAssetController(assetController).getCollateral(_assetId);
        require(_amount <= tokenBalance(_collateral), "Exceed current balance");
        IERC20(_collateral).safeTransfer(strategy.contractAddress, _amount);
        strategy.investedAmount = strategy.investedAmount.add(_amount);
        // add event
    }

    // Call only by Strategy when Strategy returns funds.
    // Method to re-calculate invested amount in strategy when it return funds to the protocol
    function recollateralized(uint256 _amount) public override {
        (uint256 _sid, bool _hasPool) = getStrategyByContract(msg.sender);
        require(_hasPool, "!strategy");
        Strategy storage strategy = strategies[_sid];
        strategy.investedAmount = strategy.investedAmount.sub(_amount);
        //add event
    }

    // TODO NOt worked, changed = 0 under exitStrategy => worked
    function exitStrategy(uint256 _sid) public override onlyOperator {
        require(_sid < strategies.length, "Strategy Not Existed");
        Strategy storage strategy = strategies[_sid];

        IGeneralStrategy(strategy.contractAddress).exitStrategy();
        strategy.investedAmount = 0;
    }

    function claimReward(uint256 _sid, uint256 _amount) public override onlyOperator {
        require(_sid < strategies.length, "Strategy Not Existed");
        Strategy storage strategy = strategies[_sid];

        IGeneralStrategy(strategy.contractAddress).sendRewardToController(_amount);
        uint256 dev_fund_profits = _amount.mul(DEV_FUND_ALLOCATION_RATIO).div(RATIO_PRECISION);
        IERC20(strategy.rewardToken).safeTransfer(devFund, dev_fund_profits);
        strategy.receivedReward = strategy.receivedReward.add(_amount.sub(dev_fund_profits));

    }

    function distributeReward(uint256 _sid, uint256 _amount) public override onlyOperator {
        require(_sid < strategies.length, "Strategy Not Existed");
        Strategy storage strategy = strategies[_sid];
        require(_amount <= strategy.receivedReward, "exceed current reward");
        strategy.receivedReward = strategy.receivedReward.sub(_amount);
        strategy.totalDistributedReward = strategy.totalDistributedReward.add(_amount);
        uint256 dev_fund_profits = _amount.mul(DEV_FUND_ALLOCATION_RATIO).div(RATIO_PRECISION);
        uint256 holders_profits = _amount.sub(dev_fund_profits);

        IERC20(strategy.rewardToken).safeTransfer(rewardDistributor, holders_profits);
        IERC20(strategy.rewardToken).safeTransfer(devFund, dev_fund_profits);
        // add event
    }

    function getStrategyByContract(address _contractAddress) internal view returns (uint256 _strategyId, bool _hasPool) {
        _strategyId = 0;
        _hasPool = false;
        for (uint256 _sid = 0; _sid < strategies.length; _sid++) {
            if (strategies[_sid].contractAddress == msg.sender) {
                _strategyId = _sid;
                _hasPool = true;
                break;
            }
        }
    }

    function addStrategy(
        address _strategy_address,
        address _reward_token,
        uint256 _assetId,
        bool _paused
    ) public onlyOperator {
        require(_strategy_address != address(0), "Invalid Address");
        require(_reward_token != address(0), "Invalid Address");
        uint256 _asset_count = IAssetController(assetController).assetCount();
        require(_assetId < _asset_count, "Asset not existed");

        strategies.push(Strategy({
        contractAddress : _strategy_address,
        rewardToken : _reward_token,
        assetId : _assetId,
        investedAmount : 0,
        receivedReward : 0,
        totalDistributedReward : 0,
        paused : _paused
        }));
        //add event
    }

    function sendToCollateralFund(uint256 _amount, uint256 _assetId) public onlyOperator {
        address collateral = IAssetController(assetController).getCollateral(_assetId);
        IERC20(collateral).transfer(collateralFund, _amount);
    }

    function toggleStrategy(uint256 _sid) public onlyOperator {
        Strategy storage strategy = strategies[_sid];
        strategy.paused = !strategy.paused;
    }

    function setTreasury(address _treasury) public onlyOperator {
        require(_treasury != address(0), "Invalid address");
        treasury = _treasury;
    }

    function setAssetController(address _assetController) public onlyOperator {
        require(_assetController != address(0), "Invalid address");
        assetController = _assetController;
    }

    function setDaoFund(address _daoFund) public onlyOperator {
        require(_daoFund != address(0), "Invalid address");
        daoFund = _daoFund;
    }

    function setCollateralFund(address _collateralFund) public onlyOperator {
        require(_collateralFund != address(0), "Invalid address");
        collateralFund = _collateralFund;
    }

    function setRewardDistributor(address _rewardDistributor) public onlyOperator {
        require(_rewardDistributor != address(0), "Invalid address");
        rewardDistributor = _rewardDistributor;
    }
}
