pragma solidity >=0.6.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./../../interfaces/ICurrencyReserve.sol";
import "./../../Operator.sol";

contract SinglePoolReserve is Operator, ICurrencyReserve {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public xShareSinglePool;
    address public xShare;
    uint256 public TOTAL_REWARD = 5000000 ether;

    bool migrated = false;

    constructor(address _xShare, address _xShareSinglePool) public {
        xShare = _xShare;
        xShareSinglePool = _xShareSinglePool;
    }

    modifier onlyPool() {
        require(msg.sender == xShareSinglePool, "!pool");
        _;
    }

    function xShareRemain() public view returns (uint256) {
        return IERC20(xShare).balanceOf(address(this));
    }

    function setSinglePool(address _singlePool) public onlyOperator {
        xShareSinglePool = _singlePool;
    }

    function transferTo(
        address _token,
        address _receiver,
        uint256 _amount
    ) public override onlyPool {
        require(_receiver != address(0), "Invalid address");
        require(_amount > 0, "Cannot transfer zero amount");
        IERC20(_token).safeTransfer(_receiver, _amount);
    }
}
