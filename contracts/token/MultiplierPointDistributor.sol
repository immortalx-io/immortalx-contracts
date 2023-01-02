// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../access/Governable.sol";
import "../interfaces/IRewardTracker.sol";
import "../interfaces/IRewardDistributor.sol";
import "../interfaces/IMultiplierPoint.sol";

contract MultiplierPointDistributor is IRewardDistributor, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public override rewardToken;
    address public rewardTracker; // sIMTX
    uint256 public override tokensPerInterval;
    uint256 public lastDistributionTime;
    uint256 public multiplierPointBP; // 1 = 0.01%

    event Distribute(uint256 amount);
    event MultiplierPointBPChange(uint256 amount);

    constructor(
        address _rewardToken,
        address _rewardTracker,
        uint256 _multiplierPointBP
    ) {
        rewardToken = _rewardToken;
        rewardTracker = _rewardTracker;
        multiplierPointBP = _multiplierPointBP;
    }

    function pendingRewards() public view override returns (uint256) {
        if (block.timestamp == lastDistributionTime) {
            return 0;
        }

        uint256 supply = IERC20(rewardTracker).totalSupply();
        uint256 timeDiff = block.timestamp.sub(lastDistributionTime);

        return timeDiff.mul(supply).mul(multiplierPointBP).div(10000).div(365 days);
    }

    function distribute() external override returns (uint256) {
        require(msg.sender == rewardTracker, "MPDistributor: !rewardTracker");
        uint256 amount = pendingRewards();
        if (amount == 0) {
            return 0;
        }

        lastDistributionTime = block.timestamp;

        IMultiplierPoint(rewardToken).mint(msg.sender, amount);

        emit Distribute(amount);
        return amount;
    }

    function updateLastDistributionTime() external onlyGov {
        lastDistributionTime = block.timestamp;
    }

    function setMultiplierPointRate(uint256 _multiplierPointBP) external onlyGov {
        require(lastDistributionTime != 0, "MPDistributor: invalid lastDistributionTime");
        IRewardTracker(rewardTracker).updateRewards();
        multiplierPointBP = _multiplierPointBP;
        emit MultiplierPointBPChange(_multiplierPointBP);
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(
        address _token,
        address _account,
        uint256 _amount
    ) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }
}
