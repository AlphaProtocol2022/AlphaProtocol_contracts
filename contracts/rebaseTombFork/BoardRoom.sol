// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "../interfaces/IBasisAsset.sol";
import "./ITreasury.sol";
import "../interfaces/IMainToken.sol";

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// upgradeable
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../utils/ContractGuard.sol";


contract ShareWrapper {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    ERC20 public share;
    uint256 public stakeFee = 200;
    uint256 public withdrawFee = 200;
    address public daoFund;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function stake(uint256 amount) public virtual {
        _totalSupply = _totalSupply.add(amount);
        uint256 feeAmount = amount.mul(stakeFee).div(10000);
        uint256 amountPostFee = amount.sub(feeAmount);
        _balances[msg.sender] = _balances[msg.sender].add(amountPostFee);
        share.safeTransferFrom(msg.sender, address(this), amountPostFee);
        share.safeTransferFrom(msg.sender, daoFund, feeAmount);
    }

    function withdraw(uint256 amount, uint256 _mainTokenPrice) public virtual {
        uint256 memberShare = _balances[msg.sender];
        require(memberShare >= amount, "Boardroom: withdraw request greater than staked amount");
        uint256 feeAmount = 0;
        if (_mainTokenPrice < 1e18) {
            feeAmount = amount.mul(withdrawFee).div(10000);
        }
        uint256 amountPostFee = amount.sub(feeAmount);
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = memberShare.sub(amount);
        share.safeTransfer(msg.sender, amountPostFee);
        share.safeTransfer(daoFund, feeAmount);
    }

}

contract Boardroom is ShareWrapper, ContractGuard {
    using SafeERC20 for ERC20;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct Masonseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct MasonrySnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized;

    ERC20 public mainToken;
    ITreasury public treasury;

    mapping(address => Masonseat) public masons;
    MasonrySnapshot[] public masonryHistory;

    uint256 public withdrawLockupEpochs;
    uint256 public rewardLockupEpochs;

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);
    event SetOperator(address indexed account, address newOperator);

    /* ========== Modifiers =============== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Boardroom: caller is not the operator");
        _;
    }

    modifier memberExists() {
        require(balanceOf(msg.sender) > 0, "Boardroom: The member does not exist");
        _;
    }

    modifier updateReward(address member) {
        if (member != address(0)) {
            Masonseat memory seat = masons[member];
            seat.rewardEarned = earned(member);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            masons[member] = seat;
        }
        _;
    }

    modifier notInitialized() {
        require(!initialized, "Boardroom: already initialized");
        _;
    }

    /* ========== GOVERNANCE ========== */
    function initialize(
        address _mainToken,
        address _shareToken,
        address _treasury,
        address _daoFund
    ) external notInitialized {
        require(_mainToken != address(0), "!_mainToken");
        require(_shareToken != address(0), "!_shareToken");
        require(_treasury != address(0), "!_treasury");
        require(_daoFund != address(0), "!_treasury");
        mainToken = ERC20(_mainToken);
        share = ERC20(_shareToken);
        treasury = ITreasury(_treasury);
        daoFund = _daoFund;
        MasonrySnapshot memory genesisSnapshot = MasonrySnapshot({time: block.number, rewardReceived: 0, rewardPerShare: 0});
        masonryHistory.push(genesisSnapshot);

        withdrawLockupEpochs = 4; // Lock for 4 epochs (24h) before release withdraw
        rewardLockupEpochs = 2; // Lock for 2 epochs (12h) before release claimReward

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
        emit SetOperator(msg.sender, _operator);
    }

    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        require(_withdrawLockupEpochs >= _rewardLockupEpochs && _withdrawLockupEpochs <= 56, "_withdrawLockupEpochs: out of range"); // <= 2 week
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters

    function latestSnapshotIndex() public view returns (uint256) {
        return masonryHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (MasonrySnapshot memory) {
        return masonryHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address member) public view returns (uint256) {
        return masons[member].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address member) internal view returns (MasonrySnapshot memory) {
        return masonryHistory[getLastSnapshotIndexOf(member)];
    }

    function canWithdraw(address member) external view returns (bool) {
        return masons[member].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch();
    }

    function canClaimReward(address member) external view returns (bool) {
        return masons[member].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch();
    }

    function epoch() external view returns (uint256) {
        return treasury.epoch();
    }

    function nextEpochPoint() external view returns (uint256) {
        return treasury.nextEpochPoint();
    }

    function getMainTokenPrice() public view returns (uint256) {
        return treasury.getMainTokenPrice();
    }

    // =========== Member getters

    function rewardPerShare() external view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address member) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(member).rewardPerShare;

        return balanceOf(member).mul(latestRPS.sub(storedRPS)).div(1e18).add(masons[member].rewardEarned);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) public override onlyOneBlock updateReward(msg.sender) {
        require(amount > 0, "Boardroom: Cannot stake 0");
        super.stake(amount);
        uint256 epochTimerStart = treasury.epoch();
        if (epochTimerStart <= 0) {
            epochTimerStart = 1;
        }
        masons[msg.sender].epochTimerStart = epochTimerStart; // reset timer
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public onlyOneBlock memberExists updateReward(msg.sender) {
        require(amount > 0, "Boardroom: Cannot withdraw 0");
        require(masons[msg.sender].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch(), "Boardroom: still in withdraw lockup");
        claimReward();
        // Get 2% fee when protocol in contraction phase
        super.withdraw(amount, getMainTokenPrice());
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender), getMainTokenPrice());
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 reward = masons[msg.sender].rewardEarned;
        if (reward > 0) {
            require(masons[msg.sender].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch(), "Boardroom: still in reward lockup");
            masons[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
            masons[msg.sender].rewardEarned = 0;
            mainToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function allocateSeigniorage(uint256 amount) external onlyOneBlock onlyOperator {
        require(amount > 0, "Boardroom: Cannot allocate 0");
        require(totalSupply() > 0, "Boardroom: Cannot allocate when totalSupply is 0");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));

        MasonrySnapshot memory newSnapshot = MasonrySnapshot({time: block.number, rewardReceived: amount, rewardPerShare: nextRPS});
        masonryHistory.push(newSnapshot);

        mainToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardAdded(msg.sender, amount);
    }
}