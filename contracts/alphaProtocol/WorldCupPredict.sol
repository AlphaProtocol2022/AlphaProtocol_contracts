pragma solidity >=0.6.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../Operator.sol";

contract WorldCupPredict is Operator, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    address public token;
    uint256 prizePool;

//    bool public winnerDecided;
//    bool public winnerId;
//
//    bool public initialized;
//
//    struct Team {
//        string team;
//        uint256 totalBet;
//    }
//
//    struct UserInfo {
//        uint256 betAmount;
//    }
//
//    function init(
//
//    )
//

}
