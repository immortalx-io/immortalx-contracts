// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../access/Governable.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IDex.sol";

contract OrderManager is ReentrancyGuard, Governable {
    using SafeERC20 for IERC20;

    struct OpenOrder {
        address account;
        bool isLong;
        bool isTriggerAbove;
        uint256 productId;
        uint256 margin;
        uint256 leverage;
        uint256 tradeFee;
        uint256 triggerPrice;
        uint256 tpPrice;
        uint256 slPrice;
        uint256 timestamp;
    }
    struct CloseOrder {
        address account;
        bool isLong;
        bool isTriggerAbove;
        uint256 productId;
        uint256 size;
        uint256 triggerPrice;
        uint256 timestamp;
    }

    address public immutable dex;
    address public immutable oracle;
    address public immutable collateralToken;

    uint256 public maxOpenOrders = 8;
    uint256 public maxCloseOrders = 8;
    uint256 public minMargin = 25 * BASE;
    uint256 private immutable tokenBase;
    uint256 private constant BASE = 10**8;

    mapping(bytes32 => OpenOrder) public openOrders;
    mapping(bytes32 => CloseOrder) public closeOrders;
    mapping(address => bool) public isKeeper;

    event CreateOpenOrder(
        bytes32 indexed orderKey,
        address indexed account,
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 tradeFee,
        uint256 triggerPrice,
        uint256 tpPrice,
        uint256 slPrice,
        uint256 timestamp
    );
    event EditOpenOrder(
        bytes32 indexed orderKey,
        address indexed account,
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 tradeFee,
        uint256 triggerPrice,
        uint256 tpPrice,
        uint256 slPrice,
        uint256 timestamp
    );
    event CancelOpenOrder(
        bytes32 indexed orderKey,
        address indexed account,
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 tradeFee,
        uint256 triggerPrice,
        uint256 tpPrice,
        uint256 slPrice,
        uint256 timestamp
    );
    event ExecuteOpenOrder(
        bytes32 indexed orderKey,
        address indexed account,
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 tradeFee,
        uint256 triggerPrice,
        uint256 tpPrice,
        uint256 slPrice,
        uint256 timestamp,
        uint256 executionPrice
    );
    event CreateCloseOrder(
        bytes32 indexed orderKey,
        address indexed account,
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 size,
        uint256 triggerPrice,
        uint256 timestamp
    );
    event EditCloseOrder(
        bytes32 indexed orderKey,
        address indexed account,
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 size,
        uint256 triggerPrice,
        uint256 timestamp
    );
    event CancelCloseOrder(
        bytes32 indexed orderKey,
        address indexed account,
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 size,
        uint256 triggerPrice,
        uint256 timestamp
    );
    event ExecuteCloseOrder(
        bytes32 indexed orderKey,
        address indexed account,
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 size,
        uint256 triggerPrice,
        uint256 timestamp,
        uint256 executionPrice
    );
    event ExecuteOpenOrderError(bytes32 indexed orderKey, address indexed account, string executionError);
    event ExecuteCloseOrderError(bytes32 indexed orderKey, address indexed account, string executionError);
    event SetKeeper(address keeper, bool isActive);

    modifier onlyKeeper() {
        require(isKeeper[msg.sender], "OrderManager: !keeper");
        _;
    }

    constructor(
        address _dex,
        address _oracle,
        address _collateralToken,
        uint256 _tokenBase
    ) {
        dex = _dex;
        oracle = _oracle;
        collateralToken = _collateralToken;
        tokenBase = _tokenBase;

        isKeeper[address(this)] = true;
    }

    function createOpenOrder(
        uint256 productId,
        bool isLong,
        bool isTriggerAbove,
        uint256 margin,
        uint256 leverage,
        uint256 triggerPrice,
        uint256 tpPrice,
        uint256 slPrice
    ) external nonReentrant {
        _createOpenOrder(
            msg.sender,
            isLong,
            isTriggerAbove,
            productId,
            margin,
            leverage,
            triggerPrice,
            tpPrice,
            slPrice
        );
    }

    function _createOpenOrder(
        address account,
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 triggerPrice,
        uint256 tpPrice,
        uint256 slPrice
    ) private {
        require(margin >= minMargin, "OrderManager: !minMargin");
        require(triggerPrice > 0, "OrderManager: triggerPrice cannot be 0");
        _validateOrderPrices(isLong, triggerPrice, tpPrice, slPrice);
        uint256 _maxOpenOrders = maxOpenOrders;

        for (uint256 i = 0; i < _maxOpenOrders; ++i) {
            bytes32 orderKey = getOrderKey(account, productId, isLong, i);

            if (openOrders[orderKey].account == address(0)) {
                if (IDex(dex).isPositionExists(account, productId, isLong)) {
                    require(tpPrice == 0 && slPrice == 0, "OrderManager: tp/sl unavailable");
                }

                uint256 tradeFee = IDex(dex).getTradeFee(margin, leverage, productId);
                IERC20(collateralToken).safeTransferFrom(
                    account,
                    address(this),
                    ((margin + tradeFee) * tokenBase) / 10**8
                );

                openOrders[orderKey] = OpenOrder(
                    account,
                    isLong,
                    isTriggerAbove,
                    productId,
                    margin,
                    leverage,
                    tradeFee,
                    triggerPrice,
                    tpPrice,
                    slPrice,
                    block.timestamp
                );

                emit CreateOpenOrder(
                    orderKey,
                    account,
                    isLong,
                    isTriggerAbove,
                    productId,
                    margin,
                    leverage,
                    tradeFee,
                    triggerPrice,
                    tpPrice,
                    slPrice,
                    block.timestamp
                );

                return;
            }
        }

        revert("OrderManager: maxOpenOrders exceeded");
    }

    function editOpenOrder(
        bytes32 orderKey,
        uint256 triggerPrice,
        uint256 tpPrice,
        uint256 slPrice
    ) external nonReentrant {
        OpenOrder storage order = openOrders[orderKey];
        require(order.account == msg.sender, "OrderManager: !order.account");

        if (triggerPrice > 0) order.triggerPrice = triggerPrice;
        if (tpPrice > 0) order.tpPrice = tpPrice;
        if (slPrice > 0) order.slPrice = slPrice;

        _validateOrderPrices(order.isLong, order.triggerPrice, order.tpPrice, order.slPrice);

        order.timestamp = block.timestamp;

        emit EditOpenOrder(
            orderKey,
            order.account,
            order.isLong,
            order.isTriggerAbove,
            order.productId,
            order.margin,
            order.leverage,
            order.tradeFee,
            order.triggerPrice,
            order.tpPrice,
            order.slPrice,
            order.timestamp
        );
    }

    function cancelOpenOrder(bytes32 orderKey) public nonReentrant {
        OpenOrder memory order = openOrders[orderKey];
        require(order.account == msg.sender, "OrderManager: !order.account");

        delete openOrders[orderKey];
        IERC20(collateralToken).safeTransfer(msg.sender, ((order.margin + order.tradeFee) * tokenBase) / 10**8);

        emit CancelOpenOrder(
            orderKey,
            order.account,
            order.isLong,
            order.isTriggerAbove,
            order.productId,
            order.margin,
            order.leverage,
            order.tradeFee,
            order.triggerPrice,
            order.tpPrice,
            order.slPrice,
            order.timestamp
        );
    }

    function executeOpenOrder(bytes32 orderKey) public onlyKeeper {
        OpenOrder memory order = openOrders[orderKey];
        require(order.account != address(0), "OrderManager: non-existent order");

        (uint256 currentPrice, ) = validateExecutionPrice(
            order.isLong,
            order.isTriggerAbove,
            order.triggerPrice,
            order.productId
        );

        delete openOrders[orderKey];

        IERC20(collateralToken).safeApprove(dex, 0);
        IERC20(collateralToken).safeApprove(dex, ((order.margin + order.tradeFee) * tokenBase) / 10**8);
        IDex(dex).openPosition(order.account, order.productId, order.isLong, order.margin, order.leverage);

        if (order.tpPrice != 0) {
            _createCloseOrder(
                order.account,
                order.isLong,
                order.isLong,
                order.productId,
                order.margin * order.leverage, // use a larger amount to close the position fully
                order.tpPrice
            );
        }
        if (order.slPrice != 0) {
            _createCloseOrder(
                order.account,
                order.isLong,
                !order.isLong,
                order.productId,
                order.margin * order.leverage,
                order.slPrice
            );
        }

        emit ExecuteOpenOrder(
            orderKey,
            order.account,
            order.isLong,
            order.isTriggerAbove,
            order.productId,
            order.margin,
            order.leverage,
            order.tradeFee,
            order.triggerPrice,
            order.tpPrice,
            order.slPrice,
            order.timestamp,
            currentPrice
        );
    }

    function createCloseOrder(
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 size,
        uint256 triggerPrice
    ) external nonReentrant {
        _createCloseOrder(msg.sender, isLong, isTriggerAbove, productId, size, triggerPrice);
    }

    function _createCloseOrder(
        address account,
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 size,
        uint256 triggerPrice
    ) private {
        require(triggerPrice > 0, "OrderManager: triggerPrice cannot be 0");
        uint256 _maxCloseOrders = maxCloseOrders;

        for (uint256 i = 0; i < _maxCloseOrders; ++i) {
            bytes32 orderKey = getOrderKey(account, productId, isLong, i);

            if (closeOrders[orderKey].account == address(0)) {
                closeOrders[orderKey] = CloseOrder(
                    account,
                    isLong,
                    isTriggerAbove,
                    productId,
                    size,
                    triggerPrice,
                    block.timestamp
                );

                emit CreateCloseOrder(
                    orderKey,
                    account,
                    isLong,
                    isTriggerAbove,
                    productId,
                    size,
                    triggerPrice,
                    block.timestamp
                );

                return;
            }
        }

        revert("OrderManager: maxCloseOrders exceeded");
    }

    function editCloseOrder(bytes32 orderKey, uint256 triggerPrice) external nonReentrant {
        CloseOrder storage order = closeOrders[orderKey];
        require(order.account == msg.sender, "OrderManager: !order.account");

        order.triggerPrice = triggerPrice;
        order.timestamp = block.timestamp;

        emit EditCloseOrder(
            orderKey,
            order.account,
            order.isLong,
            order.isTriggerAbove,
            order.productId,
            order.size,
            order.triggerPrice,
            order.timestamp
        );
    }

    function cancelCloseOrder(bytes32 orderKey) public nonReentrant {
        require(closeOrders[orderKey].account == msg.sender, "OrderManager: !order.account");
        _cancelCloseOrder(orderKey);
    }

    function cancelPositionCloseOrders(
        address account,
        uint256 productId,
        bool isLong
    ) external {
        require(msg.sender == dex, "OrderManager: !dex");
        uint256 _maxCloseOrders = maxCloseOrders;

        for (uint256 i = 0; i < _maxCloseOrders; ++i) {
            bytes32 orderKey = getOrderKey(account, productId, isLong, i);

            if (closeOrders[orderKey].account != address(0)) {
                _cancelCloseOrder(orderKey);
            }
        }
    }

    function _cancelCloseOrder(bytes32 orderKey) private {
        CloseOrder memory order = closeOrders[orderKey];

        delete closeOrders[orderKey];

        emit CancelCloseOrder(
            orderKey,
            order.account,
            order.isLong,
            order.isTriggerAbove,
            order.productId,
            order.size,
            order.triggerPrice,
            order.timestamp
        );
    }

    function executeCloseOrder(bytes32 orderKey) public onlyKeeper {
        CloseOrder memory order = closeOrders[orderKey];
        require(order.account != address(0), "OrderManager: non-existent order");

        (uint256 currentPrice, ) = validateExecutionPrice(
            !order.isLong,
            order.isTriggerAbove,
            order.triggerPrice,
            order.productId
        );

        delete closeOrders[orderKey];

        IDex(dex).closePosition(
            order.account,
            order.productId,
            order.isLong,
            (order.size * 10**8) / IDex(dex).getPositionLeverage(order.account, order.productId, order.isLong)
        );

        emit ExecuteCloseOrder(
            orderKey,
            order.account,
            order.isLong,
            order.isTriggerAbove,
            order.productId,
            order.size,
            order.triggerPrice,
            order.timestamp,
            currentPrice
        );
    }

    function executeOrdersWithPrices(
        address[] memory tokens,
        uint256[] memory prices,
        bytes32[] memory openOrderKeys,
        bytes32[] memory closeOrderKeys
    ) external onlyKeeper {
        IOracle(oracle).setPrices(tokens, prices);

        for (uint256 i = 0; i < openOrderKeys.length; ++i) {
            try this.executeOpenOrder(openOrderKeys[i]) {} catch Error(string memory executionError) {
                emit ExecuteOpenOrderError(openOrderKeys[i], openOrders[openOrderKeys[i]].account, executionError);
            } catch (bytes memory) {}
        }
        for (uint256 i = 0; i < closeOrderKeys.length; ++i) {
            try this.executeCloseOrder(closeOrderKeys[i]) {} catch Error(string memory executionError) {
                emit ExecuteCloseOrderError(closeOrderKeys[i], closeOrders[closeOrderKeys[i]].account, executionError);
            } catch (bytes memory) {}
        }
    }

    function cancelMultipleOrders(bytes32[] memory openOrderKeys, bytes32[] memory closeOrderKeys) external {
        for (uint256 i = 0; i < openOrderKeys.length; ++i) {
            cancelOpenOrder(openOrderKeys[i]);
        }
        for (uint256 i = 0; i < closeOrderKeys.length; ++i) {
            cancelCloseOrder(closeOrderKeys[i]);
        }
    }

    function _validateOrderPrices(
        bool isLong,
        uint256 triggerPrice,
        uint256 tpPrice,
        uint256 slPrice
    ) private pure {
        if (isLong) {
            if (tpPrice > 0) require(triggerPrice < tpPrice, "OrderManager: long => triggerPrice < tpPrice");
            if (slPrice > 0) require(triggerPrice > slPrice, "OrderManager: long => triggerPrice > slPrice");
        } else {
            if (tpPrice > 0) require(triggerPrice > tpPrice, "OrderManager: short => triggerPrice > tpPrice");
            if (slPrice > 0) require(triggerPrice < slPrice, "OrderManager: short => triggerPrice < slPrice");
        }
    }

    function validateExecutionPrice(
        bool isLong,
        bool isTriggerAbove,
        uint256 triggerPrice,
        uint256 productId
    ) public view returns (uint256, bool) {
        address productToken = IDex(dex).getProductToken(productId);
        uint256 currentPrice = IOracle(oracle).getPrice(productToken, isLong);
        bool isPriceValid = isTriggerAbove ? currentPrice >= triggerPrice : currentPrice <= triggerPrice;
        require(isPriceValid, "OrderManager: invalid price for execution");
        return (currentPrice, isPriceValid);
    }

    function getOrderKey(
        address account,
        uint256 productId,
        bool isLong,
        uint256 orderIndex
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, productId, isLong, orderIndex));
    }

    function getOpenOrder(
        address account,
        uint256 productId,
        bool isLong,
        uint256 orderIndex
    )
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            bool,
            uint256,
            uint256,
            uint256
        )
    {
        OpenOrder memory order = openOrders[getOrderKey(account, productId, isLong, orderIndex)];
        return (
            order.margin,
            order.leverage,
            order.tradeFee,
            order.triggerPrice,
            order.isTriggerAbove,
            order.tpPrice,
            order.slPrice,
            order.timestamp
        );
    }

    function getCloseOrder(
        address account,
        uint256 productId,
        bool isLong,
        uint256 orderIndex
    )
        external
        view
        returns (
            uint256,
            uint256,
            bool,
            uint256
        )
    {
        CloseOrder memory order = closeOrders[getOrderKey(account, productId, isLong, orderIndex)];
        return (order.size, order.triggerPrice, order.isTriggerAbove, order.timestamp);
    }

    function getUserOpenOrderKeys(address account) external view returns (bytes32[] memory userOpenOrderKeys) {
        uint256 totalProducts = IDex(dex).totalProducts();
        uint256 _maxOpenOrders = maxOpenOrders;
        userOpenOrderKeys = new bytes32[](totalProducts * _maxOpenOrders * 2);
        bytes32 orderKey;
        uint256 count;

        for (uint256 i = 1; i <= totalProducts; ++i) {
            for (uint256 j = 0; j < _maxOpenOrders; ++j) {
                orderKey = getOrderKey(account, i, true, j);
                if (openOrders[orderKey].account != address(0)) userOpenOrderKeys[count++] = orderKey;

                orderKey = getOrderKey(account, i, false, j);
                if (openOrders[orderKey].account != address(0)) userOpenOrderKeys[count++] = orderKey;
            }
        }
    }

    function getUserCloseOrderKeys(address account) external view returns (bytes32[] memory userCloseOrderKeys) {
        uint256 totalProducts = IDex(dex).totalProducts();
        uint256 _maxCloseOrders = maxCloseOrders;
        userCloseOrderKeys = new bytes32[](totalProducts * _maxCloseOrders * 2);
        bytes32 orderKey;
        uint256 count;

        for (uint256 i = 1; i <= totalProducts; ++i) {
            for (uint256 j = 0; j < _maxCloseOrders; ++j) {
                orderKey = getOrderKey(account, i, true, j);
                if (closeOrders[orderKey].account != address(0)) userCloseOrderKeys[count++] = orderKey;

                orderKey = getOrderKey(account, i, false, j);
                if (closeOrders[orderKey].account != address(0)) userCloseOrderKeys[count++] = orderKey;
            }
        }
    }

    function setMinMargin(uint256 _minMargin) external onlyGov {
        require(_minMargin <= 25 * BASE);
        minMargin = _minMargin;
    }

    function setMaxOrders(uint256 _maxOpenOrders, uint256 _maxCloseOrders) external onlyGov {
        require(maxOpenOrders >= 5 && maxCloseOrders >= 5);
        maxOpenOrders = _maxOpenOrders;
        maxCloseOrders = _maxCloseOrders;
    }

    function setKeeper(address _account, bool _isActive) external onlyGov {
        isKeeper[_account] = _isActive;
        emit SetKeeper(_account, _isActive);
    }
}
