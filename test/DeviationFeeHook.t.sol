// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DeviationFeeHook} from "../src/DeviationFeeHook.sol";
import {MinimalBaseHook} from "../src/base/MinimalBaseHook.sol";
import {RefPriceOracle} from "../src/RefPriceOracle.sol";
import {ReceiverTemplate} from "chainlink-evm/contracts/src/v0.8/automation-cre/ReceiverTemplate.sol";
import {MockForwarder} from "./mocks/MockForwarder.sol";

contract DeviationFeeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
    bytes32 constant FEED = keccak256("NVDA/USD");
    uint24 constant F0 = 3000; // 0.30%
    uint24 constant FMAX = 20_000; // 2.00%
    uint64 constant SIGMA = 85_000_000; // 0.85 bps / sqrt(s)
    uint256 constant T0 = 1_800_000_000;
    uint64 constant REF = 30_000_000_000; // $300.00

    MockForwarder fwd;
    RefPriceOracle oracle;
    DeviationFeeHook hook;

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        fwd = new MockForwarder();
        oracle = new RefPriceOracle(address(fwd));
        address hookAddr = address(uint160(FLAGS) ^ (uint160(0x4444) << 144));
        deployCodeTo("DeviationFeeHook.sol:DeviationFeeHook", abi.encode(manager, oracle, address(this)), hookAddr);
        hook = DeviationFeeHook(hookAddr);
    }

    // ------------------------------------------------------------------ helpers
    function _sqrtFor(uint256 pE8, bool stockIsC0, uint8 sd, uint8 qd) internal pure returns (uint160) {
        uint256 q192 = stockIsC0
            ? FullMath.mulDiv(pE8 * 10 ** qd, uint256(1) << 192, 10 ** (8 + sd))
            : FullMath.mulDiv(10 ** (8 + sd), uint256(1) << 192, pE8 * 10 ** qd);
        return uint160(Math.sqrt(q192));
    }

    function _tokens(bool stockIsC0, uint8 sd, uint8 qd) internal returns (PoolKey memory key) {
        MockERC20 quote = new MockERC20("Q", "Q", qd);
        MockERC20 stock;
        do {
            stock = new MockERC20("S", "S", sd);
        } while ((address(stock) < address(quote)) != stockIsC0);
        (MockERC20 a, MockERC20 b) = stockIsC0 ? (stock, quote) : (quote, stock);
        a.mint(address(this), 1e36);
        b.mint(address(this), 1e36);
        a.approve(address(swapRouter), type(uint256).max);
        b.approve(address(swapRouter), type(uint256).max);
        a.approve(address(modifyLiquidityRouter), type(uint256).max);
        b.approve(address(modifyLiquidityRouter), type(uint256).max);
        key = PoolKey(
            Currency.wrap(address(a)), Currency.wrap(address(b)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook))
        );
    }

    function _cfg(bool stockIsC0) internal pure returns (DeviationFeeHook.ConfigParams memory) {
        return DeviationFeeHook.ConfigParams({
            feedId: FEED, stockIsCurrency0: stockIsC0, f0: F0, feeMax: 0, maxAge: 0, sigmaE12: SIGMA
        });
    }

    /// full lifecycle: tokens -> configure -> initialize at `poolPriceE8` (-> optional liquidity)
    function _pool(bool stockIsC0, uint8 sd, uint8 qd, uint256 poolPriceE8, bool addLiquidity)
        internal
        returns (PoolKey memory key)
    {
        key = _tokens(stockIsC0, sd, qd);
        hook.configurePool(key, _cfg(stockIsC0));
        manager.initialize(key, _sqrtFor(poolPriceE8, stockIsC0, sd, qd));
        if (addLiquidity) {
            modifyLiquidityRouter.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(60),
                    tickUpper: TickMath.maxUsableTick(60),
                    liquidityDelta: 1e18,
                    salt: 0
                }),
                ZERO_BYTES
            );
        }
    }

    function _report(uint64 priceE8, bool open, uint256 age) internal {
        fwd.deliver(address(oracle), abi.encode(FEED, priceE8, open, uint64(block.timestamp - age)));
    }

    function _fee(PoolKey memory key, bool zeroForOne) internal view returns (uint24 fee) {
        (fee,,) = hook.quoteFee(key, zeroForOne);
    }

    // stock = currency0 => selling stock = zeroForOne
    function _sellDir(bool stockIsC0) internal pure returns (bool) {
        return stockIsC0;
    }

    // ------------------------------------------------------------------ fee scenarios (stock = currency0, 18/18)
    function test_arbDirection_surcharge_poolAboveRef() public {
        PoolKey memory key = _pool(true, 18, 18, 30_300_000_000, false);
        _report(REF, true, 0);
        assertApproxEqAbs(_fee(key, true), 5000, 1); // sell stock into an overpriced pool: d/2 = 0.50%
    }

    function test_nonArbDirection_isBaseFee() public {
        PoolKey memory key = _pool(true, 18, 18, 30_300_000_000, false);
        _report(REF, true, 0);
        assertEq(_fee(key, false), F0); // buying stock from the overpriced pool: base fee
    }

    function test_arbDirection_poolBelowRef_buyingStock() public {
        PoolKey memory key = _pool(true, 18, 18, 29_700_000_000, false);
        _report(REF, true, 0);
        assertApproxEqAbs(_fee(key, false), 5000, 1);
        assertEq(_fee(key, true), F0);
    }

    function test_insideDeadband_isBaseFee() public {
        PoolKey memory key = _pool(true, 18, 18, 30_150_000_000, false); // d = 5000 pips < 2*f0
        _report(REF, true, 0);
        assertEq(_fee(key, true), F0);
        assertEq(_fee(key, false), F0);
    }

    function test_noiseTerm_reducesSurcharge() public {
        PoolKey memory key = _pool(true, 18, 18, 30_300_000_000, false);
        _report(REF, true, 900); // age == maxAge is still fresh; noise = ceil(8.5e7*30/1e6) = 2550
        assertApproxEqAbs(_fee(key, true), 3725, 1); // (10_000 - 2550) / 2
    }

    function test_sessionClosed_isBaseFee() public {
        PoolKey memory key = _pool(true, 18, 18, 33_000_000_000, false);
        _report(REF, false, 0);
        assertEq(_fee(key, true), F0);
    }

    function test_stale_isBaseFee() public {
        PoolKey memory key = _pool(true, 18, 18, 33_000_000_000, false);
        _report(REF, true, 901); // > maxAge (900)
        assertEq(_fee(key, true), F0);
    }

    function test_noPrice_isBaseFee() public {
        PoolKey memory key = _pool(true, 18, 18, 33_000_000_000, false);
        // no report at all
        assertEq(_fee(key, true), F0);
    }

    function test_priceAges_failsOpenAsTimePasses() public {
        PoolKey memory key = _pool(true, 18, 18, 30_300_000_000, false);
        _report(REF, true, 0);
        assertGt(_fee(key, true), F0);
        vm.warp(block.timestamp + 901);
        assertEq(_fee(key, true), F0);
    }

    function test_feeClamp_toFeeMax() public {
        PoolKey memory key = _pool(true, 18, 18, 33_000_000_000, false); // d = 10% => d/2 = 5% > 2%
        _report(REF, true, 0);
        assertEq(_fee(key, true), FMAX);
    }

    // ------------------------------------------------------------------ other orientation / decimals
    function test_stockIsCurrency1_18_6() public {
        PoolKey memory key = _pool(false, 18, 6, 30_300_000_000, false);
        _report(REF, true, 0);
        // stock is currency1: selling stock == zeroForOne=false
        assertApproxEqAbs(_fee(key, false), 5000, 1);
        assertEq(_fee(key, true), F0);
    }

    function test_stockIsCurrency0_18_6() public {
        PoolKey memory key = _pool(true, 18, 6, 29_700_000_000, false);
        _report(REF, true, 0);
        assertApproxEqAbs(_fee(key, false), 5000, 1); // below ref => buying stock (zeroForOne=false) is arb
        assertEq(_fee(key, true), F0);
    }

    // ------------------------------------------------------------------ registry / access
    function test_unregisteredPool_cannotInitialize() public {
        PoolKey memory key = _tokens(true, 18, 18);
        vm.expectRevert(); // wrapped PoolNotConfigured
        manager.initialize(key, _sqrtFor(30_000_000_000, true, 18, 18));
    }

    function test_configure_onlyOwner() public {
        PoolKey memory key = _tokens(true, 18, 18);
        DeviationFeeHook.ConfigParams memory p = _cfg(true);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        hook.configurePool(key, p);
    }

    function test_configure_requiresDynamicFeeAndThisHook() public {
        PoolKey memory key = _tokens(true, 18, 18);
        DeviationFeeHook.ConfigParams memory p = _cfg(true);
        key.fee = 3000;
        vm.expectRevert(DeviationFeeHook.NotDynamicFee.selector);
        hook.configurePool(key, p);
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        key.hooks = IHooks(address(0));
        vm.expectRevert(DeviationFeeHook.WrongHook.selector);
        hook.configurePool(key, p);
    }

    function test_configure_twiceReverts() public {
        PoolKey memory key = _tokens(true, 18, 18);
        hook.configurePool(key, _cfg(true));
        DeviationFeeHook.ConfigParams memory p = _cfg(true);
        vm.expectRevert(abi.encodeWithSelector(DeviationFeeHook.PoolAlreadyConfigured.selector, key.toId()));
        hook.configurePool(key, p);
    }

    function test_configure_validatesBounds() public {
        PoolKey memory key = _tokens(true, 18, 18);
        DeviationFeeHook.ConfigParams memory p = _cfg(true);
        p.f0 = 30_000; // > default feeMax 20_000
        vm.expectRevert(DeviationFeeHook.InvalidConfig.selector);
        hook.configurePool(key, p);
        p = _cfg(true);
        p.feedId = bytes32(0);
        vm.expectRevert(DeviationFeeHook.InvalidConfig.selector);
        hook.configurePool(key, p);
        p = _cfg(true);
        p.feeMax = 200_000; // > HARD_FEE_MAX
        vm.expectRevert(DeviationFeeHook.InvalidConfig.selector);
        hook.configurePool(key, p);
    }

    function test_beforeSwap_onlyPoolManager() public {
        PoolKey memory key = _pool(true, 18, 18, 30_000_000_000, false);
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        vm.expectRevert(MinimalBaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, sp, "");
    }

    function test_setSigma_onlyOwnerAndBounded() public {
        PoolKey memory key = _pool(true, 18, 18, 30_000_000_000, false);
        hook.setSigma(key.toId(), 1);
        assertEq(hook.poolConfig(key.toId()).sigmaE12, 1);
        vm.expectRevert(DeviationFeeHook.InvalidConfig.selector);
        hook.setSigma(key.toId(), type(uint64).max);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        hook.setSigma(key.toId(), 5);
    }

    function test_hookAddressMustMatchFlags() public {
        vm.expectRevert(); // Hooks.HookAddressNotValid
        new DeviationFeeHook(manager, oracle, address(this)); // CREATE address has no flag bits
    }

    // ------------------------------------------------------------------ end to end through the real PoolManager
    function _swapFee(PoolKey memory key, bool zeroForOne) internal returns (uint24 fee) {
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e12,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == sig) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("no Swap event");
    }

    function test_e2e_swapChargesOverrideFee() public {
        PoolKey memory key = _pool(true, 18, 18, 30_300_000_000, true);
        _report(REF, true, 0);
        uint24 quotedArb = _fee(key, true);
        assertGt(quotedArb, F0);
        assertEq(_swapFee(key, false), F0); // buy stock from the overpriced pool: base fee actually charged
        // the buy nudged the pool price up a hair; re-quote then trade in the arb direction
        quotedArb = _fee(key, true);
        assertEq(_swapFee(key, true), quotedArb); // the PoolManager Swap event carries exactly the quoted fee
        assertGt(quotedArb, F0);
    }

    function test_e2e_gas_beforeSwap() public {
        PoolKey memory key = _pool(true, 18, 18, 30_300_000_000, true);
        _report(REF, true, 0);
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1e12, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        vm.prank(address(manager));
        uint256 g = gasleft();
        hook.beforeSwap(address(this), key, sp, "");
        emit log_named_uint("beforeSwap gas (cold, incl. oracle + extsload)", g - gasleft());
        vm.prank(address(manager));
        g = gasleft();
        hook.beforeSwap(address(this), key, sp, "");
        emit log_named_uint("beforeSwap gas (warm)", g - gasleft());
    }

    // ------------------------------------------------------------------ FeeSet event
    function _swapFeeSet(PoolKey memory key, bool zeroForOne)
        internal
        returns (uint24 fee, uint24 f0, uint32 devBps, bool armed, uint24 poolManagerFee)
    {
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e12,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeSetSig = keccak256("FeeSet(bytes32,uint24,uint24,uint32,bool)");
        bytes32 swapSig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == feeSetSig) {
                assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()), "FeeSet poolId topic");
                (fee, f0, devBps, armed) = abi.decode(logs[i].data, (uint24, uint24, uint32, bool));
                seen++;
            } else if (logs[i].emitter == address(manager) && logs[i].topics[0] == swapSig) {
                (,,,,, poolManagerFee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
        assertEq(seen, 1, "exactly one FeeSet per swap");
    }

    function test_feeSet_arbSwap_isArmed() public {
        PoolKey memory key = _pool(true, 18, 18, 30_300_000_000, true); // pool 1% above ref
        _report(REF, true, 0);
        (uint24 fee, uint24 f0, uint32 devBps, bool armed, uint24 pmFee) = _swapFeeSet(key, true); // sell stock into it
        assertTrue(armed);
        assertEq(f0, F0);
        assertApproxEqAbs(fee, 5000, 1);
        assertApproxEqAbs(devBps, 100, 1); // d_eff = 1.00% = 100 bps (age 0, no noise)
        assertEq(pmFee, fee, "FeeSet.fee == fee the PoolManager charged");
    }

    function test_feeSet_nonArbSwap_notArmed() public {
        PoolKey memory key = _pool(true, 18, 18, 30_300_000_000, true);
        _report(REF, true, 0);
        (uint24 fee, uint24 f0, uint32 devBps, bool armed, uint24 pmFee) = _swapFeeSet(key, false);
        assertFalse(armed);
        assertEq(fee, F0);
        assertEq(f0, F0);
        assertEq(devBps, 0);
        assertEq(pmFee, F0);
    }

    function test_feeSet_failOpen_notArmed() public {
        PoolKey memory key = _pool(true, 18, 18, 30_300_000_000, true);
        _report(REF, false, 0); // session closed
        (uint24 fee,, uint32 devBps, bool armed,) = _swapFeeSet(key, true);
        assertFalse(armed);
        assertEq(fee, F0);
        assertEq(devBps, 0);
    }

    function test_feeSet_noiseReducesReportedDeviation() public {
        PoolKey memory key = _pool(true, 18, 18, 30_300_000_000, true);
        _report(REF, true, 200); // 200 s old: noise = 0.85 bps * sqrt(200) ~ 12 bps
        (uint24 fee,, uint32 devBps, bool armed,) = _swapFeeSet(key, true);
        assertTrue(armed);
        assertApproxEqAbs(devBps, 100 - 12, 2);
        assertApproxEqAbs(fee, (uint256(devBps) * 100) / 2, 100);
    }

    function test_hookMinerFindsValidAddress() public {
        // dry-run of the CREATE2 mining used by the deploy script (bounded loop => finds a salt or reverts)
        bytes memory args = abi.encode(manager, oracle, address(this));
        bytes memory code = abi.encodePacked(type(DeviationFeeHook).creationCode, args);
        bool found;
        for (uint256 salt = 0; salt < 160_444; salt++) {
            address a = vm.computeCreate2Address(bytes32(salt), keccak256(code), address(this));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == FLAGS) {
                DeviationFeeHook h = new DeviationFeeHook{salt: bytes32(salt)}(manager, oracle, address(this));
                assertEq(address(h), a);
                found = true;
                break;
            }
        }
        assertTrue(found, "no salt within 160k iterations");
    }

    // ------------------------------------------------------------------ oracle
    function test_oracle_onlyForwarder() public {
        bytes memory report = abi.encode(FEED, REF, true, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidSender.selector, address(this), address(fwd)));
        oracle.onReport("", report);
    }

    function test_oracle_storesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(oracle));
        emit RefPriceOracle.FeedUpdated(FEED, REF, uint64(block.timestamp), true);
        _report(REF, true, 0);
        (uint64 p, uint64 a, bool o) = oracle.priceOf(FEED);
        assertEq(p, REF);
        assertEq(a, block.timestamp);
        assertTrue(o);
    }

    function test_oracle_ignoresOlderOrEqualReport() public {
        _report(REF, true, 0);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit RefPriceOracle.ReportIgnored(FEED, uint64(block.timestamp - 10), RefPriceOracle.IgnoreReason.NotNewer);
        _report(1, true, 10);
        (uint64 p,,) = oracle.priceOf(FEED);
        assertEq(p, REF); // unchanged
    }

    function test_oracle_ignoresFutureAndZero() public {
        fwd.deliver(address(oracle), abi.encode(FEED, REF, true, uint64(block.timestamp + 61)));
        (uint64 p,,) = oracle.priceOf(FEED);
        assertEq(p, 0);
        fwd.deliver(address(oracle), abi.encode(FEED, uint64(0), true, uint64(block.timestamp)));
        (p,,) = oracle.priceOf(FEED);
        assertEq(p, 0);
        // within drift tolerance is accepted
        fwd.deliver(address(oracle), abi.encode(FEED, REF, true, uint64(block.timestamp + 60)));
        (p,,) = oracle.priceOf(FEED);
        assertEq(p, REF);
    }

    function test_oracle_supportsIReceiver() public view {
        assertTrue(oracle.supportsInterface(0x805f2132)); // IReceiver.onReport interface id
    }
}
