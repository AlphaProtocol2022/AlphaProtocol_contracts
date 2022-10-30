// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./../Operator.sol";

contract SpaceToken is ERC20, Operator {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // TOTAL SUPPLY = 100.000.000 xShare
    uint256 public constant LIQUIDITY_MINING_ALLOCATION = 56000 ether;
    uint256 public constant DEV_FUND_ALLOCATION = 6700 ether;
    uint256 public constant PROJECT_TREASURY_ALLOCATION = 6700 ether;
    uint256 public constant INITIAL_LIQUIDITY_ALLOCATION = 300 ether;
    uint256 public constant INITIAL_DAOFUND_ALLOCATION = 300 ether;

    address[] public excludeTotalSupply;

    uint256 public constant VESTING_DURATION = 365 days;
    uint256 public startTime;
    uint256 public endTime;

    uint256 public daoFundRewardRate;
    address public daoFund;

    uint256 public lastClaimedTime;

    bool public rewardPoolDistributed = false;
    // Fair launch config
    bool public duringFairLaunch = true;
    uint256 public maxAmountTransfer = 1 ether;

    // Track Share burned
    event ShareBurned(address indexed from, address indexed to, uint256 amount);

    // Track Share minted
    event ShareMinted(address indexed from, address indexed to, uint256 amount);

    event DaoClaimRewards(uint256 paid);
    event FarmRewardDistribute(address indexed farmContract);

    constructor(uint256 _startTime, address _devFund, address _daoFund) public ERC20("SPACE", "SPACE") {
        _mint(_devFund, INITIAL_LIQUIDITY_ALLOCATION);
        _mint(_devFund, DEV_FUND_ALLOCATION);
        _mint(_daoFund, INITIAL_LIQUIDITY_ALLOCATION);

        startTime = _startTime;
        endTime = startTime + VESTING_DURATION;

        lastClaimedTime = startTime;

        daoFundRewardRate = PROJECT_TREASURY_ALLOCATION.div(VESTING_DURATION);

        require(_daoFund != address(0), "Address cannot be 0");
        daoFund = _daoFund;

    }

    function distributeReward(address _farmingIncentiveFund) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_farmingIncentiveFund != address(0), "!_farmingIncentiveFund");
        rewardPoolDistributed = true;
        _mint(_farmingIncentiveFund, LIQUIDITY_MINING_ALLOCATION);

        emit FarmRewardDistribute(_farmingIncentiveFund);
    }

    function circulatingSupply() public view returns (uint256) {
        uint256 cirSupply = totalSupply();
        for (uint256 i = 0; i < excludeTotalSupply.length; i++) {
            cirSupply = cirSupply.sub(balanceOf(excludeTotalSupply[i]));
        }
        return cirSupply;
    }

    function unclaimedDaoFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (lastClaimedTime >= _now) return 0;
        _pending = _now.sub(lastClaimedTime).mul(daoFundRewardRate);
    }

    /**
     * @dev Claim pending rewards to community and dev fund
     */

    function claimRewards() external {
        uint256 _pending = unclaimedDaoFund();
        if (_pending > 0 && daoFund != address(0)) {
            emit DaoClaimRewards(_pending);
            _mint(daoFund, _pending);
        }
        lastClaimedTime = block.timestamp;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = msg.sender;
        if (duringFairLaunch && from != operator()) {
            require(amount <= maxAmountTransfer, "Exceed max amount");
        }
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function endFairLaunch() public onlyOperator {
        require(duringFairLaunch, "Already ends");
        duringFairLaunch = false;
    }

    function addExcludeTotalSupply(address _rewardPool) public onlyOperator {
        require(_rewardPool != address(0), "Invalid address");
        excludeTotalSupply.push(_rewardPool);
    }

    function setDaoFund(address _daoFund) external onlyOperator {
        require(_daoFund != address(0), "zero");
        daoFund = _daoFund;
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        require(_to != address(0), "cannot send to 0 address!");
        _token.safeTransfer(_to, _amount);
    }
}
