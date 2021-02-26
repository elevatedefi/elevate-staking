pragma solidity >=0.6.0 <0.8.0;
pragma experimental ABIEncoderV2;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";
import "./ITREASURY.sol";
import "./TokenPool.sol";

contract ReflectiveStake is ReentrancyGuard{
    using SafeMath for uint256;

    event Staked(address indexed user, uint256 amount, uint256 total, bytes data);
    event Unstaked(address indexed user, uint256 amount, uint256 total, bytes data);
    event TokensClaimed(address indexed user, uint256 amount);
    event TokensLocked(uint256 amount, uint256 durationSec, uint256 total);
    event TokensUnlocked(uint256 amount, uint256 total);

    TokenPool private _stakingPool;
    TokenPool private _unlockedPool;
    ITREASURY private _reflectiveTreasury;

    uint256 public constant BONUS_DECIMALS = 2;
    uint256 public startBonus = 0;
    uint256 public bonusPeriodSec = 0;
    uint256 public lockupSec = 0;

    uint256 public totalStakingShares = 0;
    uint256 public totalStakingShareSeconds = 0;
    uint256 public lastAccountingTimestampSec = block.timestamp;
    uint256 private _initialSharesPerToken = 0;

    struct Stake {
        uint256 stakingShares;
        uint256 timestampSec;
    }

    struct UserTotals {
        uint256 stakingShares;
        uint256 stakingShareSeconds;
        uint256 lastAccountingTimestampSec;
    }

    mapping(address => UserTotals) private _userTotals;

    mapping(address => Stake[]) private _userStakes;

    /**
     * @param stakingToken The token users deposit as stake.
     * @param distributionToken The token users receive as they unstake.
     * @param reflectiveTreasury The address of the treasury contract that will fund the rewards.
     * @param startBonus_ Starting time bonus, BONUS_DECIMALS fixed point.
     *                    e.g. 25% means user gets 25% of max distribution tokens.
     * @param bonusPeriodSec_ Length of time for bonus to increase linearly to max.
     * @param initialSharesPerToken Number of shares to mint per staking token on first stake.
     * @param lockupSec_ Lockup period after staking.
     */
    constructor(IERC20 stakingToken, IERC20 distributionToken, ITREASURY reflectiveTreasury,
                uint256 startBonus_, uint256 bonusPeriodSec_, uint256 initialSharesPerToken, uint256 lockupSec_) public {
        // The start bonus must be some fraction of the max. (i.e. <= 100%)
        require(startBonus_ <= 10**BONUS_DECIMALS, 'ReflectiveStake: start bonus too high');
        // If no period is desired, instead set startBonus = 100%
        // and bonusPeriod to a small value like 1sec.
        require(bonusPeriodSec_ > 0, 'ReflectiveStake: bonus period is zero');
        require(initialSharesPerToken > 0, 'ReflectiveStake: initialSharesPerToken is zero');

        _stakingPool = new TokenPool(stakingToken);
        _unlockedPool = new TokenPool(distributionToken);
        _reflectiveTreasury = reflectiveTreasury;
        require(_unlockedPool.token() == _reflectiveTreasury.token(), 'ReflectiveStake: distribution token does not match treasury token');
        startBonus = startBonus_;
        bonusPeriodSec = bonusPeriodSec_;
        _initialSharesPerToken = initialSharesPerToken;
        lockupSec = lockupSec_;
    }

    function getStakingToken() public view returns (IERC20) {
        return _stakingPool.token();
    }

    function getDistributionToken() external view returns (IERC20) {
        return _unlockedPool.token();
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, 'ReflectiveStake: stake amount is zero');
        require(totalStakingShares == 0 || totalStaked() > 0,
                'ReflectiveStake: Invalid state. Staking shares exist, but no staking tokens do');

        // Get Actual Amount here minus TX fee
        uint256 transferAmount = _applyFee(amount);

        uint256 mintedStakingShares = (totalStakingShares > 0)
            ? totalStakingShares.mul(transferAmount).div(totalStaked())
            : transferAmount.mul(_initialSharesPerToken);
        require(mintedStakingShares > 0, 'ReflectiveStake: Stake amount is too small');

        updateAccounting();

        // 1. User Accounting
        UserTotals storage totals = _userTotals[msg.sender];
        totals.stakingShares = totals.stakingShares.add(mintedStakingShares);
        totals.lastAccountingTimestampSec = block.timestamp;

        Stake memory newStake = Stake(mintedStakingShares, block.timestamp);
        _userStakes[msg.sender].push(newStake);

        // 2. Global Accounting
        totalStakingShares = totalStakingShares.add(mintedStakingShares);

        // interactions
        require(_stakingPool.token().transferFrom(msg.sender, address(_stakingPool), amount),
            'ReflectiveStake: transfer into staking pool failed');

        emit Staked(msg.sender, transferAmount, totalStakedFor(msg.sender), "");
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

    function unstake(uint256 amount) external nonReentrant returns (uint256) {
        updateAccounting();
        return _unstake(amount);
    }

    function unstakeMax() external nonReentrant returns (uint256) {
        updateAccounting();
        return _unstake(totalStakedFor(msg.sender));
    }

    function _unstake(uint256 amount) private returns (uint256) {
        // checks
        require(amount > 0, 'ReflectiveStake: unstake amount is zero');
        require(totalStakedFor(msg.sender) >= amount,
            'ReflectiveStake: unstake amount is greater than total user stakes');
        uint256 stakingSharesToBurn = totalStakingShares.mul(amount).div(totalStaked());
        require(stakingSharesToBurn > 0, 'ReflectiveStake: Unable to unstake amount this small');

        // 1. User Accounting
        UserTotals storage totals = _userTotals[msg.sender];
        Stake[] storage accountStakes = _userStakes[msg.sender];

        Stake memory mostRecentStake = accountStakes[accountStakes.length - 1];
        require(block.timestamp.sub(mostRecentStake.timestampSec) > lockupSec, 'ReflectiveStake: Cannot unstake before the lockup period has expired');

        // Redeem from most recent stake and go backwards in time.
        uint256 stakingShareSecondsToBurn = 0;
        uint256 sharesLeftToBurn = stakingSharesToBurn;
        uint256 rewardAmount = 0;
        while (sharesLeftToBurn > 0) {
            Stake storage lastStake = accountStakes[accountStakes.length - 1];
            uint256 stakeTimeSec = block.timestamp.sub(lastStake.timestampSec);
            uint256 newStakingShareSecondsToBurn = 0;
            if (lastStake.stakingShares <= sharesLeftToBurn) {
                // fully redeem a past stake
                newStakingShareSecondsToBurn = lastStake.stakingShares.mul(stakeTimeSec);
                rewardAmount = computeNewReward(rewardAmount, newStakingShareSecondsToBurn, stakeTimeSec);
                stakingShareSecondsToBurn = stakingShareSecondsToBurn.add(newStakingShareSecondsToBurn);
                sharesLeftToBurn = sharesLeftToBurn.sub(lastStake.stakingShares);
                accountStakes.pop();
            } else {
                // partially redeem a past stake
                newStakingShareSecondsToBurn = sharesLeftToBurn.mul(stakeTimeSec);
                rewardAmount = computeNewReward(rewardAmount, newStakingShareSecondsToBurn, stakeTimeSec);
                stakingShareSecondsToBurn = stakingShareSecondsToBurn.add(newStakingShareSecondsToBurn);
                lastStake.stakingShares = lastStake.stakingShares.sub(sharesLeftToBurn);
                sharesLeftToBurn = 0;
            }
        }
        totals.stakingShareSeconds = totals.stakingShareSeconds.sub(stakingShareSecondsToBurn);
        totals.stakingShares = totals.stakingShares.sub(stakingSharesToBurn);

        // 2. Global Accounting
        totalStakingShareSeconds = totalStakingShareSeconds.sub(stakingShareSecondsToBurn);
        totalStakingShares = totalStakingShares.sub(stakingSharesToBurn);

        // interactions
        require(_stakingPool.transfer(msg.sender, amount),
            'ReflectiveStake: transfer out of staking pool failed');

        if (rewardAmount > 0) {
            require(_unlockedPool.transfer(msg.sender, rewardAmount),
                'ReflectiveStake: transfer out of unlocked pool failed');
        }


        emit Unstaked(msg.sender, amount, totalStakedFor(msg.sender), "");
        emit TokensClaimed(msg.sender, rewardAmount);

        require(totalStakingShares == 0 || totalStaked() > 0,
                "ReflectiveStake: Error unstaking. Staking shares exist, but no staking tokens do");
        return rewardAmount;
    }

    function computeNewReward(uint256 currentRewardTokens,
                                uint256 stakingShareSeconds,
                                uint256 stakeTimeSec) private view returns (uint256) {

        uint256 newRewardTokens =
            totalUnlocked()
            .mul(stakingShareSeconds)
            .div(totalStakingShareSeconds);

        if (stakeTimeSec >= bonusPeriodSec) {
            return currentRewardTokens.add(newRewardTokens);
        }

        uint256 oneHundredPct = 10**BONUS_DECIMALS;
        uint256 bonusedReward =
            startBonus
            .add(oneHundredPct.sub(startBonus).mul(stakeTimeSec).div(bonusPeriodSec))
            .mul(newRewardTokens)
            .div(oneHundredPct);
        return currentRewardTokens.add(bonusedReward);
    }

    function getUserStakes(address addr) external view returns (Stake[] memory){
        Stake[] memory userStakes = _userStakes[addr];
        return userStakes;
    }

    function getUserTotals(address addr) external view returns (UserTotals memory) {
        UserTotals memory userTotals = _userTotals[addr];
        return userTotals;
    }

    function totalStakedFor(address addr) public view returns (uint256) {
        return totalStakingShares > 0 ?
            totalStaked().mul(_userTotals[addr].stakingShares).div(totalStakingShares) : 0;
    }

    function totalStaked() public view returns (uint256) {
        return _stakingPool.balance();
    }

    function token() external view returns (address) {
        return address(getStakingToken());
    }

    function treasuryTarget() external view returns (address) {
        return address(_unlockedPool);
    }

    function updateAccounting() private returns (
        uint256, uint256, uint256, uint256, uint256, uint256) {

        unlockTokens();

        // Global accounting
        uint256 newStakingShareSeconds =
            block.timestamp
            .sub(lastAccountingTimestampSec)
            .mul(totalStakingShares);
        totalStakingShareSeconds = totalStakingShareSeconds.add(newStakingShareSeconds);
        lastAccountingTimestampSec = block.timestamp;

        // User Accounting
        UserTotals storage totals = _userTotals[msg.sender];
        uint256 newUserStakingShareSeconds =
            block.timestamp
            .sub(totals.lastAccountingTimestampSec)
            .mul(totals.stakingShares);
        totals.stakingShareSeconds =
            totals.stakingShareSeconds
            .add(newUserStakingShareSeconds);
        totals.lastAccountingTimestampSec = block.timestamp;

        uint256 totalUserRewards = (totalStakingShareSeconds > 0)
            ? totalUnlocked().mul(totals.stakingShareSeconds).div(totalStakingShareSeconds)
            : 0;

        return (
            totalPending(),
            totalUnlocked(),
            totals.stakingShareSeconds,
            totalStakingShareSeconds,
            totalUserRewards,
            block.timestamp
        );
    }

    function isUnlocked(address account) external view returns (bool) {
        if (totalStakedFor(account) == 0) return false;
        Stake[] memory accountStakes = _userStakes[account];
        Stake memory mostRecentStake = accountStakes[accountStakes.length - 1];
        return block.timestamp.sub(mostRecentStake.timestampSec) > lockupSec;
    }

    function totalPending() public view returns (uint256) {
        return _reflectiveTreasury.fundsAvailable();
    }

    function totalUnlocked() public view returns (uint256) {
        return _unlockedPool.balance();
    }

    function totalAvailable() external view returns (uint256) {
        return totalUnlocked().add(totalPending());
    }

    function unlockTokens() public {
        if (totalPending() > 0) _reflectiveTreasury.release();
    }
}
