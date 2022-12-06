pragma solidity >=0.6.12;

abstract contract ITombTreasury {
    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data) public virtual returns (bytes memory);

    function allocateSeigniorage() external virtual;
}
