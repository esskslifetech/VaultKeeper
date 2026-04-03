// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IRebalanceProof — Interface for Rebalance State Verification
/// @notice Provides cryptographic proofs that rebalance operations actually changed state
/// @dev Used for end-to-end verification of rebalancing effectiveness
interface IRebalanceProof {
    // ═══════════════════════════════════════════════════════════════════════
    //  Structs
    // ═══════════════════════════════════════════════════════════════════════

    struct RebalanceProof {
        uint256 rebalanceId;
        uint256 timestamp;
        bytes32 preStateRoot;
        bytes32 postStateRoot;
        uint256 totalValueBefore;
        uint256 totalValueAfter;
        uint256 valueDelta;
        uint256 slippageBps;
        uint256 gasCost;
        bytes32 txHash;
        address executor;
        StrategyState preState;
        StrategyState postState;
        bytes signature; // Keeper/keeper signature
    }

    struct StrategyState {
        address[] assets;
        uint256[] balances;
        uint256[] weights; // Actual weights at moment of snapshot
        uint256[] prices;
        uint256 totalValue;
        uint256 timestamp;
    }

    struct RebalanceImpact {
        uint256 rebalanceId;
        uint256 efficiencyScore; // 0-10000 (100 = perfect)
        uint256 driftReduction; // How much weight drift was corrected
        uint256 valueCaptured; // Value gained from rebalancing
        uint256 costVsBenefit; // Ratio of gas cost to value captured
        bool verified;
    }

    struct DriftMetrics {
        uint256 maxWeightDriftBefore;
        uint256 maxWeightDriftAfter;
        uint256 avgWeightDriftBefore;
        uint256 avgWeightDriftAfter;
        uint256 targetDeviationsCorrected;
        uint256 driftReduction;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    event RebalanceProofGenerated(
        uint256 indexed rebalanceId,
        bytes32 indexed preStateRoot,
        bytes32 indexed postStateRoot,
        uint256 valueDelta,
        uint256 efficiencyScore
    );

    event StateSnapshotTaken(
        uint256 indexed snapshotId,
        bytes32 stateRoot,
        uint256 totalValue,
        uint256 timestamp
    );

    event RebalanceVerified(
        uint256 indexed rebalanceId,
        address verifier,
        uint256 efficiencyScore,
        bool passed
    );

    event DriftCorrected(
        uint256 indexed rebalanceId,
        address indexed asset,
        uint256 oldWeight,
        uint256 newWeight,
        uint256 driftReduced
    );

    // ═══════════════════════════════════════════════════════════════════════
    //  Core Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Take a snapshot of current strategy state before rebalance
    /// @return snapshotId Unique ID for this state snapshot
    /// @return stateRoot Merkle root of the strategy state
    function snapshotPreRebalance() external returns (uint256 snapshotId, bytes32 stateRoot);

    /// @notice Generate proof after rebalance completes
    /// @param preSnapshotId The snapshot ID from before rebalance
    /// @param gasUsed Actual gas consumed by rebalance
    /// @return proof The complete rebalance proof
    function generateRebalanceProof(
        uint256 preSnapshotId,
        uint256 gasUsed
    ) external returns (RebalanceProof memory proof);

    /// @notice Verify a rebalance proof
    /// @param proof The proof to verify
    /// @return isValid True if proof is valid and state transition is correct
    /// @return impact Analysis of rebalance impact
    function verifyRebalanceProof(
        RebalanceProof calldata proof
    ) external view returns (bool isValid, RebalanceImpact memory impact);

    /// @notice Calculate efficiency score for a rebalance
    /// @param proof The rebalance proof
    /// @return score Efficiency score 0-10000 (higher is better)
    function calculateEfficiencyScore(RebalanceProof calldata proof) external pure returns (uint256 score);

    /// @notice Compare strategy states to calculate drift metrics
    /// @param preState State before rebalance
    /// @param postState State after rebalance
    /// @param targetWeights Expected target weights
    /// @return metrics Drift correction metrics
    function calculateDriftMetrics(
        StrategyState calldata preState,
        StrategyState calldata postState,
        uint256[] calldata targetWeights
    ) external pure returns (DriftMetrics memory metrics);

    // ═══════════════════════════════════════════════════════════════════════
    //  View Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get proof by rebalance ID
    function getProof(uint256 rebalanceId) external view returns (RebalanceProof memory);

    /// @notice Get state snapshot by ID
    function getStateSnapshot(uint256 snapshotId) external view returns (StrategyState memory);

    /// @notice Check if a rebalance has been verified
    function isVerified(uint256 rebalanceId) external view returns (bool);

    /// @notice Get the efficiency score for a specific rebalance
    function getEfficiencyScore(uint256 rebalanceId) external view returns (uint256);

    /// @notice Get historical drift data for analysis
    function getHistoricalDrift(uint256 startId, uint256 endId) external view returns (
        uint256[] memory timestamps,
        uint256[] memory maxDrifts,
        uint256[] memory avgDrifts
    );

    /// @notice Get the last N rebalance impacts
    function getRecentRebalanceImpacts(uint256 count) external view returns (RebalanceImpact[] memory);

    /// @notice Calculate expected vs actual value from rebalance
    function getValueCaptureDelta(uint256 rebalanceId) external view returns (
        uint256 expectedValue,
        uint256 actualValue,
        uint256 slippage
    );

    /// @notice Get the total number of verified rebalances
    function getVerifiedRebalanceCount() external view returns (uint256);

    /// @notice Get the cumulative efficiency score across all rebalances
    function getCumulativeEfficiency() external view returns (uint256 totalScore, uint256 count);

    // ═══════════════════════════════════════════════════════════════════════
    //  Batch & Analysis Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Batch verify multiple proofs
    /// @param proofs Array of proofs to verify
    /// @return results Array of verification results
    function batchVerifyProofs(
        RebalanceProof[] calldata proofs
    ) external view returns (bool[] memory results);

    /// @notice Generate a report for a time period
    /// @param startTime Start of period
    /// @param endTime End of period
    /// @return reportUri URI to the generated report (IPFS or similar)
    /// @return summary Summary statistics for the period
    function generatePeriodReport(
        uint256 startTime,
        uint256 endTime
    ) external view returns (string memory reportUri, bytes memory summary);

    /// @notice Identify optimal rebalance timing based on historical data
    /// @param lookbackDays Days of history to analyze
    /// @return optimalInterval Suggested rebalance interval in hours
    /// @return expectedEfficiency Expected efficiency score at optimal interval
    function analyzeOptimalRebalanceInterval(
        uint256 lookbackDays
    ) external view returns (uint256 optimalInterval, uint256 expectedEfficiency);

    // ═══════════════════════════════════════════════════════════════════════
    //  Administration
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set the minimum efficiency threshold for valid rebalances
    function setMinEfficiencyThreshold(uint256 thresholdBps) external;

    /// @notice Set the maximum acceptable slippage
    function setMaxSlippageBps(uint256 slippageBps) external;

    /// @notice Set authorized verifiers
    function setAuthorizedVerifier(address verifier, bool authorized) external;

    /// @notice Enable/disable proof generation requirement
    function setProofRequired(bool required) external;

    /// @notice Get current configuration
    function getConfig() external view returns (
        uint256 minEfficiencyBps,
        uint256 maxSlippageBps,
        bool proofRequired,
        uint256 totalProofsGenerated
    );
}
