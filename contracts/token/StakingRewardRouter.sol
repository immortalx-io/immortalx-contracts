// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../access/Governable.sol";
import "../interfaces/IRewardTracker.sol";
import "../interfaces/IMultiplierPoint.sol";

contract StakingRewardRouter is ReentrancyGuard, Governable {
    using SafeERC20 for IERC20;

    address public immutable IMTX;
    address public immutable sIMTX;
    address public immutable msIMTX;
    address public immutable multiplierPoint;

    event StakeIMTX(address account, uint256 amount);
    event UnstakeIMTX(address account, uint256 amount);

    constructor(
        address _IMTX,
        address _sIMTX,
        address _msIMTX,
        address _multiplierPoint
    ) {
        IMTX = _IMTX;
        sIMTX = _sIMTX;
        msIMTX = _msIMTX;
        multiplierPoint = _multiplierPoint;
    }

    function stakeIMTX(uint256 _amount) external nonReentrant {
        _stakeIMTX(msg.sender, msg.sender, IMTX, _amount);
    }

    function unstakeIMTX(uint256 _amount) external nonReentrant {
        _unstakeIMTX(msg.sender, IMTX, _amount);
    }

    function unstakeIMTXAndClaimReward(uint256 _amount) external nonReentrant {
        _unstakeIMTX(msg.sender, IMTX, _amount);
        IRewardTracker(msIMTX).claimForAccount(msg.sender, msg.sender);
    }

    function claimReward() external nonReentrant {
        IRewardTracker(msIMTX).claimForAccount(msg.sender, msg.sender);
    }

    function claimRewardsAndStakeMP() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(msIMTX).claimForAccount(account, account);

        uint256 multiplierPointAmount = IRewardTracker(sIMTX).claimForAccount(account, account);
        if (multiplierPointAmount > 0) {
            IRewardTracker(msIMTX).stakeForAccount(account, account, multiplierPoint, multiplierPointAmount);
        }
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(
        address _token,
        address _account,
        uint256 _amount
    ) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function _stakeIMTX(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount
    ) private {
        require(_amount > 0, "StakingRewardRouter: invalid _amount");

        IRewardTracker(sIMTX).stakeForAccount(_fundingAccount, _account, _token, _amount);
        IRewardTracker(msIMTX).stakeForAccount(_account, _account, sIMTX, _amount);

        emit StakeIMTX(_account, _amount);
    }

    function _unstakeIMTX(
        address _account,
        address _token,
        uint256 _amount
    ) private {
        require(_amount > 0, "StakingRewardRouter: invalid _amount");

        uint256 balance = IRewardTracker(sIMTX).stakedAmounts(_account);

        IRewardTracker(msIMTX).unstakeForAccount(_account, sIMTX, _amount, _account);
        IRewardTracker(sIMTX).unstakeForAccount(_account, _token, _amount, _account);

        uint256 multiplierPointAmount = IRewardTracker(sIMTX).claimForAccount(_account, _account);
        if (multiplierPointAmount > 0) {
            IRewardTracker(msIMTX).stakeForAccount(_account, _account, multiplierPoint, multiplierPointAmount);
        }

        uint256 stakedMultiplierPoint = IRewardTracker(msIMTX).depositBalances(_account, multiplierPoint);
        if (stakedMultiplierPoint > 0) {
            uint256 reductionAmount = (stakedMultiplierPoint * _amount) / balance;
            IRewardTracker(msIMTX).unstakeForAccount(_account, multiplierPoint, reductionAmount, _account);
            IMultiplierPoint(multiplierPoint).burn(_account, reductionAmount);
        }

        emit UnstakeIMTX(_account, _amount);
    }
}
