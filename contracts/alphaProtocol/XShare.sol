// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./../interfaces/IMultiAssetTreasury.sol";
import "./../Operator.sol";

contract XShare is ERC20Burnable, Operator {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // TOTAL SUPPLY = 100.000.000 xShare
    uint256 public constant LIQUIDITY_MINING_ALLOCATION = 70000000 ether; // 70.000.000 xShare
    uint256 public constant POOL_ALLOCATION = 5000000 ether; // 5.000.000 xShare
    uint256 public constant DEV_FUND_ALLOCATION = 12980000 ether; // 13.000.000 xShare
    uint256 public constant PROJECT_TREASURY_ALLOCATION = 10000000 ether; // 10.000.000 xShare
    uint256 public constant ADVISOR_ALLOCATION = 2000000 ether; // 2.0000.000 xShare
    uint256 public constant INITIAL_LIQUIDITY_ALLOCATION = 20000 ether; // 20.000 xShare

    IMultiAssetTreasury public treasury;

    address[] public excludeTotalSupply;

    uint256 public constant VESTING_DURATION = 730 days;
    uint256 public startTime;
    uint256 public endTime;

    uint256 public daoFundRewardRate;
    uint256 public devFundRewardRate;

    address public daoFund;
    address public devFund;

    address public xShareRewardPool;

    uint256 public lastClaimedTime;

    bool public rewardPoolDistributed = false;
    bool public advisorRewardDistributed = false;

    modifier onlyPools() {
        require(IMultiAssetTreasury(treasury).hasPool(msg.sender), "!pools");
        _;
    }

    // Track Share burned
    event ShareBurned(address indexed from, address indexed to, uint256 amount);

    // Track Share minted
    event ShareMinted(address indexed from, address indexed to, uint256 amount);

    event DaoClaimRewards(uint256 paid);
    event DevClaimRewards(uint256 paid);
    event FarmRewardDistribute(address indexed farmContract, address indexed poolReserve);
    event AdvisorRewardDistribute(address indexed vestingContract);

    constructor(IMultiAssetTreasury _treasury, uint256 _startTime, address _devFund, address _daoFund) public ERC20("XSHARE", "XSHARE") {
        _mint(msg.sender, INITIAL_LIQUIDITY_ALLOCATION);

        startTime = _startTime;
        endTime = startTime + VESTING_DURATION;

        lastClaimedTime = startTime;

        daoFundRewardRate = PROJECT_TREASURY_ALLOCATION.div(VESTING_DURATION);
        devFundRewardRate = DEV_FUND_ALLOCATION.div(VESTING_DURATION);

        require(_devFund != address(0), "Address cannot be 0");
        devFund = _devFund;

        require(_daoFund != address(0), "Address cannot be 0");
        daoFund = _daoFund;

        treasury = _treasury;
    }

    function distributeReward(address _farmingIncentiveFund, address _poolReserve) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_farmingIncentiveFund != address(0), "!_farmingIncentiveFund");
        require(_poolReserve != address(0), "!_poolContract");
        require(_advisorVestingContract != address(0), "!_advisorVestingContract");
        rewardPoolDistributed = true;
        _mint(_farmingIncentiveFund, LIQUIDITY_MINING_ALLOCATION);
        _mint(_poolReserve, POOL_ALLOCATION);

        emit FarmRewardDistribute(_farmingIncentiveFund, _poolReserve);
    }

    function disitributeAdvisorFund(address _vestingContract) external onlyOperator {
        require(!advisorRewardDistributed, "only can distribute once");
        require(_vestingContract != address(0), "invalid address");
        advisorRewardDistributed = true;
        _mint(_vestingContract, ADVISOR_ALLOCATION);

        emit AdvisorRewardDistribute(_vestingContract);
    }

    function circulatingSupply() public view returns (uint256) {
        uint256 cirSupply = totalSupply();
        for (uint256 i = 0; i < excludeTotalSupply.length; i++) {
            cirSupply = cirSupply.sub(balanceOf(excludeTotalSupply[i]));
        }
        return cirSupply;
    }

    function setDaoFund(address _daoFund) external onlyOperator {
        require(_daoFund != address(0), "zero");
        daoFund = _daoFund;
    }

    function setDevFund(address _devFund) external onlyOperator {
        require(_devFund != address(0), "zero");
        devFund = _devFund;
    }

    function unclaimedDaoFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (lastClaimedTime >= _now) return 0;
        _pending = _now.sub(lastClaimedTime).mul(daoFundRewardRate);
    }

    function unclaimedDevFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (lastClaimedTime >= _now) return 0;
        _pending = _now.sub(lastClaimedTime).mul(devFundRewardRate);
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
        _pending = unclaimedDevFund();
        if (_pending > 0 && devFund != address(0)) {
            emit DevClaimRewards(_pending);
            _mint(devFund, _pending);
        }
        lastClaimedTime = block.timestamp;
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    // This function is what other Pools will call to mint new SHARE
    function poolMint(address m_address, uint256 m_amount) external onlyPools {
        _mint(m_address, m_amount);
        emit ShareMinted(address(this), m_address, m_amount);
    }

    // This function is what other pools will call to burn SHARE
    function poolBurnFrom(address b_address, uint256 b_amount) external onlyPools {
        super.burnFrom(b_address, b_amount);
        emit ShareBurned(b_address, address(this), b_amount);
    }

    function addExcludeTotalSupply(address _rewardPool) public onlyOperator {
        require(_rewardPool != address(0), "Invalid address");
        excludeTotalSupply.push(_rewardPool);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        require(_to != address(0), "cannot send to 0 address!");
        _token.safeTransfer(_to, _amount);
    }

    function setTreasuryAddress(IMultiAssetTreasury _treasury) public onlyOperator {
        require(address(_treasury) != address(0), "treasury address can't be 0!");
        treasury = _treasury;
    }
}
