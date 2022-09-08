pragma solidity >=0.6.12;

interface ICollateralFund {
    function transferTo(
        address _token,
        address _receiver,
        uint256 _amount
    ) external;
}
