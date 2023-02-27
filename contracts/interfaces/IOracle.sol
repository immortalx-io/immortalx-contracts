//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IOracle {
    function getPrice(uint256 productId) external view returns (uint256);

    function getPrice(uint256 productId, bool isLong) external view returns (uint256);

    function setPrices(uint256[] memory productIds, uint256[] memory prices) external;
}
