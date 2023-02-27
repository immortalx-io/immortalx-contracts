//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IDex {
    function stakeVaultToCompound(address user, uint256 amount) external;

    function openPosition(
        address user,
        uint256 productId,
        bool isLong,
        uint256 margin,
        uint256 leverage
    ) external;

    function validateOpenPositionRequirements(
        uint256 margin,
        uint256 leverage,
        uint256 productId
    ) external view;

    function closePosition(
        address user,
        uint256 productId,
        bool isLong,
        uint256 margin
    ) external;

    function liquidatePositions(bytes32[] calldata positionKeys) external;

    function distributeVaultReward() external returns (uint256);

    function distributeStakingReward() external returns (uint256);

    function getVaultShares() external view returns (uint256);

    function getStakeShares(address user) external view returns (uint256);

    function getPositionLeverage(
        address account,
        uint256 productId,
        bool isLong
    ) external view returns (uint256);

    function minMargin() external view returns (uint256);

    function totalProducts() external view returns (uint256);

    function getTradeFee(
        uint256 margin,
        uint256 leverage,
        uint256 productId
    ) external view returns (uint256);

    function getPendingVaultReward() external view returns (uint256);

    function getPendingStakingReward() external view returns (uint256);
}
