pragma solidity >=0.6.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./../interfaces/IMultiAssetPool.sol";
import "./../interfaces/IAssetController.sol";
import "./../interfaces/IMultiAssetTreasury.sol";
import "./../interfaces/IUniswapV2Router01.sol";
import "../Operator.sol";

//TODO add multi asset Pool interface
//
//interface IPool {
//    function calcMint(uint256 _collateralAmount, uint256 _share_amount, uint256 _assetId, uint256 _missing_decimals) public view returns (
//        uint256 _actual_asset_amount,
//        uint256 _required_share_amount,
//        uint256 _fee_collect
//    );
//
//    function mint(
//        uint256 _collateral_amount,
//        uint256 _share_amount,
//        uint256 _alpha_out_min,
//        uint256 _assetId
//    ) external;
//
//    function getMissingDecimals(uint256 _assetId) external view returns (uint256);
//}
//
//interface ITreasury {
//    function assetTcr(uint256 _assetId) external view returns (uint256);
//    function minting_fee() external view returns (uint256);
//
//}

contract SpaceZap is Operator {
//    using SafeMath for uint256;
//    using SafeERC20 for ERC20;
//
//    address public pool;
//    address public treasury;
//    address public assetController;
//    address public router;
//    uint256 private constant RATIO_PRECISION = 1e6;
//
//    function _swap(address inputToken, address[] memory _path, uint256 inputAmount, uint256 outputAmountMin) public onlyOperator returns (uint256) {
//        IERC20(inputToken).approve(router, 0);
//        IERC20(inputToken).approve(router, inputAmount);
//        uint256[] memory out_amounts = IUniswapV2Router01(router).swapExactTokensForTokens(inputAmount, outputAmountMin, _path, address(this), block.timestamp.add(1800));
//        return out_amounts[out_amounts.length - 1];
//    }
//
//    function _addLiquidity(address _tokenA, address _tokenB, uint256 _amountA, uint256 _amountB) internal {
//        IERC20(_tokenA).approve(router, 0);
//        IERC20(_tokenA).approve(router, inputAmount);
//        IERC20(_tokenB).approve(router, 0);
//        IERC20(_tokenB).approve(router, inputAmount);
//
//    }
//
//    function _callFastMint(
//        uint256 _aid,
//        address _inputToken,
//        uint256 _inputAmount,
//        address[] memory _path,
//        uint256 _slippage)
//    public view returns (
//        uint256 _assetOutPut,
//        uint256 _inputAmountLeft,
//        uint256 _xShareLeft,
//        uint256 _collateralLeft,
//        uint256 _collateralReceived
//    ) {
//        address _collateral = IAssetController(assetController).getCollateral(_aid);
//        uint256 _collateral_missing_decimal = IPool(pool).getMissingDecimals(_aid);
//        require(_path[_path.length - 1] == _collateral, "Invalid Path");
//        require(_path[0] == _inputToken, "Invalid input token");
//        uint256[] memory out_amounts = IUniswapV2Router01(router).getAmountsOut(_inputAmount, _path);
//        _collateralReceived = out_amounts[out_amounts.length - 1];
//        uint256 _tcr = ITreasury(treasury).assetTcr(_aid);
//        uint256 _minting_fee = ITreasury(treasury).minting_fee();
//        _assetOutPut = _collateralReceived.sub(_collateralReceived.mul(_minting_fee).div(RATIO_PRECISION));
//
//    }

}
