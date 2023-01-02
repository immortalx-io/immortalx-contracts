// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";
import "../access/Governable.sol";

contract Oracle is Governable {
    uint256 public constant PRICE_BASE = 10**4;

    bool public isSpreadEnabled;

    mapping(address => uint256) public tokenPrices;
    mapping(address => uint256) public lastUpdatedTimes;
    mapping(address => uint256) public maxPriceDiffs;
    mapping(address => uint256) public spreads;
    mapping(address => bool) public keepers;

    event SetPrice(address token, uint256 price, uint256 timestamp);
    event SetMaxPriceDiff(address token, uint256 maxPriceDiff);
    event SetSpread(address token, uint256 spread);
    event SetIsSpreadEnabled(bool isSpreadEnabled);
    event SetKeeper(address keeper, bool isActive);

    function getPrice(address token) public view returns (uint256) {
        (uint256 price, ) = getPriceAndSource(token);
        return price;
    }

    function getPrice(address token, bool isLong) external view returns (uint256) {
        (uint256 price, bool isChainlink) = getPriceAndSource(token);
        if (isSpreadEnabled || isChainlink) {
            return isLong ? (price * (10**4 + spreads[token])) / 10**4 : (price * (10**4 - spreads[token])) / 10**4;
        }
        return price;
    }

    function getPriceAndSource(address token) public view returns (uint256, bool) {
        uint256 chainlinkPrice = getChainlinkPrice(token);
        uint256 price = tokenPrices[token];

        uint256 priceDiff = price > chainlinkPrice
            ? ((price - chainlinkPrice) * 1e18) / chainlinkPrice
            : ((chainlinkPrice - price) * 1e18) / chainlinkPrice;
        if (priceDiff > maxPriceDiffs[token]) return (chainlinkPrice, true);
        return (price, false);
    }

    function getChainlinkPrice(address token) public view returns (uint256) {
        require(token != address(0), "Oracle: zero address");

        (, int256 price, , uint256 timestamp, ) = AggregatorV3Interface(token).latestRoundData();
        require(price > 0, "Oracle: invalid chainlink price");
        require(timestamp > 0, "Oracle: invalid chainlink timestamp");

        uint8 decimals = AggregatorV3Interface(token).decimals();
        if (decimals == 8) return uint256(price);
        return (uint256(price) * (10**8)) / (10**uint256(decimals));
    }

    function getPrices(address[] memory tokens) external view returns (uint256[] memory prices) {
        prices = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            prices[i] = getPrice(tokens[i]);
        }
    }

    function setPrices(address[] memory tokens, uint256[] memory prices) external onlyKeeper {
        require(tokens.length == prices.length, "Oracle: lengths doesn't match");
        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];
            tokenPrices[token] = prices[i];
            lastUpdatedTimes[token] = block.timestamp;
            emit SetPrice(token, prices[i], block.timestamp);
        }
    }

    function setMaxPriceDiff(address _token, uint256 _maxPriceDiff) external onlyGov {
        require(_maxPriceDiff <= 5e16, "Oracle: maxPriceDiff cannot be larger than 5%");
        maxPriceDiffs[_token] = _maxPriceDiff;
        emit SetMaxPriceDiff(_token, _maxPriceDiff);
    }

    function setSpread(address _token, uint256 _spread) external onlyGov {
        require(_spread <= 500, "Oracle: spread cannot be larger than 5%");
        spreads[_token] = _spread;
        emit SetSpread(_token, _spread);
    }

    function setIsSpreadEnabled(bool _isSpreadEnabled) external onlyGov {
        isSpreadEnabled = _isSpreadEnabled;
        emit SetIsSpreadEnabled(_isSpreadEnabled);
    }

    function setKeeper(address _keeper, bool _isActive) external onlyGov {
        keepers[_keeper] = _isActive;
        emit SetKeeper(_keeper, _isActive);
    }

    modifier onlyKeeper() {
        require(keepers[msg.sender], "Oracle: !keeper");
        _;
    }
}
