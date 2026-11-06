// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwapRouter} from "../src/helpers/SwapRouter.sol";
import {LiquidityRouter} from "../src/helpers/LiquidityRouter.sol";

contract RoutersTest is Test, Deployers {
    SwapRouter sr;
    LiquidityRouter lr;
    MockERC20 t0;
    MockERC20 t1;
    PoolKey pk;
    address lpA = address(0xA1);
    address lpB = address(0xB2);
    address trader = address(0x7A);

    function setUp() public {
        deployFreshManagerAndRouters();
        sr = new SwapRouter(manager);
        lr = new LiquidityRouter(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 6);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pk = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(address(0)));
        manager.initialize(pk, TickMath.getSqrtPriceAtTick(0));
        address[3] memory who = [lpA, lpB, trader];
        for (uint256 i; i < who.length; i++) {
            t0.mint(who[i], 1e30);
            t1.mint(who[i], 1e30);
            vm.startPrank(who[i]);
            t0.approve(address(lr), type(uint256).max);
            t1.approve(address(lr), type(uint256).max);
            t0.approve(address(sr), type(uint256).max);
            t1.approve(address(sr), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_addSwapRemove_roundTripWithFees() public {
        vm.prank(lpA);
        (uint256 a0, uint256 a1) = lr.addLiquidity(pk, -600, 600, 1e18);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(lr.liquidityOf(pk, lpA, -600, 600), 1e18);
        assertEq(lr.liquidityOf(pk, lpB, -600, 600), 0, "positions are per LP");

        vm.prank(trader);
        uint256 out = sr.swapExactIn(pk, true, 1e12, 1);
        assertGt(out, 0);

        uint256 b0 = t0.balanceOf(lpA);
        uint256 b1 = t1.balanceOf(lpA);
        vm.prank(lpA);
        (int256 r0, int256 r1) = lr.removeLiquidity(pk, -600, 600, 1e18);
        assertGt(r0, 0);
        assertGt(r1, 0);
        assertEq(t0.balanceOf(lpA) - b0, uint256(r0));
        assertEq(t1.balanceOf(lpA) - b1, uint256(r1));
        // LP got back more token0 than deposited: the trader paid it in (plus the 0.30% fee)
        assertGt(uint256(r0), a0);
        assertEq(lr.liquidityOf(pk, lpA, -600, 600), 0);
    }

    function test_swapExactIn_slippageReverts() public {
        vm.prank(lpA);
        lr.addLiquidity(pk, -600, 600, 1e18);
        vm.prank(trader);
        vm.expectRevert();
        sr.swapExactIn(pk, true, 1e12, 1e18);
    }

    function test_quoteLiquidity_matchesAddLiquidityAmounts() public {
        (uint128 qL, uint256 q0, uint256 q1) = lr.quoteLiquidity(pk, -1200, 1200, 5e17, 5e5);
        vm.prank(lpA);
        (uint128 L, uint256 p0, uint256 p1) = lr.addLiquidityAmounts(pk, -1200, 1200, 5e17, 5e5);
        assertEq(L, qL);
        assertLe(p0, q0); // quote rounds up, pool charges rounded-up too; never more than the quote
        assertLe(p1, q1);
        assertLe(p0, 5e17);
        assertLe(p1, 5e5);
    }

    function test_twoLPs_independentPositions() public {
        vm.prank(lpA);
        lr.addLiquidity(pk, -600, 600, 1e18);
        vm.prank(lpB);
        lr.addLiquidity(pk, -600, 600, 2e18);
        vm.prank(lpA);
        vm.expectRevert(); // cannot remove more than LP A owns, even though the pool holds LP B's liquidity
        lr.removeLiquidity(pk, -600, 600, 2e18);
        vm.prank(lpB);
        lr.removeLiquidity(pk, -600, 600, 2e18);
        assertEq(lr.liquidityOf(pk, lpA, -600, 600), 1e18);
    }

    function test_routers_rejectDirectUnlockCallback() public {
        vm.expectRevert(SwapRouter.NotPoolManager.selector);
        sr.unlockCallback("");
        vm.expectRevert(LiquidityRouter.NotPoolManager.selector);
        lr.unlockCallback("");
    }
}
