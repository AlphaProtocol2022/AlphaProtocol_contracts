// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

interface IMasonry {
    function balanceOf(address _mason) external view returns (uint256);

    function earned(address _mason) external view returns (uint256);

    function canWithdraw(address _mason) external view returns (bool);

    function canClaimReward(address _mason) external view returns (bool);

    function epoch() external view returns (uint256);

    function nextEpochPoint() external view returns (uint256);

    function getBetaPrice() external view returns (uint256);

    function setOperator(address _operator) external;

    function setRewardAllocation(uint256 _newShareHoldersRewardPerc) external;

    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external;

    function setFeeCollector(address _feeCollector) external;

    function stake(uint256 _amount, bool isShare) external;

    function withdraw(uint256 _amount, bool isShare) external;

    function exit() external;

    function claimReward() external;

    function allocateSeigniorage(uint256 _amount) external;

    function governanceRecoverUnsupported(address _token, uint256 _amount, address _to) external;
}
