pragma solidity >=0.6.12;

abstract contract IGeneralStrategy {
    function getInvestedByController() external view virtual returns (uint256);

    function exitStrategy() external virtual;

    function sendRewardToController(uint256 _amount) external virtual;

    function getTotalEstimateReward() external virtual view  returns (uint256);

    function coverCollateralThreshold(uint256 _amount) external virtual;
}
