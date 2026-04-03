// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Minimal Chainlink Automation compatibility stub for compilation.
// This project only needs the interface definition.
interface AutomationCompatibleInterface {
  function checkUpkeep(bytes calldata checkData)
    external
    returns (bool upkeepNeeded, bytes memory performData);

  function performUpkeep(bytes calldata performData) external;
}

