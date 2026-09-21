// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { IStockPriceFeed } from "./interfaces/IVaultKeeper.sol";

/// @title PriceFeed
/// @notice Multi-source oracle aggregator for tokenised equities.
///
/// @dev Aggregation is a **true weighted median**: sources are sorted by price before
///      the cumulative-weight walk, so the result depends on reported prices and
///      weights only — never on the order in which sources were configured.
///
///      Implemented source types are `Chainlink` and `Pyth`. `Redstone` and
///      `UniswapTWAP` exist in the enum for forward compatibility but are rejected at
///      configuration time by {addSource}, so a source that can never produce a price
///      cannot be registered.
///
///      Deviations larger than {deviationBps} trip a **per-asset** circuit breaker
///      which persists on-chain, blocks that one asset's price from being read, and
///      requires an explicit {resetCircuitBreaker} or {overridePrice} before the asset
///      can be updated again. Other assets are unaffected.
contract PriceFeed is IStockPriceFeed, Ownable2Step {
    // ────────────────────────────────────────────────────────────────────────
    //  Constants
    // ────────────────────────────────────────────────────────────────────────

    uint256 public constant MAX_SOURCES_PER_ASSET = 5;
    uint256 public constant MAX_DEVIATION_BPS = 5_000; // 50%
    uint256 public constant DEFAULT_STALENESS = 3_600; // 1 hour
    uint256 public constant MIN_STALENESS = 60; // 1 minute
    uint256 public constant MAX_STALENESS = 86_400; // 24 hours
    uint256 public constant HEARTBEAT_GRACE = 300; // 5 minutes
    uint256 public constant MAX_ASSETS = 64;
    uint256 public constant HISTORY_SIZE = 10;
    uint8 public constant MAX_PRICE_DECIMALS = 36;

    // ────────────────────────────────────────────────────────────────────────
    //  Types
    // ────────────────────────────────────────────────────────────────────────

    enum SourceType {
        Chainlink,
        Pyth,
        Redstone,
        UniswapTWAP
    }

    struct PriceSource {
        address sourceAddress;
        SourceType sourceType;
        uint256 weight; // basis points
        bool isActive;
        uint256 lastSuccess;
        uint256 consecutiveFailures;
        bytes32 pythPriceId;
    }

    struct PriceData {
        uint256 price;
        uint256 confidence;
        uint256 updatedAt;
        uint256 sourceCount;
        bool isStale;
    }

    struct HistoricalPrice {
        uint256 price;
        uint256 timestamp;
    }

    struct AggregationResult {
        uint256 price;
        uint256 confidence;
        uint256 sourceCount;
        uint256 minPrice;
        uint256 maxPrice;
        uint256 spread;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Immutables / configuration
    // ────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IStockPriceFeed
    uint8 public immutable override decimals;

    address public oracleManager;
    address public pauser;
    bool public paused;

    uint256 public globalStaleness;
    uint256 public deviationBps;
    uint256 public circuitBreakerCooldown;

    // ────────────────────────────────────────────────────────────────────────
    //  State
    // ────────────────────────────────────────────────────────────────────────

    mapping(address => PriceSource[]) private _sources;
    mapping(address => PriceData) private _priceData;
    mapping(address => uint256) public assetStaleness;
    mapping(address => bool) public isAssetRegistered;
    mapping(address => HistoricalPrice[HISTORY_SIZE]) private _priceHistory;
    mapping(address => uint256) private _historyIndex;

    /// @notice Whether the deviation breaker is currently tripped for an asset.
    mapping(address => bool) public circuitBreakerActive;
    mapping(address => uint256) public circuitBreakerTriggeredAt;

    address[] private _registeredAssets;
    uint256 public registeredAssetCount;

    // ────────────────────────────────────────────────────────────────────────
    //  Events
    // ────────────────────────────────────────────────────────────────────────

    event PriceUpdated(
        address indexed asset, uint256 price, uint256 confidence, uint256 updatedAt, uint256 sourceCount
    );
    event SourceAdded(address indexed asset, address sourceAddress, SourceType sourceType, uint256 weight);
    event SourceRemoved(address indexed asset, address sourceAddress);
    event SourceUpdated(address indexed asset, address sourceAddress, uint256 oldWeight, uint256 newWeight);
    event AssetRegistered(address indexed asset);
    event AssetDeregistered(address indexed asset);
    event StalenessOverrideSet(address indexed asset, uint256 threshold);
    event CircuitBreakerTriggered(address indexed asset, uint256 oldPrice, uint256 newPrice, uint256 deviationBps);
    event CircuitBreakerReset(address indexed asset, address by);
    event PauseStateChanged(bool paused, string reason);
    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);
    event OracleManagerUpdated(address oldManager, address newManager);
    event PauserUpdated(address oldPauser, address newPauser);
    event PriceOverride(address indexed asset, uint256 price, string reason);
    event SourceHealthChanged(address indexed asset, address sourceAddress, bool isActive, uint256 failures);

    // ────────────────────────────────────────────────────────────────────────
    //  Errors
    // ────────────────────────────────────────────────────────────────────────

    error Unauthorized(address caller, string role);
    error ContractPaused();
    error AssetNotRegistered(address asset);
    error AssetAlreadyRegistered(address asset);
    error SourceNotFound(address asset, address sourceAddress);
    error SourceAlreadyExists(address asset, address sourceAddress);
    error TooManySources(address asset, uint256 max);
    error PriceStale(address asset, uint256 lastUpdate, uint256 threshold);
    error ZeroPrice(address asset, string reason);
    error ExcessiveDeviation(address asset, uint256 oldPrice, uint256 newPrice, uint256 deviation, uint256 max);
    error InvalidWeight(uint256 weight, string reason);
    error InvalidStaleness(uint256 threshold, uint256 min, uint256 max);
    error NoValidSources(address asset);
    error TooManyAssets(uint256 count, uint256 max);
    error ZeroAddress();
    error InvalidPythPriceId();
    error UnsupportedSourceType(uint8 sourceType);
    error CircuitBreakerActive(address asset);
    error InvalidParameter(string param, uint256 value);

    // ────────────────────────────────────────────────────────────────────────
    //  Constructor
    // ────────────────────────────────────────────────────────────────────────

    constructor(
        address initialOwner,
        address oracleManager_,
        address pauser_,
        uint256 globalStaleness_,
        uint8 decimals_
    ) Ownable(initialOwner) {
        if (initialOwner == address(0) || oracleManager_ == address(0) || pauser_ == address(0)) {
            revert ZeroAddress();
        }
        if (globalStaleness_ < MIN_STALENESS || globalStaleness_ > MAX_STALENESS) {
            revert InvalidStaleness(globalStaleness_, MIN_STALENESS, MAX_STALENESS);
        }
        if (decimals_ > MAX_PRICE_DECIMALS) revert InvalidParameter("decimals", decimals_);

        oracleManager = oracleManager_;
        pauser = pauser_;
        globalStaleness = globalStaleness_;
        decimals = decimals_;
        deviationBps = MAX_DEVIATION_BPS;
        circuitBreakerCooldown = 300;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Asset management
    // ────────────────────────────────────────────────────────────────────────

    function registerAsset(address asset) external {
        _onlyOracleManager();
        _whenNotPaused();
        if (asset == address(0)) revert ZeroAddress();
        if (isAssetRegistered[asset]) revert AssetAlreadyRegistered(asset);
        if (registeredAssetCount >= MAX_ASSETS) revert TooManyAssets(registeredAssetCount + 1, MAX_ASSETS);

        isAssetRegistered[asset] = true;
        _registeredAssets.push(asset);
        ++registeredAssetCount;
        emit AssetRegistered(asset);
    }

    function deregisterAsset(address asset) external {
        _onlyOracleManager();
        if (!isAssetRegistered[asset]) revert AssetNotRegistered(asset);

        delete _sources[asset];
        delete _priceData[asset];
        delete assetStaleness[asset];
        delete _priceHistory[asset];
        delete circuitBreakerActive[asset];
        delete circuitBreakerTriggeredAt[asset];
        isAssetRegistered[asset] = false;

        _removeAssetFromList(asset);
        --registeredAssetCount;
        emit AssetDeregistered(asset);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Source management
    // ────────────────────────────────────────────────────────────────────────

    function addSource(address asset, address sourceAddress, SourceType sourceType, uint256 weight, bytes32 pythPriceId)
        external
    {
        _onlyOracleManager();
        _whenNotPaused();
        if (!isAssetRegistered[asset]) revert AssetNotRegistered(asset);
        if (sourceAddress == address(0)) revert ZeroAddress();
        if (weight == 0) revert InvalidWeight(weight, "ZERO");
        if (_sources[asset].length >= MAX_SOURCES_PER_ASSET) revert TooManySources(asset, MAX_SOURCES_PER_ASSET);

        // Reject types this contract cannot actually query, rather than accepting a
        // source that silently never yields a price.
        if (sourceType != SourceType.Chainlink && sourceType != SourceType.Pyth) {
            revert UnsupportedSourceType(uint8(sourceType));
        }
        if (sourceType == SourceType.Pyth && pythPriceId == bytes32(0)) revert InvalidPythPriceId();

        uint256 len = _sources[asset].length;
        for (uint256 i; i < len; ++i) {
            if (_sources[asset][i].sourceAddress == sourceAddress) revert SourceAlreadyExists(asset, sourceAddress);
        }

        _sources[asset].push(
            PriceSource({
                sourceAddress: sourceAddress,
                sourceType: sourceType,
                weight: weight,
                isActive: true,
                lastSuccess: 0,
                consecutiveFailures: 0,
                pythPriceId: pythPriceId
            })
        );

        emit SourceAdded(asset, sourceAddress, sourceType, weight);
    }

    function removeSource(address asset, address sourceAddress) external {
        _onlyOracleManager();
        PriceSource[] storage sources = _sources[asset];
        uint256 idx = _findSourceIndex(sources, sourceAddress);
        if (idx == type(uint256).max) revert SourceNotFound(asset, sourceAddress);

        sources[idx] = sources[sources.length - 1];
        sources.pop();
        emit SourceRemoved(asset, sourceAddress);
    }

    function updateSourceWeight(address asset, address sourceAddress, uint256 newWeight) external {
        _onlyOracleManager();
        if (newWeight == 0) revert InvalidWeight(newWeight, "ZERO");

        PriceSource[] storage sources = _sources[asset];
        uint256 idx = _findSourceIndex(sources, sourceAddress);
        if (idx == type(uint256).max) revert SourceNotFound(asset, sourceAddress);

        uint256 oldWeight = sources[idx].weight;
        sources[idx].weight = newWeight;
        emit SourceUpdated(asset, sourceAddress, oldWeight, newWeight);
    }

    function setSourceActive(address asset, address sourceAddress, bool isActive) external {
        _onlyOracleManager();
        PriceSource[] storage sources = _sources[asset];
        uint256 idx = _findSourceIndex(sources, sourceAddress);
        if (idx == type(uint256).max) revert SourceNotFound(asset, sourceAddress);

        sources[idx].isActive = isActive;
        emit SourceHealthChanged(asset, sourceAddress, isActive, sources[idx].consecutiveFailures);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Price updates
    // ────────────────────────────────────────────────────────────────────────

    function updatePrice(address asset) external {
        _onlyOracleManager();
        _updatePrice(asset);
    }

    /// @notice Updates several assets in one call.
    /// @dev Fail-fast by design: unlike the previous implementation this does not
    ///      swallow per-asset reverts, so a broken configuration surfaces immediately
    ///      instead of leaving prices silently un-updated.
    function updatePrices(address[] calldata assets) external {
        _onlyOracleManager();
        uint256 len = assets.length;
        for (uint256 i; i < len; ++i) {
            _updatePrice(assets[i]);
        }
    }

    function _updatePrice(address asset) internal {
        _whenNotPaused();
        if (!isAssetRegistered[asset]) revert AssetNotRegistered(asset);
        if (circuitBreakerActive[asset]) revert CircuitBreakerActive(asset);

        AggregationResult memory result = _aggregatePrice(asset);
        if (result.price == 0) revert ZeroPrice(asset, "AGGREGATION_FAILED");

        uint256 previous = _priceData[asset].price;
        if (previous > 0) {
            uint256 deviation = _calculateDeviation(previous, result.price);
            if (deviation > deviationBps) {
                // Persist the trip; the price is deliberately NOT adopted.
                circuitBreakerActive[asset] = true;
                circuitBreakerTriggeredAt[asset] = block.timestamp;
                emit CircuitBreakerTriggered(asset, previous, result.price, deviation);
                return;
            }
        }

        _adoptPrice(asset, result.price, result.confidence, result.sourceCount);
    }

    /// @notice Clears a tripped circuit breaker so the asset can be updated again.
    function resetCircuitBreaker(address asset) external {
        _onlyOracleManager();
        if (!circuitBreakerActive[asset]) revert CircuitBreakerActive(asset);
        circuitBreakerActive[asset] = false;
        emit CircuitBreakerReset(asset, msg.sender);
    }

    /// @notice Adopts `price` directly, bypassing the deviation check.
    /// @dev The governance escape hatch for genuinely large market moves.
    function overridePrice(address asset, uint256 price, string calldata reason) external {
        _onlyOracleManager();
        _whenNotPaused();
        if (!isAssetRegistered[asset]) revert AssetNotRegistered(asset);
        if (price == 0) revert ZeroPrice(asset, "OVERRIDE_ZERO");

        circuitBreakerActive[asset] = false;
        _adoptPrice(asset, price, 0, 0);
        emit PriceOverride(asset, price, reason);
    }

    function _adoptPrice(address asset, uint256 price, uint256 confidence, uint256 sourceCount) internal {
        _updateHistory(asset, price);
        _priceData[asset] = PriceData({
            price: price, confidence: confidence, updatedAt: block.timestamp, sourceCount: sourceCount, isStale: false
        });

        emit PriceUpdated(asset, price, confidence, block.timestamp, sourceCount);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Views
    // ────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IStockPriceFeed
    function getPrice(address asset) external view override returns (uint256 price) {
        if (!isAssetRegistered[asset]) revert AssetNotRegistered(asset);
        if (circuitBreakerActive[asset]) revert CircuitBreakerActive(asset);

        PriceData memory data = _priceData[asset];
        if (data.price == 0) revert ZeroPrice(asset, "NOT_SET");

        uint256 threshold = assetStaleness[asset] > 0 ? assetStaleness[asset] : globalStaleness;
        if (block.timestamp - data.updatedAt > threshold + HEARTBEAT_GRACE) {
            revert PriceStale(asset, data.updatedAt, threshold);
        }
        return data.price;
    }

    /// @inheritdoc IStockPriceFeed
    function lastUpdate(address asset) external view override returns (uint256) {
        return _priceData[asset].updatedAt;
    }

    /// @inheritdoc IStockPriceFeed
    function stalenessThreshold() external view override returns (uint256) {
        return globalStaleness;
    }

    /// @inheritdoc IStockPriceFeed
    function isPriceFresh(address asset) external view override returns (bool) {
        if (circuitBreakerActive[asset]) return false;

        PriceData memory data = _priceData[asset];
        if (data.price == 0) return false;

        uint256 threshold = assetStaleness[asset] > 0 ? assetStaleness[asset] : globalStaleness;
        return (block.timestamp - data.updatedAt) <= threshold;
    }

    function getPriceData(address asset) external view returns (PriceData memory) {
        return _priceData[asset];
    }

    function getSources(address asset) external view returns (PriceSource[] memory) {
        return _sources[asset];
    }

    function getRegisteredAssets() external view returns (address[] memory) {
        return _registeredAssets;
    }

    function getPriceHistory(address asset) external view returns (HistoricalPrice[HISTORY_SIZE] memory) {
        return _priceHistory[asset];
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Aggregation
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Collects every usable source, sorts by price, and returns the true
    ///      weighted median. Sorting is what makes the result order-independent.
    function _aggregatePrice(address asset) internal returns (AggregationResult memory result) {
        PriceSource[] storage sources = _sources[asset];
        uint256 len = sources.length;
        if (len == 0) revert NoValidSources(asset);

        uint256[] memory prices = new uint256[](len);
        uint256[] memory weights = new uint256[](len);
        uint256 validCount;
        uint256 totalWeight;
        uint256 confidenceSum;
        uint256 minPrice = type(uint256).max;
        uint256 maxPrice;

        for (uint256 i; i < len; ++i) {
            PriceSource storage src = sources[i];
            if (!src.isActive) continue;

            (bool success, uint256 price, uint256 confidence) = _fetchPrice(src, asset);
            if (success && price > 0) {
                prices[validCount] = price;
                weights[validCount] = src.weight;
                totalWeight += src.weight;
                confidenceSum += confidence;
                if (price < minPrice) minPrice = price;
                if (price > maxPrice) maxPrice = price;
                ++validCount;

                src.lastSuccess = block.timestamp;
                src.consecutiveFailures = 0;
            } else {
                ++src.consecutiveFailures;
                if (src.consecutiveFailures >= 3) {
                    src.isActive = false;
                    emit SourceHealthChanged(asset, src.sourceAddress, false, src.consecutiveFailures);
                }
            }
        }

        if (validCount == 0) revert NoValidSources(asset);

        _sortByPrice(prices, weights, validCount);

        result = AggregationResult({
            price: _weightedMedian(prices, weights, validCount, totalWeight),
            confidence: confidenceSum / validCount,
            sourceCount: validCount,
            minPrice: minPrice,
            maxPrice: maxPrice,
            spread: maxPrice - minPrice
        });
    }

    /// @dev Insertion sort over at most {MAX_SOURCES_PER_ASSET} entries.
    function _sortByPrice(uint256[] memory prices, uint256[] memory weights, uint256 len) internal pure {
        for (uint256 i = 1; i < len; ++i) {
            uint256 keyPrice = prices[i];
            uint256 keyWeight = weights[i];
            uint256 j = i;
            while (j > 0 && prices[j - 1] > keyPrice) {
                prices[j] = prices[j - 1];
                weights[j] = weights[j - 1];
                --j;
            }
            prices[j] = keyPrice;
            weights[j] = keyWeight;
        }
    }

    /// @dev Assumes `prices` is sorted ascending. Walks cumulative weight until it
    ///      passes half of the total, which is the weighted median by definition.
    function _weightedMedian(uint256[] memory prices, uint256[] memory weights, uint256 len, uint256 totalWeight)
        internal
        pure
        returns (uint256)
    {
        if (totalWeight == 0) return prices[len / 2];

        uint256 target = totalWeight / 2;
        uint256 cumulative;
        for (uint256 i; i < len; ++i) {
            cumulative += weights[i];
            if (cumulative > target) return prices[i];
        }
        return prices[len - 1];
    }

    function _fetchPrice(PriceSource storage src, address asset)
        internal
        view
        returns (bool success, uint256 price, uint256 confidence)
    {
        if (src.sourceType == SourceType.Chainlink) {
            return _fetchChainlink(src);
        }
        if (src.sourceType == SourceType.Pyth) {
            return _fetchPyth(src, asset);
        }
        // Unreachable: {addSource} rejects types that are not implemented.
        return (false, 0, 0);
    }

    function _fetchChainlink(PriceSource storage src) internal view returns (bool, uint256, uint256) {
        try AggregatorV3Interface(src.sourceAddress).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0 || updatedAt == 0) return (false, 0, 0);

            uint8 feedDecimals = AggregatorV3Interface(src.sourceAddress).decimals();
            // `answer > 0` is enforced by the guard above.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 normalized = _rescale(uint256(answer), feedDecimals, decimals);
            return (true, normalized, 0);
        } catch {
            return (false, 0, 0);
        }
    }

    function _fetchPyth(PriceSource storage src, address asset) internal view returns (bool, uint256, uint256) {
        if (src.pythPriceId == bytes32(0)) return (false, 0, 0);

        try IPyth(src.sourceAddress).getPriceUnsafe(src.pythPriceId) returns (PythStructs.Price memory p) {
            if (p.price <= 0 || p.publishTime == 0) return (false, 0, 0);

            uint256 threshold = assetStaleness[asset] > 0 ? assetStaleness[asset] : globalStaleness;
            if (block.timestamp > p.publishTime && block.timestamp - p.publishTime > threshold) {
                return (false, 0, 0);
            }

            // Pyth reports int64; the positivity guard above makes the widening safe.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 rawPrice = uint256(uint64(p.price));
            uint256 normalized = _rescalePyth(rawPrice, p.expo);
            if (normalized == 0) return (false, 0, 0);

            uint256 normalizedConfidence;
            if (p.conf > 0) {
                normalizedConfidence = _rescalePyth(uint64(p.conf), p.expo);
            }
            return (true, normalized, normalizedConfidence);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Re-scales a value from `fromDecimals` to `toDecimals`.
    function _rescale(uint256 value, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return value;
        if (fromDecimals > toDecimals) return value / (10 ** (fromDecimals - toDecimals));
        return value * (10 ** (toDecimals - fromDecimals));
    }

    /// @dev Converts a Pyth `(price, expo)` pair into this feed's fixed-point scale.
    ///      value = price * 10**expo, returned at `decimals` precision.
    function _rescalePyth(uint256 price, int32 expo) internal view returns (uint256) {
        uint8 target = decimals;
        if (expo >= 0) {
            // `expo >= 0` in this branch, so the signed->unsigned cast cannot wrap.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 shift = uint32(expo) + target;
            if (shift > 30) return 0; // guard against absurd exponents
            return price * (10 ** shift);
        }
        // `expo < 0` here; negating first keeps the value positive before widening.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 negExpo = uint32(-expo);
        if (negExpo <= target) {
            return price * (10 ** (target - negExpo));
        }
        return price / (10 ** (negExpo - target));
    }

    function _updateHistory(address asset, uint256 price) internal {
        uint256 idx = _historyIndex[asset];
        _priceHistory[asset][idx] = HistoricalPrice({ price: price, timestamp: block.timestamp });
        _historyIndex[asset] = (idx + 1) % HISTORY_SIZE;
    }

    function _calculateDeviation(uint256 oldPrice, uint256 newPrice) internal pure returns (uint256) {
        if (oldPrice == 0) return 0;
        uint256 diff = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
        return Math.mulDiv(diff, 10_000, oldPrice);
    }

    function _findSourceIndex(PriceSource[] storage sources, address sourceAddress) internal view returns (uint256) {
        uint256 len = sources.length;
        for (uint256 i; i < len; ++i) {
            if (sources[i].sourceAddress == sourceAddress) return i;
        }
        return type(uint256).max;
    }

    function _removeAssetFromList(address asset) internal {
        uint256 len = _registeredAssets.length;
        for (uint256 i; i < len; ++i) {
            if (_registeredAssets[i] == asset) {
                _registeredAssets[i] = _registeredAssets[len - 1];
                _registeredAssets.pop();
                return;
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Governance
    // ────────────────────────────────────────────────────────────────────────

    function setGlobalStaleness(uint256 newThreshold) external onlyOwner {
        _validateStaleness(newThreshold);
        uint256 old = globalStaleness;
        globalStaleness = newThreshold;
        emit ConfigUpdated("globalStaleness", old, newThreshold);
    }

    function setDeviationBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps > MAX_DEVIATION_BPS) revert InvalidWeight(newBps, "EXCEEDS_MAX");
        uint256 old = deviationBps;
        deviationBps = newBps;
        emit ConfigUpdated("deviationBps", old, newBps);
    }

    function setCircuitBreakerCooldown(uint256 cooldown) external onlyOwner {
        uint256 old = circuitBreakerCooldown;
        circuitBreakerCooldown = cooldown;
        emit ConfigUpdated("circuitBreakerCooldown", old, cooldown);
    }

    function setAssetStaleness(address asset, uint256 threshold) external onlyOwner {
        if (!isAssetRegistered[asset]) revert AssetNotRegistered(asset);
        if (threshold > 0 && threshold > MAX_STALENESS) revert InvalidStaleness(threshold, 0, MAX_STALENESS);
        assetStaleness[asset] = threshold;
        emit StalenessOverrideSet(asset, threshold);
    }

    function setOracleManager(address newManager) external onlyOwner {
        if (newManager == address(0)) revert ZeroAddress();
        address old = oracleManager;
        oracleManager = newManager;
        emit OracleManagerUpdated(old, newManager);
    }

    function setPauser(address newPauser) external onlyOwner {
        if (newPauser == address(0)) revert ZeroAddress();
        address old = pauser;
        pauser = newPauser;
        emit PauserUpdated(old, newPauser);
    }

    function pause(string calldata reason) external {
        _onlyPauser();
        paused = true;
        emit PauseStateChanged(true, reason);
    }

    function unpause() external {
        _onlyPauser();
        paused = false;
        emit PauseStateChanged(false, "");
    }

    function _validateStaleness(uint256 threshold) internal pure {
        if (threshold < MIN_STALENESS || threshold > MAX_STALENESS) {
            revert InvalidStaleness(threshold, MIN_STALENESS, MAX_STALENESS);
        }
    }

    function _onlyOracleManager() internal view {
        if (msg.sender != oracleManager) revert Unauthorized(msg.sender, "ORACLE_MANAGER");
    }

    function _onlyPauser() internal view {
        if (msg.sender != pauser && msg.sender != owner()) revert Unauthorized(msg.sender, "PAUSER");
    }

    function _whenNotPaused() internal view {
        if (paused) revert ContractPaused();
    }
}
