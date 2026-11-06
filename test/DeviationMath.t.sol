// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {DeviationMath} from "../src/libraries/DeviationMath.sol";

contract DeviationMathTest is Test {
    /// helper: sqrtPriceX96 of a pool whose USD/stock price is `pE8`, for given orientation/decimals
    function sqrtFor(uint256 pE8, bool stockIsC0, uint8 sd, uint8 qd) internal pure returns (uint160) {
        uint256 q192;
        if (stockIsC0) q192 = FullMath.mulDiv(pE8 * 10 ** qd, uint256(1) << 192, 10 ** (8 + sd));
        else q192 = FullMath.mulDiv(10 ** (8 + sd), uint256(1) << 192, pE8 * 10 ** qd);
        return uint160(Math.sqrt(q192));
    }

    function _roundTrip(uint256 pE8, bool stockIsC0, uint8 sd, uint8 qd) internal pure {
        uint160 s = sqrtFor(pE8, stockIsC0, sd, qd);
        (uint256 back, bool ok) = DeviationMath.sqrtPriceToUsdE8(s, stockIsC0, uint8(8 + sd - qd));
        require(ok, "not ok");
        // sqrt floor error is ~1e-12 relative at these magnitudes; allow 1e-6
        uint256 diff = back > pE8 ? back - pE8 : pE8 - back;
        require(diff * 1e6 <= pE8, "round trip off");
    }

    function test_roundTrip_18_18_stock0() public pure {
        _roundTrip(30_300_000_000, true, 18, 18);
    }

    function test_roundTrip_18_6_stock0() public pure {
        _roundTrip(30_300_000_000, true, 18, 6);
    }

    function test_roundTrip_18_6_stock1() public pure {
        _roundTrip(30_300_000_000, false, 18, 6);
    }

    function test_roundTrip_18_18_stock1() public pure {
        _roundTrip(30_300_000_000, false, 18, 18);
    }

    function testFuzz_roundTrip(uint256 pE8, bool stockIsC0, bool sixDec) public pure {
        pE8 = bound(pE8, 1e6, 1e13); // $0.01 .. $100k
        _roundTrip(pE8, stockIsC0, 18, sixDec ? 6 : 18);
    }

    function test_priceMath_failsOpen_outOfRange() public pure {
        (, bool ok) = DeviationMath.sqrtPriceToUsdE8(0, true, 8);
        assertFalse(ok);
        (, ok) = DeviationMath.sqrtPriceToUsdE8(type(uint160).max, true, 8);
        assertFalse(ok);
        (, ok) = DeviationMath.sqrtPriceToUsdE8(1, false, 8); // price ~0 => 1/p overflow guard
        assertFalse(ok);
    }

    // ---- fee function

    function test_fee_exactNumbers() public pure {
        // pool 303 vs ref 300 => d = 10_000 pips, f0 = 3000, no noise => fee = 5000
        (uint24 fee, uint256 d, bool arb) = DeviationMath.feeFor(30_300_000_000, 30_000_000_000, true, 0, 3000, 20_000, 0);
        assertEq(d, 10_000);
        assertTrue(arb);
        assertEq(fee, 5000);
    }

    function test_fee_deadband_is_2xf0() public pure {
        // d = 6000 = 2*f0 => d/2 = f0 => still f0; d = 6002 => 3001
        (uint24 f1,,) = DeviationMath.feeFor(30_180_000_000, 30_000_000_000, true, 0, 3000, 20_000, 0);
        assertEq(f1, 3000);
        (uint24 f2,,) = DeviationMath.feeFor(30_180_060_000, 30_000_000_000, true, 0, 3000, 20_000, 0);
        assertEq(f2, 3001);
    }

    function test_fee_noiseRoundsUp() public pure {
        // sigma 8.5e7, age 900 => noise 2550. d=10_000 => d_eff 7450 => fee 3725
        (uint24 fee,,) = DeviationMath.feeFor(30_300_000_000, 30_000_000_000, true, 900, 3000, 20_000, 85_000_000);
        assertEq(fee, 3725);
        // age 1 => ceil sqrt = 1 => noise = ceil(8.5e7/1e6) = 85
        (uint24 fee1,,) = DeviationMath.feeFor(30_300_000_000, 30_000_000_000, true, 1, 3000, 20_000, 85_000_000);
        assertEq(fee1, 4957); // floor((10_000 - 85) / 2)
    }

    function test_fee_clampedToFeeMax() public pure {
        (uint24 fee,,) = DeviationMath.feeFor(33_000_000_000, 30_000_000_000, true, 0, 3000, 20_000, 0);
        assertEq(fee, 20_000);
    }

    function test_fee_wrongDirectionIsBase() public pure {
        (uint24 fee,, bool arb) = DeviationMath.feeFor(33_000_000_000, 30_000_000_000, false, 0, 3000, 20_000, 0);
        assertEq(fee, 3000);
        assertFalse(arb);
    }

    function test_fee_poolBelowRef_buyingStockIsArb() public pure {
        (uint24 fee,, bool arb) = DeviationMath.feeFor(29_700_000_000, 30_000_000_000, false, 0, 3000, 20_000, 0);
        assertTrue(arb);
        assertEq(fee, 5000);
        (uint24 fee2,, bool arb2) = DeviationMath.feeFor(29_700_000_000, 30_000_000_000, true, 0, 3000, 20_000, 0);
        assertFalse(arb2);
        assertEq(fee2, 3000);
    }

    function test_fee_equalPriceIsBase() public pure {
        (uint24 fee,, bool arb) = DeviationMath.feeFor(30_000_000_000, 30_000_000_000, true, 0, 3000, 20_000, 0);
        assertEq(fee, 3000);
        assertFalse(arb);
    }

    // ---- properties
    function testFuzz_fee_bounds(uint64 p, uint64 r, bool sell, uint32 age, uint24 f0, uint24 feeMax, uint64 sigma)
        public
        pure
    {
        r = uint64(bound(r, 1e6, 1e13));
        p = uint64(bound(p, 1e6, 1e13));
        feeMax = uint24(bound(feeMax, 1, 100_000));
        f0 = uint24(bound(f0, 0, feeMax));
        age = uint32(bound(age, 0, 900));
        sigma = uint64(bound(sigma, 0, 1e10));
        (uint24 fee,, bool arb) = DeviationMath.feeFor(p, r, sell, age, f0, feeMax, sigma);
        assertGe(fee, f0);
        assertLe(fee, feeMax);
        if (!arb) assertEq(fee, f0);
    }

    /// a user in the arb direction never pays more than half the deviation (beyond f0) => still beats fair price
    function testFuzz_fee_neverExceedsHalfDeviationOrF0(uint64 p, uint64 r, uint32 age, uint24 f0) public pure {
        r = uint64(bound(r, 1e6, 1e13));
        p = uint64(bound(p, 1e6, 1e13));
        f0 = uint24(bound(f0, 0, 20_000));
        bool sell = p > r;
        (uint24 fee, uint256 d,) = DeviationMath.feeFor(p, r, sell, bound(age, 0, 900), f0, 100_000, 85_000_000);
        uint256 cap = d / 2 > f0 ? d / 2 : f0;
        assertLe(fee, cap);
    }

    /// fee is monotone non-decreasing in deviation (same direction, same noise)
    function testFuzz_fee_monotoneInDeviation(uint64 p1, uint64 p2, uint32 age) public pure {
        uint64 r = 30_000_000_000;
        p1 = uint64(bound(p1, r + 1, r * 3));
        p2 = uint64(bound(p2, p1, r * 3));
        age = uint32(bound(age, 0, 900));
        (uint24 a,,) = DeviationMath.feeFor(p1, r, true, age, 3000, 20_000, 85_000_000);
        (uint24 b,,) = DeviationMath.feeFor(p2, r, true, age, 3000, 20_000, 85_000_000);
        assertGe(b, a);
    }
}
