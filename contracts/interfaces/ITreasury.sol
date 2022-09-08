// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

interface ITreasury {
    function hasPool(address _address) external view returns (bool);

    function hasStrategist(address _strategist) external view returns (bool);

    function collateralFund() external view returns (address);

    function globalCollateralBalance() external view returns (uint256);

    function globalCollateralValue() external view returns (uint256);

    function buyback(uint256 _collateral_amount, uint256 _min_share_amount, bool useSlip) external;

    function recollateralize(uint256 _share_amount, uint256 _min_collateral_amount) external;

    function requestTransfer(
        address token,
        address receiver,
        uint256 amount
    ) external;

    function info()
    external
    view
    returns (
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256
    );
}
