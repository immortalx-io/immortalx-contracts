// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../access/Governable.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IDex.sol";

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
    address public immutable collateralToken;

    uint256 public positionValidDuration = 1800;
    uint256 public executeCooldownPublic = 180;
    uint256 public minMargin = 25 * BASE;
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
        address _collateralToken,
        uint256 _tokenBase
    ) {
        dex = _dex;
        oracle = _oracle;
        collateralToken = _collateralToken;
        tokenBase = _tokenBase;
    }

    function createOpenPosition(
        bool isLong,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 acceptablePrice
    ) external nonReentrant {
        _createOpenPosition(msg.sender, isLong, productId, margin, leverage, acceptablePrice);
    }

    function _createOpenPosition(
        address account,
        bool isLong,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 acceptablePrice
    ) private {
        require(margin >= minMargin, "OrderManager: !minMargin");

        uint256 tradeFee = IDex(dex).getTradeFee(margin, leverage, productId);
        IERC20(collateralToken).safeTransferFrom(account, address(this), ((margin + tradeFee) * tokenBase) / 10**8);

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
            index,
            block.timestamp
        );
    }

    function createClosePosition(
        bool isLong,
        uint256 productId,
        uint256 margin,
        uint256 acceptablePrice
    ) external nonReentrant {
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

    function executeNPositionsWithPrices(
        address[] memory tokens,
        uint256[] memory prices,
        uint256 n
    ) external onlyKeeper {
        IOracle(oracle).setPrices(tokens, prices);
        _executeOpenPositions(openPositionKeysIndex + n);
        _executeClosePositions(closePositionKeysIndex + n);
    }

    function executePositionsWithPrices(
        address[] memory tokens,
        uint256[] memory prices,
        uint256 openEndIndex,
        uint256 closeEndIndex
    ) external onlyKeeper {
        IOracle(oracle).setPrices(tokens, prices);
        _executeOpenPositions(openEndIndex);
        _executeClosePositions(closeEndIndex);
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

    function executeOpenPosition(bytes32 key) public nonReentrant {
        OpenPosition memory position = openPositions[key];

        if (position.account == address(0)) return;

        _validateExecution(
            position.timestamp,
            position.account,
            position.productId,
            true,
            position.isLong,
            position.acceptablePrice
        );

        delete openPositions[key];
        IERC20(collateralToken).safeApprove(dex, 0);
        IERC20(collateralToken).safeApprove(dex, ((position.margin + position.tradeFee) * tokenBase) / 10**8);
        IDex(dex).openPosition(
            position.account,
            position.productId,
            position.isLong,
            position.margin,
            position.leverage
        );

        emit ExecuteOpenPosition(
            position.account,
            position.productId,
            position.margin,
            position.leverage,
            position.tradeFee,
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

    function executeClosePosition(bytes32 key) public nonReentrant {
        ClosePosition memory position = closePositions[key];

        if (position.account == address(0)) return;

        _validateExecution(
            position.timestamp,
            position.account,
            position.productId,
            false,
            !position.isLong,
            position.acceptablePrice
        );

        delete closePositions[key];
        IDex(dex).closePosition(position.account, position.productId, position.isLong, position.margin);

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

    function _cancelOpenPosition(bytes32 key) private {
        OpenPosition memory position = openPositions[key];

        if (position.account == address(0)) return;

        IERC20(collateralToken).safeTransfer(
            position.account,
            ((position.margin + position.tradeFee) * tokenBase) / 10**8
        );
        delete openPositions[key];

        emit CancelOpenPosition(
            position.account,
            position.productId,
            position.margin,
            position.leverage,
            position.tradeFee,
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

    function _validateExecution(
        uint256 positionTimestamp,
        address account,
        uint256 productId,
        bool isOpen,
        bool isLong,
        uint256 acceptablePrice
    ) private view {
        require(positionTimestamp + positionValidDuration > block.timestamp, "PositionManager: position has expired");

        if (msg.sender == address(this) || isKeeper[msg.sender]) {
            address productToken = IDex(dex).getProductToken(productId);
            uint256 price = IOracle(oracle).getPrice(productToken, isLong);

            if (isLong) require(price <= acceptablePrice, "PositionManager: long => slippage exceeded");
            else require(price >= acceptablePrice, "PositionManager: short => slippage exceeded");
            return;
        }

        require(!isOpen, "PositionManager: not openPosition");
        require(msg.sender == account, "PositionManager: !account");
        require(
            positionTimestamp + executeCooldownPublic <= block.timestamp,
            "PositionManager: cooldown has not passed yet"
        );
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
        positionValidDuration = _positionValidDuration;
        executeCooldownPublic = _executeCooldownPublic;
        emit SetDuration(_positionValidDuration, _executeCooldownPublic);
    }

    function setPositionKeysIndex(uint256 _openPositionKeysIndex, uint256 _closePositionKeysIndex) external onlyGov {
        openPositionKeysIndex = _openPositionKeysIndex;
        closePositionKeysIndex = _closePositionKeysIndex;
        emit SetPositionKeysIndex(_openPositionKeysIndex, _closePositionKeysIndex);
    }

    function setMinMargin(uint256 _minMargin) external onlyGov {
        require(_minMargin <= 50 * BASE);
        minMargin = _minMargin;
    }

    function setKeeper(address _account, bool _isActive) external onlyGov {
        isKeeper[_account] = _isActive;
        emit SetKeeper(_account, _isActive);
    }
}
