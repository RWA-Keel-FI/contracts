// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {DeviationFeeHook} from "../src/DeviationFeeHook.sol";
import {RefPriceOracle} from "../src/RefPriceOracle.sol";
import {IRefPriceOracle} from "../src/interfaces/IRefPriceOracle.sol";
import {StockToken} from "../src/tokens/StockToken.sol";
import {StockIssuer} from "../src/tokens/StockIssuer.sol";
import {SwapRouter} from "../src/helpers/SwapRouter.sol";
import {LiquidityRouter} from "../src/helpers/LiquidityRouter.sol";
import {ArcCommon} from "./ArcCommon.sol";

/// @notice ARC TESTNET (chain id 5042002) deployment of the DeviationFee system on the REAL infrastructure:
///         the existing Uniswap v4 PoolManager, the real USDC ERC-20, and the real Chainlink CRE KeystoneForwarder.
///         Deploys RefPriceOracle(forwarder = real), the CREATE2-mined hook (beforeInitialize | beforeSwap),
///         StockIssuer, a test tTSLA token, SwapRouter, LiquidityRouter, then initialises the hook pool (dynamic fee)
///         and the control pool (static 30 bps, no hook) for TSLA/USDC at the live TSLA quote.
///
///         NO liquidity is added here (see SeedLiquidityArc.s.sol, rerunnable). NO oracle price is written here:
///         `RefPriceOracle.onReport` is callable only by the forwarder, so the first price arrives from the CRE
///         workflow. Until then `priceOf` returns 0 and the hook FAILS OPEN (every swap pays the base fee).
///
///         Env: DEPLOYER_PRIVATE_KEY (required, from contracts/.env; never logged), PRICE_E8_TSLA, SIGMA_E12_TSLA,
///              optional LP1_PRIVATE_KEY, LP2_PRIVATE_KEY, LP3_PRIVATE_KEY, ARB_PRIVATE_KEY, RETAIL_PRIVATE_KEY
///              (only their ADDRESSES are logged, for the manifest).
///         Prints `DEPLOY|...`, `TICKER|...`, `POOL|...`, `ACCOUNT|...` lines for server/scripts/build_manifest.py.
contract DeployArc is ArcCommon {
    using PoolIdLibrary for PoolKey;

    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
    string constant SYM = "TSLA";

    RefPriceOracle oracle;
    DeviationFeeHook hook;
    StockIssuer issuer;
    StockToken token;
    SwapRouter sr;
    LiquidityRouter lr;
    PoolKey hookKey;
    PoolKey controlKey;
    bytes32 feed;
    bool stockIsC0;
    uint256 priceE8;
    uint64 sigmaE12;

    function run() external {
        _checkChainAndInfra();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        require(deployer.balance >= 0.5 ether, "deployer needs >= 0.5 USDC of native gas (18-decimal) on Arc Testnet");

        feed = bytes32(bytes(SYM));
        priceE8 = vm.envUint("PRICE_E8_TSLA");
        sigmaE12 = uint64(vm.envUint("SIGMA_E12_TSLA"));
        require(priceE8 >= 1e8 && priceE8 <= 1_000_000e8, "PRICE_E8_TSLA outside $1..$1,000,000");

        vm.startBroadcast(pk);
        oracle = new RefPriceOracle(FORWARDER); // owner = deployer; onReport only from the real forwarder
        hook = _deployMinedHook(deployer);
        issuer = new StockIssuer(IERC20(USDC), IRefPriceOracle(address(oracle)), deployer);
        sr = new SwapRouter(IPoolManager(POOL_MANAGER));
        lr = new LiquidityRouter(IPoolManager(POOL_MANAGER));
        token = new StockToken("Test TSLA (mock)", "tTSLA", address(issuer));
        issuer.listTicker(feed, token);
        stockIsC0 = address(token) < USDC;
        _createPools();
        vm.stopBroadcast();

        require(oracle.getForwarderAddress() == FORWARDER, "oracle forwarder mismatch");
        _log(deployer);
    }

    /// @dev brute-force a CREATE2 salt whose address has exactly the beforeInitialize|beforeSwap flag bits
    function _deployMinedHook(address owner) internal returns (DeviationFeeHook h) {
        bytes memory initCode = abi.encodePacked(
            type(DeviationFeeHook).creationCode,
            abi.encode(IPoolManager(POOL_MANAGER), IRefPriceOracle(address(oracle)), owner)
        );
        bytes32 initHash = keccak256(initCode);
        uint256 salt;
        address predicted;
        for (; salt < 2_000_000; salt++) {
            predicted = vm.computeCreate2Address(bytes32(salt), initHash, CREATE2_DEPLOYER);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) break;
        }
        require(uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS, "hook salt not found");
        h = new DeviationFeeHook{salt: bytes32(salt)}(IPoolManager(POOL_MANAGER), IRefPriceOracle(address(oracle)), owner);
        require(address(h) == predicted, "hook address mismatch (CREATE2 deployer?)");
    }

    function _createPools() internal {
        (address a, address b) = stockIsC0 ? (address(token), USDC) : (USDC, address(token));
        uint160 sqrtP = _sqrtFor(priceE8, stockIsC0);
        hookKey = PoolKey(Currency.wrap(a), Currency.wrap(b), LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(address(hook)));
        controlKey = PoolKey(Currency.wrap(a), Currency.wrap(b), BASE_FEE, SPACING, IHooks(address(0)));

        hook.configurePool(
            hookKey,
            DeviationFeeHook.ConfigParams({
                feedId: feed, stockIsCurrency0: stockIsC0, f0: BASE_FEE, feeMax: 0, maxAge: 0, sigmaE12: sigmaE12
            })
        );
        IPoolManager(POOL_MANAGER).initialize(hookKey, sqrtP);
        IPoolManager(POOL_MANAGER).initialize(controlKey, sqrtP);
    }

    // ================================================================== manifest lines
    function _log(address deployer) internal view {
        console2.log("DEPLOY|chainId|", block.chainid);
        console2.log("DEPLOY|poolManager|", POOL_MANAGER);
        console2.log("DEPLOY|oracle|", address(oracle));
        console2.log("DEPLOY|hook|", address(hook));
        console2.log("DEPLOY|forwarder|", FORWARDER);
        console2.log("DEPLOY|usdc|", USDC);
        console2.log("DEPLOY|issuer|", address(issuer));
        console2.log("DEPLOY|swapRouter|", address(sr));
        console2.log("DEPLOY|liquidityRouter|", address(lr));
        console2.log("ACCOUNT|deployer|", deployer);
        console2.log("ACCOUNT|lp1|", vm.addr(_keyOr("LP1_PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"))));
        console2.log("ACCOUNT|lp2|", vm.addr(_keyOr("LP2_PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"))));
        console2.log("ACCOUNT|lp3|", vm.addr(_keyOr("LP3_PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"))));
        console2.log("ACCOUNT|arb|", vm.addr(_keyOr("ARB_PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"))));
        console2.log("ACCOUNT|retail|", vm.addr(_keyOr("RETAIL_PRIVATE_KEY", vm.envUint("DEPLOYER_PRIVATE_KEY"))));
        console2.log(string.concat("TICKER|", SYM, "|feedId|"), vm.toString(feed));
        console2.log(string.concat("TICKER|", SYM, "|token|"), address(token));
        console2.log(string.concat("TICKER|", SYM, "|startPriceE8|"), priceE8);
        console2.log(string.concat("TICKER|", SYM, "|sigmaE12|"), uint256(sigmaE12));
        console2.log(string.concat("TICKER|", SYM, "|stockIsCurrency0|"), stockIsC0 ? "true" : "false");
        _logPool("hookPool", hookKey);
        _logPool("controlPool", controlKey);
    }

    function _logPool(string memory kind, PoolKey memory k) internal pure {
        string memory p = string.concat("POOL|", SYM, "|", kind, "|");
        console2.log(string.concat(p, "poolId|"), vm.toString(PoolId.unwrap(k.toId())));
        console2.log(string.concat(p, "currency0|"), Currency.unwrap(k.currency0));
        console2.log(string.concat(p, "currency1|"), Currency.unwrap(k.currency1));
        console2.log(string.concat(p, "fee|"), uint256(k.fee));
        console2.log(string.concat(p, "tickSpacing|"), uint256(uint24(k.tickSpacing)));
        console2.log(string.concat(p, "hooks|"), address(k.hooks));
    }
}
