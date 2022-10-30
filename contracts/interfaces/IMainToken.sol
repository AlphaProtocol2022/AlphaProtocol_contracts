// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMainToken is IERC20 {
    function grantRebaseExclusion(address account) external;
    function getExcluded() external view returns (address[] memory);
    function rebase(uint256 epoch, uint256 supplyDelta, bool negative) external returns (uint256);
    function rebaseSupply() external view returns (uint256);
    function isDevFund(address _address) external view returns (bool);
    function isDaoFund(address _address) external view returns (bool);
    function getDevFund() external view returns (address);
    function getDaoFund() external view returns (address);
    function mint(address recipient, uint256 amount) external returns (bool);
}