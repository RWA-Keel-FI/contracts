# DeviationFee — contracts architecture

Status: **prototype, unaudited, deployed on Arc Testnet (chain 5042002; addresses in README.md).** 80 Foundry tests pass (`forge test`), see §9 for what that does and does not cover.

## 1. What it does

A Uniswap v4 dynamic-fee hook for tokenized-stock / stablecoin pools. A swap that pushes the pool price *toward* a live
reference price (an arbitrage trade) pays a higher fee; every other swap pays the pool's normal base fee `f0`.

```
d      = |p_pool / r_ref − 1|                       (pips)
d_eff  = max(0, d − σ·√age)                         (reference-staleness noise removed)
fee    = max(f0, d_eff / 2)   if swap moves p_pool toward r_ref
fee    = f0                   otherwise
fee    = min(fee, feeMax)
fail-open: no price | session closed | age > maxAge | pool price out of range  →  fee = f0
```

`k = 1/2` is not a tuning knob: for arbitrage flow of size `Q = c·(d − f)` the LP's fee revenue `f·Q` is maximised at
`f = d/2`. The deadband `d ≤ 2·f0` is therefore automatic.

```
 Chainlink CRE workflow ──(report)──► MockForwarder / KeystoneForwarder ──► RefPriceOracle.onReport
                                                                                │ priceOf(feedId)
 swapper ──► PoolManager.swap ──► DeviationFeeHook.beforeSwap ◄────────────────┘
                                         │ extsload(slot0)      returns (fee | OVERRIDE_FEE_FLAG)
                                         ▼
                                   PoolManager applies fee to this swap
```

### Files

| Path | Role |
|---|---|
| `src/RefPriceOracle.sol` | `ReceiverTemplate` (Chainlink, `automation-cre/`) subclass; stores `(priceE8, asOf, sessionOpen)` per `feedId` |
| `src/DeviationFeeHook.sol` | the hook (`beforeInitialize` + `beforeSwap`), owner-gated pool registry |
| `src/libraries/DeviationMath.sol` | pure fixed-point math (price conversion + fee formula) |
| `src/base/MinimalBaseHook.sol` | tiny `IHooks` base (v4-periphery HEAD no longer ships `BaseHook`) |
| `src/interfaces/IRefPriceOracle.sol` | read interface shared with the UI/CRE agents |
| `test/DeviationMath.t.sol` | 16 tests (unit + fuzz) of the math |
| `test/DeviationFeeHook.t.sol` | 28 tests against a real `PoolManager` + mock forwarder |
| `test/mocks/MockForwarder.sol` | delivers reports to a receiver as `msg.sender` |

## 2. Fixed interface (other agents depend on this)

```
report = abi.encode(bytes32 feedId, uint64 priceE8, bool sessionOpen, uint64 asOf)
RefPriceOracle.priceOf(bytes32 feedId) → (uint64 priceE8, uint64 asOf, bool sessionOpen)
DeviationFeeHook.quoteFee(PoolKey key, bool zeroForOne) → (uint24 fee, uint256 dPips, bool arbDirection)   // view, for the UI
DeviationFeeHook.configurePool(PoolKey key, ConfigParams p)   // owner; must run BEFORE PoolManager.initialize
ConfigParams = { bytes32 feedId; bool stockIsCurrency0; uint24 f0; uint24 feeMax; uint32 maxAge; uint64 sigmaE12 }
```

Units: `priceE8` = USD per whole stock × 1e8 · fees/deviations in **pips** (1e-6; `3000` = 0.30%, the v4 unit) ·
`sigmaE12` = σ × 1e12 where σ is the stock's relative std-dev per √second (0.85 bps/√s = 8.5e-5 → `85_000_000`).
Defaults when zero: `feeMax = 20_000` (2%), `maxAge = 900` s. Ceilings: `feeMax ≤ 100_000` (10%), `sigmaE12 ≤ 1e10`.

`feedId` is opaque; the tests use `keccak256("NVDA/USD")`. CRE and the hook just have to agree.

Oracle behaviour: a report is **ignored (event `ReportIgnored`, no revert)** when `priceE8 == 0`, `asOf > now + 60 s`, or
`asOf ≤ stored asOf` (replay / out-of-order). Ignoring rather than reverting stops the forwarder retrying forever a report that
can never be accepted. `ReceiverTemplate` additionally enforces the forwarder address and (optionally) workflow id / author / name.

## 3. Storage layout and fixed-point math

### 3.1 Storage (from `forge inspect … storage-layout`)

`RefPriceOracle`

| Slot | Content |
|---|---|
| 0 | `_owner` (Ownable) |
| 1 | `s_forwarderAddress` |
| 2 | `s_expectedAuthor` (20 B) + `s_expectedWorkflowName` (10 B) |
| 3 | `s_expectedWorkflowId` |
| 4 | `mapping(feedId ⇒ Feed)`; `Feed` = `uint64 priceE8 · uint64 asOf · bool sessionOpen` = **one slot** (17 B) |

`DeviationFeeHook` (+ immutables `poolManager`, `oracle`)

| Slot | Content |
|---|---|
| 0 | `_owner` |
| 1 | `mapping(PoolId ⇒ PoolConfig)` — 2 slots per pool: **A** `feedId` (32 B); **B** `f0 u24 · feeMax u24 · maxAge u32 · sigmaE12 u64 · exp10 u8 · stockIsCurrency0 bool · configured bool · active bool` = 22 B |

A swap therefore costs: 1 oracle slot + 2 config slots + the pool's `slot0` (read through `extsload`).

### 3.2 sqrtPriceX96 → USD/stock (E8)

Pool price in raw units is `p_raw = (sqrtP / 2^96)^2 = token1_raw / token0_raw`. Let `sd`, `qd` be the stock/quote decimals and
`exp10 = 8 + sd − qd` (computed once at `configurePool` from `decimals()`; reverts if `< 0` or `> 30`).

```
pX128 = sqrtP² / 2^64                              (= p_raw · 2^128, FullMath.mulDiv, no truncation before the divide)
stock = currency0 (token1 = quote):  USD/stock = p_raw · 10^(sd−qd)   →  pE8 = pX128 · 10^exp10 / 2^128
stock = currency1 (token0 = quote):  USD/stock = 10^(sd−qd) / p_raw   →  pE8 = 10^exp10 · 2^128 / pX128
```

### 3.3 Overflow analysis

* Domain guard: `0 < sqrtP < 2^128`. Otherwise the function returns `ok=false` and the hook **fails open** (never reverts a swap).
  `2^128` corresponds to a price of 2^64 raw units — about 10^19, far beyond any stock/stable pair.
* `sqrtP² < 2^256` and `/2^64` ⇒ `pX128 < 2^192`.
* stock0: `pX128 · 10^exp10` is up to `2^192 · 2^100` — `mulDiv` uses a 512-bit intermediate; the result `< 2^164`. No overflow.
* stock1: guard `pX128 ≥ 2^64` first; then `10^exp10 · 2^128 / pX128 < 2^100 · 2^128 / 2^64 = 2^164`. No overflow, no division by zero.
* `sigmaE12 · √age ≤ 2^64 · 2^16` (age ≤ `maxAge ≤ 2^32`, √ ≤ 2^16). Fits uint256 trivially.
* Precision: `pE8` carries ~1e-9 relative error from the sqrt/floor (fuzz-tested to < 1e-6 round trip over $0.01–$100k, both orientations, 18/18 and 18/6 decimals).

### 3.4 Rounding — every choice is in the user's favour

| Step | Rounding | Effect |
|---|---|---|
| `pE8` | floor | negligible (1e-9) |
| `dPips = diff·1e6 / r` | floor | smaller deviation ⇒ lower fee |
| `√age` | **ceil** (`Math.sqrt(age, Ceil)`) | larger noise ⇒ lower fee |
| `noise = σ·√age / 1e6` | **ceil** (`ceilDiv`) | larger noise ⇒ lower fee |
| `d_eff / 2` | floor | lower fee |
| `fee = max(f0, …)`, `min(…, feeMax)` | exact | `f0 ≤ fee ≤ feeMax` always |

Properties fuzz-tested: `f0 ≤ fee ≤ feeMax`; non-arb ⇒ `fee == f0`; `fee ≤ max(f0, d/2)`; monotone non-decreasing in `d`.

## 4. Direction: is this swap an arbitrage?

`beforeSwap` sees only `SwapParams.zeroForOne` (the sign of `amountSpecified` — exact-in vs exact-out — does not matter; direction is fixed by `zeroForOne`).

`zeroForOne = true` ⇒ currency0 flows **into** the pool, currency1 out.

```
sellStock = (zeroForOne == stockIsCurrency0)        // the stock currency is the input
```

| pool vs ref | arbitrage trade | `arb = ` |
|---|---|---|
| `p_pool > r` (stock too dear in pool) | sell stock **into** the pool (lowers USD price of stock) | `sellStock == true` |
| `p_pool < r` (stock too cheap) | buy stock **from** the pool | `sellStock == false` |

i.e. `arb = (p != r) && ((p > r) == sellStock)`. Orientation × decimals are covered by tests (stock as currency0 / currency1, 18/18 and 18/6).

## 5. v4 specifics

* **Flags:** `BEFORE_INITIALIZE (1<<13) | BEFORE_SWAP (1<<7) = 0x2080`. The hook address's low 14 bits must equal exactly `0x2080`.
  `MinimalBaseHook`'s constructor calls `Hooks.validateHookPermissions`, so a wrongly-addressed deployment reverts (tested).
* **Address mining:** CREATE2 salt search; expected ≈ 2^14 = 16k tries. Use `v4-periphery/test/shared/HookMiner.sol` with the
  CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` inside a `forge script` (no script is included; see §9).
  `test_hookMinerFindsValidAddress` runs the same search loop (same 160 444-iteration cap) and deploys via CREATE2 successfully. Unit tests use `deployCodeTo` instead.
* **Dynamic fee:** pools must be created with `key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000)`. The *base* fee is therefore not in the key,
  which is why `f0` lives in the hook's per-pool config (pips). `beforeSwap` returns `fee | OVERRIDE_FEE_FLAG (0x400000)`;
  the override applies to **that swap only** (not written to `slot0`). Protocol fee, if any, is charged on top by the PoolManager.
* **Registry / `beforeInitialize`:** `PoolManager.initialize` carries no per-pool hook data, so the owner **pre-registers** the exact `PoolKey`
  (`configurePool`), and `beforeInitialize` only lets registered keys through. Result: an unregistered pool can never be created with this hook,
  and `f0 / feeMax / maxAge / feedId / stockIsCurrency0` are immutable after that (only `sigmaE12` is adjustable, bounded).
* `beforeSwap` is `view` (the override is a return value); no `afterSwap`, no delta returns, so the hook never holds or moves funds.
* `MinimalBaseHook` exists because current `v4-periphery` HEAD has no `BaseHook` (it moved to OpenZeppelin's uniswap-hooks).

## 6. Gas

Measured in a test (`test_e2e_gas_beforeSwap`): **≈ 7.4k gas** for `beforeSwap` including the oracle call and `extsload`.
Forge runs the whole test in one transaction, so slots touched earlier are already warm; treat 7.4k as the warm figure.
Cold estimate (not measured): + oracle account 2.6k + 3 SLOADs 6.3k (+ `slot0` 2.1k, but that slot is read again by the swap itself,
so it is a wash) ⇒ roughly **15–20k** on a first-in-tx swap. Levers if needed: drop `maxAge`/`feeMax` into the oracle slot, or
cache the oracle price in transient storage per tx (not implemented).

## 7. Attack surface

| Threat | Impact | Mitigation in code | Residual |
|---|---|---|---|
| **Oracle manipulation / compromised CRE workflow or forwarder** | wrong `r` ⇒ arb-direction swaps overcharged | surcharge ≤ `min(d/2, feeMax)` (default 2%, hard ceiling 10%); user still executes ≥ fair vs the *claimed* `r`; non-arb direction always `f0`; no custody, no revert path | griefing bounded by `feeMax`. Set `expectedAuthor/WorkflowId` on the oracle. |
| **Stale / missing price, API outage** | would over- or under-charge | fail-open to `f0` after `maxAge`, on `sessionOpen=false`, on `priceE8=0` | LPs lose the surcharge during outages (by design: never punish users for our downtime) |
| **Report replay / reordering** | roll price back | monotonic `asOf`; future-dated (`> now+60 s`) ignored | none known |
| **Chunked swaps / path dependence** | fee uses *pre-swap* deviation, so an arb can split into many small swaps in one tx; each later swap sees a smaller `d` and a lower fee | — | recovery falls from ≈75% to ≈50% of arb loss for large `d` (analysis only, **not simulated in tests**). Future fix: per-tx anchor in transient storage, capped by `d_now`. |
| **Sandwiching / JIT** | attacker pushes price to change a victim's fee | surcharge never exceeds `d/2`, so an arb-direction victim still beats fair; an attacker front-running toward the reference *reduces* `d` and pays the surcharge itself | no change to sandwich economics for non-arb flow |
| **Owner powers** | owner registers pools, sets σ | `f0`, `feeMax`, `maxAge`, `feedId` immutable per pool; σ bounded (`≤ 1e10`); `HARD_FEE_MAX` 10%; hook holds no funds | owner of the **oracle** can change the forwarder (`ReceiverTemplate`) — use a multisig / renounce after setup. Owner can register a pool pointing at a wrong `feedId`. |
| **Pool price outside `(0, 2^128)` / extreme ticks** | math overflow | domain guard ⇒ fail-open, never reverts | none |
| **Decimals misconfig** | wrong price scale ⇒ huge fake `d` | `exp10` derived from `decimals()` at registration; fee still ≤ `feeMax` | token with a lying `decimals()` |
| **Reentrancy** | — | hook is read-only apart from `beforeInitialize` state flag; only callable by PoolManager | none |
| **Pool price is not a "true" price** | a thin pool can be pushed away from `r` for free by anyone | non-arb-direction trades pay only `f0`; the hook does not claim to stop this | inherent AMM property |

## 8. Decisions that differ from / extend the brief

1. **Fail-open on stale** (→ `f0`), not "max fee": a max-fee fallback would overcharge normal users during outages.
2. **Owner pre-registration** instead of config "set at `beforeInitialize`": v4 passes no hook data to `initialize`, so config must pre-exist.
3. **`f0` in pips inside the hook config** because a dynamic-fee `PoolKey.fee` is the flag, not a fee.
4. **σ units**: `sigmaE12 = σ·1e12`, σ = relative std-dev per √s (the brief said "bps per √s scaled"; this is the unambiguous form).
5. **OpenZeppelin pinned to v5.1.0**: OZ `master` now requires `solc ^0.8.31`; v4-core needs 0.8.26.
6. **`ReceiverTemplate` from `chainlink-evm/contracts/src/v0.8/automation-cre/`** (the copy in the installed `chainlink-evm`), imported unmodified via a
   remapping `@openzeppelin/contracts@5.1.0/`. If the CRE docs' template (cre-templates repo) differs, only the import path changes: `onReport` / `_processReport` are the same.

## 9. Test coverage and honest limits

Covered (44 tests, all green; mutating the direction check or dropping the noise term makes tests fail):
arb direction (pool above / below ref), non-arb direction, inside deadband (`d ≤ 2·f0`), noise term (exact value), session closed, stale (and
price ageing out over time), no price, clamp to `feeMax`, unregistered pool cannot initialize, owner-only/validation of `configurePool`/`setSigma`,
hook-address/flag validation, orientation × decimals (18/18, 18/6, both sides), end-to-end swap through a real `PoolManager` whose `Swap` event fee equals `quoteFee`,
oracle (forwarder-only, store/emit, replay/future/zero ignored, ERC-165), math fuzz (round trip, bounds, monotonicity, never-above-`d/2`).

NOT covered / not done:
* Chainlink's real `KeystoneForwarder`/DON signatures are not exercised by the tests (they use a local `MockForwarder`). On Arc Testnet the oracle trusts the production KeystoneForwarder, but no CRE workflow is deployed on the network yet, so no report has arrived through it.
* Fork tests inside Foundry (Arc's USDC uses chain precompiles Foundry cannot simulate; the deploy was rehearsed on an anvil fork with a stand-in USDC, then run on Arc Testnet by `server/scripts/deploy-arc.sh`).
* Multi-swap / chunking simulations and any economic backtest (the parent analysis did that off-chain, statically).
* Gas figure is warm-ish; the cold number is an estimate.
* No audit; no formal verification; `HookMiner` comes from `v4-periphery/test/shared`, not a released package.

## 10. Build & run

```
cd contracts
forge build
forge test            # 44 tests
forge test --match-contract DeviationFeeHookTest -vv     # includes the gas log
```
Dependencies live in `lib/` (installed with `forge install --no-git`): `v4-core`, `v4-periphery`, `chainlink-evm`, `forge-std`, `openzeppelin-contracts@v5.1.0`.
Remappings are in `remappings.txt`; compiler `solc 0.8.26`, `evm_version = cancun`, `via_ir = true`.
