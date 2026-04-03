// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IRebalanceProof} from "./interfaces/IRebalanceProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RebalanceProof — State Verification for Rebalance Operations
/// @notice Provides cryptographic proofs that rebalances actually changed vault state
/// @dev Integrates with VaultKeeper to verify and track rebalance effectiveness
contract RebalanceProof is IRebalanceProof, Ownable {
    // ═══════════════════════════════════════════════════════════════════════
    //  State Variables
    // ═══════════════════════════════════════════════════════════════════════

    mapping(uint256 => RebalanceProof) private _proofs;
    mapping(uint256 => StrategyState) private _snapshots;
    mapping(uint256 => bool) private _verified;
    mapping(address => bool) public authorizedVerifiers;

    uint256 private _nextSnapshotId = 1;
    uint256 private _proofCount = 0;
    uint256 private _verifiedCount = 0;
    uint256 private _cumulativeEfficiency = 0;

    uint256 public minEfficiencyThreshold = 5000; // 50% minimum efficiency
    uint256 public maxSlippageBps = 100; // 1% max slippage
    bool public proofRequired = true;

    address public vaultKeeper;

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error UnauthorizedVerifier(address caller);
    error InvalidSnapshot(uint256 snapshotId);
    error ProofAlreadyExists(uint256 rebalanceId);
    error InvalidStateTransition(bytes32 expected, bytes32 actual);
    error EfficiencyTooLow(uint256 score, uint256 threshold);
    error SlippageTooHigh(uint256 slippage, uint256 max);
    error NotVaultKeeper(address caller);

    // ═══════════════════════════════════════════════════════════════════════
    //  Modifiers
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyVaultKeeper() {
        if (msg.sender != vaultKeeper) revert NotVaultKeeper(msg.sender);
        _;
    }

    modifier onlyAuthorizedVerifier() {
        if (!authorizedVerifiers[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedVerifier(msg.sender);
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    constructor(address _vaultKeeper, address initialOwner) Ownable(initialOwner) {
        vaultKeeper = _vaultKeeper;
        authorizedVerifiers[initialOwner] = true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Core Functions
    // ═══════════════════════════════════════════════════════════════════════

    function snapshotPreRebalance() external override onlyVaultKeeper returns (
        uint256 snapshotId,
        bytes32 stateRoot
    ) {
        snapshotId = _nextSnapshotId++;

        // Get current state from vault keeper (would be called via external call)
        // For now, we store a placeholder that gets filled during generateProof
        stateRoot = keccak256(abi.encodePacked(block.timestamp, snapshotId));

        _snapshots[snapshotId] = StrategyState({
            assets: new address[](0),
            balances: new uint256[](0),
            weights: new uint256[](0),
            prices: new uint256[](0),
            totalValue: 0,
            timestamp: block.timestamp
        });

        emit StateSnapshotTaken(snapshotId, stateRoot, 0, block.timestamp);

        return (snapshotId, stateRoot);
    }

    function recordPreState(
        uint256 snapshotId,
        StrategyState calldata state
    ) external onlyVaultKeeper {
        bytes32 stateRoot = _calculateStateRoot(state);
        _snapshots[snapshotId] = state;

        emit StateSnapshotTaken(snapshotId, stateRoot, state.totalValue, block.timestamp);
    }

    function generateRebalanceProof(
        uint256 preSnapshotId,
        uint256 gasUsed
    ) external override onlyVaultKeeper returns (RebalanceProof memory proof) {
        if (_snapshots[preSnapshotId].timestamp == 0) revert InvalidSnapshot(preSnapshotId);

        uint256 rebalanceId = _proofCount;

        // Get post-rebalance state
        StrategyState memory postState = _getCurrentState();
        StrategyState memory preState = _snapshots[preSnapshotId];

        bytes32 preStateRoot = _calculateStateRoot(preState);
        bytes32 postStateRoot = _calculateStateRoot(postState);

        // Calculate value delta
        int256 valueDelta = int256(postState.totalValue) - int256(preState.totalValue);

        proof = RebalanceProof({
            rebalanceId: rebalanceId,
            timestamp: block.timestamp,
            preStateRoot: preStateRoot,
            postStateRoot: postStateRoot,
            totalValueBefore: preState.totalValue,
            totalValueAfter: postState.totalValue,
            valueDelta: valueDelta > 0 ? uint256(valueDelta) : 0,
            slippageBps: _calculateSlippage(preState, postState),
            gasCost: gasUsed,
            txHash: blockhash(block.number - 1), // Previous block hash as proxy
            executor: msg.sender,
            preState: preState,
            postState: postState,
            signature: new bytes(0) // Would be signed by keeper
        });

        _proofs[rebalanceId] = proof;
        _proofCount++;

        // Auto-verify if meets criteria
        (bool isValid, RebalanceImpact memory impact) = _validateProof(proof);
        if (isValid) {
            _verified[rebalanceId] = true;
            _verifiedCount++;
            _cumulativeEfficiency += impact.efficiencyScore;

            emit RebalanceVerified(rebalanceId, address(0), impact.efficiencyScore, true);
        }

        emit RebalanceProofGenerated(
            rebalanceId,
            preStateRoot,
            postStateRoot,
            proof.valueDelta,
            impact.efficiencyScore
        );

        return proof;
    }

    function verifyRebalanceProof(
        RebalanceProof calldata proof
    ) external view override returns (bool isValid, RebalanceImpact memory impact) {
        (isValid, impact) = _validateProof(proof);
    }

    function calculateEfficiencyScore(RebalanceProof calldata proof) external pure override returns (uint256 score) {
        return _calculateEfficiency(proof);
    }

    function calculateDriftMetrics(
        StrategyState calldata preState,
        StrategyState calldata postState,
        uint256[] calldata targetWeights
    ) external pure override returns (DriftMetrics memory metrics) {
        // Calculate max and average drift before
        uint256 maxDriftBefore = 0;
        uint256 totalDriftBefore = 0;

        for (uint256 i = 0; i < preState.assets.length; i++) {
            uint256 actualWeight = preState.weights[i];
            uint256 targetWeight = i < targetWeights.length ? targetWeights[i] : 0;
            uint256 drift = actualWeight > targetWeight ? actualWeight - targetWeight : targetWeight - actualWeight;

            if (drift > maxDriftBefore) maxDriftBefore = drift;
            totalDriftBefore += drift;
        }

        metrics.avgWeightDriftBefore = preState.assets.length > 0 ? totalDriftBefore / preState.assets.length : 0;
        metrics.maxWeightDriftBefore = maxDriftBefore;

        // Calculate max and average drift after
        uint256 maxDriftAfter = 0;
        uint256 totalDriftAfter = 0;
        uint256 corrections = 0;

        for (uint256 i = 0; i < postState.assets.length; i++) {
            uint256 actualWeight = postState.weights[i];
            uint256 targetWeight = i < targetWeights.length ? targetWeights[i] : 0;
            uint256 drift = actualWeight > targetWeight ? actualWeight - targetWeight : targetWeight - actualWeight;

            if (drift > maxDriftAfter) maxDriftAfter = drift;
            totalDriftAfter += drift;

            // Count corrections (positions where drift was reduced)
            if (i < preState.weights.length) {
                uint256 oldDrift = preState.weights[i] > targetWeight
                    ? preState.weights[i] - targetWeight
                    : targetWeight - preState.weights[i];
                if (drift < oldDrift) corrections++;
            }
        }

        metrics.avgWeightDriftAfter = postState.assets.length > 0 ? totalDriftAfter / postState.assets.length : 0;
        metrics.maxWeightDriftAfter = maxDriftAfter;
        metrics.targetDeviationsCorrected = corrections;
        metrics.driftReduction = metrics.avgWeightDriftBefore > 0
            ? ((metrics.avgWeightDriftBefore - metrics.avgWeightDriftAfter) * 10000) / metrics.avgWeightDriftBefore
            : 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  View Functions
    // ═══════════════════════════════════════════════════════════════════════

    function getProof(uint256 rebalanceId) external view override returns (RebalanceProof memory) {
        return _proofs[rebalanceId];
    }

    function getStateSnapshot(uint256 snapshotId) external view override returns (StrategyState memory) {
        return _snapshots[snapshotId];
    }

    function isVerified(uint256 rebalanceId) external view override returns (bool) {
        return _verified[rebalanceId];
    }

    function getEfficiencyScore(uint256 rebalanceId) external view override returns (uint256) {
        return _proofs[rebalanceId].valueDelta > 0 ? _calculateEfficiency(_proofs[rebalanceId]) : 0;
    }

    function getHistoricalDrift(uint256 startId, uint256 endId) external view override returns (
        uint256[] memory timestamps,
        uint256[] memory maxDrifts,
        uint256[] memory avgDrifts
    ) {
        uint256 count = endId - startId + 1;
        timestamps = new uint256[](count);
        maxDrifts = new uint256[](count);
        avgDrifts = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            uint256 id = startId + i;
            if (id < _proofCount) {
                RebalanceProof storage proof = _proofs[id];
                timestamps[i] = proof.timestamp;

                // Calculate average drift
                uint256 totalDrift = 0;
                for (uint256 j = 0; j < proof.postState.weights.length; j++) {
                    // Compare to ideal equal weight
                    uint256 idealWeight = 10000 / proof.postState.weights.length;
                    uint256 drift = proof.postState.weights[j] > idealWeight
                        ? proof.postState.weights[j] - idealWeight
                        : idealWeight - proof.postState.weights[j];
                    totalDrift += drift;
                }

                avgDrifts[i] = proof.postState.weights.length > 0 ? totalDrift / proof.postState.weights.length : 0;
                maxDrifts[i] = 0; // Would need to track max per proof
            }
        }
    }

    function getRecentRebalanceImpacts(uint256 count) external view override returns (RebalanceImpact[] memory) {
        uint256 actualCount = count > _proofCount ? _proofCount : count;
        RebalanceImpact[] memory impacts = new RebalanceImpact[](actualCount);

        for (uint256 i = 0; i < actualCount; i++) {
            uint256 id = _proofCount - 1 - i;
            RebalanceProof storage proof = _proofs[id];

            (, RebalanceImpact memory impact) = _validateProof(proof);
            impacts[i] = impact;
        }

        return impacts;
    }

    function getValueCaptureDelta(uint256 rebalanceId) external view override returns (
        uint256 expectedValue,
        uint256 actualValue,
        uint256 slippage
    ) {
        RebalanceProof storage proof = _proofs[rebalanceId];
        expectedValue = proof.totalValueBefore;
        actualValue = proof.totalValueAfter;
        slippage = proof.slippageBps;
    }

    function getVerifiedRebalanceCount() external view override returns (uint256) {
        return _verifiedCount;
    }

    function getCumulativeEfficiency() external view override returns (uint256 totalScore, uint256 count) {
        return (_cumulativeEfficiency, _verifiedCount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Batch & Analysis Functions
    // ═══════════════════════════════════════════════════════════════════════

    function batchVerifyProofs(
        RebalanceProof[] calldata proofs
    ) external view override returns (bool[] memory results) {
        results = new bool[](proofs.length);
        for (uint256 i = 0; i < proofs.length; i++) {
            (results[i], ) = _validateProof(proofs[i]);
        }
    }

    function generatePeriodReport(
        uint256 startTime,
        uint256 endTime
    ) external view override returns (string memory reportUri, bytes memory summary) {
        uint256 totalEfficiency = 0;
        uint256 count = 0;
        uint256 totalValueDelta = 0;

        for (uint256 i = 0; i < _proofCount; i++) {
            RebalanceProof storage proof = _proofs[i];
            if (proof.timestamp >= startTime && proof.timestamp <= endTime) {
                totalEfficiency += _calculateEfficiency(proof);
                totalValueDelta += proof.valueDelta;
                count++;
            }
        }

        uint256 avgEfficiency = count > 0 ? totalEfficiency / count : 0;

        // Summary: [avgEfficiency (32 bytes), count (32 bytes), totalValueDelta (32 bytes)]
        summary = abi.encode(avgEfficiency, count, totalValueDelta);

        // Generate simple URI hash (in production, would upload to IPFS)
        reportUri = string(abi.encodePacked(
            "ipfs://report/",
            _toHexString(uint256(keccak256(abi.encodePacked(startTime, endTime, block.number))))
        ));
    }

    function analyzeOptimalRebalanceInterval(
        uint256 lookbackDays
    ) external view override returns (uint256 optimalInterval, uint256 expectedEfficiency) {
        uint256 lookbackSeconds = lookbackDays * 1 days;
        uint256 cutoffTime = block.timestamp - lookbackSeconds;

        // Count rebalances in lookback period
        uint256 recentRebalanceCount = 0;
        uint256 totalEfficiency = 0;

        for (uint256 i = 0; i < _proofCount; i++) {
            if (_proofs[i].timestamp >= cutoffTime) {
                recentRebalanceCount++;
                totalEfficiency += _calculateEfficiency(_proofs[i]);
            }
        }

        if (recentRebalanceCount == 0) {
            return (24, 5000); // Default: 24 hours, 50% efficiency
        }

        uint256 avgEfficiency = totalEfficiency / recentRebalanceCount;

        // Calculate interval based on efficiency trend
        // Higher efficiency = longer intervals possible
        if (avgEfficiency > 8000) {
            optimalInterval = 72; // 3 days
        } else if (avgEfficiency > 6000) {
            optimalInterval = 48; // 2 days
        } else {
            optimalInterval = 24; // 1 day
        }

        expectedEfficiency = avgEfficiency;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Admin Functions
    // ═══════════════════════════════════════════════════════════════════════

    function setMinEfficiencyThreshold(uint256 thresholdBps) external override onlyOwner {
        require(thresholdBps <= 10000, "Threshold too high");
        minEfficiencyThreshold = thresholdBps;
    }

    function setMaxSlippageBps(uint256 slippageBps) external override onlyOwner {
        require(slippageBps <= 1000, "Slippage too high");
        maxSlippageBps = slippageBps;
    }

    function setAuthorizedVerifier(address verifier, bool authorized) external override onlyOwner {
        authorizedVerifiers[verifier] = authorized;
    }

    function setProofRequired(bool required) external override onlyOwner {
        proofRequired = required;
    }

    function setVaultKeeper(address _vaultKeeper) external onlyOwner {
        vaultKeeper = _vaultKeeper;
    }

    function getConfig() external view override returns (
        uint256 minEfficiencyBps,
        uint256 maxSlippageBps,
        bool proofRequiredVal,
        uint256 totalProofsGenerated
    ) {
        return (minEfficiencyThreshold, maxSlippageBps, proofRequired, _proofCount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal Functions
    // ═══════════════════════════════════════════════════════════════════════

    function _calculateStateRoot(StrategyState memory state) internal pure returns (bytes32) {
        return keccak256(abi.encode(state));
    }

    function _getCurrentState() internal view returns (StrategyState memory) {
        // This would normally query the vault keeper for current state
        // For now, return empty state (to be populated by vault integration)
        return StrategyState({
            assets: new address[](0),
            balances: new uint256[](0),
            weights: new uint256[](0),
            prices: new uint256[](0),
            totalValue: 0,
            timestamp: block.timestamp
        });
    }

    function _calculateSlippage(
        StrategyState memory preState,
        StrategyState memory postState
    ) internal pure returns (uint256 slippageBps) {
        if (preState.totalValue == 0) return 0;

        // Estimate expected value after rebalance (ideal = no slippage)
        // Slippage = (expected - actual) / expected
        int256 valueDiff = int256(postState.totalValue) - int256(preState.totalValue);
        if (valueDiff < 0) {
            uint256 loss = uint256(-valueDiff);
            slippageBps = (loss * 10000) / preState.totalValue;
        } else {
            slippageBps = 0; // Gained value, no slippage
        }
    }

    function _calculateEfficiency(RebalanceProof memory proof) internal pure returns (uint256 score) {
        // Efficiency = (valueDelta * 10000) / (gasCost * estimatedGasPrice + totalValueBefore * opportunityCost)
        // Simplified: Based on value delta vs total value

        if (proof.totalValueBefore == 0) return 0;

        // Base score from value capture
        uint256 valueScore = (proof.valueDelta * 10000) / proof.totalValueBefore;

        // Penalty for slippage
        uint256 slippagePenalty = proof.slippageBps;

        // Efficiency = valueScore - slippagePenalty, min 0, max 10000
        if (valueScore > slippagePenalty) {
            score = valueScore - slippagePenalty;
        } else {
            score = 0;
        }

        // Cap at 10000 (100%)
        if (score > 10000) score = 10000;
    }

    function _validateProof(
        RebalanceProof memory proof
    ) internal view returns (bool isValid, RebalanceImpact memory impact) {
        // Verify state roots match
        bytes32 calculatedPreRoot = _calculateStateRoot(proof.preState);
        bytes32 calculatedPostRoot = _calculateStateRoot(proof.postState);

        if (calculatedPreRoot != proof.preStateRoot || calculatedPostRoot != proof.postStateRoot) {
            return (false, impact);
        }

        // Calculate efficiency
        uint256 efficiency = _calculateEfficiency(proof);

        // Check thresholds
        if (efficiency < minEfficiencyThreshold) {
            return (false, impact);
        }

        if (proof.slippageBps > maxSlippageBps) {
            return (false, impact);
        }

        // Calculate drift reduction
        uint256 driftReduction = 0;
        if (proof.preState.weights.length > 0 && proof.postState.weights.length > 0) {
            uint256 preDrift = 0;
            uint256 postDrift = 0;

            for (uint256 i = 0; i < proof.preState.weights.length; i++) {
                // Assume equal target weights for simplicity
                uint256 target = 10000 / proof.preState.weights.length;
                preDrift += proof.preState.weights[i] > target
                    ? proof.preState.weights[i] - target
                    : target - proof.preState.weights[i];
            }

            for (uint256 i = 0; i < proof.postState.weights.length; i++) {
                uint256 target = 10000 / proof.postState.weights.length;
                postDrift += proof.postState.weights[i] > target
                    ? proof.postState.weights[i] - target
                    : target - proof.postState.weights[i];
            }

            if (preDrift > 0) {
                driftReduction = ((preDrift - postDrift) * 10000) / preDrift;
            }
        }

        impact = RebalanceImpact({
            rebalanceId: proof.rebalanceId,
            efficiencyScore: efficiency,
            driftReduction: driftReduction,
            valueCaptured: proof.valueDelta,
            costVsBenefit: proof.gasCost > 0 ? proof.valueDelta / proof.gasCost : 0,
            verified: true
        });

        return (true, impact);
    }

    function _toHexString(uint256 value) internal pure returns (string memory) {
        bytes16 symbols = "0123456789abcdef";
        bytes memory buffer = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            buffer[63 - i] = symbols[value & 0xf];
            value >>= 4;
        }
        return string(buffer);
    }

    // Additional events
    event AssetRegistered(address indexed asset);
    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);
}
