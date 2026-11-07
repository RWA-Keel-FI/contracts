# Uniswap v4 feedback (Keel / DeviationFee)

Project: Keel, a v4 hook that raises the swap fee only on swaps that move a tokenized-stock pool toward the stock's real price (arbitrage direction), using a Chainlink CRE price oracle.
Repo: https://github.com/RWA-Keel-FI/contracts
Network: Arc Testnet (chain id 5042002), on the existing v4 `PoolManager` `0x1d70945634F618eefdF9EDaAdB59B9A183CEF929`

> Written from what we actually ran into while building and deploying. Builders: add anything the team hit that is not listed here.

## What we built on
- v4-core and v4-periphery as vendored in `lib/`
- `beforeInitialize` and `beforeSwap` hook permissions, with `LPFeeLibrary.OVERRIDE_FEE_FLAG` returned from `beforeSwap` on a `DYNAMIC_FEE_FLAG` pool
- A control pool (same pair, static 30 bps, no hook) next to the hook pool, to compare the same trade in both

## What worked well
- The per-swap fee override is exactly the primitive this rule needs: the fee depends on the swap direction and on an external price, and it can be decided in `beforeSwap` without touching the pool's accounting.
- `beforeInitialize` let us restrict the hook to pools the owner registered (`configurePool`), so nobody can attach our hook to an arbitrary pool.
- The `PoolManager` on Arc behaved the same as the one we tested against locally: the same hook, routers and pool keys worked unchanged.

## Friction we hit
- **No `getSlot0` on `IPoolManager`.** Reading the pool price (needed for the deviation) from a hook, script or router means using `StateLibrary` (`extsload` with the right storage slot). It is easy to write `IPoolManager(...).getSlot0(...)` out of habit and get a compile error. A short, prominent note in the hook docs ("read pool state with `StateLibrary`") would save time.
- **Hook address mining.** The hook's address must carry the permission bits, so deployment needs a CREATE2 salt search. We loop on-chain-compatible salts in the deploy script. It works, but it is a step every hook author rebuilds. A first-party helper in the standard script template would help.
- **Mixed decimals in the price conversion.** The stock token has 18 decimals and USDC has 6, and the stock can be `currency0` or `currency1` depending on address order. Converting `sqrtPriceX96` to a USD price in both orders is easy to get wrong. We needed tests for both orders (`test_stockIsCurrency0_18_6`, `test_stockIsCurrency1_18_6`).
- **The fee is decided before the swap.** `beforeSwap` sees the pre-swap price, so a very large swap can cross the reference inside one call and still pay a fee based on the starting gap. We cap the fee (default 2%, hard ceiling 10%) and document it. A documented pattern for this case would help.
- **Observing the fee actually charged.** We emit our own `FeeSet(poolId, fee, f0, deviationBps, armed)` event from the hook, because the final per-swap fee is otherwise not directly visible. A standard event or return value for the fee applied would make dashboards simpler.

## Tooling notes (not Uniswap, but they cost us time)
- Arc's USDC ERC-20 moves balances through chain precompiles that Foundry's local EVM does not have. `forge script` cannot simulate any step that moves USDC (including v4 settle/take of USDC), so those steps are sent with `cast send` instead. A local fork with the precompiles, or Foundry support for Arc, would remove this workaround.
- `cast send` reads a negative tick such as `-8` as a flag; options must come before `--` and the arguments after it.

## Requests
- A canonical example of a hook that reads an external oracle with a staleness guard and fails open (charges the base fee) when the data is missing or old. That is the pattern this project uses.
- A documented, tested recipe for testing a hook against a fork of a live `PoolManager`.

## API / tooling notes
- We did not use the Uniswap API; pool reads go straight to the `PoolManager`.
