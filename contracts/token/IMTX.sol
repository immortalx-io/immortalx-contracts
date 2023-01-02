// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract IMTX is ERC20 {
    constructor(uint256 amount) ERC20("ImmortalX", "IMTX") {
        _mint(msg.sender, amount);
    }
}
