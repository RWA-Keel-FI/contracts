// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title LiquidityRouter
/// @notice DEMO/TEST helper. Add or remove concentrated liquidity on ERC20/ERC20 v4 pools. The PoolManager sees this
///         router as the position owner, so each LP's position is separated by `salt = bytes32(uint160(lp))`.
///         Removing also pays out the fees the position earned. Not audited, ERC20 only.
contract LiquidityRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;

    struct CallbackData {
        address lp;
        PoolKey key;
        ModifyLiquidityParams params;
    }

    error NotPoolManager();
    error ZeroLiquidity();

    event LiquidityChanged(
        address indexed lp, bytes32 indexed poolId, int24 tickLower, int24 tickUpper, int256 liquidityDelta, int256 amount0, int256 amount1
    );

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    // ---------------------------------------------------------------- liquidity
    /// @notice add `liquidity` units between the ticks. Pulls both tokens from the caller (approve this router first).
    /// @return amount0 amount0 paid by the LP (positive number)
    /// @return amount1 amount1 paid by the LP (positive number)
    function addLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        public
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) revert ZeroLiquidity();
        BalanceDelta d = _modify(key, tickLower, tickUpper, int256(uint256(liquidity)));
        amount0 = uint256(int256(-d.amount0()));
        amount1 = uint256(int256(-d.amount1()));
    }

    /// @notice add as much liquidity as `amount0Max` / `amount1Max` allow at the current price
    function addLiquidityAmounts(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint256 amount0Max, uint256 amount1Max)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (liquidity,,) = quoteLiquidity(key, tickLower, tickUpper, amount0Max, amount1Max);
        (amount0, amount1) = addLiquidity(key, tickLower, tickUpper, liquidity);
    }

    /// @notice remove `liquidity` units of the caller's position; tokens and earned fees go to the caller
    function removeLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        returns (int256 amount0, int256 amount1)
    {
        if (liquidity == 0) revert ZeroLiquidity();
        BalanceDelta d = _modify(key, tickLower, tickUpper, -int256(uint256(liquidity)));
        amount0 = d.amount0();
        amount1 = d.amount1();
    }

    // ---------------------------------------------------------------- views
    /// @notice liquidity that `amount0Max` / `amount1Max` buys at the current price, and what it would cost
    function quoteLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint256 amount0Max, uint256 amount1Max)
        public
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, amount0Max, amount1Max);
        (amount0, amount1) = _amounts(sqrtP, sqrtA, sqrtB, liquidity);
    }

    /// @notice liquidity currently held by `lp` in the given range
    function liquidityOf(PoolKey calldata key, address lp, int24 tickLower, int24 tickUpper) external view returns (uint128) {
        bytes32 id = Position.calculatePositionKey(address(this), tickLower, tickUpper, bytes32(uint256(uint160(lp))));
        return manager.getPositionLiquidity(key.toId(), id);
    }

    // ---------------------------------------------------------------- internals
    function _modify(PoolKey calldata key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        internal
        returns (BalanceDelta d)
    {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: bytes32(uint256(uint160(msg.sender)))
        });
        bytes memory res = manager.unlock(abi.encode(CallbackData(msg.sender, key, p)));
        d = abi.decode(res, (BalanceDelta));
        emit LiquidityChanged(msg.sender, keccak256(abi.encode(key)), tickLower, tickUpper, liquidityDelta, d.amount0(), d.amount1());
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        CallbackData memory c = abi.decode(raw, (CallbackData));
        (BalanceDelta callerDelta,) = manager.modifyLiquidity(c.key, c.params, "");
        _settleOrTake(c.key.currency0, c.lp, callerDelta.amount0());
        _settleOrTake(c.key.currency1, c.lp, callerDelta.amount1());
        return abi.encode(callerDelta);
    }

    function _settleOrTake(Currency cur, address lp, int128 amount) internal {
        if (amount < 0) {
            manager.sync(cur);
            IERC20(Currency.unwrap(cur)).safeTransferFrom(lp, address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(cur, lp, uint256(uint128(amount)));
        }
    }

    function _amounts(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liq) internal pure returns (uint256 a0, uint256 a1) {
        // amounts needed to mint `liq` (rounded up), same piecewise rule the pool uses
        if (sqrtP <= sqrtA) {
            a0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liq, true);
        } else if (sqrtP < sqrtB) {
            a0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liq, true);
            a1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liq, true);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liq, true);
        }
    }
}
