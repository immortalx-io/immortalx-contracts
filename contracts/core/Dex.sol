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
    uint256 public liquidationThreshold = 9850;
    uint256 public maxFundingRate = 10 * FUNDING_BASE;
    uint256 public vaultRewardRatio = 6000;
    uint256 public stakingRewardRatio = 4000;
    uint256 private pendingVaultReward;
    uint256 private pendingStakingReward;
    uint256 private immutable tokenBase;
    uint256 private constant BASE = 10**8;
    uint256 private constant PARAM_BASE = 10**4;
    uint256 private constant TRADEFEE_BASE = 10**5;
    uint256 private constant FUNDING_BASE = 10**12;

    bool public isStakeEnabled = true;
    bool public isOpenPositionEnabled = true;

    mapping(address => Stake) private stakes;
    mapping(uint256 => Product) private products;
    mapping(uint256 => Funding) private fundings;
    mapping(bytes32 => Position) public positions;
    mapping(address => uint256) public totalReferrerRebates;
    mapping(address => uint256) public totalTraderRebates;
    mapping(address => uint256) public claimedReferrerRebates;
    mapping(address => uint256) public claimedTraderRebates;
    mapping(address => bool) public liquidators;
    mapping(address => bool) public guardians;

    Vault private vault;

    event StakeVault(address indexed user, uint256 amount, uint256 shares);
    event UnstakeVault(address indexed user, uint256 amount, uint256 shares, uint256 shareBalance, bool isFullRedeem);
    event OpenPosition(
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
        bool isLiquidated,
        uint256 productId,
        uint256 price,
        uint256 entryPrice,
        uint256 margin,
        uint256 leverage,
        int256 pnl,
        int256 fundingFee
    );
    event UpdateFunding(uint256 productId, int256 total, int256 fundingRate);
    event AddMargin(
        bytes32 indexed positionKey,
        address indexed user,
        bool isLong,
        uint256 productId,
        uint256 margin,
        uint256 newMargin,
        uint256 leverage,
        uint256 newLeverage
    );
    event LiquidationError(bytes32 indexed positionKey, string executionError);
    event ClaimReferrerRebates(address indexed user, uint256 amount);
    event ClaimTraderRebates(address indexed user, uint256 amount);
    event ReferralVolume(address referrer, address trader, uint256 volume);
    event DistributeVaultReward(uint256 amount);
    event DistributeStakingReward(uint256 amount);
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
        IERC20(token).safeTransferFrom(msg.sender, address(this), (amount * tokenBase) / BASE);

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
        require(totalOpenInterest <= (vault.balance * utilizationMultiplier) / PARAM_BASE, "vault is being utilized");
        IERC20(token).safeTransfer(user, (shareBalance * tokenBase) / BASE);

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

        uint256 size = (margin * leverage) / BASE;
        uint256 tradeFee = (size * product.fee) / TRADEFEE_BASE;
        IERC20(token).safeTransferFrom(msg.sender, address(this), ((margin + tradeFee) * tokenBase) / BASE);

        _updateFeeWithReferral(user, tradeFee, size);

        uint256 price = _calculatePrice(
            productId,
            isLong,
            product.openInterestLong,
            product.openInterestShort,
            getMaxExposure(product.weight),
            product.reserve,
            size
        );

        _updateFundingAndOpenInterest(productId, size, isLong, true);
        int256 funding = fundings[productId].total;

        bytes32 positionKey = getPositionKey(user, productId, isLong);
        Position memory position = positions[positionKey];
        if (position.margin > 0) {
            price =
                (position.margin * position.leverage * position.price + margin * leverage * price) /
                (position.margin * position.leverage + margin * leverage);
            funding =
                (int256(position.margin * position.leverage) * position.funding + int256(margin * leverage) * funding) /
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

        emit OpenPosition(positionKey, user, isLong, productId, margin, leverage, price, tradeFee, funding);
    }

    function addMargin(
        uint256 productId,
        bool isLong,
        uint256 margin
    ) external nonReentrant {
        bytes32 positionKey = getPositionKey(msg.sender, productId, isLong);
        Position storage position = positions[positionKey];

        uint256 newMargin = position.margin + margin;
        uint256 leverage = position.leverage;
        uint256 newLeverage = (leverage * position.margin) / newMargin;
        require(newLeverage >= minLeverage, "!minleverage");

        IERC20(token).safeTransferFrom(msg.sender, address(this), (margin * tokenBase) / BASE);
        position.margin = newMargin;
        position.leverage = newLeverage;

        emit AddMargin(positionKey, msg.sender, isLong, productId, margin, newMargin, leverage, newLeverage);
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
        require(msg.sender == positionManager || msg.sender == orderManager, "!manager");
        if (margin == 0) return;

        Position storage position = positions[positionKey];
        if (position.owner == address(0)) return; // position does not exist

        Product memory product = products[position.productId];

        if (margin > position.margin) {
            margin = position.margin;
        }

        uint256 size = (margin * position.leverage) / BASE;
        uint256 price = _calculatePrice(
            position.productId,
            !position.isLong,
            product.openInterestLong,
            product.openInterestShort,
            getMaxExposure(product.weight),
            product.reserve,
            size
        );

        _updateFundingAndOpenInterest(position.productId, size, position.isLong, false);
        int256 fundingFee = getFundingFee(position.isLong, position.productId, size, position.funding);

        int256 pnl = getPnl(position.isLong, position.price, position.leverage, margin, price) - fundingFee;
        if (pnl < 0) {
            require(uint256(-1 * pnl) < (margin * liquidationThreshold) / PARAM_BASE, "position should be liquidated");
        }

        uint256 tradeFee = (size * product.fee) / TRADEFEE_BASE;
        int256 pnlAfterFee = pnl - int256(tradeFee);

        if (pnlAfterFee < 0) {
            uint256 _pnlAfterFee = uint256(-1 * pnlAfterFee);

            if (_pnlAfterFee < margin) {
                IERC20(token).safeTransfer(position.owner, ((margin - _pnlAfterFee) * tokenBase) / BASE);
                vault.balance += _pnlAfterFee;
            } else {
                vault.balance += margin;
            }
        } else {
            uint256 _pnlAfterFee = uint256(pnlAfterFee);
            require(vault.balance >= _pnlAfterFee, "insufficient vault balance");

            IERC20(token).safeTransfer(position.owner, ((margin + _pnlAfterFee) * tokenBase) / BASE);
            vault.balance -= _pnlAfterFee;
        }

        _updateFeeWithReferral(position.owner, tradeFee, size);
        vault.balance -= tradeFee;

        emit ClosePosition(
            positionKey,
            position.owner,
            false,
            position.productId,
            price,
            position.price,
            margin,
            position.leverage,
            pnl,
            fundingFee
        );

        if (margin == position.margin) {
            IOrderManager(orderManager).cancelActiveCloseOrders(position.owner, position.productId, position.isLong);
            delete positions[positionKey];
        } else {
            position.margin -= margin;
        }
    }

    function liquidatePositions(bytes32[] calldata positionKeys) external {
        require(liquidators[msg.sender], "!liquidator");

        for (uint256 i = 0; i < positionKeys.length; ++i) {
            try this.liquidatePosition(positionKeys[i]) {} catch Error(string memory errorMessage) {
                emit LiquidationError(positionKeys[i], errorMessage);
            } catch (bytes memory) {}
        }
    }

    function liquidatePosition(bytes32 positionKey) external {
        require(msg.sender == address(this), "invalid liquidator");

        Position memory position = positions[positionKey];
        if (position.owner == address(0)) return; // position does not exist

        Product memory product = products[position.productId];

        uint256 size = (position.margin * position.leverage) / BASE;
        uint256 price = IOracle(oracle).getPrice(position.productId);

        _updateFundingAndOpenInterest(position.productId, size, position.isLong, false);
        int256 fundingFee = getFundingFee(position.isLong, position.productId, size, position.funding);

        int256 pnl = getPnl(position.isLong, position.price, position.leverage, position.margin, price) - fundingFee;
        require(
            pnl < 0 && uint256(-1 * pnl) >= (position.margin * liquidationThreshold) / PARAM_BASE,
            "position is not liquidatable"
        );

        uint256 tradeFee = (size * product.fee) / TRADEFEE_BASE;
        _updateFeeWithReferral(position.owner, tradeFee, size);
        vault.balance += position.margin - tradeFee;

        emit ClosePosition(
            positionKey,
            position.owner,
            true,
            position.productId,
            price,
            position.price,
            position.margin,
            position.leverage,
            -1 * int256(position.margin),
            fundingFee
        );

        IOrderManager(orderManager).cancelActiveCloseOrders(position.owner, position.productId, position.isLong);
        delete positions[positionKey];
    }

    function claimReferrerRebates() external nonReentrant {
        uint256 claimableReferrerRebates = totalReferrerRebates[msg.sender] - claimedReferrerRebates[msg.sender];
        require(claimableReferrerRebates > 0, "Not claimable");

        claimedReferrerRebates[msg.sender] += claimableReferrerRebates;
        IERC20(token).safeTransfer(msg.sender, claimableReferrerRebates);

        emit ClaimReferrerRebates(msg.sender, claimableReferrerRebates);
    }

    function claimTraderRebates() external nonReentrant {
        uint256 claimableTraderRebates = totalTraderRebates[msg.sender] - claimedTraderRebates[msg.sender];
        require(claimableTraderRebates > 0, "Not claimable");

        claimedTraderRebates[msg.sender] += claimableTraderRebates;
        IERC20(token).safeTransfer(msg.sender, claimableTraderRebates);

        emit ClaimTraderRebates(msg.sender, claimableTraderRebates);
    }

    function distributeVaultReward() external returns (uint256) {
        address _vaultRewardReceiver = vaultRewardReceiver;
        uint256 _pendingVaultReward = pendingVaultReward;
        require(msg.sender == _vaultRewardReceiver, "!vaultRewardReceiver");

        if (_pendingVaultReward > 0) {
            pendingVaultReward = 0;
            IERC20(token).safeTransfer(_vaultRewardReceiver, _pendingVaultReward);

            emit DistributeVaultReward(_pendingVaultReward);
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

            emit DistributeStakingReward(_pendingStakingReward);
        }
        return _pendingStakingReward;
    }

    function getMaxExposure(uint256 productWeight) public view returns (uint256) {
        return (vault.balance * productWeight * exposureMultiplier) / totalWeight / PARAM_BASE;
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

    function _calculatePrice(
        uint256 productId,
        bool isLong,
        uint256 openInterestLong,
        uint256 openInterestShort,
        uint256 maxExposure,
        uint256 reserve,
        uint256 amount
    ) private view returns (uint256) {
        uint256 oraclePrice = IOracle(oracle).getPrice(productId, isLong);

        if (reserve > 0) {
            int256 shift = ((int256(openInterestLong) - int256(openInterestShort)) * int256(maxShift)) /
                int256(maxExposure);

            if (isLong) {
                uint256 slippage = (((reserve * reserve) / (reserve - amount) - reserve) * BASE) / amount;
                slippage = shift >= 0 ? slippage + uint256(shift) : slippage - (uint256(-1 * shift) / shiftDivider);
                return (oraclePrice * slippage) / BASE;
            } else {
                uint256 slippage = ((reserve - (reserve * reserve) / (reserve + amount)) * BASE) / amount;
                slippage = shift >= 0 ? slippage + (uint256(shift) / shiftDivider) : slippage - uint256(-1 * shift);
                return (oraclePrice * slippage) / BASE;
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
            emit UpdateFunding(productId, funding.total, fundingRate);
        }
        funding.timestamp = block.timestamp;

        Product storage product = products[productId];

        if (isIncrease) {
            totalOpenInterest += amount;
            uint256 maxExposure = getMaxExposure(product.weight);
            require(totalOpenInterest <= (vault.balance * utilizationMultiplier) / PARAM_BASE, "!totalOpenInterest");
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

    function getFundingFee(
        bool isLong,
        uint256 productId,
        uint256 size,
        int256 funding
    ) public view returns (int256) {
        return
            isLong
                ? (int256(size) * (fundings[productId].total - funding)) / int256(FUNDING_BASE)
                : (int256(size) * (funding - fundings[productId].total)) / int256(FUNDING_BASE);
    }

    function getPnl(
        bool isLong,
        uint256 positionPrice,
        uint256 positionLeverage,
        uint256 margin,
        uint256 price
    ) public pure returns (int256) {
        if (isLong) {
            if (price >= positionPrice) {
                return int256((margin * positionLeverage * (price - positionPrice)) / positionPrice / BASE);
            } else {
                return -1 * int256((margin * positionLeverage * (positionPrice - price)) / positionPrice / BASE);
            }
        } else {
            if (price > positionPrice) {
                return -1 * int256((margin * positionLeverage * (price - positionPrice)) / positionPrice / BASE);
            } else {
                return int256((margin * positionLeverage * (positionPrice - price)) / positionPrice / BASE);
            }
        }
    }

    function _updateFeeWithReferral(
        address user,
        uint256 tradeFee,
        uint256 size
    ) private {
        (address referrer, uint256 referrerRebate, uint256 traderRebate) = IReferralManager(referralManager)
            .getReferrerInfo(user);
        uint256 _tradeFee = (tradeFee * tokenBase) / BASE;

        if (referrer != address(0)) {
            uint256 referrerRebateAmount = (_tradeFee * referrerRebate) / PARAM_BASE;
            uint256 traderRebateAmount = (_tradeFee * traderRebate) / PARAM_BASE;
            totalReferrerRebates[referrer] += referrerRebateAmount;
            totalTraderRebates[user] += traderRebateAmount;

            emit ReferralVolume(referrer, user, size);

            _updatePendingRewards(_tradeFee - referrerRebateAmount - traderRebateAmount);
        } else {
            _updatePendingRewards(_tradeFee);
        }
    }

    function _updatePendingRewards(uint256 reward) private {
        uint256 vaultReward = (reward * vaultRewardRatio) / PARAM_BASE;
        pendingVaultReward += vaultReward;
        pendingStakingReward += reward - vaultReward;
    }

    function validateOpenPositionRequirements(
        uint256 margin,
        uint256 leverage,
        uint256 productId
    ) external view {
        require(isOpenPositionEnabled, "open position is disabled");
        require(margin >= minMargin && margin < type(uint64).max, "!margin");
        require(leverage >= minLeverage, "!minLeverage");
        require(products[productId].isActive, "!active");
        require(leverage <= products[productId].maxLeverage, "!maxLeverage");
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

    function getUserPositions(
        address user,
        uint256 startId,
        uint256 endId
    ) external view returns (Position[] memory userPositions) {
        require(startId > 0, "!startId");
        if (endId > totalProducts) endId = totalProducts;
        userPositions = new Position[]((endId - startId + 1) * 2);
        bytes32 positionKey;
        uint256 count;

        for (uint256 i = startId; i <= endId; ++i) {
            positionKey = getPositionKey(user, i, true);
            if (positions[positionKey].owner != address(0)) userPositions[count++] = positions[positionKey];

            positionKey = getPositionKey(user, i, false);
            if (positions[positionKey].owner != address(0)) userPositions[count++] = positions[positionKey];
        }
    }

    function getFundingData(uint256 startId, uint256 endId)
        external
        view
        returns (int256[] memory fundingRates, int256[] memory fundingTotals)
    {
        require(startId > 0, "!startId");
        if (endId > totalProducts) endId = totalProducts;
        fundingRates = new int256[]((endId - startId + 1) * 2);
        fundingTotals = new int256[]((endId - startId + 1) * 2);

        for (uint256 i = startId; i <= endId; ++i) {
            fundingRates[i - 1] = getFundingRate(i);
            fundingTotals[i - 1] = fundings[i].total;
        }
    }

    function getTradeFee(
        uint256 margin,
        uint256 leverage,
        uint256 productId
    ) external view returns (uint256) {
        return (margin * leverage * products[productId].fee) / (BASE * TRADEFEE_BASE);
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

    function addProduct(
        uint256 productId,
        uint256 _maxLeverage,
        uint256 _fee,
        uint256 _weight,
        uint256 _reserve
    ) external onlyGov {
        require(productId > 0, "invalid productId");

        Product memory product = products[productId];
        require(product.maxLeverage == 0, "product exists");

        require(_maxLeverage >= 1 * BASE && _fee <= 10**3, "invalid product");
        products[productId] = Product({
            isActive: true,
            maxLeverage: _maxLeverage,
            fee: _fee,
            weight: _weight,
            reserve: _reserve,
            openInterestLong: 0,
            openInterestShort: 0
        });

        totalWeight += _weight;
        totalProducts += 1;

        emit AddProduct(productId, products[productId]);
    }

    function updateProduct(
        uint256 productId,
        bool _isActive,
        uint256 _maxLeverage,
        uint256 _fee,
        uint256 _weight,
        uint256 _reserve
    ) external onlyGov {
        require(productId > 0, "invalid productId");

        Product storage product = products[productId];
        require(product.maxLeverage > 0, "product not exists");

        require(_maxLeverage >= 1 * BASE && _fee <= 10**3, "invalid product");
        totalWeight = totalWeight - product.weight + _weight;

        product.isActive = _isActive;
        product.maxLeverage = _maxLeverage;
        product.fee = _fee;
        product.weight = _weight;
        product.reserve = _reserve;

        emit UpdateProduct(productId, product);
    }

    function setFundingMultiplier(uint256 productId, uint256 multiplier) external onlyGov {
        fundings[productId].multiplier = multiplier;
        emit SetFundingMultiplier(productId, multiplier);
    }

    function setParameter(uint256 index, uint256 value) external onlyGov {
        require(index >= 1 && index <= 9, "invalid index for parameter");

        if (index == 1) {
            require(value >= 25 * BASE, "invalid minMargin");
            minMargin = value;
        } else if (index == 2) {
            require(value <= 1 * BASE, "invalid minLeverage");
            minLeverage = value;
        } else if (index == 3) {
            require(value < 0.01e8, "invalid maxShift");
            maxShift = value;
        } else if (index == 4) {
            require(value > 0, "invalid shiftDivider");
            shiftDivider = value;
        } else if (index == 5) {
            require(value > 0, "invalid utilizationMultiplier");
            utilizationMultiplier = value;
        } else if (index == 6) {
            require(value > 0, "invalid exposureMultiplier");
            exposureMultiplier = value;
        } else if (index == 7) {
            require(value > 0, "invalid maxExposureMultiplier");
            maxExposureMultiplier = value;
        } else if (index == 8) {
            require(value >= 9500, "invalid liquidationThreshold");
            liquidationThreshold = value;
        } else if (index == 9) {
            require(value <= 10 * FUNDING_BASE, "invalid maxFundingRate");
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
