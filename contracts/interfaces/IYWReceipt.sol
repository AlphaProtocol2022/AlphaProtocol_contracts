pragma solidity >=0.6.12;

interface IYWReceipt {
    function totalStakeTokens() external view returns (uint256);

    function totalSupply() external view returns (uint256);
}
