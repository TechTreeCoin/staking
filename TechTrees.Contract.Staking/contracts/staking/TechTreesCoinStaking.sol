// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/IPoint.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TechTreesCoinStaking is Ownable {
    using SafeERC20 for IERC20;

    event PoolAdded(address indexed operator, uint256 flags, uint256 factor, uint256 feeFreePeriod, uint256 lockPeriod);
    event Deposit(address indexed account, uint256 indexed poolId, uint256 value);
    event Withdraw(address indexed account, uint256 indexed poolId, uint256 value);
    event WithdrawPendingTokens(address indexed account, uint256 points, uint256 value);
    event EmergencyWithdraw(address indexed account, uint256 value);

    event Start(address indexed operator, uint256 powEndBlock);
    event StakingParameterChanged(address indexed operator, uint256 totalInjectedTokens, uint256 powTokensPerBlock, uint256 pointsPerBlock);
    event StakingInternalParameterChanged(address indexed operator, uint256 lastUpdateBlock, uint256 accTokensPerShare, uint256 accPointsPerEther);

    // TTC-10 remove unnecessary variables
    uint256 private constant fPoint = 1 << 0;
    uint256 private constant fTTC = 1 << 1;
    uint256 private constant fObsolete = 1 << 2;
    uint256 private constant blocksPerday = 20 * 60 * 24;
    uint256 private constant sqrt1EtherFBase = 1e10;
    uint256 private constant feePercentage = 95;
    uint256 private constant factorBase = 100;
    uint256 private constant acc1e12 = 1e12;

    struct Pool {
        uint8 flags;
        uint16 factor; // base 100
        uint32 feeFreePeriod; // fee free blocks
        uint32 lockPeriod; // lock blocks
        uint96 totalStake; // total
    }

    struct StakedShare {
        uint96 amount;
        uint32 lastDepositBlock;
        uint32 lastRewardBlock;
        uint128 powRewardDebt; // 256bits
        uint256 pointRewardDebt; // 256bits
    }

    bool public emergency;
    uint216 public accTokensPerShare;
    uint32 public lastUpdateBlock;
    // 256 bits
    uint32 public powEndBlock;
    uint96 public powTokensPerBlock;
    uint128 public powShareTotal;
    // 256 bits
    uint256 public totalStaked;
    uint256 public totalInjectedTokens;

    uint96 public pointsPerBlock;
    uint160 public accPointsPerEther;
    // 256 bits

    // pool => account => value
    mapping(address => mapping(uint256 => StakedShare)) private _userStakes;

    Pool[] public pools;

    IPoint public immutable ttPoint;
    IERC20 public immutable ttCoin;

    constructor(address ttPoint_, address ttCoin_) {
        ttPoint = IPoint(ttPoint_);
        ttCoin = IERC20(ttCoin_);
        _initPoolDev();
    }

    function setEmergency() external onlyOwner {
        emergency = true;
    }

    function _initPoolDev() private {
        pools.push(Pool({flags: uint8(fPoint), factor: 100, feeFreePeriod: uint32(blocksPerday * 7), lockPeriod: 0, totalStake: 0}));
        pools.push(Pool({flags: uint8(fTTC), factor: 100, feeFreePeriod: uint32(blocksPerday * 7), lockPeriod: 0, totalStake: 0}));
        pools.push(Pool({flags: uint8(fPoint | fTTC), factor: 150, feeFreePeriod: 0, lockPeriod: uint32(blocksPerday * 30), totalStake: 0}));
        pools.push(Pool({flags: uint8(fPoint | fTTC), factor: 200, feeFreePeriod: 0, lockPeriod: uint32(blocksPerday * 60), totalStake: 0}));
        pools.push(Pool({flags: uint8(fPoint | fTTC), factor: 400, feeFreePeriod: 0, lockPeriod: uint32(blocksPerday * 120), totalStake: 0}));
    }

    // can be done multiply time before started
    function injectPowTokensBeforeStart(
        uint256 powTokens,
        uint256 powTokensPerBlock_,
        uint256 pointsPerblock_
    ) external nonStarted onlyOwner {
        ttCoin.safeTransferFrom(msg.sender, address(this), powTokens);
        totalInjectedTokens += powTokens;
        powTokensPerBlock = uint96(powTokensPerBlock_);
        pointsPerBlock = uint96(pointsPerblock_);
        emit StakingParameterChanged(msg.sender, totalInjectedTokens, powTokensPerBlock, pointsPerBlock);
    }

    function start() external onlyOwner nonStarted {
        // make sure the contract has been injected enought tokens for staking
        require(totalInjectedTokens > 0, "not enought pow tokens");
        // confirm staking end block
        powEndBlock = uint32(block.number + totalInjectedTokens / powTokensPerBlock);
        // set last update block to current block
        lastUpdateBlock = uint32(block.number);
        emit Start(msg.sender, powEndBlock);
    }

    // can be called after staking is started in order to adjust dispatch ratio
    // it will change the end time of staking proceduce
    function setPowTokensPerBlock(uint256 powTokensPerBlock_) external started onlyOwner {
        require(powEndBlock > block.number, "already ended");
        _updateStakingParameter();
        uint256 restToken = (uint256(powEndBlock) - block.number) * powTokensPerBlock;
        powEndBlock = uint32(block.number + restToken / powTokensPerBlock_);
        powTokensPerBlock = uint96(powTokensPerBlock_);
        emit StakingParameterChanged(msg.sender, totalInjectedTokens, powTokensPerBlock, pointsPerBlock);
    }

    // can be called after staking is started in order to adjust dispatch ratio
    function setPointsPerBlock(uint256 pointsPerBlock_) external started onlyOwner {
        require(lastUpdateBlock > 0, "not started");
        require(powEndBlock > block.number, "already ended");
        _updateStakingParameter();
        pointsPerBlock = uint96(pointsPerBlock_);
        emit StakingParameterChanged(msg.sender, totalInjectedTokens, powTokensPerBlock, pointsPerBlock);
    }

    // can be called after staking is started in order to add more dispatchable tokens
    // it will change the end time of staking proceduce
    function addPowTokens(uint256 powTokens) external started onlyOwner {
        require(powEndBlock > block.number, "already ended");
        _updateStakingParameter();
        ttCoin.safeTransferFrom(msg.sender, address(this), powTokens);
        totalInjectedTokens += powTokens;
        uint256 restToken = (uint256(powEndBlock) - block.number) * powTokensPerBlock + powTokens;
        if (lastUpdateBlock > 0) powEndBlock = uint32(block.number + restToken / powTokensPerBlock);
        emit StakingParameterChanged(msg.sender, totalInjectedTokens, powTokensPerBlock, pointsPerBlock);
    }

    function restInjectedTokens() public view returns (uint256) {
        if (lastUpdateBlock == 0) return totalInjectedTokens;
        else return (powEndBlock - min(block.number, powEndBlock)) * powTokensPerBlock;
    }

    function flipPoolObsolete(uint256 pId) external onlyOwner {
        pools[pId].flags ^= uint8(fObsolete);
    }

    function addPool(
        uint8 flags,
        uint16 factor,
        uint32 feeFreePeriod,
        uint32 lockPeriod
    ) external onlyOwner {
        pools.push(Pool({flags: flags, factor: factor, feeFreePeriod: feeFreePeriod, lockPeriod: lockPeriod, totalStake: 0}));
        emit PoolAdded(msg.sender, flags, factor, feeFreePeriod, lockPeriod);
    }

    function poolCount() external view returns (uint256 count) {
        return pools.length;
    }

    // deposit
    function deposit(uint256 pId, uint256 value) external nonEmergency validPool(pId) {
        require(value > 0, "empty deposit is not allowed");
        // transfer-in tokens
        ttCoin.safeTransferFrom(msg.sender, address(this), value);

        // withdraw pending tokens(if any) then update global staking parameters
        (uint256 _accTokensPerShare, uint256 _accPointsPerEther) = _withdrawSinglePending(msg.sender, pId);
        powShareTotal += uint128((value * pools[pId].factor) / factorBase);
        totalStaked += value;

        // update user's staking parameters
        StakedShare storage stakedShare = _userStakes[msg.sender][pId];
        stakedShare.amount += uint96(value);
        stakedShare.lastDepositBlock = uint32(block.number);
        // recalculate the reward debt of points and tokens
        uint256 userStakeFactor = uint256(stakedShare.amount) * pools[pId].factor;
        stakedShare.powRewardDebt = uint128((userStakeFactor * _accTokensPerShare) / (factorBase * acc1e12));
        stakedShare.pointRewardDebt = uint128((sqrt(userStakeFactor) * _accPointsPerEther) / sqrt1EtherFBase);

        emit Deposit(msg.sender, pId, value);
    }

    function withdraw(uint256 pId, uint256 value) external nonEmergency {
        require(value > 0, "empty withdraw is not allowed");
        // check prerequirement
        StakedShare storage stakedShare = _userStakes[msg.sender][pId];
        require(value <= stakedShare.amount, "not enough to withdraw");
        require(block.number >= stakedShare.lastDepositBlock + pools[pId].lockPeriod, "not reach withdraw block");

        // withdraw pending tokens(if any) then update global staking parameters
        (uint256 _accTokensPerShare, uint256 _accPointsPerEther) = _withdrawSinglePending(msg.sender, pId);
        powShareTotal -= uint128((value * pools[pId].factor) / factorBase);
        totalStaked -= value;

        // update user's staking parameters
        stakedShare.amount -= uint96(value);
        uint256 userStakeFactor = uint256(stakedShare.amount) * pools[pId].factor;
        stakedShare.powRewardDebt = uint128((userStakeFactor * _accTokensPerShare) / (factorBase * acc1e12));
        stakedShare.pointRewardDebt = (sqrt(userStakeFactor) * _accPointsPerEther) / sqrt1EtherFBase;

        // transfer-out withdraw tokens
        // the penalty fee will be taken under some situation
        if (block.number < stakedShare.lastDepositBlock + pools[pId].feeFreePeriod) ttCoin.safeTransfer(msg.sender, (value * feePercentage) / factorBase);
        else ttCoin.safeTransfer(msg.sender, value);

        emit Withdraw(msg.sender, pId, value);
    }

    // do a loop to withdraw all pending tokens
    function withdrawAllPending() external nonEmergency {
        uint256 points;
        uint256 tokens;
        uint256 _poolCount = pools.length;
        for (uint256 index = 0; index < _poolCount; ++index) {
            (, , uint256 tempPoints, uint256 tempTokens) = _withdrawPending(msg.sender, index);
            points += tempPoints;
            tokens += tempTokens;
        }
        _withdrawTransfer(msg.sender, points, tokens);
    }

    function withdrawPending(uint256 pId) external nonEmergency {
        _withdrawSinglePending(msg.sender, pId);
    }

    function _withdrawSinglePending(address account, uint256 pId) private returns (uint256 _accTokensPerShare, uint256 _accPointsPerEther) {
        uint256 points;
        uint256 tokens;
        (_accTokensPerShare, _accPointsPerEther, points, tokens) = _withdrawPending(account, pId);
        _withdrawTransfer(account, points, tokens);
    }

    function _withdrawPending(address account, uint256 pId)
        private
        returns (
            uint256 _accTokensPerShare,
            uint256 _accPointsPerEther,
            uint256 points,
            uint256 tokens
        )
    {
        uint256 minBlock;
        StakedShare storage _stakeShare = _userStakes[account][pId];
        uint256 userStakeFactor = _stakeShare.amount * pools[pId].factor;
        // if user has some staking values
        if (userStakeFactor > 0) {
            // update global staking parameters
            (_accTokensPerShare, _accPointsPerEther, minBlock) = _updateStakingParameter();
            if ((pools[pId].flags & fPoint) > 0) {
                // points pending calculation
                uint256 _pending = (sqrt(userStakeFactor) * _accPointsPerEther) / sqrt1EtherFBase;
                points = _pending - _stakeShare.pointRewardDebt;
                _stakeShare.pointRewardDebt = _pending;
            }
            if ((pools[pId].flags & fTTC) > 0) {
                // token pending calculation
                uint256 _pending = (userStakeFactor * _accTokensPerShare) / (factorBase * acc1e12);
                tokens = _pending - _stakeShare.powRewardDebt;
                _stakeShare.powRewardDebt = uint128(_pending);
            }
        }
        _stakeShare.lastRewardBlock = uint32(minBlock);
    }

    function _withdrawTransfer(
        address to,
        uint256 points,
        uint256 tokens
    ) private {
        if (points > 0) ttPoint.mint(to, points);
        if (tokens > 0) ttCoin.safeTransfer(to, tokens);
        if (points > 0 || tokens > 0) emit WithdrawPendingTokens(to, points, tokens);
    }

    // fixes for TCK-01 emit events when internal parameter changes
    function _updateStakingParameter()
        private
        returns (
            uint256 _accTokensPerShare,
            uint256 _accPointsPerEther,
            uint256 minBlock
        )
    {
        _accTokensPerShare = accTokensPerShare;
        _accPointsPerEther = accPointsPerEther;
        // get the minor block of current block and staking end block to avoid the overflow of token dispatching
        minBlock = min(block.number, powEndBlock);
        // make sure staking is started and not yet finished
        if (lastUpdateBlock > 0 && minBlock > lastUpdateBlock) {
            uint256 diffBlocks = minBlock - lastUpdateBlock;
            // accumulate points
            _accPointsPerEther += diffBlocks * pointsPerBlock;
            accPointsPerEther = uint160(_accPointsPerEther);
            // update last update blocks
            lastUpdateBlock = uint32(minBlock);
            if (powShareTotal > 0) {
                // accumulate token dispatching parameters
                uint256 diff = powTokensPerBlock * diffBlocks;
                _accTokensPerShare += (diff * acc1e12) / powShareTotal;
                accTokensPerShare = uint216(_accTokensPerShare);
            }
            // emit event
            emit StakingInternalParameterChanged(msg.sender, minBlock, _accTokensPerShare, _accPointsPerEther);
        }
    }

    // fixes for TTC-04
    function emergencyWithdraw(uint256 pId) external underEmergency {
        require(emergency, "not in emergency");
        uint256 _poolCount = pools.length;
        uint256 value;
        for (uint256 index = 0; index < _poolCount; ++index) {
            uint256 oneAmount = _userStakes[msg.sender][pId].amount;
            if (oneAmount > 0) {
                // in case of emergency withdraw, modify deposited values
                value += oneAmount;
                _userStakes[msg.sender][pId].amount = 0;
            }
        }
        if (value > 0) {
            ttCoin.safeTransfer(msg.sender, value);
            totalStaked -= value;
            emit EmergencyWithdraw(msg.sender, value);
        }
    }

    // get user withdrawable tokens and point, base on _withdrawPending() algorithm, view only
    function pending(address account, uint256 pId) public view returns (uint256 points, uint256 tokens) {
        StakedShare storage _stakeShare = _userStakes[account][pId];
        uint256 userStakeFactor = _stakeShare.amount * pools[pId].factor;
        if (lastUpdateBlock > 0 && userStakeFactor > 0) {
            uint256 diffBlock = min(block.number, powEndBlock) - lastUpdateBlock;
            if ((pools[pId].flags & fPoint) > 0) {
                uint256 _accPointsPerEther = accPointsPerEther;
                _accPointsPerEther += diffBlock * pointsPerBlock;
                points = (sqrt(userStakeFactor) * _accPointsPerEther) / sqrt1EtherFBase - _stakeShare.pointRewardDebt;
            }
            if ((pools[pId].flags & fTTC) > 0 && powShareTotal > 0) {
                uint256 _accTokensPerShare = accTokensPerShare;
                _accTokensPerShare += (powTokensPerBlock * diffBlock * acc1e12) / powShareTotal;
                tokens = (userStakeFactor * _accTokensPerShare) / (factorBase * acc1e12) - _stakeShare.powRewardDebt;
            }
        }
    }

    function userStakes(address account, uint256 pId)
        external
        view
        returns (
            uint256 amount,
            uint256 feeFreeRestBlocks,
            uint256 lockRestBlocks,
            uint256 points,
            uint256 tokens
        )
    {
        amount = _userStakes[account][pId].amount;
        {
            uint256 withdrawBlock = _userStakes[account][pId].lastDepositBlock + pools[pId].lockPeriod;
            if (withdrawBlock > block.number) lockRestBlocks = withdrawBlock - block.number;
        }
        {
            uint256 feeFreeBlock = _userStakes[account][pId].lastDepositBlock + pools[pId].feeFreePeriod;
            if (feeFreeBlock > block.number) feeFreeRestBlocks = feeFreeBlock - block.number;
        }
        (points, tokens) = pending(account, pId);
    }

    function estimate(uint256 pId, uint256 value) public view returns (uint256 pointsPerBlock_, uint256 userStakeFactor_) {
        userStakeFactor_ = value * pools[pId].factor;
        if ((pools[pId].flags & fPoint) > 0) {
            pointsPerBlock_ = (sqrt(userStakeFactor_) * pointsPerBlock) / sqrt1EtherFBase;
        }
        if ((pools[pId].flags & fTTC) == 0) userStakeFactor_ = 0;
    }

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev uint256 sqrt function
     */
    function sqrt(uint256 x) public pure returns (uint256) {
        uint256 z = (x + 1) >> 1;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) >> 1;
        }
        return y;
    }

    modifier validPool(uint256 pId) {
        require((pools[pId].flags & fObsolete) == 0, "pool is obsolete");
        _;
    }

    modifier started() {
        require(lastUpdateBlock > 0, "not started");
        _;
    }

    modifier nonStarted() {
        require(lastUpdateBlock == 0, "already started");
        _;
    }

    modifier nonEmergency() {
        require(!emergency, "cannot perform under emergency");
        _;
    }

    modifier underEmergency() {
        require(emergency, "only under emergency");
        _;
    }
}
