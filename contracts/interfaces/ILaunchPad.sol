pragma solidity >=0.6.12;

interface ILaunchPad {
    function commitToken(uint256 amount) external;

    function claimToken() external;

    function useRaisedFund() external;

}
