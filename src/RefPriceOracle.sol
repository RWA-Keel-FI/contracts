// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReceiverTemplate} from "chainlink-evm/contracts/src/v0.8/automation-cre/ReceiverTemplate.sol";
import {IRefPriceOracle} from "./interfaces/IRefPriceOracle.sol";

/// @title RefPriceOracle
/// @notice Stores the latest stock reference price written by the Chainlink CRE workflow.
/// @dev Only the configured forwarder can call `onReport` (enforced by ReceiverTemplate).
///      Report layout (fixed): abi.encode(bytes32 feedId, uint64 priceE8, bool sessionOpen, uint64 asOf).
///      Invalid / stale / replayed reports are IGNORED (event emitted) rather than reverted, so the
///      forwarder never retries a report that can never be accepted.
contract RefPriceOracle is ReceiverTemplate, IRefPriceOracle {
    struct Feed {
        uint64 priceE8;
        uint64 asOf;
        bool sessionOpen;
    } // one 256-bit slot

    /// @notice Reports dated further than this into the future are ignored.
    uint64 public constant MAX_FUTURE_DRIFT = 60;

    enum IgnoreReason {
        ZeroPrice,
        FutureTimestamp,
        NotNewer
    }

    mapping(bytes32 feedId => Feed) private s_feeds;

    event FeedUpdated(bytes32 indexed feedId, uint64 priceE8, uint64 asOf, bool sessionOpen);
    event ReportIgnored(bytes32 indexed feedId, uint64 asOf, IgnoreReason reason);

    constructor(address forwarder) ReceiverTemplate(forwarder) {}

    /// @inheritdoc IRefPriceOracle
    function priceOf(bytes32 feedId) external view returns (uint64 priceE8, uint64 asOf, bool sessionOpen) {
        Feed memory f = s_feeds[feedId];
        return (f.priceE8, f.asOf, f.sessionOpen);
    }

    function _processReport(bytes calldata report) internal override {
        (bytes32 feedId, uint64 priceE8, bool sessionOpen, uint64 asOf) =
            abi.decode(report, (bytes32, uint64, bool, uint64));

        if (priceE8 == 0) {
            emit ReportIgnored(feedId, asOf, IgnoreReason.ZeroPrice);
            return;
        }
        if (asOf > block.timestamp + MAX_FUTURE_DRIFT) {
            emit ReportIgnored(feedId, asOf, IgnoreReason.FutureTimestamp);
            return;
        }
        Feed storage f = s_feeds[feedId];
        if (asOf <= f.asOf) {
            emit ReportIgnored(feedId, asOf, IgnoreReason.NotNewer);
            return;
        }
        f.priceE8 = priceE8;
        f.asOf = asOf;
        f.sessionOpen = sessionOpen;
        emit FeedUpdated(feedId, priceE8, asOf, sessionOpen);
    }
}
