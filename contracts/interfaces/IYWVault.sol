pragma solidity >=0.6.12;

interface IYWVault {
    function deposit(uint256 _pid, uint256 _depositAmount) external;

    function withdraw(uint256 _pid, uint256 _withdrawAmount) external;

    function emergencyWithdraw(uint256 _pid) external;

    function stakedTokens(uint256 _pid, address _user) external view returns (uint256);
}
