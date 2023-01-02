// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IReferralManager {
    function getReferrerInfo(address _account)
        external
        view
        returns (
            address,
            uint256,
            uint256
        );
}
