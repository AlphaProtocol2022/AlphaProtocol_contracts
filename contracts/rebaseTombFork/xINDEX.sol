// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./../Operator.sol";

contract xINDEX is ERC20Burnable, Operator {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public minter;

    // Track Share burned
    event ShareBurned(address indexed from, address indexed to, uint256 amount);

    // Track Share minted
    event ShareMinted(address indexed from, address indexed to, uint256 amount);

    constructor(address _minter) public ERC20("xINDEX", "xINDEX") {
        minter = _minter;
    }

    modifier onlyMinter() {
        require(msg.sender == minter, "!minter");
        _;
    }

    function setMinter(address _newMinter) external onlyOperator {
        require(_newMinter != address(0), "Invalid address");
        minter = _newMinter;
    }

    function poolMint(address _to, uint256 _amount) public onlyMinter {
        _mint(_to, _amount);
        emit ShareMinted(address(this), _to, _amount);
    }

    function poolBurnFrom(address _from, uint256 _amount) external onlyMinter {
        super.burnFrom(_from, _amount);
        emit ShareBurned(_from, address(this), _amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = msg.sender;
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

}
