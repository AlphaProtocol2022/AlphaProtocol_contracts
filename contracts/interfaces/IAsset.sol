pragma solidity >=0.6.12;

abstract contract IAsset {
    function mint(address _to, uint256 _amount) external virtual;
    function burn(uint256 _amount) external virtual;

    function balanceOf(address account) external view virtual returns (uint256);

    function transfer(address recipient, uint256 amount) external virtual returns (bool);

    function poolBurnFrom(address _address, uint256 _amount) external virtual;

    function poolMint(address _address, uint256 _amount) external virtual;

    function circulatingSupply() external view virtual returns (uint256) ;
}
