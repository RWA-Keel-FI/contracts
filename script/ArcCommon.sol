// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Constants + helpers shared by DeployArc and SeedLiquidityArc. Everything external is the REAL Arc Testnet
///         infrastructure (verified on-chain: PoolManager, USDC ERC-20 interface, Chainlink KeystoneForwarder).
abstract contract ArcCommon is Script {
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5042002;

    /// Uniswap v4 PoolManager on Arc Testnet
    address internal constant POOL_MANAGER = 0x1d70945634F618eefdF9EDaAdB59B9A183CEF929;
    /// USDC ERC-20 interface (6 decimals). On Arc the same balance is the native gas token at 18 decimals.
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    /// Chainlink CRE production KeystoneForwarder for arc-testnet (the 0x6E9EE680... one is simulation-only)
    address internal constant FORWARDER = 0x76c9cf548b4179F8901cda1f8623568b58215E62;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint24 internal constant BASE_FEE = 3000; // 30 bps
    int24 internal constant SPACING = 60;
    uint256 internal constant MAX_MINT_FEE_BPS = 10; // StockIssuer.FEE_BPS

    function _checkChainAndInfra() internal view {
        require(block.chainid == ARC_TESTNET_CHAIN_ID, "Arc scripts: chain id must be 5042002 (Arc Testnet)");
        require(POOL_MANAGER.code.length > 0, "no PoolManager at expected address");
        require(USDC.code.length > 0, "no USDC at expected address");
        require(FORWARDER.code.length > 0, "no KeystoneForwarder at expected address");
        require(CREATE2_DEPLOYER.code.length > 0, "no CREATE2 deployer on this chain");
        (bool ok, bytes memory d) = USDC.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && abi.decode(d, (uint8)) == 6, "USDC ERC-20 interface must report 6 decimals");
    }

    /// @dev key from env, or `fallbackKey` when the variable is unset/empty. Never logged.
    function _keyOr(string memory name, uint256 fallbackKey) internal view returns (uint256) {
        string memory raw = vm.envOr(name, string(""));
        if (bytes(raw).length == 0) return fallbackKey;
        return vm.parseUint(raw);
    }

    /// @dev sqrtPriceX96 for a stock with 18 decimals vs USDC with 6. price = USD per whole stock = pE8 / 1e8.
    function _sqrtFor(uint256 pE8, bool stockIsC0) internal pure returns (uint160) {
        uint256 q192 = stockIsC0
            ? FullMath.mulDiv(pE8 * 1e6, uint256(1) << 192, 1e8 * 1e18)
            : FullMath.mulDiv(1e8 * 1e18, uint256(1) << 192, pE8 * 1e6);
        return uint160(Math.sqrt(q192));
    }

    /// @param kind 0 wide (full range), 1 medium (about +-10%), 2 tight (about +-2.4%)
    function _range(int24 tickCenter, uint8 kind) internal pure returns (int24 lo, int24 hi) {
        if (kind == 0) return (TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING));
        int24 w = kind == 1 ? int24(960) : int24(240);
        lo = _floor(tickCenter - w);
        hi = _floor(tickCenter + w) + SPACING;
    }

    function _floor(int24 tick) internal pure returns (int24) {
        int24 r = tick / SPACING;
        if (tick < 0 && tick % SPACING != 0) r--;
        return r * SPACING;
    }
}
