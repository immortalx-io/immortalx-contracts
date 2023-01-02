// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IDex.sol";
import "../interfaces/IVaultReward.sol";

contract VaultFeeRewardRouter is IVaultReward, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable dex;
    address public immutable rewardToken;
    uint256 public immutable rewardTokenBase;

    uint256 public cumulativeRewardPerTokenStored;

    mapping(address => uint256) private claimableReward;
    mapping(address => uint256) private previousRewardPerToken;

    uint256 private locked = 1;

    uint256 public constant PRECISION = 10**18;
    uint256 public constant BASE = 10**8;

    event ClaimReward(address user, address rewardToken, uint256 amount);
    event CompoundReward(address user, address rewardToken, uint256 amount);

    constructor(
        address _dex,
        address _rewardToken,
        uint256 _rewardTokenBase
    ) {
        dex = _dex;
        rewardToken = _rewardToken;
        rewardTokenBase = _rewardTokenBase;
    }

    function getClaimableReward(address account) external view returns (uint256) {
        uint256 currentClaimableReward = claimableReward[account];
        uint256 supply = IDex(dex).getVaultShares();
        if (supply == 0) return currentClaimableReward;

        uint256 _pendingReward = IDex(dex).getPendingVaultReward();
        uint256 _rewardPerTokenStored = cumulativeRewardPerTokenStored + (_pendingReward * 10**18) / supply;
        if (_rewardPerTokenStored == 0) return currentClaimableReward;

        return
            currentClaimableReward +
            (IDex(dex).getStakeShares(account) * (_rewardPerTokenStored - previousRewardPerToken[account])) /
            10**18;
    }

    function claimReward() external nonReentrant returns (uint256 rewardToSend) {
        _updateReward(msg.sender);
        rewardToSend = claimableReward[msg.sender];
        claimableReward[msg.sender] = 0;

        if (rewardToSend > 0) {
            IERC20(rewardToken).safeTransfer(msg.sender, rewardToSend);
            emit ClaimReward(msg.sender, rewardToken, rewardToSend);
        }
    }

    function compoundReward() external nonReentrant returns (uint256 reinvestAmount) {
        _updateReward(msg.sender);
        reinvestAmount = claimableReward[msg.sender];
        claimableReward[msg.sender] = 0;

        if (reinvestAmount > 0) {
            IERC20(rewardToken).safeApprove(dex, 0);
            IERC20(rewardToken).safeApprove(dex, reinvestAmount);
            IDex(dex).stakeVaultToCompound(msg.sender, (reinvestAmount * 10**8) / rewardTokenBase);

            emit CompoundReward(msg.sender, rewardToken, reinvestAmount);
        }
    }

    function updateReward(address account) external override {
        require(locked == 1, "REENTRANCY");
        locked = 2;
        _updateReward(account);
        locked = 1;
    }

    function _updateReward(address account) private {
        if (account == address(0)) return;
        uint256 vaultReward = IDex(dex).distributeVaultReward();
        uint256 supply = IDex(dex).getVaultShares();

        if (supply > 0) {
            cumulativeRewardPerTokenStored += (vaultReward * 10**18) / supply;
        }
        if (cumulativeRewardPerTokenStored == 0) return;

        claimableReward[account] +=
            (IDex(dex).getStakeShares(account) * (cumulativeRewardPerTokenStored - previousRewardPerToken[account])) /
            10**18;
        previousRewardPerToken[account] = cumulativeRewardPerTokenStored;
    }
}
