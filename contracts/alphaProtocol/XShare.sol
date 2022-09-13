// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./../interfaces/IMultiAssetTreasury.sol";
import "./../Operator.sol";

contract XShare is ERC20Burnable, Operator {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // TOTAL MAX SUPPLY = 100.000.000 xShare
    uint256 public constant LIQUIDITY_MINING_ALLOCATION = 65000000 ether; // 65.000.000 xShare
    uint256 public constant POOL_ALLOCATION = 7000000 ether; // 7.000.000 xShare
    uint256 public constant DEV_FUND_ALLOCATION = 12000000 ether; // 12.000.000 xShare
    uint256 public constant PROJECT_TREASURY_ALLOCATION = 12000000 ether; // 12.000.000 xShare
    uint256 public constant ADVISOR_ALLOCATION = 1000000 ether; // 1.000.000 xShare
    uint256 public constant PRIVATE_SALE_ALLOCATION = 500000 ether; // 500.000 xShare
    uint256 public constant PUBLIC_SALE_ALLOCATION = 1500000 ether; // 1.500.000 xShare
    uint256 public constant INITIAL_LIQUIDITY_ALLOCATION = 1000000 ether; // 1.000.000 xShare

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
    bool public privateSaleDistributed = false;
    bool public publicSaleDistributed = false;

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

    constructor(IMultiAssetTreasury _treasury, uint256 _startTime, address _devFund, address _daoFund) public ERC20("10SHARE", "10SHARE") {
        _mint(_devFund, 50 ether);

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

    function distributeReward(address _farmingIncentiveFund, address _poolContract, address _advisorVestingContract) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_farmingIncentiveFund != address(0), "!_farmingIncentiveFund");
        require(_poolContract != address(0), "!_poolContract");
        require(_advisorVestingContract != address(0), "!_advisorVestingContract");
        rewardPoolDistributed = true;
        _mint(_farmingIncentiveFund, LIQUIDITY_MINING_ALLOCATION);
        _mint(_poolContract, POOL_ALLOCATION);
        _mint(_advisorVestingContract, ADVISOR_ALLOCATION);
    }

    function distributePrivateSale(address _privateSaleContract) external onlyOperator {
        require(!privateSaleDistributed, "only can distribute once");
        require(_privateSaleContract != address(0), "invalid address");
        privateSaleDistributed = true;
        _mint(_privateSaleContract, PRIVATE_SALE_ALLOCATION);
    }

    function distributePublicSale(address _publicSaleContract) external onlyOperator {
        require(!privateSaleDistributed, "only can distribute once");
        require(_publicSaleContract != address(0), "invalid address");
        privateSaleDistributed = true;
        _mint(_publicSaleContract, PUBLIC_SALE_ALLOCATION);
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
