// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";
import "../access/Governable.sol";

contract Oracle is Governable {
    uint256 public constant PRICE_BASE = 10**4;

    bool public isSpreadEnabled;

    mapping(uint256 => uint256) public prices;
    mapping(uint256 => address) public chainLinkTokenAddresses;
    mapping(uint256 => uint256) public lastUpdatedTimes;
    mapping(uint256 => uint256) public maxPriceDiffs;
    mapping(uint256 => uint256) public spreads;
    mapping(address => bool) public keepers;

    event SetPrice(uint256 productId, uint256 price, uint256 timestamp);
    event SetChainLinkTokenAddress(uint256 productId, address chainLinkTokenAddress);
    event SetMaxPriceDiff(uint256 productId, uint256 maxPriceDiff);
    event SetSpread(uint256 productId, uint256 spread);
    event SetIsSpreadEnabled(bool isSpreadEnabled);
    event SetKeeper(address keeper, bool isActive);

    modifier onlyKeeper() {
        require(keepers[msg.sender], "Oracle: !keeper");
        _;
    }

    function getPrice(uint256 productId) public view returns (uint256) {
        (uint256 price, ) = getPriceAndSource(productId);
        return price;
    }

    function getPrices(uint256[] memory productIds) external view returns (uint256[] memory _prices) {
        _prices = new uint256[](productIds.length);

        for (uint256 i = 0; i < productIds.length; ++i) {
            _prices[i] = getPrice(productIds[i]);
        }
    }

    function getPrice(uint256 productId, bool isLong) external view returns (uint256) {
        (uint256 price, bool isChainlink) = getPriceAndSource(productId);

        if (isSpreadEnabled || isChainlink) {
            return
                isLong
                    ? (price * (10**4 + spreads[productId])) / 10**4
                    : (price * (10**4 - spreads[productId])) / 10**4;
        }
        return price;
    }

    function getPriceAndSource(uint256 productId) public view returns (uint256, bool) {
        uint256 price = prices[productId];
        uint256 chainlinkPrice = getChainlinkPrice(productId);

        uint256 priceDiff = price > chainlinkPrice
            ? ((price - chainlinkPrice) * 1e18) / chainlinkPrice
            : ((chainlinkPrice - price) * 1e18) / chainlinkPrice;
        if (priceDiff > maxPriceDiffs[productId]) return (chainlinkPrice, true);
        return (price, false);
    }

    function getChainlinkPrice(uint256 productId) public view returns (uint256) {
        address chainLinkTokenAddress = chainLinkTokenAddresses[productId];
        require(chainLinkTokenAddress != address(0), "Oracle: zero address");

        (, int256 price, , uint256 timestamp, ) = AggregatorV3Interface(chainLinkTokenAddress).latestRoundData();
        require(price > 0, "Oracle: invalid chainlink price");
        require(timestamp > 0, "Oracle: invalid chainlink timestamp");

        uint8 decimals = AggregatorV3Interface(chainLinkTokenAddress).decimals();
        if (decimals == 8) return uint256(price);
        return (uint256(price) * (10**8)) / (10**uint256(decimals));
    }

    function setPrices(uint256[] memory productIds, uint256[] memory _prices) external onlyKeeper {
        require(productIds.length == _prices.length, "Oracle: lengths doesn't match");

        for (uint256 i = 0; i < productIds.length; ++i) {
            uint256 productId = productIds[i];
            prices[productId] = _prices[i];
            lastUpdatedTimes[productId] = block.timestamp;

            emit SetPrice(productId, _prices[i], block.timestamp);
        }
    }

    function setChainLinkTokenAddress(uint256 productId, address _chainLinkTokenAddress) external onlyGov {
        require(_chainLinkTokenAddress != address(0), "Oracle: invalid address");
        chainLinkTokenAddresses[productId] = _chainLinkTokenAddress;
        emit SetChainLinkTokenAddress(productId, _chainLinkTokenAddress);
    }

    function setMaxPriceDiff(uint256 productId, uint256 _maxPriceDiff) external onlyGov {
        require(_maxPriceDiff <= 5e16, "Oracle: maxPriceDiff cannot be larger than 5%");
        maxPriceDiffs[productId] = _maxPriceDiff;
        emit SetMaxPriceDiff(productId, _maxPriceDiff);
    }

    function setSpread(uint256 productId, uint256 _spread) external onlyGov {
        require(_spread <= 500, "Oracle: spread cannot be larger than 5%");
        spreads[productId] = _spread;
        emit SetSpread(productId, _spread);
    }

    function setIsSpreadEnabled(bool _isSpreadEnabled) external onlyGov {
        isSpreadEnabled = _isSpreadEnabled;
        emit SetIsSpreadEnabled(_isSpreadEnabled);
    }

    function setKeeper(address _keeper, bool _isActive) external onlyGov {
        keepers[_keeper] = _isActive;
        emit SetKeeper(_keeper, _isActive);
    }
}
