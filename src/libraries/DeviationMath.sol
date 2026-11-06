// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title DeviationMath
/// @notice Pure fixed-point math for the DeviationFee hook. See ARCHITECTURE.md §3.
/// @dev Units: prices are USD per whole stock with 8 decimals ("E8"); fees and deviations are in
///      pips (1e-6, the Uniswap v4 fee unit; 3000 = 0.30%). sigmaE12 = sigma * 1e12 where sigma is the
///      relative std-dev of the stock per sqrt(second) (e.g. 0.85 bps/sqrt(s) => 8.5e-5 => 85_000_000).
library DeviationMath {
    uint256 internal constant PIPS = 1_000_000;

    /// @notice Convert a pool sqrtPriceX96 into USD-per-stock E8.
    /// @param exp10 8 + stockDecimals - quoteDecimals (>= 0, <= 30)
    /// @return pE8 price in E8 (floor); ok=false when the pool price is outside the safe range (caller fails open)
    function sqrtPriceToUsdE8(uint160 sqrtPriceX96, bool stockIsCurrency0, uint8 exp10)
        internal
        pure
        returns (uint256 pE8, bool ok)
    {
        // Safe range: sqrtP in (0, 2^128). Keeps every mulDiv result below 2^256 (ARCHITECTURE.md §3.3).
        if (sqrtPriceX96 == 0 || sqrtPriceX96 >= (uint256(1) << 128)) return (0, false);
        // price (token1/token0, raw units) * 2^128  ==  sqrtP^2 / 2^64   (< 2^192)
        uint256 pX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, uint256(1) << 64);
        uint256 unit = 10 ** uint256(exp10);
        if (stockIsCurrency0) {
            // token0 = stock, token1 = quote:  USD/stock = p_raw * 10^(sd-qd)
            pE8 = FullMath.mulDiv(pX128, unit, uint256(1) << 128);
        } else {
            // token0 = quote, token1 = stock:  USD/stock = 10^(sd-qd) / p_raw
            if (pX128 < (uint256(1) << 64)) return (0, false);
            pE8 = FullMath.mulDiv(unit, uint256(1) << 128, pX128);
        }
        ok = pE8 != 0;
    }

    /// @notice The fee formula. fee = max(f0, d_eff/2) if the swap moves the pool toward the reference, else f0.
    /// @param pE8        pool price (USD/stock, E8)
    /// @param rE8        reference price (USD/stock, E8), must be > 0
    /// @param sellStock  true if the swap puts stock INTO the pool (lowers the USD price of stock)
    /// @param age        seconds since the reference was observed
    /// @return fee       pips, in [f0, feeMax]
    /// @return dPips     raw deviation |p/r - 1| in pips (floor)
    /// @return arb       whether the swap is in the arbitrage direction (pool != ref and swap moves it toward ref)
    function feeFor(
        uint256 pE8,
        uint256 rE8,
        bool sellStock,
        uint256 age,
        uint24 f0,
        uint24 feeMax,
        uint64 sigmaE12
    ) internal pure returns (uint24 fee, uint256 dPips, bool arb) {
        bool poolAbove = pE8 > rE8;
        uint256 diff = poolAbove ? pE8 - rE8 : rE8 - pE8;
        dPips = FullMath.mulDiv(diff, PIPS, rE8); // floor => rounds in the user's favour
        fee = f0;
        // pool above ref: arbitrageur SELLS stock into the pool; pool below ref: arbitrageur BUYS stock from it.
        arb = diff != 0 && (poolAbove == sellStock);
        if (!arb) return (fee, dPips, false);

        // noise = sigma * sqrt(age) in pips; sqrt and division both round UP => bigger deadband => never over-charge.
        uint256 noise = Math.ceilDiv(uint256(sigmaE12) * Math.sqrt(age, Math.Rounding.Ceil), 1_000_000);
        uint256 dEff = dPips > noise ? dPips - noise : 0;
        uint256 half = dEff / 2; // floor
        uint256 f = half > f0 ? half : f0;
        if (f > feeMax) f = feeMax;
        fee = uint24(f);
    }
}
