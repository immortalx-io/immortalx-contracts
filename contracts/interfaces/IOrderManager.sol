//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IOrderManager {
    function createCloseOrderForTPSL(
        address account,
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 size,
        uint256 triggerPrice
    ) external payable;

    function cancelActiveCloseOrders(
        address account,
        uint256 productId,
        bool isLong
    ) external;
}
