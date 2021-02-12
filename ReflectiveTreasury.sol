// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";
import "openzeppelin-solidity/contracts/access/Ownable.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";

/**
 * @dev A token holder contract that will allow a beneficiary to extract only interest eanred on the principle deposited.
 */
contract ReflectiveTreasury is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // ERC20 basic token contract being held
    IERC20 private _token;

    // beneficiary of tokens after they are released
    address private _beneficiary;

    // amount of principle deposited
    uint256 private _principle;

    constructor (IERC20 token, address beneficiary) public {
        _token = token;
        _beneficiary = beneficiary;
    }

    /**
     * @return the token being held.
     */
    function token() public view returns (IERC20) {
        return _token;
    }

    /**
     * @return the beneficiary of the tokens.
     */
    function beneficiary() public view returns (address) {
        return _beneficiary;
    }

    /**
     * @return the principal that has been been added to the contract.  This can never be withdrawn.
     */
    function principle() public view returns (uint256) {
        return _principle;
    }

    /**
     * @return The amount of tokens available to release.
     */
    function fundsAvailable() public view returns (uint256) {
        return _token.balanceOf(address(this)).sub(_principle);
    }

    /**
     * @notice Deposit funds to the treasury.
     */
    function deposit(uint256 amount) external {
        _token.safeTransferFrom(msg.sender, address(this), amount); 
        amount = _applyFee(amount);
        _principle = _principle.add(amount);
    }

    /**
     * @notice Applies token fee.  Override for tokens other than ELE.
     */
    function _applyFee(uint256 amount) internal pure virtual returns (uint256) {
        uint256 tFeeHalf = amount.div(200);
        uint256 tFee = tFeeHalf.mul(2);
        uint256 tTransferAmount = amount.sub(tFee); 
        return tTransferAmount;
    }

    /**
     * @notice Withdraw entire balance to the owner.
     */
    function withdraw() external onlyOwner() {
        uint256 amount = _token.balanceOf(address(this));
        require(amount > 0, "Treasury: no balance to withdraw");
        _token.safeTransfer(msg.sender, amount);
        _principle = 0;
    }

    /**
     * @notice Sets a new beneficiary.
     */
    function setBeneficiary(address newBeneficiary) external onlyOwner() {
        _beneficiary = newBeneficiary;
    }

    /**
     * @notice Transfers tokens to beneficiary.
     */
    function release() public {
        uint256 amount = fundsAvailable();
        require(amount > 0, 'Treasury: no funds to release');
        _token.safeTransfer(_beneficiary, amount);
    }
}
