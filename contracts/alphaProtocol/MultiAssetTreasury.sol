// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import "./../interfaces/IOracle.sol";
import "./../interfaces/IMultiAssetPool.sol";
import "./../Operator.sol";
import "./../interfaces/ICurrencyReserve.sol";
import "./../interfaces/ICollateralFund.sol";
import "./../interfaces/IUniswapV2Router01.sol";
import "./../interfaces/IAssetController.sol";
import "./../interfaces/IMultiAssetTreasury.sol";
import "./../interfaces/IInvestmentController.sol";

contract MultiAssetTreasury is IMultiAssetTreasury, Operator, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    struct CollateralPolicy {
        uint256 target_collateral_ratio; // 6 decimals of precision
        uint256 effective_collateral_ratio; // 6 decimals of precision
        uint256 price_band; // 6 decimals of precision
        uint256 missing_decimals; // Number of decimals needed to get to 18
    }

    mapping(uint256 => CollateralPolicy) public assetCollateralPolicy; // Map assetId to Collateral policy

    address public override collateralFund; // Store Collateral reserve
    address public daoFund; // Dao Fund smart contract
    address public assetController; // Smart-Contract to add/update Synthetic Assets

    address public share; // Share token

    bool public initialized = false;

    // Investment Controller => This will using idle collateral for investing in lending protocol or yield to get profit
    IInvestmentController public investmentController;

    // list of pools can mint/redeem synthetic assets
    address[] public pools_array;
    mapping(address => bool) public pools;

    // constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;
    uint256 private constant RATIO_PRECISION = 1e6;

    // fees
    uint256 public redemption_fee; // 6 decimals of precision
    uint256 public minting_fee; // 6 decimals of precision
    uint256 public constant MAX_FEE = 10000;

    // re-balance function
    uint256 public rebalance_cooldown = 3600;
    uint256 public MIN_REBALANCE_COOLDOWN = 1800;
    uint256 public last_rebalance_timestamp;

    //swap router
    address public router;

    // collateral_ratio
    uint256 public last_refresh_cr_timestamp;
    uint256 public refresh_cooldown; // Seconds to wait before being able to run refreshCollateralRatio() again
    uint256 public constant MIN_REFRESH_COOLDOWN = 1800;
    uint256 public constant MAX_REFRESH_COOLDOWN = 3600;
    uint256 public ratio_step; // Amount to change the collateralization ratio by upon refreshCollateralRatio()
    uint256 public price_target; // Every Asset are pegged to the value of it's collateral. This will be hardcoded at 1
    bool public collateral_ratio_paused = false; // Manage collateral ratio adjustment
    bool public using_effective_collateral_ratio = true; // toggle the effective collateral ratio usage
    uint256 private constant COLLATERAL_RATIO_MAX = 1e6; // Max 100% Ratio

    /* ========== MODIFIERS ========== */

    modifier onlyPoolsOrOperator {
        require(pools[msg.sender] || operator() == msg.sender, "Only pools can use this function");
        _;
    }

    modifier checkRebalanceCooldown() {
        uint256 _blockTimestamp = block.timestamp;
        require(_blockTimestamp - last_rebalance_timestamp >= rebalance_cooldown, "<rebalance_cooldown");
        _;
        last_rebalance_timestamp = _blockTimestamp;
    }

    modifier onlyAssetController() {
        require(msg.sender == assetController, "!AssetController");
        _;
    }

    /* ========== EVENTS ============= */

    event TransactionExecuted(address indexed target, uint256 value, string signature, bytes data);
    event BoughtBackAndBurned(uint256 collateral_value, uint256 collateral_amount, uint256 output_share_amount);
    event Recollateralized(uint256 share_amount, uint256 output_collateral_amount);
    event AddNewPool(address indexed pool_address);
    event RemovePool(address indexed pool_address);
    event ChangeDaoFund(address indexed new_dao_fund);
    event ChangeCollateralFund(address indexed new_collateral_fund);

    /* ========== CONSTRUCTOR ========== */

    constructor(address _router) public {
        ratio_step = 2500;
        // = 0.25% at 6 decimals of precision
        refresh_cooldown = 3600;
        // Refresh cooldown period is set to 1 hour (3600 seconds) at genesis
        price_target = 1000000;
        // = $1. (6 decimals of precision). Collateral ratio will adjust according to the $1 price target at genesis
        redemption_fee = 4000;
        minting_fee = 3000;
        router = _router;
    }

    function initializing(address _share, address _collateralFund, address _daoFund, address _assetController) external onlyOperator {
        require(!initialized, "alreadyInitialized");
        require(_collateralFund != address(0), "Invalid Address");
        require(_daoFund != address(0), "Invalid Address");
        require(_assetController != address(0), "Invalid Address");

        share = _share;
        collateralFund = _collateralFund;
        daoFund = _daoFund;
        assetController = _assetController;

        initialized = true;
    }

    /* ========== VIEWS ========== */

    function assetPrice(uint256 _assetId) public view returns (uint256) {
        return IAssetController(assetController).getAssetPrice(_assetId);
    }

    function sharePrice() public view returns (uint256) {
        return IAssetController(assetController).getXSharePrice();
    }

    function assetTcr(uint256 _assetId) public view returns (uint256) {
        return assetCollateralPolicy[_assetId].target_collateral_ratio;
    }

    function assetEcr(uint256 _assetId) public view returns (uint256) {
        return assetCollateralPolicy[_assetId].effective_collateral_ratio;
    }

    function getMissingDecimal(uint256 _assetId) public view returns (uint256) {
        return assetCollateralPolicy[_assetId].missing_decimals;
    }

    function assetPriceBand(uint256 _assetId) public view returns (uint256) {
        return assetCollateralPolicy[_assetId].price_band;
    }

    function hasPool(address _address) external view override returns (bool) {
        return pools[_address] == true;
    }

    // Get Asset Info
    function info(uint256 _assetId) external view override returns (
        uint256 _assetTWAP,
        uint256 _shareTWAP,
        uint256 _assetSupply,
        uint256 _tcr,
        uint256 _ecr,
        uint256 _collateralValue,
        uint256 _minting_fee,
        uint256 _redemption_fee
    ){
        _assetTWAP = assetPrice(_assetId);
        _shareTWAP = sharePrice();
        _assetSupply = IAssetController(assetController).getAssetTotalSupply(_assetId);
        _tcr = assetTcr(_assetId);
        _ecr = assetEcr(_assetId);
        _collateralValue = collateralValue(_assetId);
        _minting_fee = minting_fee;
        _redemption_fee = redemption_fee;
    }

    // Get Total Collateral of all asset
    function globalCollateralValue() public view returns (uint256 _global_collateral_value) {
        uint256 _assetCount = IAssetController(assetController).assetCount();
        _global_collateral_value = 0;
        for (uint256 aid = 0; aid < _assetCount; aid++) {
            uint256 collateral_price = IAssetController(assetController).getCollateralPriceInDollar(aid);
            uint256 collateral_value = collateralValue(aid);
            _global_collateral_value = _global_collateral_value.add(collateral_price.mul(collateral_value).div(1e18));
        }
    }

    // Get Collateral reserve of an asset
    function globalCollateralBalance(uint256 _assetId) public view override returns (uint256) {
        address _collateral = IAssetController(assetController).getCollateral(_assetId);
        uint256 investedBalance = 0;
        if (address(investmentController) != address(0)) {
            investedBalance = investmentController.collateralBalance(_assetId);
        }
        uint256 _collateralReserveBalance = IERC20(_collateral).balanceOf(collateralFund) + investedBalance;
        return _collateralReserveBalance - totalUnclaimedBalance(_assetId);
    }

    // Get Collateral value (in 18 decimals) of an asset
    function collateralValue(uint256 _assetId) public view override returns (uint256) {
        uint256 _missing_decimals = assetCollateralPolicy[_assetId].missing_decimals;
        return
        (globalCollateralBalance(_assetId) * PRICE_PRECISION * (10 ** _missing_decimals)) /
        PRICE_PRECISION;
    }

    // Calculate current ECR of an asset
    function calcEffectiveCollateralRatio(uint256 _assetId) public view returns (uint256 _ecr) {
        uint256 _tcr = assetTcr(_assetId);
        if (!using_effective_collateral_ratio) {
            _ecr = _tcr;
        }
        uint256 total_collateral_value = collateralValue(_assetId);
        uint256 total_supply_asset = IAssetController(assetController).getAssetTotalSupply(_assetId);
        _ecr = total_collateral_value.mul(PRICE_PRECISION).div(total_supply_asset);
        if (_ecr > COLLATERAL_RATIO_MAX) {
            _ecr = COLLATERAL_RATIO_MAX;
        }
    }

    // Get unclaimed Collateral of an asset
    function totalUnclaimedBalance(uint256 _assetId) public view returns (uint256 _totalUnclaimed) {
        _totalUnclaimed = 0;
        for (uint256 i = 0; i < pools_array.length; i++) {
            // Exclude null addresses
            if (pools_array[i] != address(0)) {
                _totalUnclaimed = _totalUnclaimed + (IMultiAssetPool(pools_array[i]).getUnclaimedCollateral(_assetId));
            }
        }
    }

    // Get excess collateral of an asset
    function excessCollateralBalance(uint256 _assetId) public view returns (uint256 _excess) {
        uint256 _tcr = assetTcr(_assetId);
        uint256 _ecr = assetEcr(_assetId);
        if (_ecr <= _tcr) {
            _excess = 0;
        } else {
            _excess = ((_ecr - _tcr) * globalCollateralBalance(_assetId)) / RATIO_PRECISION;
        }
    }

    // Check if the protocol is over- or under-collateralized, by how much
    function calcCollateralBalance(uint256 _assetId) public view returns (uint256 _collateral_value, bool _exceeded) {
        uint256 total_collateral_value = collateralValue(_assetId);
        uint256 asset_total_supply = IAssetController(assetController).getAssetTotalSupply(_assetId);
        uint256 target_collateral_value = asset_total_supply.mul(assetCollateralPolicy[_assetId].target_collateral_ratio).div(PRICE_PRECISION);
        if (total_collateral_value >= target_collateral_value) {
            _collateral_value = total_collateral_value.sub(target_collateral_value);
            _exceeded = true;
        } else {
            _collateral_value = target_collateral_value.sub(total_collateral_value);
            _exceeded = false;
        }
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    // Refresh tcr and ecr of all asset
    function refreshCollateralRatio() public {
        require(collateral_ratio_paused == false, "Collateral Ratio has been paused");
        require(block.timestamp - last_refresh_cr_timestamp >= refresh_cooldown, "Must wait for the refresh cooldown since last refresh");
        uint256 assetCount = IAssetController(assetController).assetCount();

        for (uint256 aid = 0; aid < assetCount; aid++) {
            CollateralPolicy storage _collateralPolicy = assetCollateralPolicy[aid];
            try IAssetController(assetController).updateOracle(aid) {} catch {}
            uint256 current_asset_price = assetPrice(aid);
            uint256 _tcr = _collateralPolicy.target_collateral_ratio;
            uint256 _ecr = _collateralPolicy.effective_collateral_ratio;
            uint256 _price_band = _collateralPolicy.price_band;
            // Step increments are 0.25% (upon genesis, changable by setRatioStep())
            if (current_asset_price > price_target.add(_price_band)) {
                // decrease collateral ratio
                if (_tcr <= ratio_step) {
                    // if within a step of 0, go to 0
                    _collateralPolicy.target_collateral_ratio = 0;
                } else {
                    _collateralPolicy.target_collateral_ratio = _tcr.sub(ratio_step);
                }
            }
            // If Asset/Collateral price below 1 - `price_band`. Need to increase `target_collateral_ratio`
            else if (current_asset_price < price_target.sub(_price_band)) {
                // increase collateral ratio
                if (_tcr.add(ratio_step) >= COLLATERAL_RATIO_MAX) {
                    _collateralPolicy.target_collateral_ratio = COLLATERAL_RATIO_MAX;
                    // cap collateral ratio at 1.000000
                } else {
                    _collateralPolicy.target_collateral_ratio = _tcr.add(ratio_step);
                }
            }

            // If using ECR, then calcECR. If not, update ECR = TCR
            if (using_effective_collateral_ratio) {
                _collateralPolicy.effective_collateral_ratio = calcEffectiveCollateralRatio(aid);
            } else {
                _collateralPolicy.effective_collateral_ratio = _collateralPolicy.target_collateral_ratio;
            }
        }

        last_refresh_cr_timestamp = block.timestamp;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    //Transfer fund from Collateral Fund
    //Only called by Pools or Operator
    function requestTransfer(
        address _token,
        address _receiver,
        uint256 _amount
    ) external override onlyPoolsOrOperator {
        ICollateralFund(collateralFund).transferTo(_token, _receiver, _amount);
    }

    // Extract to internal function to avoid "Stack Too Deep" exception, used in buyback() to covert input _collateral_amount to value in dollar
    function calcCollateralValue(uint256 _collateral_amount, uint256 _assetId) internal view returns (uint256 _collateral_value) {
        uint256 _missing_decimals = getMissingDecimal(_assetId);
        bool isStable = IAssetController(assetController).isAssetStable(_assetId);
        _collateral_value = _collateral_amount.mul(10 ** _missing_decimals);

        if (!isStable) {
            uint256 _collateral_exchange_price = IAssetController(assetController).getCollateralPriceInDollar(_assetId);
            _collateral_value = _collateral_amount.mul(_collateral_exchange_price).div(PRICE_PRECISION);
        }
    }

    // Use excess collateral to buy back xShare and burn
    function buyback(
        uint256 _assetId,
        uint256 _collateral_amount,
        uint256 _min_share_amount,
        uint256 _min_asset_out,
        address[] calldata path
    ) external override onlyOperator checkRebalanceCooldown {
        // Check if asset is over-collateralized
        (uint256 _excess_collateral_value, bool _exceeded) = calcCollateralBalance(_assetId);
        require(_exceeded && _excess_collateral_value > 0, "!exceeded");

        // Validating path: input token must be collateral of asset and output token must be xShare
        require(path[path.length - 1] == share, "Output Token must be xShare");
        address _collateral = IAssetController(assetController).getCollateral(_assetId);
        require(path[0] == share, "Input Token must be collateral of selected asset");

        // Convert into dollar value (18 decimals)
        uint256 _collateral_value = calcCollateralValue(_collateral_amount, _assetId);
        require(_collateral_amount > 0 && _collateral_value < _excess_collateral_value, "Invalid collateral amount");

        // Request transfer from CollateralFund to Treasury to buy xShare
        ICollateralFund(collateralFund).transferTo(_collateral, address(this), _collateral_amount);

        // Execute swap and Burn
        uint256 out_xShare_amount = _swap(_collateral, path, _collateral_amount, _min_share_amount);
        ERC20Burnable(share).burn(out_xShare_amount);
        emit BoughtBackAndBurned(_collateral_amount, _collateral_amount, out_xShare_amount);
    }

    // Transfer xShare from Dao Fund to sell and re-collateralizing
    function reCollateralize(
        uint256 _assetId,
        uint256 _share_amount,
        uint256 _min_collateral_amount,
        address[] calldata path
    ) external override onlyOperator checkRebalanceCooldown {
        // Check if asset is under-collateralized
        (uint256 _deficit_collateral_value, bool _exceeded) = calcCollateralBalance(_assetId);
        require(!_exceeded && _deficit_collateral_value > 0, "exceeded");
        require(_min_collateral_amount <= _deficit_collateral_value, ">deficit");

        // Validating path: Input token must be xShare, output token must be collateral of selected asset
        address _collateral = IAssetController(assetController).getCollateral(_assetId);
        require(path[0] == share, "Input token must be xShare");
        require(path[path.length - 1] == _collateral, "Output token must be collateral of selected asset");

        uint256 _share_balance = IERC20(share).balanceOf(daoFund);
        require(_share_amount <= _share_balance, "DaoFund: Not enough xShare");

        // Transfer share from DaoFund to this to swap
        ICurrencyReserve(daoFund).transferTo(share, address(this), _share_amount);

        uint256 out_collateral_amount = _swap(share, path, _share_amount, _min_collateral_amount);

        // Transfer collateral after swap from Treasury to CollateralFund
        IERC20(_collateral).transfer(collateralFund, out_collateral_amount);

        emit Recollateralized(_share_amount, out_collateral_amount);
    }

    // Add asset CollateralPolicy - Only called by AssetController
    function addCollateralPolicy(uint256 _aid, uint256 _price_band, uint256 _missing_decimals, uint256 _init_tcr, uint256 _init_ecr) external override onlyAssetController {
        CollateralPolicy storage _collateralPolicy = assetCollateralPolicy[_aid];
        _collateralPolicy.target_collateral_ratio = _init_tcr;
        _collateralPolicy.effective_collateral_ratio = _init_ecr;
        _collateralPolicy.price_band = _price_band;
        _collateralPolicy.missing_decimals = _missing_decimals;
    }

    // Add new Pool
    function addPool(address pool_address) public onlyOperator {
        require(pools[pool_address] == false, "poolExisted");
        pools[pool_address] = true;
        pools_array.push(pool_address);
        emit AddNewPool(pool_address);
    }

    // Remove a pool
    function removePool(address pool_address) public onlyOperator {
        require(pools[pool_address] == true, "!pool");
        // Delete from the mapping
        delete pools[pool_address];
        // 'Delete' from the array by setting the address to 0x0
        for (uint256 i = 0; i < pools_array.length; i++) {
            if (pools_array[i] == pool_address) {
                pools_array[i] = address(0);
                // This will leave a null in the array and keep the indices the same
                break;
            }
        }
        emit RemovePool(pool_address);
    }

    /* -========= INTERNAL FUNCTIONS ============ */

    function _swap(address inputToken, address[] memory _path, uint256 inputAmount, uint256 outputAmountMin) public onlyOperator returns (uint256) {
        IERC20(inputToken).approve(router, 0);
        IERC20(inputToken).approve(router, inputAmount);
        uint256[] memory out_amounts = IUniswapV2Router01(router).swapExactTokensForTokens(inputAmount, outputAmountMin, _path, address(this), block.timestamp.add(1800));
        return out_amounts[out_amounts.length - 1];
    }

    /* -========= SETTER ============ */

    function setRedemptionFee(uint256 _redemption_fee) public onlyOperator {
        require(_redemption_fee <= MAX_FEE, "Max 1% fee");
        redemption_fee = _redemption_fee;
    }

    function setMintingFee(uint256 _minting_fee) public onlyOperator {
        require(_minting_fee <= MAX_FEE, "Max 1% fee");
        minting_fee = _minting_fee;
    }

    function setRatioStep(uint256 _ratio_step) public onlyOperator {
        require(_ratio_step > 0, "Invalid ratio step");
        ratio_step = _ratio_step;
    }

    function setRefreshCooldown(uint256 _refresh_cooldown) public onlyOperator {
        require(_refresh_cooldown >= MIN_REBALANCE_COOLDOWN && _refresh_cooldown <= MAX_REFRESH_COOLDOWN, "Invalid refresh cooldown");
        refresh_cooldown = _refresh_cooldown;
    }

    function setPriceBand(uint256 _price_band, uint256 _assetId) external onlyOperator {
        CollateralPolicy storage _collateralPolicy = assetCollateralPolicy[_assetId];
        _collateralPolicy.price_band = _price_band;
    }

    function toggleCollateralRatio() public onlyOperator {
        collateral_ratio_paused = !collateral_ratio_paused;
    }

    function toggleEffectiveCollateralRatio() public onlyOperator {
        using_effective_collateral_ratio = !using_effective_collateral_ratio;
    }

    function setRouter(address _router) public onlyOwner {
        require(_router != address(0), "invalidAddress");
        router = _router;
    }

    function setDaoFund(address _daoFund) public onlyOwner {
        require(_daoFund != address(0), "invalidAddress");
        daoFund = _daoFund;
        emit ChangeDaoFund(_daoFund);
    }

    function setMissingDecimals(uint256 _missing_decimals, uint256 _assetId) external override onlyAssetController {
        CollateralPolicy storage _collateralPolicy = assetCollateralPolicy[_assetId];
        _collateralPolicy.missing_decimals = _missing_decimals;
    }

    function setCollateralFund(address _collateralFund) public onlyOperator {
        require(_collateralFund != address(0), "invalidAddress");
        collateralFund = _collateralFund;
        emit ChangeCollateralFund(_collateralFund);
    }

    function setRebalanceCoolDown(uint256 _rebalance_cooldown) public onlyOperator {
        require(_rebalance_cooldown > MIN_REBALANCE_COOLDOWN, "Not exceed min cooldown");
        rebalance_cooldown = _rebalance_cooldown;
    }

    function setAssetController(address _assetController) public onlyOperator {
        require(_assetController != address(0), "Invalid address");
        assetController = _assetController;
    }

    function setInvestmentController(address _investmentController) public onlyOperator {
        require(_investmentController != address(0), "Invalid address");
        investmentController = IInvestmentController(_investmentController);
    }

    /* ========== EMERGENCY ========== */

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
