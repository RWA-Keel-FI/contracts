// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReceiver} from "chainlink-evm/contracts/src/v0.8/automation-cre/IReceiver.sol";

/// @notice Stand-in for the Chainlink KeystoneForwarder: just delivers a report to a receiver as `msg.sender`.
/// @dev In the real flow the forwarder verifies DON signatures; here that is out of scope (it is Chainlink's code).
contract MockForwarder {
    function deliver(address receiver, bytes calldata report) external {
        // metadata = abi.encodePacked(workflowId, workflowName(bytes10), workflowOwner)
        IReceiver(receiver).onReport(abi.encodePacked(bytes32(uint256(1)), bytes10("riskhook"), address(0xA11CE)), report);
    }
}
