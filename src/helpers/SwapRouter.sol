// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title SwapRouter
/// @notice DEMO/TEST helper. Exact-input swaps on any ERC20/ERC20 v4 pool. The caller approves this router for the
///         input token, receives the output token, and pays nothing else. Not audited, no deadline, no native ETH.
contract SwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;

    struct CallbackData {
        address payer;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    error NotPoolManager();
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error ZeroAmount();

    event Routed(address indexed payer, bytes32 indexed poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut);

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice sell exactly `amountIn` of the input currency, receive at least `minAmountOut` of the other.
    /// @param zeroForOne true = pay currency0, receive currency1
    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        bytes memory result = manager.unlock(abi.encode(CallbackData(msg.sender, key, zeroForOne, amountIn, minAmountOut)));
        amountOut = abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        CallbackData memory d = abi.decode(raw, (CallbackData));

        BalanceDelta delta = manager.swap(
            d.key,
            SwapParams({
                zeroForOne: d.zeroForOne,
                amountSpecified: -int256(d.amountIn),
                sqrtPriceLimitX96: d.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        (Currency cIn, Currency cOut) = d.zeroForOne ? (d.key.currency0, d.key.currency1) : (d.key.currency1, d.key.currency0);
        int128 owed = d.zeroForOne ? delta.amount0() : delta.amount1(); // <= 0
        int128 got = d.zeroForOne ? delta.amount1() : delta.amount0(); // >= 0
        uint256 amountOut = uint256(uint128(got));
        if (amountOut < d.minAmountOut) revert SlippageExceeded(amountOut, d.minAmountOut);

        // pay what the pool actually consumed (may be < amountIn if liquidity ran out), then take the output
        manager.sync(cIn);
        IERC20(Currency.unwrap(cIn)).safeTransferFrom(d.payer, address(manager), uint256(uint128(-owed)));
        manager.settle();
        manager.take(cOut, d.payer, amountOut);

        emit Routed(d.payer, keccak256(abi.encode(d.key)), d.zeroForOne, uint256(uint128(-owed)), amountOut);
        return abi.encode(amountOut);
    }
}
