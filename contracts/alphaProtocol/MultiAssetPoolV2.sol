// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./../interfaces/IMultiAssetTreasury.sol";
import "./../interfaces/IOracle.sol";
import "./../interfaces/IAsset.sol";
import "./../interfaces/IAssetController.sol";
import "./../interfaces/IMultiAssetPool.sol";
import "./../interfaces/IUniswapV2Router01.sol";
import "../Operator.sol";

contract MultiAssetPoolV2 is Operator, ReentrancyGuard, IMultiAssetPool {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    /* ========== STATE VARIABLES ========== */

    struct AssetStat {
        uint256 netMinted;
        uint256 netRedeemed;
        uint256 totalUnclaimedCollateral;
        uint256 missing_decimals;
        uint256 uncollectedFee;
        uint256 pool_ceiling;
        address collat_main_liq_pair;
        bool mint_paused;
        bool redeem_paused;
    }

    mapping(uint256 => AssetStat) public assetStat; //Map AssetStat to assetId

    address public xShare;
    address public assetController;
    address public treasury; // MultiAssetTreasury Address
    address public feeCollector;
    address public router;

    mapping(address => uint256) public redeem_share_balances; // Unclaimed xShare of User
    mapping(uint256 => mapping(address => uint256))
        public redeem_collateral_balances; // Unclaimed collateral of User
    uint256 public unclaimed_pool_share; // Total Unclaimed share

    mapping(address => uint256) public last_redeemed; // Last claim of User => prevent flash loan attack

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;
    uint256 private constant COLLATERAL_RATIO_PRECISION = 1e6;
    uint256 private constant COLLATERAL_RATIO_MAX = 1e6;

    // Number of blocks to wait before being able to collectRedemption()
    uint256 public redemption_delay = 1;

    address public usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);

    /* ========== MODIFIERS ========== */

    modifier onlyAssetControllerOrOperator() {
        require(
            msg.sender == assetController || msg.sender == operator(),
            "!assetController"
        );
        _;
    }

    modifier onlyTreasury() {
        require(msg.sender == treasury, "!treasury");
        _;
    }

    modifier onlyFeeCollector() {
        require(msg.sender == feeCollector, "!feeCollector");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _xShare,
        address _treasury,
        address _assetController
    ) public {
        require(_xShare != address(0), "Invalid address");
        require(_treasury != address(0), "Invalid address");
        require(_assetController != address(0), "Invalid address");
        feeCollector = msg.sender;
        xShare = _xShare;
        treasury = _treasury;
        assetController = _assetController;
    }

    /* ========== VIEWS ========== */

    function getMissingDecimals(uint256 _assetId)
        public
        view
        returns (uint256)
    {
        return assetStat[_assetId].missing_decimals;
    }

    function getUncollectedFee(uint256 _assetId) public view returns (uint256) {
        return assetStat[_assetId].uncollectedFee;
    }

    function getNetMinted(uint256 _assetId) public view returns (uint256) {
        return assetStat[_assetId].netMinted;
    }

    function getNetRedeemed(uint256 _assetId) public view returns (uint256) {
        return assetStat[_assetId].netRedeemed;
    }

    function getPoolCeiling(uint256 _assetId) public view returns (uint256) {
        return assetStat[_assetId].pool_ceiling;
    }

    function getCollateralPrice(uint256 _assetId)
        public
        view
        returns (uint256)
    {
        return IAssetController(assetController).getAssetPrice(_assetId);
    }

    function getCollateralToken(uint256 _assetId)
        public
        view
        override
        returns (address)
    {
        return IAssetController(assetController).getCollateral(_assetId);
    }

    function netSupplyMinted(uint256 _assetId)
        public
        view
        override
        returns (uint256)
    {
        uint256 _netMinted = getNetMinted(_assetId);
        uint256 _netRedeemed = getNetRedeemed(_assetId);
        if (_netMinted > _netRedeemed) return _netMinted.sub(_netRedeemed);
        return 0;
    }

    function getUnclaimedCollateral(uint256 _assetId)
        public
        view
        override
        returns (uint256)
    {
        return assetStat[_assetId].totalUnclaimedCollateral;
    }

    // Returns alpha value of collateral held in collateralFund
    function collateralBalance(uint256 _assetId)
        public
        view
        override
        returns (uint256)
    {
        return
            (
                ERC20(getCollateralToken(_assetId))
                    .balanceOf(collateralFund())
                    .sub(getUnclaimedCollateral(_assetId))
            ).mul(10**getMissingDecimals(_assetId));
    }

    function collateralFund() public view returns (address) {
        return IMultiAssetTreasury(treasury).collateralFund();
    }

    function info(uint256 _assetId)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bool,
            bool
        )
    {
        return (
            getPoolCeiling(_assetId), // Ceiling of pool - collateral-amount
            collateralBalance(_assetId), // amount of COLLATERAL locked
            assetStat[_assetId].totalUnclaimedCollateral, // unclaimed amount of COLLATERAL
            unclaimed_pool_share, // unclaimed amount of SHARE
            getCollateralPrice(_assetId), // collateral price
            assetStat[_assetId].mint_paused,
            assetStat[_assetId].redeem_paused
        );
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    //     Calculate Minting output variables
    function calcMint(
        uint256 _collateral_amount,
        uint256 _assetId,
        uint256 _missing_decimals
    )
        public
        view
        returns (
            uint256 _asset_out,
            uint256 _collateral_to_buy_xshare,
            uint256 _fee_collect,
            uint256 _collateral_to_reserve
        )
    {
        // Calculate fee based on input collateral amount
        (, , , uint256 _tcr, , , uint256 _minting_fee, ) = IMultiAssetTreasury(
            treasury
        ).info(_assetId);
        _fee_collect = _collateral_amount.mul(_minting_fee).div(
            COLLATERAL_RATIO_PRECISION
        );
        _collateral_to_reserve = (_collateral_amount.sub(_fee_collect))
            .mul(_tcr)
            .div(COLLATERAL_RATIO_PRECISION);
        _asset_out = (_collateral_amount.sub(_fee_collect)).mul(
            10**_missing_decimals
        );
        _collateral_to_buy_xshare = _collateral_amount.sub(_fee_collect).sub(
            _collateral_to_reserve
        );
    }

    function mint(uint256 _collateral_amount, uint256 _assetId)
        external
        nonReentrant
    {
        require(_collateral_amount > 0, "Invalid amount");
        require(assetStat[_assetId].mint_paused == false, "Minting is paused");
        require(
            _assetId <= IAssetController(assetController).assetCount(),
            "Not Exsited Asset"
        );

        AssetStat storage _assetStat = assetStat[_assetId];
        (, , , uint256 _tcr, , , uint256 _minting_fee, ) = IMultiAssetTreasury(
            treasury
        ).info(_assetId);
        (
            address _asset,
            address _collateral,
            ,
            bool isStable
        ) = IAssetController(assetController).getAssetInfo(_assetId);

        require(
            ERC20(_collateral)
                .balanceOf(collateralFund())
                .sub(getUnclaimedCollateral(_assetId))
                .add(_collateral_amount) <= getPoolCeiling(_assetId),
            ">poolCeiling"
        );
        (
            uint256 _asset_out,
            uint256 _collateral_to_buy_xShare,
            uint256 _fee_collect,
            uint256 _collateral_to_reserve
        ) = calcMint(_collateral_amount, _assetId, _assetStat.missing_decimals);

        ERC20(_collateral).safeTransferFrom(
            msg.sender,
            address(this),
            _collateral_amount
        );

        if (_collateral_to_reserve > 0) {
            _transferCollateralToReserve(_collateral_to_reserve, _assetId);
        }

        uint256 xshareBought = 0;

        if (_collateral_to_buy_xShare > 0) {
            xshareBought = _swapToXshare(
                _collateral,
                _assetStat.collat_main_liq_pair,
                _collateral_to_buy_xShare
            );
            IAsset(xShare).burn(xshareBought);
        }

        _assetStat.uncollectedFee = _assetStat.uncollectedFee.add(_fee_collect);
        _assetStat.netMinted = _assetStat.netMinted.add(_asset_out);

        IAsset(_asset).poolMint(msg.sender, _asset_out);

        emit Minted(msg.sender, _collateral_amount, xshareBought, _asset_out);
    }

    function calcRedeem(
        uint256 _asset_amount,
        uint256 _assetId,
        uint256 _missing_decimals
    )
        public
        view
        returns (
            uint256 _collateral_output_amount,
            uint256 _share_output_amount,
            uint256 _fee_collect
        )
    {
        (
            ,
            uint256 _share_price,
            ,
            ,
            uint256 _ecr,
            ,
            ,
            uint256 _redemption_fee
        ) = IMultiAssetTreasury(treasury).info(_assetId);
        uint256 _fee = _asset_amount
            .mul(_redemption_fee)
            .div(PRICE_PRECISION)
            .div(10**_missing_decimals);
        _fee_collect = _fee.mul(_ecr).div(PRICE_PRECISION);
        uint256 _asset_amount_post_fee = _asset_amount.sub(
            _fee.mul(10**_missing_decimals)
        );
        _collateral_output_amount = 0;
        _share_output_amount = 0;
        if (_ecr < COLLATERAL_RATIO_MAX && _ecr >= 0) {
            _collateral_output_amount = _asset_amount_post_fee
                .mul(_ecr)
                .div(10**_missing_decimals)
                .div(PRICE_PRECISION);

            uint256 _collateral_output_value = _collateral_output_amount.mul(
                10**_missing_decimals
            );
            uint256 _collateral_price = IAssetController(assetController)
                .getCollateralPriceInDollar(_assetId);
            uint256 _share_output_value = (
                _asset_amount_post_fee.sub(_collateral_output_value)
            ).mul(_collateral_price).div(PRICE_PRECISION);
            _share_output_amount = _share_output_value.mul(PRICE_PRECISION).div(
                    _share_price
                );
        } else if (_ecr == COLLATERAL_RATIO_MAX) {
            _collateral_output_amount = _asset_amount_post_fee;
        }
    }

    function redeem(
        uint256 _asset_amount,
        uint256 _share_out_min,
        uint256 _collateral_out_min,
        uint256 _assetId
    ) external nonReentrant {
        require(
            assetStat[_assetId].redeem_paused == false,
            "Redeeming is paused"
        );
        AssetStat storage _assetStat = assetStat[_assetId];
        (
            uint256 _collateral_output_amount,
            uint256 _share_output_amount,
            uint256 _fee_collect
        ) = calcRedeem(_asset_amount, _assetId, _assetStat.missing_decimals);
        (address _asset, address _collateral, , ) = IAssetController(
            assetController
        ).getAssetInfo(_assetId);
        //Add To Fee
        _assetStat.uncollectedFee = _assetStat.uncollectedFee.add(_fee_collect);

        // Check if collateral balance meets and meet output expectation
        require(
            _collateral_output_amount <=
                ERC20(_collateral).balanceOf(collateralFund()).sub(
                    _assetStat.totalUnclaimedCollateral
                ),
            "<collateralBlanace"
        );
        require(
            _collateral_out_min <= _collateral_output_amount &&
                _share_out_min <= _share_output_amount,
            ">slippage"
        );

        if (_collateral_output_amount > 0) {
            redeem_collateral_balances[_assetId][
                msg.sender
            ] = redeem_collateral_balances[_assetId][msg.sender].add(
                _collateral_output_amount
            );
            _assetStat.totalUnclaimedCollateral = _assetStat
                .totalUnclaimedCollateral
                .add(_collateral_output_amount);
        }

        if (_share_output_amount > 0) {
            redeem_share_balances[msg.sender] = redeem_share_balances[
                msg.sender
            ].add(_share_output_amount);
            unclaimed_pool_share = unclaimed_pool_share.add(
                _share_output_amount
            );
        }

        last_redeemed[msg.sender] = block.number;

        _assetStat.netRedeemed = _assetStat.netRedeemed.add(_asset_amount);

        // Move all external functions to the end
        IAsset(_asset).poolBurnFrom(msg.sender, _asset_amount);

        if (_share_output_amount > 0) {
            _mintShareToCollateralReserve(_share_output_amount);
        }

        emit Redeemed(
            msg.sender,
            _asset_amount,
            _collateral_output_amount,
            _share_output_amount
        );
    }

    // Collect all pending collateral and xShare of msg.sender
    function collectRedemption() external nonReentrant {
        // Redeem and Collect cannot happen in the same transaction to avoid flash loan attack
        require(
            (last_redeemed[msg.sender].add(redemption_delay)) <= block.number,
            "<redemption_delay"
        );
        uint256 _asset_count = IAssetController(assetController).assetCount();

        bool _send_share = false;
        uint256 _share_amount;

        // Use Checks-Effects-Interactions pattern
        if (redeem_share_balances[msg.sender] > 0) {
            _share_amount = redeem_share_balances[msg.sender];
            redeem_share_balances[msg.sender] = 0;
            unclaimed_pool_share = unclaimed_pool_share.sub(_share_amount);
            _send_share = true;
        }

        if (_send_share) {
            _requestTransferShare(msg.sender, _share_amount);
        }

        // Run a loop to collect all collateral that need to be collected
        for (uint256 aid = 0; aid < _asset_count; aid++) {
            bool _send_collateral = false;
            uint256 _collateral_amount;

            if (redeem_collateral_balances[aid][msg.sender] > 0) {
                _collateral_amount = redeem_collateral_balances[aid][
                    msg.sender
                ];
                redeem_collateral_balances[aid][msg.sender] = 0;
                assetStat[aid].totalUnclaimedCollateral = assetStat[aid]
                    .totalUnclaimedCollateral
                    .sub(_collateral_amount);
                _send_collateral = true;
            }

            if (_send_collateral) {
                _requestTransferCollateral(msg.sender, _collateral_amount, aid);
            }
        }

        emit RedeemCollected(msg.sender);
    }

    function collectFee() external onlyFeeCollector {
        uint256 _asset_count = IAssetController(assetController).assetCount();
        for (uint256 aid = 0; aid < _asset_count; aid++) {
            uint256 _uncollectedFee = assetStat[aid].uncollectedFee;
            if (_uncollectedFee > 0) {
                _requestTransferCollateral(feeCollector, _uncollectedFee, aid);
                assetStat[aid].uncollectedFee = 0;
            }
        }

        emit CollectFee(msg.sender);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _swapToXshare(
        address input_token,
        address bridgeToken,
        uint256 inputAmount
    ) internal returns (uint256) {
        IERC20(input_token).approve(router, 0);
        IERC20(input_token).approve(router, inputAmount);

        address[] memory _path;

        if (input_token != bridgeToken) {
            _path = new address[](3);
            _path[0] = input_token;
            _path[1] = bridgeToken;
            _path[2] = xShare;
        } else {
            _path = new address[](2);
            _path[0] = input_token;
            _path[1] = xShare;
        }

        uint256[] memory estimate_amounts_out = IUniswapV2Router01(router)
            .getAmountsOut(inputAmount, _path);
        uint256 estimate_amount_out = estimate_amounts_out[
            estimate_amounts_out.length - 1
        ];
        uint256 amount_out_min = estimate_amount_out.mul(9500).div(10000);
        uint256[] memory out_amounts = IUniswapV2Router01(router)
            .swapExactTokensForTokens(
                inputAmount,
                0,
                _path,
                address(this),
                block.timestamp.add(1800)
            );
        return out_amounts[out_amounts.length - 1];
    }

    // Transfer collateral to collateralFund when user mint new asset
    function _transferCollateralToReserve(uint256 _amount, uint256 _assetId)
        internal
    {
        address _reserve = collateralFund();
        address _collateral = IAssetController(assetController).getCollateral(
            _assetId
        );
        require(_reserve != address(0), "Invalid reserve address");
        ERC20(_collateral).safeTransfer(_reserve, _amount);
    }

    // Mint new Share to collateral for user to collect when Redeem asset
    function _mintShareToCollateralReserve(uint256 _amount) internal {
        address _reserve = collateralFund();
        require(_reserve != address(0), "Invalid reserve address");
        IAsset(xShare).poolMint(_reserve, _amount);
    }

    // Request transfer collateral when user Redeem asset
    function _requestTransferCollateral(
        address _receiver,
        uint256 _amount,
        uint256 _assetId
    ) internal {
        address _collateral = IAssetController(assetController).getCollateral(
            _assetId
        );
        IMultiAssetTreasury(treasury).requestTransfer(
            _collateral,
            _receiver,
            _amount
        );
    }

    // Request transfer xShare when collect redemption
    function _requestTransferShare(address _receiver, uint256 _amount)
        internal
    {
        IMultiAssetTreasury(treasury).requestTransfer(
            xShare,
            _receiver,
            _amount
        );
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function addAssetStat(uint256 _aid, uint256 _missingDecimals)
        external
        override
        onlyAssetControllerOrOperator
    {
        AssetStat storage _assetStat = assetStat[_aid];
        _assetStat.missing_decimals = _missingDecimals;
        _assetStat.pool_ceiling = 999999999999999999999 ether;
        _assetStat.collat_main_liq_pair = usdc;
    }

    function setCollatMainLiq(address token, uint256 _aid)
        external
        onlyOperator
    {
        AssetStat storage _assetStat = assetStat[_aid];
        _assetStat.collat_main_liq_pair = token;
    }

    function toggleMinting(uint256 _assetId) external onlyOperator {
        assetStat[_assetId].mint_paused = !assetStat[_assetId].mint_paused;
    }

    function toggleRedeeming(uint256 _assetId) external onlyOperator {
        assetStat[_assetId].redeem_paused = !assetStat[_assetId].redeem_paused;
    }

    function setPoolCeiling(uint256 _pool_ceiling, uint256 _assetId)
        external
        onlyOperator
    {
        assetStat[_assetId].pool_ceiling = _pool_ceiling;
    }

    function setRedemptionDelay(uint256 _redemption_delay)
        external
        onlyOperator
    {
        redemption_delay = _redemption_delay;
    }

    function setTreasury(address _treasury) external onlyOperator {
        emit TreasuryTransferred(treasury, _treasury);
        treasury = _treasury;
    }

    function setRouter(address _router) external onlyOperator {
        router = _router;
    }

    // EVENTS
    event TreasuryTransferred(
        address indexed previousTreasury,
        address indexed newTreasury
    );
    event Minted(
        address indexed user,
        uint256 usdtAmountIn,
        uint256 _xShareAmountIn,
        uint256 _alphaAmountOut
    );
    event Redeemed(
        address indexed user,
        uint256 _alphaAmountIn,
        uint256 usdtAmountOut,
        uint256 _xShareAmountOut
    );
    event RedeemCollected(address indexed user);
    event CollectFee(address indexed collector);
}
