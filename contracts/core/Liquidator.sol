// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../access/Governable.sol";
import "../interfaces/IDex.sol";
import "../interfaces/IOracle.sol";

contract Liquidator is Governable {
    address public immutable dex;
    address public immutable oracle;

    mapping(address => bool) public isKeeper;

    event SetKeeper(address keeper, bool isActive);

    modifier onlyKeeper() {
        require(isKeeper[msg.sender], "Liquidator: !keeper");
        _;
    }

    constructor(address _dex, address _oracle) {
        dex = _dex;
        oracle = _oracle;
    }

    function liquidateWithPrices(
        address[] memory tokens,
        uint256[] memory prices,
        bytes32[] calldata positionKeys
    ) external onlyKeeper {
        IOracle(oracle).setPrices(tokens, prices);
        IDex(dex).liquidatePositions(positionKeys);
    }

    function setKeeper(address _account, bool _isActive) external onlyGov {
        isKeeper[_account] = _isActive;
        emit SetKeeper(_account, _isActive);
    }
}
