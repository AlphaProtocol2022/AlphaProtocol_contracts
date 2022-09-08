// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;
pragma experimental ABIEncoderV2;

interface IPool {
    function collateralBalance() external view returns (uint256);

    function unclaimed_pool_collateral() external view returns (uint256);

    function netSupplyMinted() external view returns (uint256);

    function getCollateralToken() external view returns (address);

}
