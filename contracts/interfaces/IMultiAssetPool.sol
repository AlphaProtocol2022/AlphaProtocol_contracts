// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;
pragma experimental ABIEncoderV2;

interface IMultiAssetPool {
    function addAssetStat(uint256 _aid, uint256 _missingDecimals) external;

    function collateralBalance(uint256 _assetId) external view returns (uint256);

    function getUnclaimedCollateral(uint256 _assetId) external view returns (uint256);

    function netSupplyMinted(uint256 _assetId) external view returns (uint256);

    function getCollateralToken(uint256 _assetId) external view returns (address);

}
