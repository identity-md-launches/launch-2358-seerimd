// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SeerToken} from "../src/SeerToken.sol";

/// @title DeploySeerToken
/// @notice Reviewable deployment script for `SeerToken`. The token has no constructor arguments
/// and no post-deployment configuration, so the script is a single `new SeerToken()`.
/// @dev On the IMD launch the factory, not this script, deploys the creation code; the script is
/// here for local dry runs and for tests, which call `deploy()` directly. It reads no environment
/// variables, so it behaves the same under any caller.
contract DeploySeerToken is Script {
    /// @notice Deploys the token. The broadcasting account (or the test contract) becomes
    /// `msg.sender` of the constructor and receives the whole supply.
    function deploy() public returns (SeerToken token) {
        token = new SeerToken();
    }

    /// @notice Entry point for `forge script`. Wraps `deploy()` in a broadcast.
    function run() external returns (SeerToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
