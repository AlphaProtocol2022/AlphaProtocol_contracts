pragma solidity >=0.6.12;

abstract contract IInvestmentController {
    function collateralBalance(uint256 _assetId) external view virtual returns (uint256);

    function getUnDistributedReward(uint256 _strategyId) external view virtual returns (uint256, address);

    function getStrategyUnclaimedReward(uint256 _strategyId) external view virtual returns (uint256);

    function getInvestedAmount(address _strategyContract) external view virtual returns (uint256);

    function invest(uint256 _strategyId, uint256 _amount) external virtual;

    function recollateralized(uint256 _amount) external virtual;

    function claimReward(uint256 _strategyId, uint256 _amount) external virtual;

    function exitStrategy(uint256 _strategyId) external virtual;

    function distributeReward(uint256 _strategyId, uint256 _amount) external virtual;

    function coverCollateralThreshold(uint256 _assetId, uint256 _strategyId) external virtual;
}
