# Keel contracts

Solidity (Foundry) for **Keel**, a Uniswap v4 hook that sets a swap fee from how far a tokenized-stock pool has drifted from the stock's real price.

Part of three repos, which are meant to be checked out side by side:
[`contracts`](https://github.com/RWA-Keel-FI/contracts) (this one), [`server`](https://github.com/RWA-Keel-FI/server) (Chainlink CRE price workflow, simulation, backtest, deploy scripts), [`client`](https://github.com/RWA-Keel-FI/client) (React dapp).

> **Test tokens only.** `tTSLA` is a mock token minted by a mock issuer. No real shares exist anywhere, nothing here is custody of securities, and nothing has value.

## The problem

A tokenized stock trades on a Uniswap pool around the clock, but the real stock only trades during market hours. When the real price moves, an arbitrageur trades the pool back to the right price and the liquidity providers (LPs) pay for that move. A flat fee charges a retail trader the same as the arbitrageur.

## What the hook does

`DeviationFeeHook` runs in `beforeSwap` and overrides the pool's dynamic fee:

```
d      = |pool_price / ref_price - 1|              how far the pool is from the reference
d_eff  = max(0, d - sigma * sqrt(age))             minus the noise an aging reference could explain
fee    = max(f0, d_eff / 2)   if the swap moves the pool TOWARD the reference
fee    = f0                   otherwise
fee    = min(fee, feeMax)
```

- `f0` is the pool's base fee (30 bps in the deployment), `sigma` is the stock's measured volatility per root second, `age` is seconds since the reference was written.
- `feeMax` defaults to 2%. The owner cannot raise it above a hard ceiling of 10% (`HARD_FEE_MAX`).
- The surcharge applies only in the arbitrage direction. A swap that moves the pool away from the reference always pays `f0`.
- **Fails open.** No reference price, session closed, reference older than `maxAge` (default 900 s) or a pool price outside the safe range all give `f0`. Missing data never makes a normal user pay more.
- The hook never holds funds and never blocks a swap. It emits `FeeSet(poolId, fee, f0, deviationBps, armed)` on every swap. `quoteFee(key, zeroForOne)` returns the fee a swap would pay right now.
- Only pools the owner registered with `configurePool` can be initialized with the hook.

The `k = 1/2` factor comes from a derivation (it maximizes the LP's fee revenue from arbitrage flow), not from tuning.

## Contracts (`src/`)

| File | What it is |
|---|---|
| `DeviationFeeHook.sol` | The hook. Permissions: `beforeInitialize`, `beforeSwap`. Its address is CREATE2-mined so the permission bits match. |
| `libraries/DeviationMath.sol` | Pure fixed-point math: pool price from `sqrtPriceX96`, and the fee formula. |
| `RefPriceOracle.sol` | Stores the latest stock price per feed. Built on Chainlink's `ReceiverTemplate`, so only the configured forwarder can call `onReport`. |
| `tokens/StockIssuer.sol` | **Mock** primary market. Mints and redeems a stock token against USDC at the oracle price, with a 10 bps fee. Works only while the session is open and the price is under 900 s old. |
| `tokens/StockToken.sol` | 18-decimal ERC-20 whose only minter and burner is its issuer. |
| `tokens/MockUSDC.sol` | Mock 6-decimal USDC for local runs and tests. Not used on Arc. |
| `helpers/SwapRouter.sol`, `helpers/LiquidityRouter.sol` | Small routers for exact-in swaps and for adding and removing liquidity. |
| `base/MinimalBaseHook.sol`, `interfaces/` | Hook base and the oracle interface. |

Oracle report layout: `abi.encode(bytes32 feedId, uint64 priceE8, bool sessionOpen, uint64 asOf)`. The oracle ignores (emits `ReportIgnored`, does not revert) a zero price, a timestamp more than 60 s in the future, and a report that is not newer than the stored one. A zero price therefore cannot signal "market closed". A closed market shows up as the price going stale.

## Deployment: Arc Testnet (chain id 5042002)

Deployed on the real infrastructure of Arc Testnet: the existing Uniswap v4 `PoolManager`, Arc's USDC and Chainlink's production forwarder. Nothing in this deployment is a mock except the stock token and its issuer.

| | Address |
|---|---|
| Uniswap v4 PoolManager (existing) | `0x1d70945634F618eefdF9EDaAdB59B9A183CEF929` |
| USDC, 6-decimal ERC-20 interface (existing) | `0x3600000000000000000000000000000000000000` |
| Chainlink CRE KeystoneForwarder (existing, production) | `0x76c9cf548b4179F8901cda1f8623568b58215E62` |
| `DeviationFeeHook` | `0xb5b44F87473da93eb56BE43597BeaB59F50a2080` |
| `RefPriceOracle` | `0x907782029126f5f583010b4B5877A351236FE8f5` |
| `StockIssuer` | `0x55cf735Efe7c5b266dd6248B61dc765D4c7e51f9` |
| `tTSLA` (mock stock token) | `0x7910aEb89f4843457d90cb26161EebA34d39EB60` |
| `SwapRouter` | `0xAeAb87E3a16f980f69267F6002B21cb9CFc36d4A` |
| `LiquidityRouter` | `0xFF6d2be7c1128d42Fba72401ce974436336674c7` |

Explorer: <https://explorer.testnet.arc.network>

Two `tTSLA/USDC` pools were initialized at the live TSLA price ($358.22, the last traded price when it was deployed on a Friday evening) and seeded with about 12 USDC of liquidity in wide, medium and tight ranges:

- **Hook pool** `0x8da9612899aac68e58409d29419ca36966ab5cf3e41ca9d2334f6c55a7c64aed`: dynamic fee, uses the hook.
- **Control pool** `0x9ee74a05d558a48e026d5259bd2cb2d43759d4643dc9bb2517fd98992b5a4cb6`: the same pair with a static 30 bps fee and no hook, for paired comparison.

### What the on-chain demo showed

| Step | Pool | Fee paid | Tx |
|---|---|---|---|
| Retail-size buy | hook | 0.30%, deviation 0 | `0xc3e0efd2…99fd` |
| Same buy | control | 0.30% | `0xfb9427bc…da09` |
| Large buy that pushes the pool to $370.94 (reference $358.22), moving away from the reference | hook | 0.30% | `0xfd2bc5d6…ff8a` |
| Sell back toward the reference (arbitrage direction) | hook | **1.74%**, deviation 348 bps, `armed = true` | `0x87793e75…5445` |

The same four transactions can be looked up by hash on the Arc explorer.

### Things to know about this deployment

- **The first price was written by hand.** The Chainlink network cannot be reached from the deployment machine yet (no CRE account), and minting needs a fresh price. So the oracle was deployed with the deployer as its *temporary* forwarder, the deployer wrote one real TSLA quote (flagged session-open although the market was closed), minted `tTSLA`, seeded liquidity and ran the demo swaps, and then called `setForwarderAddress` to hand the oracle to the production KeystoneForwarder. From that point only Chainlink can write prices.
- **The reference goes stale after 15 minutes.** Until the CRE workflow in the `server` repo is deployed and writing, the hook sees a stale price and charges only the base fee (fail-open). That is the designed behavior, and also why the deviation fee will not show on the live pools until CRE is running.
- The oracle is deployed against the production forwarder, so `cre workflow simulate --broadcast` (which uses a simulation forwarder) will be rejected by it.

## Build and test

```bash
forge build
forge test        # 80 tests, 4 suites
```

Solidity 0.8.26, EVM `cancun`, `via_ir`. Dependencies are in `lib/`: OpenZeppelin, Uniswap v4-core and v4-periphery, Chainlink `chainlink-evm`, forge-std.

Tests cover the fee math, the hook (fail-open paths, direction, caps, pool registration), the routers, and the mock issuer (rounding, solvency, fuzzing).

## Deploy

Local anvil: `server/scripts/deploy-local.sh` (in the `server` repo) runs `script/DeployLocal.s.sol`, which deploys its own v4 PoolManager plus a mock forwarder and mock USDC.

Arc Testnet: `server/scripts/deploy-arc.sh real` runs `script/DeployArc.s.sol` and then the seed, demo and handover steps. `deploy-arc.sh fork` rehearses the whole flow on a local fork first.

1. `cp .env.example .env`, set `DEPLOYER_PRIVATE_KEY` to a throwaway testnet key, and fund it with Arc testnet USDC (<https://faucet.circle.com>). USDC is also the gas token on Arc.
2. Never commit `.env`. It is gitignored.

Why the extra steps are not a `forge script`: Arc's USDC ERC-20 moves balances through chain precompiles that Foundry's local EVM does not have, so a Forge script cannot simulate any step that moves USDC. Contract deployment works with Forge; the USDC-moving steps are sent with `cast send`. A fork rehearsal swaps Arc's USDC for a plain 6-decimal ERC-20, so it covers our contracts but not Arc's real USDC behavior.

## Limits, stated plainly

- Test tokens and a mock issuer. A real issuer would hold the actual shares.
- In a backtest of real swaps on Ethereum (see the `server` repo) the rule recovered a small share of arbitrage loss. It is a protective rule for LPs, not a profit engine.
- The contracts have not been audited.
