// SPDX-License-Identifier: GPL-3.0-only

pragma solidity >=0.6.0 <0.8.0;
pragma experimental ABIEncoderV2;

import "./ReflectiveStake.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";

contract RFIStake is ReflectiveStake {
    using SafeMath for uint256;

    constructor(IERC20 stakingToken, IERC20 distributionToken, ITREASURY reflectiveTreasury,
    uint256 startBonus_, uint256 bonusPeriodSec_, uint256 initialSharesPerToken, uint256 lockupSec_)
    ReflectiveStake(stakingToken, distributionToken, reflectiveTreasury, startBonus_, bonusPeriodSec_, initialSharesPerToken, lockupSec_)
    public {}

    function _applyFee(uint256 amount) internal pure override returns (uint256) {
        uint256 tFee = amount.div(100);
        uint256 tTransferAmount = amount.sub(tFee);
        return tTransferAmount;
    }

}