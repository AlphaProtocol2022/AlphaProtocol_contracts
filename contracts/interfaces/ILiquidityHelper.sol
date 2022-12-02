pragma solidity ^0.8.0;

abstract contract ILiquidityHelper {
    function addLiquidity(
        address _tokenA,
        address _tokenB,
        uint256 _amountA,
        uint256 _amountB,
        uint256 _minAmountLp
    ) external virtual;

    function getEstimateTokenAmountAddLp(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view virtual returns(uint256);
}
