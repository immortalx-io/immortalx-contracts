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

    bool public isInitialized;

    address public positionManager;
    address public immutable dex;
    address public immutable oracle;
    address public immutable collateralToken;

    uint256 public maxOpenOrders = 8;
    uint256 public maxCloseOrders = 8;
    uint256 public executionFee = 1e15;
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
    event ExecutionFeeRefundError(address indexed account, uint256 totalExecutionFee);
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

    function initialize(address _positionManager) external onlyGov {
        require(!isInitialized, "OrderManager: already initialized");
        isInitialized = true;

        positionManager = _positionManager;
    }

    function createOpenOrder(
        uint256 productId,
        bool isLong,
        bool isTriggerAbove,
        uint256 margin,
        uint256 leverage,
        uint256 triggerPrice,
        uint256 tpPrice, // no tp set if tpPrice == 0
        uint256 slPrice // no sl set if slPrice == 0
    ) external payable nonReentrant {
        uint256 numOfExecutions = 1;
        if (tpPrice > 0) numOfExecutions += 2;
        if (slPrice > 0) numOfExecutions += 2;
        require(msg.value == executionFee * numOfExecutions, "OrderManager: invalid executionFee");
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
        IDex(dex).validateOpenPositionRequirements(margin, leverage, productId);

        uint256 _maxOpenOrders = maxOpenOrders;
        for (uint256 i = 0; i < _maxOpenOrders; ++i) {
            bytes32 orderKey = getOrderKey(account, productId, isLong, i);

            if (openOrders[orderKey].account == address(0)) {
                uint256 tradeFee = IDex(dex).getTradeFee(margin, leverage, productId);
                IERC20(collateralToken).safeTransferFrom(
                    account,
                    address(this),
                    ((margin + tradeFee) * tokenBase) / BASE
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
        bool isAdjustingTriggerPrice,
        uint256 triggerPrice,
        bool isAdjustingTpPrice,
        uint256 tpPrice,
        bool isAdjustingSlPrice,
        uint256 slPrice
    ) external payable nonReentrant {
        OpenOrder storage order = openOrders[orderKey];
        require(order.account == msg.sender, "OrderManager: !order.account");

        if (isAdjustingTriggerPrice) order.triggerPrice = triggerPrice;
        uint256 numOfExecutions = 0;
        if (isAdjustingTpPrice) {
            if (order.tpPrice == 0) {
                if (tpPrice != 0) {
                    order.tpPrice = tpPrice;
                    numOfExecutions += 2;
                }
            } else {
                if (tpPrice == 0) {
                    order.tpPrice = tpPrice;
                    (bool success, ) = payable(msg.sender).call{value: executionFee}("");
                    require(success, "OrderManager: failed to send execution fee");
                } else {
                    order.tpPrice = tpPrice;
                }
            }
        }
        if (isAdjustingSlPrice) {
            if (order.slPrice == 0) {
                if (slPrice != 0) {
                    order.slPrice = slPrice;
                    numOfExecutions += 2;
                }
            } else {
                if (slPrice == 0) {
                    order.slPrice = slPrice;
                    (bool success, ) = payable(msg.sender).call{value: executionFee}("");
                    require(success, "OrderManager: failed to send execution fee");
                } else {
                    order.slPrice = slPrice;
                }
            }
        }

        if (numOfExecutions > 0) {
            require(msg.value == executionFee * numOfExecutions, "OrderManager: invalid executionFee");
        }

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

        IERC20(collateralToken).safeTransfer(msg.sender, ((order.margin + order.tradeFee) * tokenBase) / BASE);
        delete openOrders[orderKey];

        uint256 numOfExecutions = 1;
        if (order.tpPrice > 0) numOfExecutions += 2;
        if (order.slPrice > 0) numOfExecutions += 2;
        (bool success, ) = payable(msg.sender).call{value: executionFee * numOfExecutions}("");
        require(success, "OrderManager: failed to send execution fee");

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

    function executeOpenOrder(bytes32 orderKey) external {
        require(msg.sender == address(this) || isKeeper[msg.sender], "OrderManager: !keeper");

        OpenOrder memory order = openOrders[orderKey];

        if (order.account == address(0)) return;

        uint256 currentPrice = validateExecutionPrice(
            order.isLong,
            order.isTriggerAbove,
            order.triggerPrice,
            order.productId
        );

        IERC20(collateralToken).safeIncreaseAllowance(dex, ((order.margin + order.tradeFee) * tokenBase) / BASE);
        IDex(dex).openPosition(order.account, order.productId, order.isLong, order.margin, order.leverage);
        uint256 numOfExecutions = 1;
        if (order.tpPrice != 0) {
            _createCloseOrder(
                order.account,
                order.isLong,
                order.isLong,
                order.productId,
                (order.margin * order.leverage) / BASE,
                order.tpPrice
            );
            numOfExecutions += 1;
        }
        if (order.slPrice != 0) {
            _createCloseOrder(
                order.account,
                order.isLong,
                !order.isLong,
                order.productId,
                (order.margin * order.leverage) / BASE,
                order.slPrice
            );
            numOfExecutions += 1;
        }

        delete openOrders[orderKey];

        (bool success, ) = payable(tx.origin).call{value: executionFee * numOfExecutions}("");
        require(success, "OrderManager: failed to send execution fee");

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
    ) external payable nonReentrant {
        require(msg.value == executionFee, "OrderManager: invalid executionFee");
        _createCloseOrder(msg.sender, isLong, isTriggerAbove, productId, size, triggerPrice);
    }

    function createCloseOrderForTPSL(
        address account,
        bool isLong,
        bool isTriggerAbove,
        uint256 productId,
        uint256 size,
        uint256 triggerPrice
    ) external payable nonReentrant {
        require(msg.sender == positionManager, "OrderManager: !positionManager");
        require(msg.value == executionFee, "OrderManager: invalid executionFee");
        _createCloseOrder(account, isLong, isTriggerAbove, productId, size, triggerPrice);
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
        (bool success, ) = payable(msg.sender).call{value: executionFee}("");
        require(success, "OrderManager: failed to send execution fee");
    }

    function cancelActiveCloseOrders(
        address account,
        uint256 productId,
        bool isLong
    ) external {
        require(msg.sender == dex, "OrderManager: !dex");
        uint256 numOfExecutions = 0;
        uint256 _maxCloseOrders = maxCloseOrders;

        for (uint256 i = 0; i < _maxCloseOrders; ++i) {
            bytes32 orderKey = getOrderKey(account, productId, isLong, i);

            if (closeOrders[orderKey].account != address(0)) {
                _cancelCloseOrder(orderKey);
                numOfExecutions += 1;
            }
        }

        if (numOfExecutions != 0) {
            uint256 _executionFee = executionFee;
            (bool success, ) = payable(tx.origin).call{value: _executionFee * numOfExecutions}("");
            require(success, "OrderManager: failed to send execution fee");
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

    function executeCloseOrder(bytes32 orderKey) external {
        require(msg.sender == address(this) || isKeeper[msg.sender], "OrderManager: !keeper");

        CloseOrder memory order = closeOrders[orderKey];

        if (order.account == address(0)) return;

        uint256 currentPrice = validateExecutionPrice(
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
            (order.size * BASE) / IDex(dex).getPositionLeverage(order.account, order.productId, order.isLong)
        );

        (bool success, ) = payable(tx.origin).call{value: executionFee}("");
        require(success, "OrderManager: failed to send execution fee");

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
        uint256[] memory productIds,
        uint256[] memory prices,
        bytes32[] memory openOrderKeys,
        bytes32[] memory closeOrderKeys
    ) external onlyKeeper {
        IOracle(oracle).setPrices(productIds, prices);

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

    function validateExecutionPrice(
        bool isLong,
        bool isTriggerAbove,
        uint256 triggerPrice,
        uint256 productId
    ) public view returns (uint256) {
        uint256 currentPrice = IOracle(oracle).getPrice(productId, isLong);
        if (isTriggerAbove) {
            require(currentPrice >= triggerPrice, "OrderManager: current price is below trigger price");
        } else {
            require(currentPrice <= triggerPrice, "OrderManager: current price is above trigger price");
        }
        return currentPrice;
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

    function getUserOpenOrders(
        address user,
        uint256 startId,
        uint256 endId
    ) public view returns (bytes32[] memory userOpenOrderKeys, OpenOrder[] memory userOpenOrders) {
        require(startId > 0, "OrderManager: !startId");
        uint256 totalProducts = IDex(dex).totalProducts();
        if (endId > totalProducts) endId = totalProducts;
        uint256 _maxOpenOrders = maxOpenOrders;
        userOpenOrderKeys = new bytes32[]((endId - startId + 1) * _maxOpenOrders * 2);
        userOpenOrders = new OpenOrder[]((endId - startId + 1) * _maxOpenOrders * 2);
        bytes32 orderKey;
        uint256 count;

        for (uint256 i = startId; i <= endId; ++i) {
            for (uint256 j = 0; j < _maxOpenOrders; ++j) {
                orderKey = getOrderKey(user, i, true, j);
                if (openOrders[orderKey].account != address(0)) {
                    userOpenOrderKeys[count] = orderKey;
                    userOpenOrders[count++] = openOrders[orderKey];
                }

                orderKey = getOrderKey(user, i, false, j);
                if (openOrders[orderKey].account != address(0)) {
                    userOpenOrderKeys[count] = orderKey;
                    userOpenOrders[count++] = openOrders[orderKey];
                }
            }
        }
    }

    function getUserCloseOrders(
        address user,
        uint256 startId,
        uint256 endId
    ) external view returns (bytes32[] memory userCloseOrderKeys, CloseOrder[] memory userCloseOrders) {
        require(startId > 0, "OrderManager: !startId");
        uint256 totalProducts = IDex(dex).totalProducts();
        if (endId > totalProducts) endId = totalProducts;
        uint256 _maxCloseOrders = maxCloseOrders;
        userCloseOrderKeys = new bytes32[]((endId - startId + 1) * _maxCloseOrders * 2);
        userCloseOrders = new CloseOrder[]((endId - startId + 1) * _maxCloseOrders * 2);
        bytes32 orderKey;
        uint256 count;

        for (uint256 i = startId; i <= endId; ++i) {
            for (uint256 j = 0; j < _maxCloseOrders; ++j) {
                orderKey = getOrderKey(user, i, true, j);
                if (closeOrders[orderKey].account != address(0)) {
                    userCloseOrderKeys[count] = orderKey;
                    userCloseOrders[count++] = closeOrders[orderKey];
                }

                orderKey = getOrderKey(user, i, false, j);
                if (closeOrders[orderKey].account != address(0)) {
                    userCloseOrderKeys[count] = orderKey;
                    userCloseOrders[count++] = closeOrders[orderKey];
                }
            }
        }
    }

    function isUserOpenOrderAvailable(
        address user,
        uint256 productId,
        bool isLong
    ) external view returns (bool) {
        uint256 _maxOpenOrders = maxOpenOrders;

        for (uint256 i = 0; i < _maxOpenOrders; ++i) {
            if (openOrders[getOrderKey(user, productId, isLong, i)].account == address(0)) {
                return true;
            }
        }
        return false;
    }

    function isUserCloseOrderAvailable(
        address user,
        uint256 productId,
        bool isLong
    ) external view returns (bool) {
        uint256 _maxCloseOrders = maxCloseOrders;

        for (uint256 i = 0; i < _maxCloseOrders; ++i) {
            if (closeOrders[getOrderKey(user, productId, isLong, i)].account == address(0)) {
                return true;
            }
        }
        return false;
    }

    function getUserAvailableOpenOrderSlots(
        address user,
        uint256 productId,
        bool isLong
    ) external view returns (uint256 availableOpenOrderSlots) {
        availableOpenOrderSlots = 0;
        uint256 _maxOpenOrders = maxOpenOrders;

        for (uint256 i = 0; i < _maxOpenOrders; ++i) {
            if (openOrders[getOrderKey(user, productId, isLong, i)].account == address(0)) {
                availableOpenOrderSlots += 1;
            }
        }
    }

    function getUserAvailableCloseOrderSlots(
        address user,
        uint256 productId,
        bool isLong
    ) external view returns (uint256 availableCloseOrderSlots) {
        availableCloseOrderSlots = 0;
        uint256 _maxCloseOrders = maxCloseOrders;

        for (uint256 i = 0; i < _maxCloseOrders; ++i) {
            if (closeOrders[getOrderKey(user, productId, isLong, i)].account == address(0)) {
                availableCloseOrderSlots += 1;
            }
        }
    }

    function setMaxOrders(uint256 _maxOpenOrders, uint256 _maxCloseOrders) external onlyGov {
        require(maxOpenOrders >= 5 && maxCloseOrders >= 5, "OrderManager: !maxNumOfOrders");
        maxOpenOrders = _maxOpenOrders;
        maxCloseOrders = _maxCloseOrders;
    }

    function setExecutionFee(uint256 _executionFee) external onlyGov {
        require(_executionFee <= 1e18);
        executionFee = _executionFee;
    }

    function setKeeper(address _account, bool _isActive) external onlyGov {
        isKeeper[_account] = _isActive;
        emit SetKeeper(_account, _isActive);
    }
}
