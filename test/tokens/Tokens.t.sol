// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRefPriceOracle} from "../../src/interfaces/IRefPriceOracle.sol";
import {MockUSDC} from "../../src/tokens/MockUSDC.sol";
import {StockToken} from "../../src/tokens/StockToken.sol";
import {StockIssuer} from "../../src/tokens/StockIssuer.sol";

contract SettableOracle is IRefPriceOracle {
    struct P {
        uint64 priceE8;
        uint64 asOf;
        bool sessionOpen;
    }

    mapping(bytes32 => P) public p;

    function set(bytes32 feedId, uint64 priceE8, uint64 asOf, bool sessionOpen) external {
        p[feedId] = P(priceE8, asOf, sessionOpen);
    }

    function priceOf(bytes32 feedId) external view returns (uint64, uint64, bool) {
        P memory x = p[feedId];
        return (x.priceE8, x.asOf, x.sessionOpen);
    }
}

contract TokensTest is Test {
    bytes32 constant NVDA = bytes32("NVDA");
    bytes32 constant TSLA = bytes32("TSLA");
    uint64 constant P100 = 100e8; // $100

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    MockUSDC usdc;
    SettableOracle oracle;
    StockIssuer issuer;
    StockToken nvda;
    StockToken tsla;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC(owner);
        oracle = new SettableOracle();
        issuer = new StockIssuer(IERC20(address(usdc)), oracle, owner);
        nvda = new StockToken("Test NVIDIA", "tNVDA", address(issuer));
        tsla = new StockToken("Test Tesla", "tTSLA", address(issuer));
        vm.startPrank(owner);
        issuer.listTicker(NVDA, nvda);
        issuer.listTicker(TSLA, tsla);
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(owner, 1_000_000e6);
        vm.stopPrank();
        oracle.set(NVDA, P100, uint64(block.timestamp), true);
        oracle.set(TSLA, 250e8, uint64(block.timestamp), true);
        vm.prank(alice);
        usdc.approve(address(issuer), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(issuer), type(uint256).max);
    }

    // ------------------------------------------------------------ round trip and fee

    function test_mint_exactNumbers() public {
        vm.prank(alice);
        uint256 out = issuer.mint(NVDA, 1_000e6);
        // fee 10 bps = 1 USDC, net 999 USDC at $100 = 9.99 shares
        assertEq(out, 9.99e18);
        assertEq(nvda.balanceOf(alice), 9.99e18);
        assertEq(issuer.reserves(NVDA), 999e6);
        assertEq(issuer.feesAccrued(), 1e6);
        assertEq(usdc.balanceOf(address(issuer)), 1_000e6);
    }

    function test_redeem_exactNumbers_andRoundTripLoss() public {
        vm.startPrank(alice);
        uint256 tokens = issuer.mint(NVDA, 1_000e6);
        uint256 before = usdc.balanceOf(alice);
        uint256 out = issuer.redeem(NVDA, tokens);
        vm.stopPrank();
        // value 999 USDC, fee ceil(0.999) = 0.999 USDC (999000), out 998.001 USDC
        assertEq(out, 998_001_000);
        assertEq(usdc.balanceOf(alice) - before, 998_001_000);
        assertEq(nvda.totalSupply(), 0);
        assertEq(issuer.reserves(NVDA), 0);
        assertEq(issuer.feesAccrued(), 1e6 + 999_000);
        // the round trip costs the user about 20 bps
        assertLt(out, 1_000e6);
    }

    function test_quotes_matchActual() public {
        (uint256 qOut, uint256 qFee) = issuer.quoteMint(NVDA, 12_345e6);
        vm.prank(alice);
        uint256 out = issuer.mint(NVDA, 12_345e6);
        assertEq(out, qOut);
        assertEq(qFee, 12_345_000); // 10 bps of 12,345 USDC = 12.345 USDC
        (uint256 rOut,) = issuer.quoteRedeem(NVDA, out);
        vm.prank(alice);
        assertEq(issuer.redeem(NVDA, out), rOut);
    }

    function test_twoTickers_independentPrices() public {
        vm.startPrank(alice);
        uint256 a = issuer.mint(NVDA, 1_000e6); // $100
        uint256 b = issuer.mint(TSLA, 1_000e6); // $250
        vm.stopPrank();
        assertEq(a, 9.99e18);
        assertEq(b, 3.996e18);
        assertEq(issuer.reserves(NVDA), 999e6);
        assertEq(issuer.reserves(TSLA), 999e6);
    }

    // ------------------------------------------------------------ primary market hours

    function test_mint_revertsWhenSessionClosed() public {
        oracle.set(NVDA, P100, uint64(block.timestamp), false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StockIssuer.PrimaryMarketClosed.selector, NVDA, false, uint64(block.timestamp)));
        issuer.mint(NVDA, 1_000e6);
        assertFalse(issuer.primaryMarketOpen(NVDA));
    }

    function test_redeem_revertsWhenSessionClosed() public {
        vm.prank(alice);
        uint256 t = issuer.mint(NVDA, 1_000e6);
        oracle.set(NVDA, P100, uint64(block.timestamp), false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StockIssuer.PrimaryMarketClosed.selector, NVDA, false, uint64(block.timestamp)));
        issuer.redeem(NVDA, t);
    }

    function test_secondaryTransfersStillWorkWhenClosed() public {
        vm.prank(alice);
        uint256 t = issuer.mint(NVDA, 1_000e6);
        oracle.set(NVDA, P100, uint64(block.timestamp), false);
        vm.prank(alice);
        nvda.transfer(bob, t); // the token itself keeps moving; only the primary market is closed
        assertEq(nvda.balanceOf(bob), t);
    }

    function test_stalePrice_reverts_exactBoundary() public {
        uint64 asOf = uint64(block.timestamp);
        oracle.set(NVDA, P100, asOf, true);
        vm.warp(block.timestamp + 900); // age == 900 still fine
        vm.prank(alice);
        issuer.mint(NVDA, 100e6);
        vm.warp(block.timestamp + 1); // age 901
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StockIssuer.PrimaryMarketClosed.selector, NVDA, true, asOf));
        issuer.mint(NVDA, 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StockIssuer.PrimaryMarketClosed.selector, NVDA, true, asOf));
        issuer.redeem(NVDA, 1e18);
    }

    function test_noPrice_reverts() public {
        bytes32 feed = bytes32("AAPL");
        StockToken t = new StockToken("Test Apple", "tAAPL", address(issuer));
        vm.prank(owner);
        issuer.listTicker(feed, t);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StockIssuer.PrimaryMarketClosed.selector, feed, false, uint64(0)));
        issuer.mint(feed, 100e6);
    }

    // ------------------------------------------------------------ listing and access control

    function test_unlistedTicker_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StockIssuer.TickerNotListed.selector, bytes32("META")));
        issuer.mint(bytes32("META"), 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StockIssuer.TickerNotListed.selector, bytes32("META")));
        issuer.redeem(bytes32("META"), 1e18);
        vm.expectRevert(abi.encodeWithSelector(StockIssuer.TickerNotListed.selector, bytes32("META")));
        issuer.proofOfReserve(bytes32("META"));
    }

    function test_listTicker_onlyOwner() public {
        StockToken t = new StockToken("Test Meta", "tMETA", address(issuer));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        issuer.listTicker(bytes32("META"), t);
    }

    function test_listTicker_rejectsDuplicatesAndForeignTokens() public {
        StockToken t = new StockToken("Test Meta", "tMETA", address(issuer));
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(StockIssuer.TickerAlreadyListed.selector, NVDA));
        issuer.listTicker(NVDA, t);
        vm.expectRevert(abi.encodeWithSelector(StockIssuer.TokenAlreadyListed.selector, address(nvda)));
        issuer.listTicker(bytes32("X"), nvda);
        StockToken foreign = new StockToken("Foreign", "F", address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(StockIssuer.WrongIssuer.selector, address(foreign)));
        issuer.listTicker(bytes32("Y"), foreign);
        vm.stopPrank();
        assertEq(issuer.feedCount(), 2);
        assertEq(issuer.feedAt(0), NVDA);
    }

    function test_stockToken_onlyIssuerMintsAndBurns() public {
        vm.prank(alice);
        vm.expectRevert(StockToken.NotIssuer.selector);
        nvda.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(StockToken.NotIssuer.selector);
        nvda.burn(alice, 1);
        vm.prank(owner); // even the issuer's owner cannot mint directly
        vm.expectRevert(StockToken.NotIssuer.selector);
        nvda.mint(owner, 1e18);
        assertEq(nvda.issuer(), address(issuer));
        assertEq(nvda.decimals(), 18);
    }

    function test_withdrawFees_onlyOwner() public {
        vm.prank(alice);
        issuer.mint(NVDA, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        issuer.withdrawFees(alice);
        uint256 before = usdc.balanceOf(bob);
        vm.prank(owner);
        issuer.withdrawFees(bob);
        assertEq(usdc.balanceOf(bob) - before, 1e6);
        assertEq(issuer.feesAccrued(), 0);
        // reserves untouched by the fee withdrawal
        assertEq(usdc.balanceOf(address(issuer)), 999e6);
    }

    // ------------------------------------------------------------ reserves

    function test_proofOfReserve_afterMint() public {
        vm.prank(alice);
        issuer.mint(NVDA, 1_000e6);
        (uint256 res, uint256 supplyValue, bool ok) = issuer.proofOfReserve(NVDA);
        assertEq(res, 999e6);
        assertEq(supplyValue, 999e6);
        assertTrue(ok);
        assertTrue(issuer.isSolvent());
    }

    function test_priceRise_underbacked_untilFunded() public {
        vm.prank(alice);
        issuer.mint(NVDA, 1_000e6);
        oracle.set(NVDA, 110e8, uint64(block.timestamp), true); // +10%
        (uint256 res, uint256 supplyValue, bool ok) = issuer.proofOfReserve(NVDA);
        assertEq(res, 999e6);
        assertEq(supplyValue, 1_098_900_000); // 9.99 x $110
        assertFalse(ok);
        assertFalse(issuer.isSolvent());

        vm.startPrank(owner);
        usdc.approve(address(issuer), 200e6);
        issuer.fundReserves(200e6);
        vm.stopPrank();
        (res,, ok) = issuer.proofOfReserve(NVDA);
        assertEq(res, 1_199e6);
        assertTrue(ok);
        assertTrue(issuer.isSolvent());
    }

    function test_redeem_afterPriceRise_needsBuffer() public {
        vm.prank(alice);
        uint256 t = issuer.mint(NVDA, 1_000e6);
        oracle.set(NVDA, 110e8, uint64(block.timestamp), true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StockIssuer.InsufficientReserves.selector, 1_098_900_000, 999e6));
        issuer.redeem(NVDA, t);

        vm.startPrank(owner);
        usdc.approve(address(issuer), 200e6);
        issuer.fundReserves(200e6);
        vm.stopPrank();
        vm.prank(alice);
        uint256 out = issuer.redeem(NVDA, t);
        // value 1098.9, fee ceil(1.0989) = 1.0989 USDC exactly (1_098_900), out 1097.8011
        assertEq(out, 1_097_801_100);
        assertEq(issuer.reserves(NVDA), 0);
        assertEq(issuer.buffer(), 200e6 - (1_098_900_000 - 999e6)); // buffer paid the 99.9 USDC gap
    }

    function test_fundReserves_zeroReverts_andAnyoneCanFund() public {
        vm.prank(alice);
        vm.expectRevert(StockIssuer.ZeroAmount.selector);
        issuer.fundReserves(0);
        vm.prank(alice);
        issuer.fundReserves(5e6);
        assertEq(issuer.buffer(), 5e6);
    }

    // ------------------------------------------------------------ rounding and dust

    function test_dustMint_reverts() public {
        vm.prank(alice);
        vm.expectRevert(StockIssuer.ZeroAmount.selector);
        issuer.mint(NVDA, 0);
        vm.prank(alice);
        vm.expectRevert(StockIssuer.ZeroAmount.selector);
        issuer.mint(NVDA, 1); // fee rounds up to 1, net 0, no tokens
    }

    function test_redeem_zeroAndDust_revert() public {
        vm.prank(alice);
        issuer.mint(NVDA, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(StockIssuer.ZeroAmount.selector);
        issuer.redeem(NVDA, 0);
        vm.prank(alice);
        vm.expectRevert(StockIssuer.ZeroAmount.selector);
        issuer.redeem(NVDA, 1e6); // 1e6 wei of token is worth 0 USDC units
    }

    function test_roundingAlwaysFavoursIssuer() public {
        // price $333.33333333, odd amount
        oracle.set(NVDA, 33_333_333_333, uint64(block.timestamp), true);
        vm.startPrank(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 t = issuer.mint(NVDA, 777_777_777);
        issuer.redeem(NVDA, t);
        vm.stopPrank();
        assertLt(usdc.balanceOf(alice), usdcBefore);
        assertGe(usdc.balanceOf(address(issuer)), issuer.reserves(NVDA) + issuer.feesAccrued());
    }

    // ------------------------------------------------------------ MockUSDC

    function test_usdc_basics() public {
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.symbol(), "tUSDC");
        assertEq(usdc.name(), "Test USDC");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        usdc.mint(alice, 1);
    }

    function test_faucet_onceAnHour() public {
        address carol = makeAddr("carol");
        vm.startPrank(carol);
        vm.expectEmit(true, false, false, true);
        emit MockUSDC.Faucet(carol, 10_000e6);
        usdc.faucet();
        assertEq(usdc.balanceOf(carol), 10_000e6);
        uint256 first = block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.FaucetCooldown.selector, first + 1 hours));
        usdc.faucet();
        vm.warp(first + 1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.FaucetCooldown.selector, first + 1 hours));
        usdc.faucet();
        vm.warp(first + 1 hours);
        usdc.faucet();
        assertEq(usdc.balanceOf(carol), 20_000e6);
        vm.stopPrank();
        // another address is independent
        vm.prank(bob);
        usdc.faucet();
    }

    function test_faucet_firstClaimAtTimestampZeroSafe() public {
        // a fresh address can always claim even right at deployment time
        address dave = makeAddr("dave");
        vm.prank(dave);
        usdc.faucet();
        assertEq(usdc.balanceOf(dave), 10_000e6);
    }

    // ------------------------------------------------------------ fuzz

    /// @dev a mint followed by a redeem of everything minted never returns more than was paid in, and the
    ///      issuer's USDC balance never falls: the round trip cannot create value.
    function testFuzz_roundTrip_neverCreatesValue(uint256 usdcIn, uint64 priceE8) public {
        usdcIn = bound(usdcIn, 1e6, 500_000e6);
        priceE8 = uint64(bound(priceE8, 1e6, 1e12)); // $0.01 .. $10,000
        oracle.set(NVDA, priceE8, uint64(block.timestamp), true);
        uint256 issuerBefore = usdc.balanceOf(address(issuer));
        vm.startPrank(alice);
        uint256 before = usdc.balanceOf(alice);
        uint256 t = issuer.mint(NVDA, usdcIn);
        uint256 out = issuer.redeem(NVDA, t);
        vm.stopPrank();
        assertLe(out, usdcIn, "user got more than paid");
        assertLe(usdc.balanceOf(alice), before, "user balance grew");
        assertGe(usdc.balanceOf(address(issuer)), issuerBefore, "issuer balance fell");
        assertEq(nvda.totalSupply(), 0);
    }

    /// @dev redeeming in pieces cannot beat redeeming at once by more than rounding dust per piece
    function testFuzz_splitRedeem_noFreeValue(uint256 usdcIn, uint8 pieces) public {
        usdcIn = bound(usdcIn, 10e6, 100_000e6);
        pieces = uint8(bound(pieces, 2, 10));
        vm.startPrank(alice);
        uint256 before = usdc.balanceOf(alice);
        uint256 t = issuer.mint(NVDA, usdcIn);
        uint256 part = t / pieces;
        for (uint256 i; i < pieces - 1; ++i) {
            issuer.redeem(NVDA, part);
        }
        issuer.redeem(NVDA, t - part * (pieces - 1));
        vm.stopPrank();
        assertLe(usdc.balanceOf(alice), before);
    }

    function testFuzz_quoteMatchesMint(uint256 usdcIn, uint64 priceE8) public {
        usdcIn = bound(usdcIn, 1e6, 500_000e6);
        priceE8 = uint64(bound(priceE8, 1e6, 1e12));
        oracle.set(NVDA, priceE8, uint64(block.timestamp), true);
        (uint256 q,) = issuer.quoteMint(NVDA, usdcIn);
        vm.prank(alice);
        assertEq(issuer.mint(NVDA, usdcIn), q);
    }
}
