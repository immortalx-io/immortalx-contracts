// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../access/Governable.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IVaultRewardRouter.sol";
import "../interfaces/IReferralManager.sol";
import "../interfaces/IOrderManager.sol";

contract Dex is ReentrancyGuard, Governable {
    using SafeERC20 for IERC20;

    struct Vault {
        uint256 cap;
        uint256 balance;
        uint256 staked;
        uint256 shares;
        uint256 minTime;
    }
    struct Stake {
        address owner;
        uint256 amount;
        uint256 shares;
        uint256 timestamp;
    }
    struct Product {
        address productToken;
        bool isActive;
        uint256 maxLeverage;
        uint256 fee;
        uint256 weight;
        uint256 reserve;
        uint256 openInterestLong;
        uint256 openInterestShort;
    }
    struct Funding {
        int256 total;
        uint256 timestamp;
        uint256 multiplier;
    }
    struct Position {
        address owner;
        bool isLong;
        uint256 productId;
        uint256 margin;
        uint256 leverage;
        uint256 price;
        int256 funding;
        uint256 timestamp;
    }

    address public oracle;
    address public referralManager;
    address public positionManager;
    address public orderManager;
    address public vaultRewardReceiver;
    address public stakingRewardReceiver;
    address public vaultRewardRouter;
    address public immutable token;

    uint256 public totalProducts;
    uint256 public totalWeight;
    uint256 public totalOpenInterest;
    uint256 public minMargin = 25 * BASE;
    uint256 public minLeverage = 1 * BASE;
    uint256 public maxShift = 0.002e8;
    uint256 public shiftDivider = 20;
    uint256 public utilizationMultiplier = 10000;
    uint256 public exposureMultiplier = 12000;
    uint256 public maxExposureMultiplier = 30000;
    uint256 public liquidationThreshold = 9000;
    uint256 public maxFundingRate = 10 * FUNDING_BASE;
    uint256 public vaultRewardRatio = 6000;
    uint256 public stakingRewardRatio = 4000;
    uint256 private pendingVaultReward;
    uint256 private pendingStakingReward;
    uint256 private immutable tokenBase;
    uint256 private constant BASE = 10**8;
    uint256 private constant FUNDING_BASE = 10**12;

    bool public isStakeEnabled = true;
    bool public isOpenPositionEnabled = true;

    mapping(address => Stake) private stakes;
    mapping(uint256 => Product) private products;
    mapping(uint256 => Funding) private fundings;
    mapping(bytes32 => Position) public positions;
    mapping(address => uint256) public claimableTraderRebates;
    mapping(address => uint256) public claimableReferrerRebates;
    mapping(address => bool) public liquidators;
    mapping(address => bool) public guardians;

    Vault private vault;

    event StakeVault(address indexed user, uint256 amount, uint256 shares);
    event UnstakeVault(address indexed user, uint256 amount, uint256 shares, uint256 shareBalance, bool isFullRedeem);
    event NewPosition(
        bytes32 indexed positionKey,
        address indexed user,
        bool isLong,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 price,
        uint256 fee,
        int256 funding
    );
    event ClosePosition(
        bytes32 indexed positionKey,
        address indexed user,
        uint256 productId,
        uint256 price,
        uint256 entryPrice,
        uint256 margin,
        uint256 leverage,
        uint256 fee,
        int256 pnl,
        int256 fundingPayment,
        bool wasLiquidated
    );
    event AddMargin(
        bytes32 indexed positionKey,
        address indexed user,
        uint256 margin,
        uint256 newMargin,
        uint256 leverage,
        uint256 newLeverage
    );
    event PositionLiquidated(bytes32 indexed positionKey);
    event ClaimReferrerRebates(address indexed user, uint256 amount);
    event ClaimTraderRebates(address indexed user, uint256 amount);
    event SetPeripheralContracts(
        address oracle,
        address referralManager,
        address positionManager,
        address orderManager,
        address vaultRewardReceiver,
        address stakingRewardReceiver,
        address vaultRewardRouter
    );
    event UpdateVault(Vault vault);
    event AddProduct(uint256 productId, Product product);
    event UpdateProduct(uint256 productId, Product product);
    event SetFundingMultiplier(uint256 productId, uint256 multiplier);
    event SetParameter(uint256 index, uint256 value);
    event SetRewardRatio(uint256 vaultRewardRatio, uint256 stakingRewardRatio);
    event SetLiquidator(address indexed account, bool isActive);
    event SetGuardian(address indexed account, bool isActive);
    event EmergencyPause(uint256 timestamp);
    event Unpause(uint256 timestamp);

    constructor(address _token, uint256 _tokenBase) {
        token = _token;
        tokenBase = _tokenBase;
        guardians[msg.sender] = true;
    }

    function stakeVault(uint256 amount) external nonReentrant {
        _stakeVault(msg.sender, amount);
    }

    function stakeVaultToCompound(address user, uint256 amount) external {
        require(msg.sender == vaultRewardReceiver, "!vaultRewardReceiver");
        _stakeVault(user, amount);
    }

    function _stakeVault(address user, uint256 amount) private {
        require(isStakeEnabled, "staking is disabled");
        require(vault.staked + amount <= vault.cap, "vault cap exceeded");

        IVaultRewardRouter(vaultRewardRouter).updateRewards(user);
        IERC20(token).safeTransferFrom(msg.sender, address(this), (amount * tokenBase) / 10**8);

        uint256 shares = vault.staked > 0 ? (amount * vault.shares) / vault.balance : amount;
        vault.balance += amount;
        vault.staked += amount;
        vault.shares += shares;

        if (stakes[user].amount == 0) {
            stakes[user] = Stake({owner: user, amount: amount, shares: shares, timestamp: block.timestamp});
        } else {
            stakes[user].amount += amount;
            stakes[user].shares += shares;
            if (msg.sender != vaultRewardReceiver) stakes[user].timestamp = block.timestamp;
        }

        emit StakeVault(user, amount, shares);
    }

    function unstakeVault(uint256 shares) external nonReentrant {
        _unstakeVault(msg.sender, shares);
    }

    function _unstakeVault(address user, uint256 shares) private {
        Stake storage stake = stakes[user];
        require(shares > 0, "shares cannot be zero");
        require(shares <= vault.shares, "vault.shares exceeded");
        require(stake.amount > 0, "no staked amount");
        require(block.timestamp > vault.minTime + stake.timestamp, "!vault.minTime");
        IVaultRewardRouter(vaultRewardRouter).updateRewards(user);

        bool isFullRedeem = shares >= stake.shares;
        if (isFullRedeem) shares = stake.shares;

        uint256 shareBalance = (shares * vault.balance) / vault.shares;
        uint256 amount = (shares * stake.amount) / stake.shares;

        stake.amount -= amount;
        stake.shares -= shares;
        vault.staked -= amount;
        vault.shares -= shares;
        vault.balance -= shareBalance;

        if (isFullRedeem) delete stakes[user];
        require(totalOpenInterest <= (vault.balance * utilizationMultiplier) / 10**4, "vault is being utilized");
        IERC20(token).safeTransfer(user, (shareBalance * tokenBase) / 10**8);

        emit UnstakeVault(user, amount, shares, shareBalance, isFullRedeem);
    }

    function openPosition(
        address user,
        uint256 productId,
        bool isLong,
        uint256 margin,
        uint256 leverage
    ) external {
        require(isOpenPositionEnabled, "open position is disabled");
        require(msg.sender == positionManager || msg.sender == orderManager, "!manager");
        require(margin >= minMargin && margin < type(uint64).max, "!margin");
        require(leverage >= minLeverage, "!minLeverage");

        Product memory product = products[productId];
        require(product.isActive, "!active");
        require(leverage <= product.maxLeverage, "!maxLeverage");

        uint256 tradeFee = _getTradeFee(margin, leverage, product.fee);
        IERC20(token).safeTransferFrom(msg.sender, address(this), ((margin + tradeFee) * tokenBase) / 10**8);

        _updateFeeWithReferral(user, tradeFee);

        uint256 price;

        price = _calculatePrice(
            product.productToken,
            isLong,
            product.openInterestLong,
            product.openInterestShort,
            getMaxExposure(product.weight),
            product.reserve,
            (margin * leverage) / 10**8
        );

        _updateFundingAndOpenInterest(productId, (margin * leverage) / 10**8, isLong, true);
        int256 funding = fundings[productId].total;

        bytes32 positionKey = getPositionKey(user, productId, isLong);
        Position memory position = positions[positionKey];
        if (position.margin > 0) {
            price =
                (position.margin * position.leverage * position.price + margin * leverage * price) /
                (position.margin * position.leverage + margin * leverage);
            funding =
                (int256(position.margin) *
                    int256(position.leverage) *
                    int256(position.funding) +
                    int256(margin * leverage) *
                    funding) /
                int256(position.margin * position.leverage + margin * leverage);
            leverage = (position.margin * position.leverage + margin * leverage) / (position.margin + margin);
            margin = position.margin + margin;
        }

        positions[positionKey] = Position({
            owner: user,
            isLong: isLong,
            productId: productId,
            margin: margin,
            leverage: leverage,
            price: price,
            funding: funding,
            timestamp: block.timestamp
        });

        emit NewPosition(positionKey, user, isLong, productId, margin, leverage, price, tradeFee, funding);
    }

    function addMargin(bytes32 positionKey, uint256 margin) external nonReentrant {
        Position storage position = positions[positionKey];
        require(margin >= minMargin, "!minMargin");
        require(msg.sender == position.owner, "!position.owner (addMargin)");
        IERC20(token).safeTransferFrom(msg.sender, address(this), (margin * tokenBase) / 10**8);

        uint256 newMargin = position.margin + margin;
        uint256 leverage = position.leverage;
        uint256 newLeverage = (leverage * position.margin) / newMargin;
        require(newLeverage >= minLeverage, "!minleverage");

        position.margin = newMargin;
        position.leverage = newLeverage;

        emit AddMargin(positionKey, msg.sender, margin, newMargin, leverage, newLeverage);
    }

    function closePosition(
        address user,
        uint256 productId,
        bool isLong,
        uint256 margin
    ) external {
        _closePosition(getPositionKey(user, productId, isLong), margin);
    }

    function _closePosition(bytes32 positionKey, uint256 margin) private {
        require(margin > 0, "invalid margin");
        require(msg.sender == positionManager || msg.sender == orderManager, "!manager");

        Position storage position = positions[positionKey];
        Product storage product = products[position.productId];

        bool isFullClose;
        if (margin >= position.margin) {
            margin = position.margin;
            isFullClose = true;
        }

        uint256 price;

        price = _calculatePrice(
            product.productToken,
            !position.isLong,
            product.openInterestLong,
            product.openInterestShort,
            getMaxExposure(product.weight),
            product.reserve,
            (margin * position.leverage) / 10**8
        );

        _updateFundingAndOpenInterest(position.productId, (margin * position.leverage) / 10**8, position.isLong, false);
        int256 fundingPayment = _getFundingPayment(
            position.isLong,
            position.productId,
            position.leverage,
            margin,
            position.funding
        );

        int256 pnl = _getPnl(position.isLong, position.price, position.leverage, margin, price) - fundingPayment;
        bool isLiquidatable;
        if (pnl < 0 && uint256(-1 * pnl) >= (margin * liquidationThreshold) / 10**4) {
            margin = position.margin;
            pnl = -1 * int256(position.margin);
            isLiquidatable = true;
        }

        uint256 tradeFee = _getTradeFee(margin, position.leverage, product.fee);
        int256 pnlAfterFee = pnl - int256(tradeFee);

        if (pnlAfterFee < 0) {
            uint256 _pnlAfterFee = uint256(-1 * pnlAfterFee);

            if (_pnlAfterFee < margin) {
                IERC20(token).safeTransfer(position.owner, ((margin - _pnlAfterFee) * tokenBase) / 10**8);
                vault.balance += _pnlAfterFee;
            } else {
                vault.balance += margin;
            }
        } else {
            uint256 _pnlAfterFee = uint256(pnlAfterFee);
            require(vault.balance >= _pnlAfterFee, "insufficient vault balance");

            IERC20(token).safeTransfer(position.owner, ((margin + _pnlAfterFee) * tokenBase) / 10**8);
            vault.balance -= _pnlAfterFee;
        }

        _updateFeeWithReferral(position.owner, tradeFee);
        vault.balance -= tradeFee;

        emit ClosePosition(
            positionKey,
            position.owner,
            position.productId,
            price,
            position.price,
            margin,
            position.leverage,
            tradeFee,
            pnl,
            fundingPayment,
            isLiquidatable
        );

        if (isFullClose || isLiquidatable) {
            IOrderManager(orderManager).cancelPositionCloseOrders(position.owner, position.productId, position.isLong);
            delete positions[positionKey];
        } else {
            position.margin -= margin;
        }
    }

    function liquidatePositions(bytes32[] calldata positionKeys) external {
        require(liquidators[msg.sender], "!liquidator");

        for (uint256 i = 0; i < positionKeys.length; ++i) {
            _liquidatePosition(positionKeys[i]);
        }
    }

    function _liquidatePosition(bytes32 positionKey) private {
        Position storage position = positions[positionKey];
        Product storage product = products[position.productId];

        uint256 price = IOracle(oracle).getPrice(product.productToken);

        _updateFundingAndOpenInterest(
            position.productId,
            (position.margin * position.leverage) / 10**8,
            position.isLong,
            false
        );
        int256 fundingPayment = _getFundingPayment(
            position.isLong,
            position.productId,
            position.leverage,
            position.margin,
            position.funding
        );

        int256 pnl = _getPnl(position.isLong, position.price, position.leverage, position.margin, price) -
            fundingPayment;
        require(pnl < 0 && uint256(-1 * pnl) >= (position.margin * liquidationThreshold) / 10**4);

        uint256 tradeFee = _getTradeFee(position.margin, position.leverage, product.fee);
        _updateFeeWithReferral(position.owner, tradeFee);
        vault.balance += position.margin - tradeFee;

        emit ClosePosition(
            positionKey,
            position.owner,
            position.productId,
            price,
            position.price,
            position.margin,
            position.leverage,
            0,
            -1 * int256(position.margin),
            fundingPayment,
            true
        );
        emit PositionLiquidated(positionKey);

        IOrderManager(orderManager).cancelPositionCloseOrders(position.owner, position.productId, position.isLong);
        delete positions[positionKey];
    }

    function claimReferrerRebates() external nonReentrant {
        uint256 _claimableReferrerRebates = claimableReferrerRebates[msg.sender];
        require(_claimableReferrerRebates > 0, "Not claimable");

        claimableReferrerRebates[msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, _claimableReferrerRebates);

        emit ClaimReferrerRebates(msg.sender, _claimableReferrerRebates);
    }

    function claimTraderRebates() external nonReentrant {
        uint256 _claimableTraderRebates = claimableTraderRebates[msg.sender];
        require(_claimableTraderRebates > 0, "Not claimable");

        claimableTraderRebates[msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, _claimableTraderRebates);

        emit ClaimTraderRebates(msg.sender, _claimableTraderRebates);
    }

    function distributeVaultReward() external returns (uint256) {
        address _vaultRewardReceiver = vaultRewardReceiver;
        uint256 _pendingVaultReward = pendingVaultReward;
        require(msg.sender == _vaultRewardReceiver, "!vaultRewardReceiver");

        if (_pendingVaultReward > 0) {
            pendingVaultReward = 0;
            IERC20(token).safeTransfer(_vaultRewardReceiver, _pendingVaultReward);
        }
        return _pendingVaultReward;
    }

    function distributeStakingReward() external returns (uint256) {
        address _stakingRewardReceiver = stakingRewardReceiver;
        uint256 _pendingStakingReward = pendingStakingReward;
        require(msg.sender == _stakingRewardReceiver, "!stakingRewardReceiver");

        if (_pendingStakingReward > 0) {
            pendingStakingReward = 0;
            IERC20(token).safeTransfer(_stakingRewardReceiver, _pendingStakingReward);
        }
        return _pendingStakingReward;
    }

    function getMaxExposure(uint256 productWeight) public view returns (uint256) {
        return (vault.balance * productWeight * exposureMultiplier) / totalWeight / 10**4;
    }

    function getFundingRate(uint256 productId) public view returns (int256) {
        uint256 openInterestLong = products[productId].openInterestLong;
        uint256 openInterestShort = products[productId].openInterestShort;
        uint256 maxExposure = getMaxExposure(products[productId].weight);
        uint256 fundingMultiplier = fundings[productId].multiplier;
        uint256 _maxFundingRate = maxFundingRate;

        if (openInterestLong >= openInterestShort) {
            uint256 fundingRate = ((openInterestLong - openInterestShort) * fundingMultiplier) / maxExposure;

            if (fundingRate < _maxFundingRate) {
                return int256(fundingRate);
            } else {
                return int256(_maxFundingRate);
            }
        } else {
            uint256 fundingRate = ((openInterestShort - openInterestLong) * fundingMultiplier) / maxExposure;

            if (fundingRate < _maxFundingRate) {
                return -1 * int256(fundingRate);
            } else {
                return -1 * int256(_maxFundingRate);
            }
        }
    }

    function _getTradeFee(
        uint256 margin,
        uint256 leverage,
        uint256 productFee
    ) private pure returns (uint256) {
        return (margin * leverage * productFee) / 10**12;
    }

    function _calculatePrice(
        address productToken,
        bool isLong,
        uint256 openInterestLong,
        uint256 openInterestShort,
        uint256 maxExposure,
        uint256 reserve,
        uint256 amount
    ) private view returns (uint256) {
        uint256 oraclePrice = IOracle(oracle).getPrice(productToken, isLong);

        if (reserve > 0) {
            int256 shift = ((int256(openInterestLong) - int256(openInterestShort)) * int256(maxShift)) /
                int256(maxExposure);

            if (isLong) {
                uint256 slippage = (((reserve * reserve) / (reserve - amount) - reserve) * 10**8) / amount;
                slippage = shift >= 0 ? slippage + uint256(shift) : slippage - (uint256(-1 * shift) / shiftDivider);
                return (oraclePrice * slippage) / 10**8;
            } else {
                uint256 slippage = ((reserve - (reserve * reserve) / (reserve + amount)) * 10**8) / amount;
                slippage = shift >= 0 ? slippage + (uint256(shift) / shiftDivider) : slippage - uint256(-1 * shift);
                return (oraclePrice * slippage) / 10**8;
            }
        } else {
            return oraclePrice;
        }
    }

    function _updateFundingAndOpenInterest(
        uint256 productId,
        uint256 amount,
        bool isLong,
        bool isIncrease
    ) private {
        Funding storage funding = fundings[productId];

        if (funding.timestamp != 0) {
            int256 fundingRate = getFundingRate(productId);
            funding.total += (fundingRate * int256(block.timestamp - funding.timestamp)) / int256(365 days);
        }
        funding.timestamp = block.timestamp;

        Product storage product = products[productId];

        if (isIncrease) {
            totalOpenInterest += amount;
            uint256 maxExposure = getMaxExposure(product.weight);
            require(totalOpenInterest <= (vault.balance * utilizationMultiplier) / 10**4, "!totalOpenInterest");
            require(
                product.openInterestLong + product.openInterestShort + amount <
                    (maxExposureMultiplier * maxExposure) / 10000,
                "!productOpenInterest"
            );

            if (isLong) {
                product.openInterestLong += amount;
                require(product.openInterestLong <= product.openInterestShort + maxExposure, "!openInterestLong");
            } else {
                product.openInterestShort += amount;
                require(product.openInterestShort <= product.openInterestLong + maxExposure, "!openInterestShort");
            }
        } else {
            totalOpenInterest -= amount;

            if (isLong) {
                if (product.openInterestLong >= amount) {
                    product.openInterestLong -= amount;
                } else {
                    product.openInterestLong = 0;
                }
            } else {
                if (product.openInterestShort >= amount) {
                    product.openInterestShort -= amount;
                } else {
                    product.openInterestShort = 0;
                }
            }
        }
    }

    function _getFundingPayment(
        bool isLong,
        uint256 productId,
        uint256 positionLeverage,
        uint256 margin,
        int256 funding
    ) private view returns (int256) {
        return
            isLong
                ? (int256(margin * positionLeverage) * (fundings[productId].total - funding)) / int256(1e20)
                : (int256(margin * positionLeverage) * (funding - fundings[productId].total)) / int256(1e20);
    }

    function _getPnl(
        bool isLong,
        uint256 positionPrice,
        uint256 positionLeverage,
        uint256 margin,
        uint256 price
    ) private pure returns (int256) {
        if (isLong) {
            if (price >= positionPrice) {
                return int256((margin * positionLeverage * (price - positionPrice)) / positionPrice / 10**8);
            } else {
                return -1 * int256((margin * positionLeverage * (positionPrice - price)) / positionPrice / 10**8);
            }
        } else {
            if (price > positionPrice) {
                return -1 * int256((margin * positionLeverage * (price - positionPrice)) / positionPrice / 10**8);
            } else {
                return int256((margin * positionLeverage * (positionPrice - price)) / positionPrice / 10**8);
            }
        }
    }

    function _updateFeeWithReferral(address user, uint256 tradeFee) private {
        (address referrer, uint256 referrerRebate, uint256 traderRebate) = IReferralManager(referralManager)
            .getReferrerInfo(user);
        uint256 _tradeFee = (tradeFee * tokenBase) / 10**8;

        if (referrer != address(0)) {
            uint256 referrerRebateAmount = (_tradeFee * referrerRebate) / 10**4;
            uint256 traderRebateAmount = (_tradeFee * traderRebate) / 10**4;
            claimableReferrerRebates[referrer] += referrerRebateAmount;
            claimableTraderRebates[user] += traderRebateAmount;

            _updatePendingRewards(_tradeFee - referrerRebateAmount - traderRebateAmount);
        } else {
            _updatePendingRewards(_tradeFee);
        }
    }

    function _updatePendingRewards(uint256 reward) private {
        uint256 vaultReward = (reward * vaultRewardRatio) / 10**4;
        pendingVaultReward += vaultReward;
        pendingStakingReward += reward - vaultReward;
    }

    function getVault() external view returns (Vault memory) {
        return vault;
    }

    function getVaultShares() external view returns (uint256) {
        return vault.shares;
    }

    function getStake(address user) external view returns (Stake memory) {
        return stakes[user];
    }

    function getStakeShares(address user) external view returns (uint256) {
        return stakes[user].shares;
    }

    function getProduct(uint256 productId) external view returns (Product memory) {
        return products[productId];
    }

    function getProductToken(uint256 productId) external view returns (address) {
        return products[productId].productToken;
    }

    function getFunding(uint256 productId) external view returns (Funding memory) {
        return fundings[productId];
    }

    function getPositionKey(
        address account,
        uint256 productId,
        bool isLong
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, productId, isLong));
    }

    function getPosition(
        address account,
        uint256 productId,
        bool isLong
    ) external view returns (Position memory) {
        return positions[getPositionKey(account, productId, isLong)];
    }

    function getPositionLeverage(
        address account,
        uint256 productId,
        bool isLong
    ) external view returns (uint256) {
        return positions[getPositionKey(account, productId, isLong)].leverage;
    }

    function getUserPositions(address user) external view returns (Position[] memory userPositions) {
        uint256 _totalProducts = totalProducts;
        userPositions = new Position[](_totalProducts * 2);
        bytes32 positionKey;
        uint256 count;

        for (uint256 i = 1; i <= _totalProducts; ++i) {
            positionKey = getPositionKey(user, i, true);
            if (positions[positionKey].owner != address(0)) userPositions[count++] = positions[positionKey];

            positionKey = getPositionKey(user, i, false);
            if (positions[positionKey].owner != address(0)) userPositions[count++] = positions[positionKey];
        }
    }

    function isPositionExists(
        address account,
        uint256 productId,
        bool isLong
    ) external view returns (bool) {
        return positions[getPositionKey(account, productId, isLong)].owner != address(0);
    }

    function getTradeFee(
        uint256 margin,
        uint256 leverage,
        uint256 productId
    ) external view returns (uint256) {
        return (margin * leverage * products[productId].fee) / 10**12;
    }

    function getPendingVaultReward() external view returns (uint256) {
        return pendingVaultReward;
    }

    function getPendingStakingReward() external view returns (uint256) {
        return pendingStakingReward;
    }

    function setPeripheralContracts(
        address _oracle,
        address _referralManager,
        address _positionManager,
        address _orderManager,
        address _vaultRewardReceiver,
        address _stakingRewardReceiver,
        address _vaultRewardRouter
    ) external onlyGov {
        oracle = _oracle;
        referralManager = _referralManager;
        positionManager = _positionManager;
        orderManager = _orderManager;
        vaultRewardReceiver = _vaultRewardReceiver;
        stakingRewardReceiver = _stakingRewardReceiver;
        vaultRewardRouter = _vaultRewardRouter;

        emit SetPeripheralContracts(
            _oracle,
            _referralManager,
            _positionManager,
            _orderManager,
            _vaultRewardReceiver,
            _stakingRewardReceiver,
            _vaultRewardRouter
        );
    }

    function updateVault(uint256 _cap, uint256 _minTime) external onlyGov {
        require(_minTime <= 3 days, "!minTime");

        vault.cap = _cap;
        vault.minTime = _minTime;

        emit UpdateVault(vault);
    }

    function addProduct(uint256 productId, Product memory _product) external onlyGov {
        Product memory product = products[productId];

        require(productId > 0, "invalid productId");
        require(product.maxLeverage == 0 && _product.maxLeverage >= 1 * BASE && _product.productToken != address(0));

        products[productId] = Product({
            productToken: _product.productToken,
            isActive: true,
            maxLeverage: _product.maxLeverage,
            fee: _product.fee,
            weight: _product.weight,
            reserve: _product.reserve,
            openInterestLong: 0,
            openInterestShort: 0
        });

        totalWeight = totalWeight + _product.weight;
        totalProducts += 1;

        emit AddProduct(productId, products[productId]);
    }

    function updateProduct(uint256 productId, Product memory _product) external onlyGov {
        Product storage product = products[productId];

        require(productId > 0, "invalid productId");
        require(product.maxLeverage > 0 && _product.maxLeverage >= 1 * BASE && _product.productToken != address(0));

        totalWeight = totalWeight - product.weight + _product.weight;

        product.productToken = _product.productToken;
        product.isActive = _product.isActive;
        product.maxLeverage = _product.maxLeverage;
        product.fee = _product.fee;
        product.weight = _product.weight;
        product.reserve = _product.reserve;

        emit UpdateProduct(productId, product);
    }

    function setFundingMultiplier(uint256 productId, uint256 multiplier) external onlyGov {
        fundings[productId].multiplier = multiplier;
        emit SetFundingMultiplier(productId, multiplier);
    }

    function setParameter(uint256 index, uint256 value) external onlyGov {
        require(index >= 1 && index <= 9, "invalid index for parameter");

        if (index == 1) {
            minMargin = value;
        } else if (index == 2) {
            minLeverage = value;
        } else if (index == 3) {
            require(value < 0.01e8);
            maxShift = value;
        } else if (index == 4) {
            require(value > 0);
            shiftDivider = value;
        } else if (index == 5) {
            utilizationMultiplier = value;
        } else if (index == 6) {
            exposureMultiplier = value;
        } else if (index == 7) {
            require(value > 0);
            maxExposureMultiplier = value;
        } else if (index == 8) {
            require(value >= 9000);
            liquidationThreshold = value;
        } else if (index == 9) {
            maxFundingRate = value;
        }

        emit SetParameter(index, value);
    }

    function setRewardRatio(uint256 _vaultRewardRatio) external onlyGov {
        require(_vaultRewardRatio <= 10000);
        vaultRewardRatio = _vaultRewardRatio;
        stakingRewardRatio = 10000 - _vaultRewardRatio;
        emit SetRewardRatio(vaultRewardRatio, stakingRewardRatio);
    }

    function setLiquidator(address _liquidator, bool _isActive) external onlyGov {
        liquidators[_liquidator] = _isActive;
        emit SetLiquidator(_liquidator, _isActive);
    }

    function setGuardian(address _guardian, bool _isActive) external onlyGov {
        guardians[_guardian] = _isActive;
        emit SetGuardian(_guardian, _isActive);
    }

    function emergencyPause() external {
        require(guardians[msg.sender], "!guardian");
        isOpenPositionEnabled = false;
        isStakeEnabled = false;
        emit EmergencyPause(block.timestamp);
    }

    function unpause() external onlyGov {
        isOpenPositionEnabled = true;
        isStakeEnabled = true;
        emit Unpause(block.timestamp);
    }
}
