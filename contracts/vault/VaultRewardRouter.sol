// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../interfaces/IVaultReward.sol";
import "../interfaces/IVaultRewardRouter.sol";

contract VaultRewardRouter is IVaultRewardRouter {
    IVaultReward public immutable vaultFeeRewardRouter;

    constructor(address _vaultFeeRewardRouter) {
        vaultFeeRewardRouter = IVaultReward(_vaultFeeRewardRouter);
    }

    function updateRewards(address account) external override {
        vaultFeeRewardRouter.updateReward(account);
    }
}
