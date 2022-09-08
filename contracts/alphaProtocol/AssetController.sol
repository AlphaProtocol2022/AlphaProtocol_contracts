pragma solidity >=0.6.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./../interfaces/IMultiAssetTreasury.sol";
import "./../interfaces/IMultiAssetPool.sol";
import "./../interfaces/IOracle.sol";
import "./../interfaces/IUniswapV2Router01.sol";
import "./../Operator.sol";
import "./../interfaces/IAssetController.sol";

contract AssetController is Operator, IAssetController {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    address public treasury;
    address public pool;
    address public xShare;
    address public xShareOracle;
    address public router;
    uint256 public override assetCount = 0;
    address public usdc;
    bool initialized = false;

    // List of Synthetic Assets
    AssetInfo[] assetInfo;

    // Asset information
    struct AssetInfo {
        address asset;
        address collateral;
        address oracle;
        bool isStable; // Is Asset peg to the value Stable coin like USDC,USDT,...
    }

    function initialize(
        address _treasury,
        address _pool,
        address _xShare,
        address _xShareOracle,
        address _router,
        address _usdc
    ) public onlyOperator {
        require(!initialized, "Already initialized");
        require(_treasury != address(0), "Invalid Address");
        require(_pool != address(0), "Invalid Address");
        require(_xShare != address(0), "Invalid Address");
        require(_xShareOracle != address(0), "Invalid Address");
        require(_router != address(0), "Invalid Address");

        treasury = _treasury;
        pool = _pool;
        xShare = _xShare;
        xShareOracle = _xShareOracle;
        router = _router;
        usdc = _usdc;

        initialized = true;
    }

    function checkAssetExisted(address _asset, address _collateral) internal view {
        require(_asset != address(0), "Invalid address");
        require(_collateral != address(0), "Invalid address");
        for (uint256 aid = 0; aid < assetInfo.length; aid++) {
            require(assetInfo[aid].asset != _asset, "Existed asset");
        }
    }

    // Function to define new Synthetic Asset
    function addAsset(address _asset, address _collateral, address _oracle, bool _isStable, uint256 _price_band, uint256 _init_tcr, uint256 _init_ecr) public onlyOperator {
        checkAssetExisted(_asset, _collateral);
        uint256 missingDecimals = uint256(18).sub(ERC20(_collateral).decimals());

        assetInfo.push(AssetInfo({
        asset : _asset,
        collateral : _collateral,
        oracle : _oracle,
        isStable : _isStable
        }));

        // assetCount = assetId, assetId will be mapped to AssetStat in MultiAssetPool and CollateralPolicy in MultiAssetTreasury
        IMultiAssetTreasury(treasury).addCollateralPolicy(assetCount, _price_band, missingDecimals, _init_tcr, _init_ecr);
        IMultiAssetPool(pool).addAssetStat(assetCount, missingDecimals);

        assetCount = assetCount.add(1);
        emit AddNewAsset(_asset, _collateral);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getAssetInfo(uint256 _assetId) public override view returns (
        address _asset,
        address _collateral,
        address _oracle,
        bool _isStable
    ) {
        _asset = getAsset(_assetId);
        _collateral = getCollateral(_assetId);
        _oracle = getOracle(_assetId);
        _isStable = isAssetStable(_assetId);
    }

    function getAsset(uint256 _assetId) public view override returns (address) {
        return assetInfo[_assetId].asset;
    }

    function getCollateral(uint256 _assetId) public view override returns (address) {
        return assetInfo[_assetId].collateral;
    }

    function getOracle(uint256 _assetId) public view override returns (address) {
        return assetInfo[_assetId].oracle;
    }

    function getAssetTotalSupply(uint256 _assetId) public view override returns (uint256) {
        return ERC20(getAsset(_assetId)).totalSupply();
    }

    function isAssetStable(uint256 _assetId) public view override returns (bool) {
        return assetInfo[_assetId].isStable;
    }

    function getXSharePrice() public view override returns (uint256) {
        return IOracle(xShareOracle).consult(xShare, 1e18);
    }

    function getAssetPrice(uint256 _assetId) public view override returns (uint256) {
        return IOracle(getOracle(_assetId)).consult(getAsset(_assetId), 1e18);
    }

    function updateOracle(uint256 _assetId) public override {
        IOracle(getOracle(_assetId)).update();
    }

    function getCollateralPriceInDollar(uint256 _assetId) public view override returns (uint) {
        if (isAssetStable(_assetId)) {
            uint256 _collateral_decimals = ERC20(getCollateral(_assetId)).decimals();
            return 10 ** _collateral_decimals;
        } else {
            address[] memory _path = new address[](2);
            _path[0] = getCollateral(_assetId);
            _path[1] = usdc;
            uint[] memory amounts = new uint[](2);
            amounts = IUniswapV2Router01(router).getAmountsOut(1 ether, _path);
            return amounts[amounts.length - 1];
        }
    }

    /* ========== GOVERNANCE FUNCTIONS ========== */

    function setTreasury(address _treasury) public onlyOperator {
        require(_treasury != address(0), "Invalid address");
        treasury = _treasury;
    }

    function setPool(address _pool) public onlyOperator {
        require(_pool != address(0), "Invalid address");
        pool = _pool;
    }

    function setShare(address _share) public onlyOperator {
        require(_share != address(0), "Invalid address");
        xShare = _share;
    }

    function setAsset(address _asset, uint256 _assetId) public onlyOperator {
        require(_assetId <= assetInfo.length, "invalid asset");
        require(_asset != address(0), "Invalid address");
        AssetInfo storage _assetInfo = assetInfo[_assetId];
        _assetInfo.asset = _asset;
    }

    function setCollateral(address _collateral, uint256 _assetId) public onlyOperator {
        require(_assetId <= assetInfo.length, "invalid asset");
        require(_collateral != address(0), "Invalid address");
        AssetInfo storage _assetInfo = assetInfo[_assetId];
        _assetInfo.collateral = _collateral;
        uint256 missingDecimals = uint256(18).sub(ERC20(_collateral).decimals());
        IMultiAssetTreasury(treasury).setMissingDecimals(missingDecimals, _assetId);
    }

    function setOracle(address _oracle, uint256 _assetId) public onlyOperator {
        require(_assetId <= assetInfo.length, "invalid asset");
        require(_oracle != address(0), "Invalid address");
        AssetInfo storage _assetInfo = assetInfo[_assetId];
        _assetInfo.oracle = _oracle;
    }

    function setShareOracle(address _oracle) public onlyOperator {
        require(_oracle != address(0), "Invalid address");
        xShareOracle = _oracle;
    }

    function setIsStable(bool _isStable, uint256 _assetId) public onlyOperator {
        require(_assetId <= assetInfo.length, "invalid asset");
        AssetInfo storage _assetInfo = assetInfo[_assetId];
        _assetInfo.isStable = _isStable;
    }

    function setUsd(address _usdc) public onlyOperator {
        require(_usdc != address(0), "Invalid Address");
        usdc = _usdc;
    }

    event AddNewAsset(address indexed asset, address indexed collateral);

}
