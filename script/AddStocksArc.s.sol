// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {DeviationFeeHook} from "../src/DeviationFeeHook.sol";
import {StockToken} from "../src/tokens/StockToken.sol";
import {StockIssuer} from "../src/tokens/StockIssuer.sol";
import {ArcCommon} from "./ArcCommon.sol";

/// @notice Add more tokenized stocks to an EXISTING Arc Testnet deployment (hook, issuer, routers, oracle are reused).
///         For each ticker in TICKERS: deploy a mock `t<TICKER>` token owned by the issuer, list it in the issuer, register the
///         hook pool (dynamic fee, uses the hook) and the control pool (static 30 bps, no hook) and initialise both at the live price.
///         Does NOT move USDC, so it runs fine as a forge script. Minting and liquidity are done by arc_add_stocks.py (cast send).
///
///         Env: DEPLOYER_PRIVATE_KEY (must own the issuer and the hook), HOOK, ISSUER, TICKERS="NVDA,AAPL,...",
///              PRICE_E8_<TICKER>, SIGMA_E12_<TICKER> for each ticker.
///         Prints TICKER| and POOL| lines in the same format as DeployArc, for the manifest merge.
contract AddStocksArc is ArcCommon {
    using PoolIdLibrary for PoolKey;

    uint160 internal sqrtP; // scratch to keep the stack small

    function run() external {
        _checkChainAndInfra();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        DeviationFeeHook hook = DeviationFeeHook(vm.envAddress("HOOK"));
        StockIssuer issuer = StockIssuer(vm.envAddress("ISSUER"));
        string[] memory syms = vm.envString("TICKERS", ",");
        require(hook.owner() == vm.addr(pk) && issuer.owner() == vm.addr(pk), "DEPLOYER_PRIVATE_KEY must own the hook and the issuer");

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < syms.length; i++) _add(hook, issuer, syms[i]);
        vm.stopBroadcast();
    }

    function _add(DeviationFeeHook hook, StockIssuer issuer, string memory sym) internal {
        bytes32 feed = bytes32(bytes(sym));
        uint256 priceE8 = vm.envUint(string.concat("PRICE_E8_", sym));
        uint64 sigma = uint64(vm.envUint(string.concat("SIGMA_E12_", sym)));
        require(priceE8 >= 1e8 && priceE8 <= 1_000_000e8, "price outside $1..$1,000,000");
        require(address(issuer.tokenOf(feed)) == address(0), "ticker already listed");

        StockToken token = new StockToken(string.concat("Test ", sym, " (mock)"), string.concat("t", sym), address(issuer));
        issuer.listTicker(feed, token);
        bool stockIsC0 = address(token) < USDC;
        (address a, address b) = stockIsC0 ? (address(token), USDC) : (USDC, address(token));
        PoolKey memory hookKey = PoolKey(Currency.wrap(a), Currency.wrap(b), LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(address(hook)));
        PoolKey memory controlKey = PoolKey(Currency.wrap(a), Currency.wrap(b), BASE_FEE, SPACING, IHooks(address(0)));
        hook.configurePool(
            hookKey,
            DeviationFeeHook.ConfigParams({feedId: feed, stockIsCurrency0: stockIsC0, f0: BASE_FEE, feeMax: 0, maxAge: 0, sigmaE12: sigma})
        );
        sqrtP = _sqrtFor(priceE8, stockIsC0);
        IPoolManager(POOL_MANAGER).initialize(hookKey, sqrtP);
        IPoolManager(POOL_MANAGER).initialize(controlKey, sqrtP);

        _log(sym, feed, address(token), priceE8, sigma, stockIsC0);
        _logPool(sym, "hookPool", hookKey);
        _logPool(sym, "controlPool", controlKey);
    }

    function _log(string memory sym, bytes32 feed, address token, uint256 priceE8, uint64 sigma, bool stockIsC0) internal pure {
        console2.log(string.concat("TICKER|", sym, "|feedId|"), vm.toString(feed));
        console2.log(string.concat("TICKER|", sym, "|token|"), token);
        console2.log(string.concat("TICKER|", sym, "|startPriceE8|"), priceE8);
        console2.log(string.concat("TICKER|", sym, "|sigmaE12|"), uint256(sigma));
        console2.log(string.concat("TICKER|", sym, "|stockIsCurrency0|"), stockIsC0 ? "true" : "false");
    }

    function _logPool(string memory sym, string memory kind, PoolKey memory k) internal pure {
        string memory p = string.concat("POOL|", sym, "|", kind, "|");
        console2.log(string.concat(p, "poolId|"), vm.toString(PoolId.unwrap(k.toId())));
        console2.log(string.concat(p, "currency0|"), Currency.unwrap(k.currency0));
        console2.log(string.concat(p, "currency1|"), Currency.unwrap(k.currency1));
        console2.log(string.concat(p, "fee|"), uint256(k.fee));
        console2.log(string.concat(p, "tickSpacing|"), uint256(uint24(k.tickSpacing)));
        console2.log(string.concat(p, "hooks|"), address(k.hooks));
    }
}
