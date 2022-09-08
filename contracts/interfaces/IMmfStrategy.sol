pragma solidity >=0.6.12;

import "./IGeneralStrategy.sol";

abstract contract IMmfStrategy is IGeneralStrategy {

    function deposit(uint256 _amount, uint256 _rwPid) external virtual;

    function withdraw(uint256 _amount, uint256 _rwPid) external virtual;

    function returnToCollateralFund(uint256 _amount, uint256 _rwPid) external virtual;

    function convertReward(uint256 _rwPid) external virtual;
}
