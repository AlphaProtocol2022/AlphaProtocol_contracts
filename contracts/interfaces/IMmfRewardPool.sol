pragma solidity >=0.6.12;

abstract contract IMmfRewardPool {

    //Interface for pool stake MMF => earn MMF
    function pendingMeerkat(uint256 _pid, address _user) external view virtual returns (uint256);

    function deposit(uint256 _pid, uint256 _amount, address _referrer) external virtual;

    function withdraw(uint256 _pid, uint256 _amount) external virtual;

    function userInfo(uint256 _pid, address _user) external view virtual returns (uint256, uint256);

    // Interface for pool Stake MMF => earn ALTs
    function pendingReward(address _user) external view virtual returns (uint256);

    function deposit(uint256 _amount) external virtual;

    function withdraw(uint256 _amount) external virtual;

    function userInfo(uint256 _user) external view virtual returns (uint256, uint256);

}
