# DaoProposalExecutor

Keeper-bounty registry for executing passed-but-stalled DAO proposals. Anyone
(proposer, supporter, opportunist) pre-funds a bounty for executing a specific
governance call. The bounty grows linearly with time so long-stalled proposals
become increasingly attractive to keepers.

## Mechanism

1. `register(dao, executeSelector, executeCalldata, bountyBase, multiplierBps, bountyMaxMultiplier, daysToMax)` — escrows ETH for one job.
2. `currentBounty(jobId)` — view, returns the bounty payable to a keeper at the current timestamp.
3. `execute(jobId)` — anyone can call. Forwards `executeCalldata` to `dao`. If the DAO call succeeds, the keeper is paid the current bounty, the treasury is paid the protocol fee, and any leftover escrow is refunded to the job owner.
4. `cancel(jobId)` — owner-only refund, anytime before `execute()`.

## Bounty Formula

```
elapsedDays = (now - registeredAt) / 1 days        // floor
growthBps   = multiplierBps * elapsedDays / daysToMax
multiplier  = min(BPS + growthBps, bountyMaxMultiplier)
bounty(t)   = bountyBase * multiplier / BPS
```

`bountyMaxMultiplier` is in bps where 10_000 = 1x. Lower bound 1x (no negative
ramp). Upper bound is the natural uint16 ceiling (6.5535x), which keeps the
escrow ceiling sane.

Example with `bountyBase=1 ETH`, `multiplierBps=10_000` (+100% per `daysToMax`
window), `daysToMax=10`, `bountyMaxMultiplier=25_000` (cap = 2.5x):

| elapsed | bounty |
|--------:|-------:|
|   0 d   |  1.00 ETH |
|   5 d   |  1.50 ETH |
|  10 d   |  2.00 ETH |
|  15 d   |  2.50 ETH (cap) |
| 365 d   |  2.50 ETH (still cap) |

## Deposit Sizing

`register()` requires `msg.value >= maxBounty + maxFeeOnMaxBounty` where
`maxBounty = bountyBase * bountyMaxMultiplier / BPS` and
`maxFeeOnMaxBounty = maxBounty * maxFeeBps / BPS`. This guarantees the contract
is always solvent regardless of when the keeper claims, even if the treasury
later raises `feeBps` up to `maxFeeBps`. Unused escrow refunds to the owner on
`execute()`.

## Treasury Fee

Fee is `feeBps` of the **current** bounty (not the base), capped by the
immutable `maxFeeBps`. Fee is paid out of escrow to the treasury as part of
`execute()`; no separate `claim()` step.

## Reentrancy Posture

No `ReentrancyGuard` import. Strict checks-effects-interactions:

1. **Checks**: status is `Active`, escrow covers `bounty + fee`.
2. **Effects**: `status = Executed`, `escrow = 0`. Snapshot all values into
   memory.
3. **Interactions**: `dao.call(executeCalldata)` first — if it reverts the
   whole tx unwinds and no funds move. Then `_send(keeper, bounty)`,
   `_send(treasury, fee)`, `_send(owner, refund)`.

If the DAO calls back into `execute(jobId)` during the external call, status
is already `Executed` so the reentry hits `BadStatus`. Test
`test_Execute_ReentryGuardedByCEI` proves this with a `ReentrantDao` mock.

## Gas Snapshot

```
Deployment: 2,096,212 gas (10,201 bytes runtime)

Function           Min       Avg       Median    Max
register           25,020    206,359   279,171   279,171   (cold path ~279k incl. 1 SSTORE per word of calldata)
execute            26,179    111,099   139,316   155,182   (success ~155k incl. one external call + 3 transfers)
currentBounty       7,148     10,738    11,302    11,508
cancel             26,014     34,093    34,710    40,941
setFee             23,890     25,345    23,940    28,206
setTreasury        23,943     26,317    26,317    28,692
```

Storage of `executeCalldata` dominates `register()` cost — a typical OZ
Governor `execute(targets, values, calldatas, descriptionHash)` will be longer
and push the cost above 300k. Acceptable for a one-shot register.

`execute()` is roughly DAO-call-cost + 110k for our overhead. On Base mainnet
at ~0.05 gwei this is ~$0.0005 worst-case for our slice — keepers care almost
entirely about the DAO call cost on top.

## Complexity / Audit Surface

- ~270 LOC of Solidity, no external dependencies (only forge-std for tests).
- Bounded loops: none. All state ops are O(1) per call.
- Only payable function is `register()`. Treasury cannot drain escrow — it can
  only adjust `feeBps` up to `maxFeeBps`, and `escrow` is bounded by what the
  owner deposited.
- No upgrade path. Re-deploy if mechanism changes.

## Governance Compatibility

Generic across frameworks because we accept `(daoAddress, executeSelector,
executeCalldata)` — the contract knows nothing about proposal IDs, vote
windows, or quorum.

| Framework | Compatible? | Notes |
|---|---|---|
| **OZ Governor** | yes | `execute(address[],uint256[],bytes[],bytes32)` — pre-encode the args at register time |
| **Compound Bravo** | yes | `execute(uint256 proposalId)` — simplest case, exactly the shape our test mocks |
| **Aragon OSx** | yes (one job per action) | Aragon proposals can have multiple actions; encode each `IDAO.execute` separately |
| **Snapshot** (off-chain) | no | Snapshot has no on-chain `execute` — by design, nothing to keep |
| **Tally / Boardroom** | n/a | UIs over OZ/Bravo, not their own execution layer |
| **Safe (Gnosis) multisig** | partial | The `execTransaction` call needs threshold signatures already aggregated; our keeper can submit a pre-signed batch but cannot collect signatures |
| **Realms / SPL governance** (Solana) | no | EVM-only |

### Caveats

1. **Proposals with a queueing step**: OZ Governor with a Timelock has a
   separate `queue()` step before `execute()`. This contract only handles
   `execute()`. A second job (or a contract extension) could handle `queue()`,
   but linking them is the proposer's responsibility.
2. **Proposals with dynamic state**: if the DAO call requires fresh signatures
   or oracle data inside calldata, the registered calldata will be stale.
   Suitable only for proposals where the call is fully determined at proposal
   time (the common case).
3. **Hostile DAO callbacks**: by design `dao.call()` runs arbitrary code. CEI
   guards us against direct re-entry on the same jobId, but a malicious DAO
   could re-enter `register()` or read public view fns. None of those grant
   value extraction beyond what was already escrowed for that jobId.
4. **Failed DAO calls leave escrow stuck**: status flips to `Executed` before
   the external call (CEI), so a reverting `dao.call` makes the whole tx
   revert and status stays `Active`. (Test `test_Execute_RevertsIfDaoCallReverts`
   proves no funds move and status is unchanged on revert.) Owner can then
   `cancel()` to recover.

## Honest Demand Notes

**Does this solve a real problem?**

Real-world DAO execution lag exists but is rare and concentrated in a few
ecosystems:

- **OZ Governor + Timelock** is the dominant pattern. Once a proposal passes
  and is queued, a 2-day timelock fires and *anyone* can call `execute()`
  permissionlessly with no bounty needed. Foundations and dev shops already
  babysit their own proposals — there's no execution gap to fill for healthy
  DAOs.
- **Compound Bravo** has the same dynamic. Compound's own multisig executes
  proposals within minutes of the timelock expiring.
- **Long-tail DAOs** (post-launch tokens with no active dev team) are where
  proposals do stall. But these are exactly the DAOs whose proposers have no
  treasury to fund a bounty, and whose proposals usually aren't worth executing
  anyway.
- **MEV-relevant proposals** (parameter tweaks, treasury moves) are already
  front-run by sophisticated keepers without a bounty — they extract value
  directly from the proposal effect.

The bounty-grows-over-time mechanic is clean math but solves a problem most
target users don't have. The honest market is probably DAO tooling vendors
(Tally, Boardroom) bundling this as a free service to their customers, not a
standalone protocol.

**Where this could matter**: cross-chain governance bridges where a vote
passes on chain A but the execution call on chain B requires a relayer to
submit a proof. There the relayer cost is real, the timing is uncertain, and
a bounty grows-over-time matches the market. But that's a different contract
shape than this one (needs proof verification, not arbitrary calldata).

Recommend deferring mainnet deploy unless we can find one paying user with a
real stalled proposal.
