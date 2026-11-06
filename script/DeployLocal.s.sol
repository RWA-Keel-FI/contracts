// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {DeviationFeeHook} from "../src/DeviationFeeHook.sol";
import {RefPriceOracle} from "../src/RefPriceOracle.sol";
import {IRefPriceOracle} from "../src/interfaces/IRefPriceOracle.sol";
import {MockUSDC} from "../src/tokens/MockUSDC.sol";
import {StockToken} from "../src/tokens/StockToken.sol";
import {StockIssuer} from "../src/tokens/StockIssuer.sol";
import {SwapRouter} from "../src/helpers/SwapRouter.sol";
import {LiquidityRouter} from "../src/helpers/LiquidityRouter.sol";
import {MockForwarder} from "../test/mocks/MockForwarder.sol";

/// @notice LOCAL ANVIL ONLY (chain id 31337). Uses anvil's public default test keys. Deploys the whole demo:
///         PoolManager, MockForwarder, RefPriceOracle, mined DeviationFeeHook, tUSDC, one test stock token per ticker,
///         the mock StockIssuer, routers, and two pools per ticker (hook pool + static-fee control pool) with LP
///         liquidity from three accounts. Prints `DEPLOY|...`, `TICKER|...`, `POOL|...`, `ACCOUNT|...` lines that
///         scripts/deploy-local.sh turns into deployments/local.json.
///         Env: TICKERS=NVDA,TSLA,...  PRICE_E8_<T>=<uint>  SIGMA_E12_<T>=<uint>
contract DeployLocal is Script {
    using PoolIdLibrary for PoolKey;

    // anvil's well-known PUBLIC default keys (accounts 0..5). Worthless anywhere but a local anvil.
    uint256 constant K0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant K1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant K2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant K3 = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 constant K4 = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 constant K5 = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    uint24 constant BASE_FEE = 3000; // 30 bps
    int24 constant SPACING = 60;
    uint256 constant LP_USD_PER_POOL = 40_000e6; // each LP puts up to $40k of stock + $40k tUSDC into EACH pool
    uint256 constant MAX_MINT_FEE_BPS = 10;

    struct T {
        string sym;
        bytes32 feed;
        StockToken token;
        uint256 priceE8;
        uint64 sigmaE12;
        bool stockIsC0;
        uint160 sqrtP;
        int24 tick0;
        PoolKey hookKey;
        PoolKey controlKey;
    }

    struct Core {
        PoolManager pm;
        MockForwarder fwd;
        RefPriceOracle oracle;
        DeviationFeeHook hook;
        MockUSDC usdc;
        StockIssuer issuer;
        SwapRouter sr;
        LiquidityRouter lr;
    }

    Core c;
    T[] ts;

    function run() external {
        require(block.chainid == 31337, "DeployLocal: local anvil only (chain id 31337)");
        uint256[6] memory keys = [K0, K1, K2, K3, K4, K5];
        for (uint256 i; i < 6; i++) {
            require(vm.addr(keys[i]).balance > 1 ether, "DeployLocal: not an anvil default account");
        }
        address deployer = vm.addr(K0);

        _loadTickers();

        // ------------------------------------------------------------ phase A: protocol + tokens (deployer)
        vm.startBroadcast(K0);
        c.pm = new PoolManager(deployer);
        c.fwd = new MockForwarder();
        c.oracle = new RefPriceOracle(address(c.fwd));
        c.hook = _deployMinedHook(deployer);
        c.usdc = new MockUSDC(deployer);
        c.issuer = new StockIssuer(c.usdc, IRefPriceOracle(address(c.oracle)), deployer);
        c.sr = new SwapRouter(c.pm);
        c.lr = new LiquidityRouter(c.pm);

        for (uint256 i; i < ts.length; i++) {
            T storage t = ts[i];
            t.token = new StockToken(string.concat("Test ", t.sym, " (mock)"), string.concat("t", t.sym), address(c.issuer));
            c.issuer.listTicker(t.feed, t.token);
            t.stockIsC0 = address(t.token) < address(c.usdc);
            // oracle price first: the issuer and the hook both read it
            c.fwd.deliver(address(c.oracle), abi.encode(t.feed, uint64(t.priceE8), true, uint64(block.timestamp)));
        }

        // test money: mint tUSDC to every actor (owner-only mint), then seed the issuer's reserve buffer
        c.usdc.mint(deployer, 3_000_000e6);
        c.usdc.mint(vm.addr(K1), 2_000_000e6);
        c.usdc.mint(vm.addr(K2), 2_000_000e6);
        c.usdc.mint(vm.addr(K3), 2_000_000e6);
        c.usdc.mint(vm.addr(K4), 3_000_000e6); // arbitrageur
        c.usdc.mint(vm.addr(K5), 300_000e6); // retail
        c.usdc.approve(address(c.issuer), type(uint256).max);
        c.issuer.fundReserves(2_000_000e6);

        // pools: hook pool (dynamic fee, configured first) + control pool (static 30 bps, no hook)
        for (uint256 i; i < ts.length; i++) {
            _createPools(ts[i]);
        }
        vm.stopBroadcast();

        // ------------------------------------------------------------ phase B: actors
        _lp(K1, 0); // wide
        _lp(K2, 1); // medium (+-~10%)
        _lp(K3, 2); // tight (+-~2.4%)
        _trader(K4, 200_000e6); // arbitrageur: $200k of every stock
        _trader(K5, 10_000e6); // retail: $10k of every stock

        _log(deployer);
    }

    // ================================================================== setup helpers
    function _loadTickers() internal {
        string[] memory syms = vm.envString("TICKERS", ",");
        for (uint256 i; i < syms.length; i++) {
            T storage t = ts.push();
            t.sym = syms[i];
            t.feed = bytes32(bytes(syms[i])); // ASCII, left aligned, zero right-padded
            t.priceE8 = vm.envUint(string.concat("PRICE_E8_", syms[i]));
            t.sigmaE12 = uint64(vm.envUint(string.concat("SIGMA_E12_", syms[i])));
        }
    }

    /// @dev brute-force a CREATE2 salt whose address has exactly the beforeInitialize|beforeSwap flag bits
    function _deployMinedHook(address owner) internal returns (DeviationFeeHook hook) {
        bytes memory initCode = abi.encodePacked(
            type(DeviationFeeHook).creationCode, abi.encode(IPoolManager(address(c.pm)), IRefPriceOracle(address(c.oracle)), owner)
        );
        bytes32 initHash = keccak256(initCode);
        uint256 salt;
        address predicted;
        for (; salt < 2_000_000; salt++) {
            predicted = vm.computeCreate2Address(bytes32(salt), initHash, CREATE2_DEPLOYER);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) break;
        }
        require(uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS, "hook salt not found");
        hook = new DeviationFeeHook{salt: bytes32(salt)}(IPoolManager(address(c.pm)), IRefPriceOracle(address(c.oracle)), owner);
        require(address(hook) == predicted, "hook address mismatch (CREATE2 deployer?)");
    }

    function _sqrtFor(uint256 pE8, bool stockIsC0) internal pure returns (uint160) {
        // stock 18 decimals, tUSDC 6 decimals. price = USD per whole stock = pE8 / 1e8
        // raw price(token1/token0): stock0 => usdc_raw/stock_raw = pE8*1e6/(1e8*1e18); stock1 => inverse
        uint256 q192 = stockIsC0
            ? FullMath.mulDiv(pE8 * 1e6, uint256(1) << 192, 1e8 * 1e18)
            : FullMath.mulDiv(1e8 * 1e18, uint256(1) << 192, pE8 * 1e6);
        return uint160(Math.sqrt(q192));
    }

    function _createPools(T storage t) internal {
        (address a, address b) = address(t.token) < address(c.usdc) ? (address(t.token), address(c.usdc)) : (address(c.usdc), address(t.token));
        t.sqrtP = _sqrtFor(t.priceE8, t.stockIsC0);
        t.tick0 = TickMath.getTickAtSqrtPrice(t.sqrtP);

        t.hookKey = PoolKey(Currency.wrap(a), Currency.wrap(b), LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(address(c.hook)));
        t.controlKey = PoolKey(Currency.wrap(a), Currency.wrap(b), BASE_FEE, SPACING, IHooks(address(0)));

        c.hook.configurePool(
            t.hookKey,
            DeviationFeeHook.ConfigParams({
                feedId: t.feed, stockIsCurrency0: t.stockIsC0, f0: BASE_FEE, feeMax: 0, maxAge: 0, sigmaE12: t.sigmaE12
            })
        );
        c.pm.initialize(t.hookKey, t.sqrtP);
        c.pm.initialize(t.controlKey, t.sqrtP);
    }

    // ================================================================== actors
    function _approveAll(address who) internal {
        c.usdc.approve(address(c.sr), type(uint256).max);
        c.usdc.approve(address(c.lr), type(uint256).max);
        c.usdc.approve(address(c.issuer), type(uint256).max);
        who; // silence unused
    }

    /// @param kind 0 wide, 1 medium, 2 tight
    function _lp(uint256 pk, uint8 kind) internal {
        vm.startBroadcast(pk);
        _approveAll(vm.addr(pk));
        for (uint256 i; i < ts.length; i++) {
            T storage t = ts[i];
            // $80k of stock for the two pools, bought through the issuer at the oracle price (primary market)
            uint256 usdcIn = (2 * LP_USD_PER_POOL * 10_000) / (10_000 - MAX_MINT_FEE_BPS) + 1e6;
            c.issuer.mint(t.feed, usdcIn);
            t.token.approve(address(c.sr), type(uint256).max);
            t.token.approve(address(c.lr), type(uint256).max);
            uint256 stockBudget = t.token.balanceOf(vm.addr(pk)) / 2;
            (int24 lo, int24 hi) = _range(t.tick0, kind);
            _add(t, t.hookKey, lo, hi, stockBudget);
            _add(t, t.controlKey, lo, hi, stockBudget);
        }
        vm.stopBroadcast();
    }

    function _add(T storage t, PoolKey memory key, int24 lo, int24 hi, uint256 stockBudget) internal {
        (uint256 a0, uint256 a1) = t.stockIsC0 ? (stockBudget, LP_USD_PER_POOL) : (LP_USD_PER_POOL, stockBudget);
        c.lr.addLiquidityAmounts(key, lo, hi, a0, a1);
    }

    function _trader(uint256 pk, uint256 usdPerStock) internal {
        vm.startBroadcast(pk);
        _approveAll(vm.addr(pk));
        for (uint256 i; i < ts.length; i++) {
            T storage t = ts[i];
            c.issuer.mint(t.feed, usdPerStock);
            t.token.approve(address(c.sr), type(uint256).max);
            t.token.approve(address(c.lr), type(uint256).max);
        }
        vm.stopBroadcast();
    }

    function _range(int24 tick0, uint8 kind) internal pure returns (int24 lo, int24 hi) {
        if (kind == 0) return (TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING));
        int24 w = kind == 1 ? int24(960) : int24(240);
        lo = _floor(tick0 - w);
        hi = _floor(tick0 + w) + SPACING;
    }

    function _floor(int24 tick) internal pure returns (int24) {
        int24 r = tick / SPACING;
        if (tick < 0 && tick % SPACING != 0) r--;
        return r * SPACING;
    }

    // ================================================================== manifest lines
    function _log(address deployer) internal view {
        console2.log("DEPLOY|chainId|", block.chainid);
        console2.log("DEPLOY|poolManager|", address(c.pm));
        console2.log("DEPLOY|oracle|", address(c.oracle));
        console2.log("DEPLOY|hook|", address(c.hook));
        console2.log("DEPLOY|forwarder|", address(c.fwd));
        console2.log("DEPLOY|usdc|", address(c.usdc));
        console2.log("DEPLOY|issuer|", address(c.issuer));
        console2.log("DEPLOY|swapRouter|", address(c.sr));
        console2.log("DEPLOY|liquidityRouter|", address(c.lr));
        console2.log("ACCOUNT|deployer|", deployer);
        console2.log("ACCOUNT|lp1|", vm.addr(K1));
        console2.log("ACCOUNT|lp2|", vm.addr(K2));
        console2.log("ACCOUNT|lp3|", vm.addr(K3));
        console2.log("ACCOUNT|arb|", vm.addr(K4));
        console2.log("ACCOUNT|retail|", vm.addr(K5));
        for (uint256 i; i < ts.length; i++) {
            T storage t = ts[i];
            console2.log(string.concat("TICKER|", t.sym, "|feedId|"), vm.toString(t.feed));
            console2.log(string.concat("TICKER|", t.sym, "|token|"), address(t.token));
            console2.log(string.concat("TICKER|", t.sym, "|startPriceE8|"), t.priceE8);
            console2.log(string.concat("TICKER|", t.sym, "|sigmaE12|"), uint256(t.sigmaE12));
            console2.log(string.concat("TICKER|", t.sym, "|stockIsCurrency0|"), t.stockIsC0 ? "true" : "false");
            _logPool(t.sym, "hookPool", t.hookKey);
            _logPool(t.sym, "controlPool", t.controlKey);
        }
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
