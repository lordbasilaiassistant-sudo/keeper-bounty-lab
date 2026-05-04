# NftCancelOnFloorDrop

Keeper-bounty pattern #4. NFT seller pre-funds a bounty + an arbitrary marketplace
cancel-call; any keeper can trigger that call once a trusted floor-price oracle
reports the collection's floor below the seller's threshold. Bounty pays the keeper.

## Mechanism

1. **Seller** calls `register(marketplace, cancelCalldata, collection, floorThresholdWei)`
   with `msg.value = bounty + 5% protocol fee`. Fee is auto-routed to treasury.
2. **Keeper** monitors the trusted oracle off-chain (or just calls `isTriggerable(id)`).
   When the oracle floor drops below threshold, keeper calls `execute(id)`.
3. Contract reads oracle, rejects if stale (>1h) or floor still above threshold,
   then calls `marketplace.call(cancelCalldata)`. Bounty (full remaining job balance
   minus the fee taken at registration) goes to `msg.sender`.
4. **Seller** can call `cancel(id)` at any time pre-execution to refund the bounty.

## Gas snapshot

Deployment: **1,999,199 gas** / 10,132 bytes runtime. (Comfortably under the 24 KB EIP-170
limit; ~12% of headroom used.)

| Function          | Min    | Avg    | Median | Max    |
|-------------------|--------|--------|--------|--------|
| `register`        | 23,660 | 243,670| 317,229| 317,229|
| `execute`         | 26,073 | 72,449 | 85,531 | 106,273|
| `cancel`          | 26,037 | 42,347 | 42,937 | 57,479 |
| `setFees`         | 23,858 | 25,313 | 23,908 | 28,174 |
| `setTreasury`     | 23,921 | 26,295 | 26,295 | 28,670 |
| `isTriggerable`   | 15,941 | 17,343 | 18,044 | 18,044 |
| `getJob`          | 23,643 | 23,643 | 23,643 | 23,643 |

`register` is dominated by storing the full `cancelCalldata` blob; the median ~317k
reflects a small calldata (~36 bytes for `cancelOrder(bytes32)`). Real Seaport
cancel calldata for a single order is ~280–340 bytes which would push register to
~400–500k. **Note:** at 0.05 gwei (Base) and ETH ~$3.4k, `register` ≈ $0.05–0.08
and `execute` ≈ $0.02. Cheap enough that the bounty itself dominates economics.

## Tests

15 tests, all passing. Run:

```bash
forge test --match-path test/NftCancelOnFloorDrop.t.sol \
  --skip "DaoProposalExecutor*" --skip "CurveGraduationPusher*" --skip "EnsAutoRenewer*"
```

(The `--skip` flags exclude unrelated contracts from sibling agents that don't
compile cleanly in this prototype repo. Production deploy will use this contract
in isolation.)

Coverage: register happy + 4 invalid-input branches, fee accounting, oracle stale
guard, oracle floor-above-threshold guard, happy execute, double-execute guard,
marketplace-revert behavior + retry, seller cancel + refund, non-seller can't
cancel, double-cancel guard, treasury role (set fees, rotate, reject above cap),
multi-seller / multi-job isolation, constructor input validation, treasury reject
ETH surfacing `TransferFailed`.

## Honest concerns

### 1. Oracle trust is the entire security model

**This is the load-bearing risk.** v1 ships with a single trusted address that
implements `IFloorOracle.getFloor(collection)`. If that address lies (sets floor
to 0 wei), every active job becomes triggerable and every bounty drains.

Realistic v1 oracle options, ranked:

- **Our own keeper signing prices off-chain, posting on-chain hourly.** Cheap,
  fully under our control, single-point-of-failure on us. Probably the v1 pick.
- **Chainlink Data Feeds.** No floor-price feed for any NFT collection on Base
  mainnet as of 2026-05-03. Chainlink's NFT Floor Price feeds were only ever
  shipped on Ethereum mainnet for ~6 collections (BAYC, CryptoPunks, Doodles,
  Azuki, MAYC, CloneX) and were sunset late 2024. Not a v1 path.
- **Reservoir attestation.** Reservoir signs floor prices off-chain, anyone can
  post to chain. Closest thing to industry-standard, but requires building a
  signature-verifying oracle adapter (added complexity + new trust dependency).

The README should display "trusted oracle: 0x…" prominently in any UI, with a
link to the oracle's update history. Sellers must understand this — it is not a
trustless system.

A v2 could move to "keeper submits an on-chain sale txhash + log proof" using a
ReceiptVerifier-style log-inclusion check. Implementable but several hundred
extra lines of code and adds a dependency on archive-node-style log retrieval
for the keeper. Not worth shipping at v1.

### 2. Marketplace integration realism

The contract calls `marketplace.call(cancelCalldata)` blindly — whatever the
seller registers is what fires. That works for a mock, but real marketplaces
have specific authorization models:

- **Seaport (OpenSea/Blur/etc.) `cancel(OrderComponents[])`** is gated by
  `msg.sender == offerer`. **This contract IS NOT the offerer**, so a direct
  Seaport `cancel` call from this contract reverts. The realistic flows are:
  - Use Seaport's `incrementCounter()` — but that nukes ALL the seller's open
    orders, not just the one they meant to bail on. Probably not what they want.
  - Use a Seaport zone / restricted order with a custom `validateOrder` hook
    that this contract can flip off. Adds a deployment dependency (the seller
    must list with the special zone in the first place) but is the cleanest
    path. Most existing OpenSea listings won't use it.
  - Seaport 1.6 has `bulkCancel` via signed approvals — research needed on
    whether a seller can pre-sign a cancellation that's only valid once a
    condition fires. If not, a meta-tx relayer with the seller's signature
    works but adds infrastructure off-chain.
- **Blur** is API-only for cancellations. There is no on-chain cancel that any
  third party can call. **A Blur seller cannot use this contract at all** —
  their listings are off-chain order books. Hard "no" for this market.
- **LooksRare / X2Y2** have similar `msg.sender` gating to Seaport.

**Honest pitch to a seller:** "This works if you list through a Seaport zone we
deploy alongside. We'll provide a UI that creates the zone-restricted listing
for you. It does not work for your existing OpenSea listings — those need to be
cancelled and re-listed through our flow." That's a real friction wall.

### 3. Demand notes

Who actually wants this?

- **Genuine target:** Mid-cap PFP project sellers worried about a coordinated
  rug or floor crash overnight. Threshold-cancel saves them from waking up to
  a -40% sale. Real but small audience — most of them just delist manually
  before bed.
- **Adjacent target:** Treasury-managed NFT positions (DAOs, funds) that need
  programmatic risk controls. They'd actually pay protocol fee + maintain the
  oracle themselves.
- **Not the target:** Casual collectors. They're not pre-funding bounties. The
  whole "register a job + lock ETH" UX is too much for someone who paid 0.03
  ETH for a JPEG.

**Best-case revenue model:** 5% fee on bounty. If a seller pre-funds 0.005 ETH
bounty (~$17 at $3.4k ETH) per listing, treasury earns $0.85/listing. Need
~1,200 listings to clear a single ETH ($3,400). Plausible only if we're the
default cancel-on-crash tool for one major NFT marketplace's UI. Not plausible
as a standalone dApp.

**Verdict:** technically interesting; commercial viability is bottlenecked on
either (a) a marketplace partnership that bundles us into their listing flow,
or (b) a single whale customer (DAO/fund). Neither is reachable without
peopling — which is a hard "no" per global rules. **I'd rank this 4th of 5
candidates** behind any of the other patterns whose customer is more obviously
"any wallet that does X automatically." Worth shipping the contract anyway as
infrastructure, but not the second mainnet deploy.
