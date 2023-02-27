// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../access/Governable.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IDex.sol";
import "../interfaces/IOrderManager.sol";

contract PositionManager is Governable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct OpenPosition {
        address account;
        bool isLong;
        uint256 productId;
        uint256 margin;
        uint256 leverage;
        uint256 tradeFee;
        uint256 acceptablePrice;
        uint256 tpPrice;
        uint256 slPrice;
        uint256 index;
        uint256 timestamp;
    }
    struct ClosePosition {
        address account;
        bool isLong;
        uint256 productId;
        uint256 margin;
        uint256 acceptablePrice;
        uint256 index;
        uint256 timestamp;
    }

    address public immutable dex;
    address public immutable oracle;
    address public immutable orderManager;
    address public immutable collateralToken;

    uint256 public positionValidDuration = 60;
    uint256 public executeCooldownPublic = 180;
    uint256 public executionFee = 1e15;
    uint256 private immutable tokenBase;
    uint256 private constant BASE = 10**8;

    uint256 public openPositionKeysIndex;
    bytes32[] public openPositionKeys;
    uint256 public closePositionKeysIndex;
    bytes32[] public closePositionKeys;

    mapping(address => uint256) public openPositionsIndex;
    mapping(bytes32 => OpenPosition) public openPositions;
    mapping(address => uint256) public closePositionsIndex;
    mapping(bytes32 => ClosePosition) public closePositions;
    mapping(address => bool) public isKeeper;

    event CreateOpenPosition(
        address indexed account,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 tradeFee,
        bool isLong,
        uint256 acceptablePrice,
        uint256 tpPrice,
        uint256 slPrice,
        uint256 index,
        uint256 timestamp
    );
    event ExecuteOpenPosition(
        address indexed account,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 tradeFee,
        bool isLong,
        uint256 acceptablePrice,
        uint256 tpPrice,
        uint256 slPrice,
        uint256 index,
        uint256 timeUsed
    );
    event CancelOpenPosition(
        address indexed account,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 tradeFee,
        bool isLong,
        uint256 acceptablePrice,
        uint256 tpPrice,
        uint256 slPrice,
        uint256 index,
        uint256 timeUsed
    );
    event CreateClosePosition(
        address indexed account,
        uint256 productId,
        uint256 margin,
        bool isLong,
        uint256 acceptablePrice,
        uint256 index,
        uint256 timestamp
    );
    event ExecuteClosePosition(
        address indexed account,
        uint256 productId,
        uint256 margin,
        bool isLong,
        uint256 acceptablePrice,
        uint256 index,
        uint256 timeUsed
    );
    event CancelClosePosition(
        address indexed account,
        uint256 productId,
        uint256 margin,
        bool isLong,
        uint256 acceptablePrice,
        uint256 index,
        uint256 timeUsed
    );
    event ExecuteOpenPositionError(address indexed account, uint256 index, string executionError);
    event ExecuteClosePositionError(address indexed account, uint256 index, string executionError);
    event ExecutionFeeRefundError(address indexed account, uint256 totalExecutionFee);
    event SetPositionKeysIndex(uint256 openPositionKeysIndex, uint256 closePositionKeysIndex);
    event SetDuration(uint256 positionValidDuration, uint256 executeCooldownPublic);
    event SetKeeper(address indexed account, bool isActive);

    modifier onlyKeeper() {
        require(isKeeper[msg.sender], "PositionManager: !Keeper");
        _;
    }

    constructor(
        address _dex,
        address _oracle,
        address _orderManager,
        address _collateralToken,
        uint256 _tokenBase
    ) {
        dex = _dex;
        oracle = _oracle;
        orderManager = _orderManager;
        collateralToken = _collateralToken;
        tokenBase = _tokenBase;
    }

    function createOpenPosition(
        bool isLong,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 acceptablePrice,
        uint256 tpPrice,
        uint256 slPrice
    ) external payable nonReentrant {
        uint256 numOfExecutions = 1;
        if (tpPrice > 0) numOfExecutions += 2;
        if (slPrice > 0) numOfExecutions += 2;
        require(msg.value == executionFee * numOfExecutions, "PositionManager: invalid executionFee");
        _createOpenPosition(msg.sender, isLong, productId, margin, leverage, acceptablePrice, tpPrice, slPrice);
    }

    function _createOpenPosition(
        address account,
        bool isLong,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 acceptablePrice,
        uint256 tpPrice,
        uint256 slPrice
    ) private {
        IDex(dex).validateOpenPositionRequirements(margin, leverage, productId);

        uint256 tradeFee = IDex(dex).getTradeFee(margin, leverage, productId);
        IERC20(collateralToken).safeTransferFrom(account, address(this), ((margin + tradeFee) * tokenBase) / BASE);

        uint256 index = openPositionsIndex[account];
        openPositionsIndex[account] += 1;

        bytes32 key = getPositionKey(account, index);
        openPositions[key] = OpenPosition(
            account,
            isLong,
            productId,
            margin,
            leverage,
            tradeFee,
            acceptablePrice,
            tpPrice,
            slPrice,
            index,
            block.timestamp
        );
        openPositionKeys.push(key);

        emit CreateOpenPosition(
            account,
            productId,
            margin,
            leverage,
            tradeFee,
            isLong,
            acceptablePrice,
            tpPrice,
            slPrice,
            index,
            block.timestamp
        );
    }

    function executeOpenPosition(bytes32 key) external nonReentrant {
        require(msg.sender == address(this) || isKeeper[msg.sender], "PositionManager: !executor");

        OpenPosition memory position = openPositions[key];

        if (position.account == address(0)) return;

        require(position.timestamp + positionValidDuration > block.timestamp, "PositionManager: position has expired");

        _validateExecution(position.productId, position.isLong, position.acceptablePrice);

        IERC20(collateralToken).safeIncreaseAllowance(dex, ((position.margin + position.tradeFee) * tokenBase) / BASE);
        IDex(dex).openPosition(
            position.account,
            position.productId,
            position.isLong,
            position.margin,
            position.leverage
        );
        uint256 numOfExecutions = 1;
        uint256 _executionFee = executionFee;
        if (position.tpPrice != 0) {
            IOrderManager(orderManager).createCloseOrderForTPSL{value: _executionFee}(
                position.account,
                position.isLong,
                position.isLong,
                position.productId,
                (position.margin * position.leverage) / BASE,
                position.tpPrice
            );
            numOfExecutions += 1;
        }
        if (position.slPrice != 0) {
            IOrderManager(orderManager).createCloseOrderForTPSL{value: _executionFee}(
                position.account,
                position.isLong,
                !position.isLong,
                position.productId,
                (position.margin * position.leverage) / BASE,
                position.slPrice
            );
            numOfExecutions += 1;
        }

        delete openPositions[key];

        (bool success, ) = payable(tx.origin).call{value: _executionFee * numOfExecutions}("");
        require(success, "PositionManager: failed to send execution fee");

        emit ExecuteOpenPosition(
            position.account,
            position.productId,
            position.margin,
            position.leverage,
            position.tradeFee,
            position.isLong,
            position.acceptablePrice,
            position.tpPrice,
            position.slPrice,
            position.index,
            block.timestamp - position.timestamp
        );
    }

    function _cancelOpenPosition(bytes32 key) private {
        OpenPosition memory position = openPositions[key];

        if (position.account == address(0)) return;

        IERC20(collateralToken).safeTransfer(
            position.account,
            ((position.margin + position.tradeFee) * tokenBase) / BASE
        );
        uint256 _executionFee = executionFee;
        uint256 numOfExecutions = 0;
        if (position.tpPrice > 0) numOfExecutions += 2;
        if (position.slPrice > 0) numOfExecutions += 2;
        if (numOfExecutions != 0) {
            (bool success, ) = payable(position.account).call{gas: 2300, value: _executionFee * numOfExecutions}("");
            if (!success) {
                emit ExecutionFeeRefundError(position.account, _executionFee * numOfExecutions);

                (bool success2, ) = payable(msg.sender).call{value: _executionFee * numOfExecutions}("");
                require(success2, "PositionManager: failed to send execution fee");
            }
        }

        delete openPositions[key];

        (bool success3, ) = payable(msg.sender).call{value: _executionFee}("");
        require(success3, "PositionManager: failed to send execution fee");

        emit CancelOpenPosition(
            position.account,
            position.productId,
            position.margin,
            position.leverage,
            position.tradeFee,
            position.isLong,
            position.acceptablePrice,
            position.tpPrice,
            position.slPrice,
            position.index,
            block.timestamp - position.timestamp
        );
    }

    function _executeOpenPositions(uint256 endIndex) private {
        uint256 index = openPositionKeysIndex;
        uint256 length = openPositionKeys.length;

        if (index >= length) return;
        if (endIndex > length) endIndex = length;

        while (index < endIndex) {
            bytes32 key = openPositionKeys[index];

            try this.executeOpenPosition(key) {} catch Error(string memory executionError) {
                _cancelOpenPosition(key);
                emit ExecuteOpenPositionError(openPositions[key].account, index, executionError);
            } catch (bytes memory) {
                _cancelOpenPosition(key);
            }

            delete openPositionKeys[index];
            ++index;
        }

        openPositionKeysIndex = index;
    }

    function createClosePosition(
        bool isLong,
        uint256 productId,
        uint256 margin,
        uint256 acceptablePrice
    ) external payable nonReentrant {
        require(msg.value == executionFee, "PositionManager: invalid executionFee");
        _createClosePosition(msg.sender, isLong, productId, margin, acceptablePrice);
    }

    function _createClosePosition(
        address account,
        bool isLong,
        uint256 productId,
        uint256 margin,
        uint256 acceptablePrice
    ) private {
        uint256 index = closePositionsIndex[account];
        closePositionsIndex[account] += 1;

        bytes32 key = getPositionKey(account, index);
        closePositions[key] = ClosePosition(
            account,
            isLong,
            productId,
            margin,
            acceptablePrice,
            index,
            block.timestamp
        );
        closePositionKeys.push(key);

        emit CreateClosePosition(account, productId, margin, isLong, acceptablePrice, index, block.timestamp);
    }

    function executeClosePosition(bytes32 key) external nonReentrant {
        require(msg.sender == address(this) || isKeeper[msg.sender], "PositionManager: !executor");

        ClosePosition memory position = closePositions[key];

        if (position.account == address(0)) return;

        require(position.timestamp + positionValidDuration > block.timestamp, "PositionManager: position has expired");

        _validateExecution(position.productId, !position.isLong, position.acceptablePrice);

        IDex(dex).closePosition(position.account, position.productId, position.isLong, position.margin);

        delete closePositions[key];

        (bool success, ) = payable(tx.origin).call{value: executionFee}("");
        require(success, "PositionManager: failed to send execution fee");

        emit ExecuteClosePosition(
            position.account,
            position.productId,
            position.margin,
            position.isLong,
            position.acceptablePrice,
            position.index,
            block.timestamp - position.timestamp
        );
    }

    function executeClosePositionByOwner(bytes32 key) external nonReentrant {
        ClosePosition memory position = closePositions[key];

        require(msg.sender == position.account, "PositionManager: !account");
        require(
            position.timestamp + executeCooldownPublic <= block.timestamp,
            "PositionManager: cooldown has not passed yet"
        );

        _validateExecution(position.productId, !position.isLong, position.acceptablePrice);

        IDex(dex).closePosition(position.account, position.productId, position.isLong, position.margin);

        delete closePositions[key];

        (bool success, ) = payable(msg.sender).call{value: executionFee}("");
        require(success, "PositionManager: failed to send execution fee");

        emit ExecuteClosePosition(
            position.account,
            position.productId,
            position.margin,
            position.isLong,
            position.acceptablePrice,
            position.index,
            block.timestamp - position.timestamp
        );
    }

    function _cancelClosePosition(bytes32 key) private {
        ClosePosition memory position = closePositions[key];

        if (position.account == address(0)) return;

        delete closePositions[key];

        (bool success, ) = payable(msg.sender).call{value: executionFee}("");
        require(success, "PositionManager: failed to send execution fee");

        emit CancelClosePosition(
            position.account,
            position.productId,
            position.margin,
            position.isLong,
            position.acceptablePrice,
            position.index,
            block.timestamp - position.timestamp
        );
    }

    function _executeClosePositions(uint256 endIndex) private {
        uint256 index = closePositionKeysIndex;
        uint256 length = closePositionKeys.length;

        if (index >= length) return;
        if (endIndex > length) endIndex = length;

        while (index < endIndex) {
            bytes32 key = closePositionKeys[index];

            try this.executeClosePosition(key) {} catch Error(string memory executionError) {
                _cancelClosePosition(key);
                emit ExecuteClosePositionError(closePositions[key].account, index, executionError);
            } catch (bytes memory) {
                _cancelClosePosition(key);
            }

            delete closePositionKeys[index];
            ++index;
        }

        closePositionKeysIndex = index;
    }

    function executeNPositionsWithPrices(
        uint256[] memory productIds,
        uint256[] memory prices,
        uint256 n
    ) external onlyKeeper {
        IOracle(oracle).setPrices(productIds, prices);
        _executeOpenPositions(openPositionKeysIndex + n);
        _executeClosePositions(closePositionKeysIndex + n);
    }

    function executePositionsWithPrices(
        uint256[] memory productIds,
        uint256[] memory prices,
        uint256 openEndIndex,
        uint256 closeEndIndex
    ) external onlyKeeper {
        IOracle(oracle).setPrices(productIds, prices);
        _executeOpenPositions(openEndIndex);
        _executeClosePositions(closeEndIndex);
    }

    function _validateExecution(
        uint256 productId,
        bool isLong,
        uint256 acceptablePrice
    ) private view {
        uint256 price = IOracle(oracle).getPrice(productId, isLong);
        if (isLong) {
            require(price <= acceptablePrice, "PositionManager: long => slippage exceeded");
        } else {
            require(price >= acceptablePrice, "PositionManager: short => slippage exceeded");
        }
    }

    function getPositionKey(address account, uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, index));
    }

    function getOpenPosition(address account, uint256 index) external view returns (OpenPosition memory) {
        return openPositions[getPositionKey(account, index)];
    }

    function getClosePosition(address account, uint256 index) external view returns (ClosePosition memory) {
        return closePositions[getPositionKey(account, index)];
    }

    function getPositionKeysInfo()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return (openPositionKeysIndex, openPositionKeys.length, closePositionKeysIndex, closePositionKeys.length);
    }

    function canKeeperExecute() external view returns (bool) {
        return openPositionKeysIndex < openPositionKeys.length || closePositionKeysIndex < closePositionKeys.length;
    }

    function setDuration(uint256 _positionValidDuration, uint256 _executeCooldownPublic) external onlyGov {
        require(_positionValidDuration >= 15 && _positionValidDuration <= 60, "PositionManager: invalid duration");
        require(_executeCooldownPublic <= 300, "PositionManager: invalid duration");

        positionValidDuration = _positionValidDuration;
        executeCooldownPublic = _executeCooldownPublic;
        emit SetDuration(_positionValidDuration, _executeCooldownPublic);
    }

    function setExecutionFee(uint256 _executionFee) external onlyGov {
        require(_executionFee <= 1e18);
        executionFee = _executionFee;
    }

    function setPositionKeysIndex(uint256 _openPositionKeysIndex, uint256 _closePositionKeysIndex) external onlyGov {
        openPositionKeysIndex = _openPositionKeysIndex;
        closePositionKeysIndex = _closePositionKeysIndex;
        emit SetPositionKeysIndex(_openPositionKeysIndex, _closePositionKeysIndex);
    }

    function setKeeper(address _account, bool _isActive) external onlyGov {
        isKeeper[_account] = _isActive;
        emit SetKeeper(_account, _isActive);
    }
}
