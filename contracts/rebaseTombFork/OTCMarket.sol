pragma solidity >=0.6.12;


import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../Operator.sol";
import "../utils/ContractGuard.sol";

import "../interfaces/IYWVault.sol";
import "../interfaces/IYWReceipt.sol";
import "../interfaces/ILiquidityHelper.sol";
import "../interfaces/IOracle.sol";

contract OTCMarket is Operator, ContractGuard, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    struct SellToken {
        address token; // Token for sale
        address purchaseToken; // Token to buy with
        address oracle; // Oracle for price feed
        address lpPair; // Main Liquidity pool of @token
        uint256 amountForSale; // Current amount of @token available for sale
        uint256 soldAmount; // Sold amount of @token
        uint256 ywPid; // YieldWolf Pool id of @lpPair vault
        address ywReceiptTok; // YieldWolf Receipt Token of @lpPair vault
        uint256 lockPeriod; // Locking period after buy
        uint256 discount; // Discount compare to current TWAP
        uint256 minimum; // Minimum purcahse amount of @token
        uint256 twapThreshold;
    }

    struct UserLocker {
        uint256 lockedAmount; // YW Receipt Token locked
        uint256 startTs;
    }

    /* =================== Variables =================== */

    mapping(address => bool) public whiteListSeller;
    mapping(uint256 => mapping(address => UserLocker)) public userLocker;

    address public liquidityHelper = address(0xBC1FaBd34d61B346F40712a80482DcAE5df76291);
    address public router = address(0x7E5E5957De93D00c352dF75159FbC37d5935f8bF);
    address public daoFund = address(0x62CE5d9cD2FBB670Cf2c73D0dF2bfe8e706D887F);
    address public ywVault = address(0xaa59f23CA9De24d88153841ffb8769BC6858618b);

    uint256[] public earlyWithdrawPeriod;
    uint256[] public earlyWithdrawTaxes;
    uint256 public constant MAX_TAX = 2000;

    uint256 public constant DENOMINATOR = 10000; // 100%
    uint256 public constant MAX_DISCOUNT = 1000; // 10%
    bool public useTwapThreshold = true;

    SellToken[] public tokenList;

    /* =================== Events =================== */
    event AddTokenToSell(uint256 tid, address indexed seller, uint256 amount);
    event BuyTokenAndLock(uint256 tid, address indexed buyer, uint256 amount);
    event Withdraw(uint256 tid, address indexed buyer, uint256 amount);
    event CollectPurchasedAmount(uint256 tid, uint256 amount);
    event CollectTax(uint256 tid, uint256 amount);

    constructor() {
        uint256 one_day = 86400;
        earlyWithdrawPeriod = [0 , one_day, one_day * 2, one_day * 3, one_day * 4, one_day * 5, one_day * 6, one_day * 7];
        earlyWithdrawTaxes = [2000, 1800, 1600, 1400, 1200, 1000, 500, 0];
    }

    /* =================== Modifiers =================== */

    modifier onlySeller() {
        require(whiteListSeller[msg.sender], "Invalid seller");
        _;
    }

    function checkSellTokenDuplicate(address _token) internal view {
        uint256 length = tokenList.length;
        for (uint256 tid = 0; tid < length; ++tid) {
            require(tokenList[tid].token != _token, "SellToken: existing token?");
        }
    }

    function addSellToken(
        address _token,
        address _purchaseToken,
        address _oracle,
        address _lpPair,
        uint256 _ywPid,
        uint256 _lockPeriod,
        address _ywReceiptToken,
        uint256 _discount,
        uint256 _minimum,
        uint256 _twapThreshold

    ) external onlyOperator {
        require(_token != address(0), "Invalid token");
        require(_purchaseToken != address(0), "Invalid token");
        require(_lpPair != address(0), "Invalid token");
        require(_oracle != address(0), "Invalid token");
        checkSellTokenDuplicate(_token);

        tokenList.push(SellToken({
        token : _token,
        purchaseToken : _purchaseToken,
        oracle : _oracle,
        lpPair : _lpPair,
        amountForSale : 0,
        soldAmount : 0,
        ywPid : _ywPid,
        lockPeriod : _lockPeriod,
        ywReceiptTok : _ywReceiptToken,
        discount : _discount,
        minimum : _minimum,
        twapThreshold: _twapThreshold
        }));
    }

    /* =================== Views =================== */

    function calculateTaxRate(uint256 _startTs) public view returns (uint256) {
        uint256 taxTierPeriodCount = earlyWithdrawPeriod.length;
        uint256 taxRate = 0;
        uint256 locked_period = block.timestamp.sub(_startTs);
        for (uint8 tierId = uint8(taxTierPeriodCount.sub(1)); tierId >= 0; --tierId) {
            if (locked_period >= earlyWithdrawPeriod[tierId]) {
                taxRate = earlyWithdrawTaxes[tierId];
                break;
            }
        }

        return taxRate;
    }

    function getLpOwned(address _user, uint256 _tid) public view returns (uint256 _lp_owned, uint256 _receipt_staked) {
        UserLocker storage locker = userLocker[_tid][_user];
        SellToken storage sToken = tokenList[_tid];

        _receipt_staked = locker.lockedAmount;
        IYWReceipt receipt_token = IYWReceipt(sToken.ywReceiptTok);
        uint256 total_lp_Staked = receipt_token.totalStakeTokens();
        uint256 total_receipt_supply = receipt_token.totalSupply();
        _lp_owned = _receipt_staked.mul(total_lp_Staked).div(total_receipt_supply);
    }

    function getTotalLpStaked(uint256 _tid) public view returns (uint256) {
        SellToken storage sToken = tokenList[_tid];

        IYWReceipt receipt_token = IYWReceipt(sToken.ywReceiptTok);
        uint256 receipt_tok_bal = IERC20(sToken.ywReceiptTok).balanceOf(address(this));
        uint256 total_staked = receipt_token.totalStakeTokens();
        uint256 total_receipt_supply = receipt_token.totalSupply();
        return receipt_tok_bal.mul(total_staked).div(total_receipt_supply);
    }

    function calcOnBuy(uint256 _tid, uint256 _buy_amount) public view returns (uint256 _cost_amount, uint256 _amount_for_liquidity) {
        SellToken storage sToken = tokenList[_tid];
        IOracle oracle = IOracle(sToken.oracle);
        uint256 twap = oracle.twap(sToken.token, 1e18);
        (uint256 price_precision, uint256 missing_decimal) = _getTwapPricePrecision(_tid);
        uint256 _buy_value = _buy_amount.mul(twap).div(price_precision);
        uint256 _discounted_value = _buy_value.sub(_buy_amount.mul(sToken.discount).div(DENOMINATOR));
        _cost_amount = _discounted_value.div(10 ** missing_decimal);
        _amount_for_liquidity = ILiquidityHelper(liquidityHelper).getEstimateTokenAmountAddLp(sToken.token, sToken.purchaseToken, _buy_amount);
    }

    /* =================== Governance =================== */

    function setOracle(uint256 _tid, address _oracle) external onlyOperator {
        SellToken storage sToken = tokenList[_tid];
        sToken.oracle = _oracle;
    }

    function setLpPair(uint256 _tid, address _lpPair) external onlyOperator {
        SellToken storage sToken = tokenList[_tid];
        sToken.lpPair = _lpPair;
    }

    function setYwPid(uint256 _tid, uint256 _ywPid) external onlyOperator {
        SellToken storage sToken = tokenList[_tid];
        sToken.ywPid = _ywPid;
    }

    function setLockPeriod(uint256 _tid, uint256 _lockPeriod) external onlyOperator {
        SellToken storage sToken = tokenList[_tid];
        sToken.lockPeriod = _lockPeriod;
    }

    function setLockPeriod(uint256 _tid, address _ywReceiptToken) external onlyOperator {
        SellToken storage sToken = tokenList[_tid];
        sToken.ywReceiptTok = _ywReceiptToken;
    }

    function setDiscount(uint256 _tid, uint256 _discount) external onlyOperator {
        SellToken storage sToken = tokenList[_tid];
        require(_discount <= MAX_DISCOUNT, "Exceed max discount");
        sToken.discount = _discount;
    }

    function setMinimum(uint256 _tid, uint256 _minimum) external onlyOperator {
        SellToken storage sToken = tokenList[_tid];
        sToken.minimum = _minimum;
    }

    function modifySellerPermission(address _seller, bool _bool) external onlyOperator {
        whiteListSeller[_seller] = _bool;
    }

    function setRouter(address _router) external onlyOperator {
        require(_router != address(0), "Invalid address");
        router = _router;
    }

    function setLiqHelper(address _liq_helper) external onlyOperator {
        require(_liq_helper != address(0), "Invalid address");
        liquidityHelper = _liq_helper;
    }

    function setDao(address _daoFund) external onlyOperator {
        require(_daoFund != address(0), "Invalid address");
        daoFund = _daoFund;
    }

    function toggleUseTwapThreshold() external onlyOperator {
        useTwapThreshold = !useTwapThreshold;
    }

    /* =================== Sellers Function =================== */

    function addTokenAmountForSell(uint256 tid, uint256 _amount) external onlySeller {
        SellToken storage sToken = tokenList[tid];
        sToken.amountForSale = sToken.amountForSale.add(_amount);
        IERC20(sToken.token).safeTransferFrom(msg.sender, address(this), _amount);
        emit AddTokenToSell(tid, msg.sender, _amount);
    }

    function withdrawTokenAmountForSell(uint256 _tid, uint256 _amount) external onlySeller {
        SellToken storage sToken = tokenList[_tid];
        require(_amount <= sToken.amountForSale, "Exceed amount for sale");
        IERC20(sToken.token).safeTransfer(msg.sender, _amount);
        sToken.amountForSale = sToken.amountForSale.sub(_amount);
    }

    function collectPurchaseToken(uint256 _tid) external onlySeller {
        SellToken storage sToken = tokenList[_tid];
        uint256 token_balance = IERC20(sToken.purchaseToken).balanceOf(address(this));
        IERC20(sToken.purchaseToken).safeTransfer(daoFund, token_balance);

        emit CollectPurchasedAmount(_tid, token_balance);
    }

    function collectTaxes(uint256 _tid) external onlySeller {
        SellToken storage sToken = tokenList[_tid];
        uint256 tax_collected = IERC20(sToken.lpPair).balanceOf(address(this));
        IERC20(sToken.lpPair).safeTransfer(daoFund, tax_collected);

        emit CollectTax(_tid, tax_collected);
    }

    /* =================== Public Functions =================== */

    function buy(uint256 _tid, uint256 _buy_amount) public nonReentrant {
        SellToken storage sToken = tokenList[_tid];
        address user = msg.sender;

        uint256 twap = IOracle(sToken.oracle).consult(sToken.token, 1e18);
        if (useTwapThreshold) {
            require(twap >= sToken.twapThreshold, "< 1.01");
        }

        require(_buy_amount <= sToken.amountForSale, "Exceed current sell amount");
        require(_buy_amount >= sToken.minimum, "Not meet the minimum amount");

        // Calculate cost amount & amount to addliquidity
        (uint256 cost_amount, uint256 amount_for_liquidity) = calcOnBuy(_tid, _buy_amount);
        IERC20(sToken.purchaseToken).safeTransferFrom(user, address(this), cost_amount.add(amount_for_liquidity));
        // transfer cost amount
        uint256 lp_added = _addLiquidity(sToken.lpPair, sToken.token, sToken.purchaseToken, _buy_amount, amount_for_liquidity);
        // Lockup added LP for user
        _depositYwAndLockUp(user, lp_added, _tid);

        sToken.amountForSale = sToken.amountForSale.sub(_buy_amount);
        sToken.soldAmount = sToken.soldAmount.add(_buy_amount);
        // Event
        emit BuyTokenAndLock(_tid, user, _buy_amount);
    }

    function withdraw(uint256 _tid) public nonReentrant {
        UserLocker storage locker = userLocker[_tid][msg.sender];
        SellToken storage sToken = tokenList[_tid];
//        require(block.timestamp >= locker.startTs.add(sToken.lockPeriod), "Still in lock");

        (uint256 lp_owned,) = getLpOwned(msg.sender, _tid);

        // Calc Taxes
        uint256 taxRate = calculateTaxRate(locker.startTs);
        uint256 taxAmount = lp_owned.mul(taxRate).div(DENOMINATOR);
        // Withdraw from YW
        IERC20(sToken.ywReceiptTok).safeApprove(ywVault, 0);
        IERC20(sToken.ywReceiptTok).safeApprove(ywVault, locker.lockedAmount);
        IYWVault(ywVault).withdraw(sToken.ywPid, lp_owned);

        // Transfer LP
        IERC20(sToken.lpPair).safeTransfer(msg.sender, lp_owned.sub(taxAmount));

        locker.lockedAmount = 0;
        locker.startTs = 0;
        // Event
        emit Withdraw(_tid, msg.sender, lp_owned);
    }

    function _addLiquidity(address _lpPair, address _tokenA, address _tokenB, uint256 _amountA, uint256 _amountB) internal returns (uint256 _liqAmount) {
        uint256 _lp_bal_prev = IERC20(_lpPair).balanceOf(address(this));
        _approveTokenIfNeeded(_tokenA, liquidityHelper);
        _approveTokenIfNeeded(_tokenB, liquidityHelper);
        ILiquidityHelper liqHelper = ILiquidityHelper(liquidityHelper);
        liqHelper.addLiquidity(_tokenA, _tokenB, _amountA, _amountB, 0);
        uint256 _lp_bal_after = IERC20(_lpPair).balanceOf(address(this));

        _liqAmount = _lp_bal_after.sub(_lp_bal_prev);
    }

    function _depositYwAndLockUp(address _user, uint256 _lpAmount, uint256 _tid) internal {
        SellToken storage sToken = tokenList[_tid];

        uint256 _receipt_bal_prev = IERC20(sToken.ywReceiptTok).balanceOf(address(this));
        _approveTokenIfNeeded(sToken.lpPair, ywVault);
        IYWVault(ywVault).deposit(sToken.ywPid, _lpAmount);
        uint256 _receipt_bal_after = IERC20(sToken.ywReceiptTok).balanceOf(address(this));

        uint256 _receipt_bal = _receipt_bal_after.sub(_receipt_bal_prev);

        // Lockup
        UserLocker storage locker = userLocker[_tid][_user];
        locker.lockedAmount = locker.lockedAmount.add(_receipt_bal);
        locker.startTs = block.timestamp;
    }

    function _approveTokenIfNeeded(address token, address _spender) private {
        if (IERC20(token).allowance(address(this), address(_spender)) == 0) {
            IERC20(token).safeApprove(address(_spender), type(uint256).max);
        }
    }

    function _getTwapPricePrecision(uint256 _tid) internal view returns (uint256 _price_precision, uint256 _missing_decimal) {
        SellToken storage sToken = tokenList[_tid];
        uint256 purchase_token_decimal = ERC20(sToken.purchaseToken).decimals();
        _price_precision = 10 ** purchase_token_decimal;
        _missing_decimal = 18 - purchase_token_decimal;
    }
}
