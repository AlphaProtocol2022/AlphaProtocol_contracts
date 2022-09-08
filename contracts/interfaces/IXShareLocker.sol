pragma solidity >=0.6.12;

interface IXShareLocker {
    function lockXShare(uint256 _amount, uint256 duration) external;

    function unlockXShare(uint256 _amount) external;

    function addMoreXShare(uint256 _amount) external;

    function extendLockDuration(uint256 _extendDuration) external;

    function emergencyUnlockAll() external;

}
