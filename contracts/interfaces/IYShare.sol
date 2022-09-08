pragma solidity >=0.6.12;

interface IYShare {
    function lockerBurnFrom(address _address, uint256 _amount) external;

    function lockerMintFrom(address _address, uint256 _amount) external;
}
