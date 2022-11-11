pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVault is IERC20 {
    function deposit(uint256 amount) external;
    function withdraw(uint256 shares) external;
    function want() external pure returns (address);
}