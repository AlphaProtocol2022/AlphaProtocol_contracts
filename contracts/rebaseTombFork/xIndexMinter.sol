pragma solidity >=0.6.12;


import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../interfaces/IHyperswapRouter01.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IRewardPool.sol";
import "./../interfaces/IAsset.sol";

import "../interfaces/IZap.sol";
import "../utils/ContractGuard.sol";
import "../Operator.sol";

contract xIndexMinter is Operator, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    address public xIndex;
    address public zapper;
    address public router;

    uint256 public constant xINDEX_PRICE = 10 ** 18; // fixed at 1$
    uint256 public constant PRICE_PRECISION = 10 ** 18;

    uint256 public constant PERCENT_PRECISION = 10000; // 100%
    uint256 public constant MAX_DAO_PERCENT = 3000; // 30%
    uint256 public daoPercent = 1000; // 10%
    address public daoFund = address(0x62CE5d9cD2FBB670Cf2c73D0dF2bfe8e706D887F);

    address public usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);

    bool initialized = false;

    struct Collateral {
        address collateral; // xUSD/USDC or xMATIC/WMATIC
        address mainToken; // XUSD or XMATIC
        address nativeToken; // USDC or WMATIC
        uint256 nativeMissingDecimals;
        address rewardPool;
        bool active;
    }

    Collateral[] public collateralList;

    /* ========== EVENT ========== */

    event Initialized();
    event AddCollateral(address indexed collateral);
    event MintXIndex(address indexed minter, uint256 xIndexAmount);
    event DaoFundChanged(address indexed newDaoFund);
    event ChangeDaoFundPercent(uint256 newPercent);

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _xIndex,
        address _zapper,
        address _router
    ) public onlyOperator {
        require(!initialized, "Already initialized");
        require(_xIndex != address(0), "Invalid address");
        require(_zapper != address(0), "Invalid address");
        require(_router != address(0), "Invalid address");

        xIndex = _xIndex;
        zapper = _zapper;
        router = _router;

        initialized = true;
        emit Initialized();
    }

    function addCollateral(
        address _collateral,
        address _mainToken,
        address _nativeToken,
        uint256 _nativeMissingDecimals,
        address _lpPool
    ) public onlyOperator {
        require(_collateral != address(0), "Invalid address");
        require(_mainToken != address(0), "Invalid address");
        require(_nativeToken != address(0), "Invalid address");

        collateralList.push(Collateral({
        collateral : _collateral,
        mainToken : _mainToken,
        nativeToken : _nativeToken,
        nativeMissingDecimals : _nativeMissingDecimals,
        active : true,
        rewardPool : _lpPool
        }));
    }

    function setDaoFund(address _daoFund) external onlyOperator {
        require(_daoFund != address(0), "Invalid address");
        daoFund = _daoFund;
    }

    function setDaoPercentage(uint256 _daoPercent) external onlyOperator {
        require(_daoPercent <= MAX_DAO_PERCENT, "Exceed Max percent");
        daoPercent = _daoPercent;
        emit ChangeDaoFundPercent(_daoPercent);
    }

    function setXIndex(address _xIndex) external onlyOperator {
        require(_xIndex != address(0), "Invalid address");
        xIndex = _xIndex;
    }

    function setZapper(address _zapper) external onlyOperator {
        require(_zapper != address(0), "Invalid address");
        zapper = _zapper;
    }

    function setRouter(address _router) external onlyOperator {
        require(_router != address(0), "Invalid address");
        router = _router;
    }

    function setCollateral(address _collateral, uint256 _cid) external onlyOperator {
        Collateral storage collateral = collateralList[_cid];
        collateral.collateral = _collateral;
    }

    function setNative(address _native, uint256 _cid) external onlyOperator {
        Collateral storage collateral = collateralList[_cid];
        collateral.nativeToken = _native;
    }

    function setRewardPool(address _rewardPool, uint256 _cid) external onlyOperator {
        Collateral storage collateral = collateralList[_cid];
        collateral.rewardPool = _rewardPool;
    }

    function toggleActive(uint256 _cid) external onlyOperator {
        Collateral storage collateral = collateralList[_cid];
        collateral.active = !collateral.active;
    }

    function setMissingDecimals(uint256 _missingDecimals, uint256 _cid) external onlyOperator {
        Collateral storage collateral = collateralList[_cid];
        collateral.nativeMissingDecimals = _missingDecimals;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getNativePrice(uint256 _cid) public view returns (uint256 _nativePrice) {
        Collateral memory collateral = collateralList[_cid];
        address _native = collateral.nativeToken;
        if (_native == usdc) {
            _nativePrice = 1e18;
        } else {
            IHyperswapRouter01 router = IHyperswapRouter01(router);
            address[] memory _path = new address[](2);
            _path[0] = _native;
            _path[1] = usdc;
            uint[] memory amounts = new uint[](2);
            amounts = router.getAmountsOut(1 ether, _path);
            _nativePrice = amounts[amounts.length - 1].mul(10 ** 12);
        }
    }

    function getLpPrice(uint256 _cid) public view returns (uint256 _lpPrice) {
        Collateral memory collateral = collateralList[_cid];

        IUniswapV2Pair lpToken = IUniswapV2Pair(collateral.collateral);
        bool isToken0Native = lpToken.token0() == collateral.nativeToken;
        uint256 nativeReserve = 0;
        (uint256 token0Reserve, uint256 token1Reserve,) = lpToken.getReserves();
        if (isToken0Native) {
            nativeReserve = token0Reserve;
        } else {
            nativeReserve = token1Reserve;
        }
        uint256 lpSupply = lpToken.totalSupply();
        uint256 native_price = getNativePrice(_cid);
        _lpPrice = native_price.mul(nativeReserve).div(10 ** 18).mul(2).mul(10 ** collateral.nativeMissingDecimals).mul(10 ** 18).div(lpSupply);
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    function calcMint(uint256 _cid, uint256 _amount, bool _useNative) public view returns (uint256 _xIndex_amount) {
        Collateral memory collateral = collateralList[_cid];
        uint256 collateral_price = _useNative ? getNativePrice(_cid) : getLpPrice(_cid);
        uint256 missing_decimals = _useNative ? collateral.nativeMissingDecimals : 0;
        _xIndex_amount = _amount.mul(collateral_price).div(PRICE_PRECISION).mul(10 ** missing_decimals);
    }

    function mint(uint256 _cid, uint256 _amount, bool _useNative) public nonReentrant {
        Collateral memory _collateral = collateralList[_cid];
        require(_collateral.active, "Minting Closed");

        address token_to_transfer = _useNative ? _collateral.nativeToken : _collateral.collateral;
        ERC20(token_to_transfer).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 _xIndex_to_mint = calcMint(_cid, _amount, _useNative);
        uint256 dao_allocation = _amount.mul(daoPercent).div(PERCENT_PRECISION);
        uint256 lp_for_reward = _useNative ? convertNativeToLp(_cid, _amount.sub(dao_allocation)) : _amount.sub(dao_allocation);

        IAsset(xIndex).poolMint(msg.sender, _xIndex_to_mint);

        // Transfer tokens
        ERC20(token_to_transfer).safeTransfer(daoFund, dao_allocation);
        ERC20(_collateral.collateral).safeTransfer(_collateral.rewardPool, lp_for_reward);

        IRewardPool(_collateral.rewardPool).addReward(lp_for_reward);
        emit MintXIndex(msg.sender, _xIndex_to_mint);
    }

    function convertNativeToLp(uint256 _cid, uint256 _amount) internal returns (uint256 _lpAmount) {
        Collateral memory _collateral = collateralList[_cid];
        _approveTokenIfNeeded(_collateral.nativeToken, zapper);
        uint256 _collateralBal_before_zap = ERC20(_collateral.collateral).balanceOf(address(this));
        IZap(zapper).zapInToken(_collateral.nativeToken, _amount, _collateral.collateral, router, address(this));
        uint256 _collateralBal_after_zap = ERC20(_collateral.collateral).balanceOf(address(this));
        _lpAmount = _collateralBal_after_zap.sub(_collateralBal_before_zap);
    }

    function _approveTokenIfNeeded(address token, address _spender) private {
        if (ERC20(token).allowance(address(this), _spender) == 0) {
            ERC20(token).safeApprove(_spender, type(uint).max);
        }
    }
}
