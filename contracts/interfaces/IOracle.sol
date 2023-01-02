//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IOracle {
    function getPrice(address token) external view returns (uint256);

    function getPrice(address token, bool isMax) external view returns (uint256);

    function setPrices(address[] memory tokens, uint256[] memory prices) external;
}
