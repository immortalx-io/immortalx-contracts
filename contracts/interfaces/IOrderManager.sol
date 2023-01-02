//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IOrderManager {
    function cancelPositionCloseOrders(
        address account,
        uint256 productId,
        bool isLong
    ) external;
}
