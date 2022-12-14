pragma solidity >=0.6.12;

abstract contract IRewardPool {
    function addReward(uint256 amount) external virtual;
}
