// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Read interface of the reference-price oracle (shared with the off-chain/UI agents).
interface IRefPriceOracle {
    /// @param feedId    opaque feed key (e.g. keccak256("NVDA/USD"))
    /// @return priceE8  USD per whole stock, 8 decimals. 0 = no price ever reported
    /// @return asOf     unix seconds the CRE workflow observed the price
    /// @return sessionOpen true while the US session that sources this price is open
    function priceOf(bytes32 feedId) external view returns (uint64 priceE8, uint64 asOf, bool sessionOpen);
}
