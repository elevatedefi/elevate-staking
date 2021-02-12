pragma solidity >=0.6.0 <0.8.0;

import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";

interface ITREASURY {

    function token() external view returns (IERC20);

    function fundsAvailable() external view returns (uint256);

    function release() external;
}