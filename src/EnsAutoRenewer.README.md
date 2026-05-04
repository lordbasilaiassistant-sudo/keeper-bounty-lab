# EnsAutoRenewer

Multi-user ENS auto-renewal vault. ENS holders pre-fund a renewal job
(rent budget + keeper bounty + protocol fee). Once the name enters its
renewal window, anyone can call `execute(jobId, durationSecs)` and the
contract pushes the renewal to the configured ENS controller, paying the
keeper a flat bounty.

## Mechanism

1. **register(controller, name, expectedExpirationTs, renewalBudget, bounty)** — payable.
   `msg.value` must equal `renewalBudget + bounty + protocolFee`, where
   `protocolFee = bounty * protocolFeeBps / 10_000`. The fee is forwarded
   to the treasury immediately. The remainder is escrowed.
2. **execute(jobId, durationSecs)** — anyone. Reverts if not in window
   `[expectedExpiration - renewalWindow, expectedExpiration + 90 days]`.
   Forwards `renewalBudget` to `controller.renew{value: budget}(name, duration)`.
   On success: keeper gets `bounty`, owner gets back any controller refund
   (overpayment), job is marked settled.
3. **cancel(jobId)** — owner-only. Refunds `renewalBudget + bounty`.
   Protocol fee is non-refundable (left for treasury at register time).
4. **updateExpectation(jobId, newTs)** — owner-only. Updates the stored
   expiration timestamp. Useful if the name was renewed off-band by another
   wallet, dapp, or auto-renew service.

## Constructor params

| param | meaning |
|-------|---------|
| `_treasury` | fee recipient. Hard-set to `0x7a3E312Ec6e20a9F62fE2405938EB9060312E334` for our deploy. |
| `_protocolFeeBps` | initial protocol fee in bps (default plan: 500 = 5%). |
| `_maxProtocolFeeBps` | hard cap, immutable. Default: 1000 (10%). |
| `_renewalWindow` | seconds before expiration that execution becomes legal. Default: `90 days`. |

## ENS controller reference

Mainnet ETHRegistrarController (the canonical "v3" deployment, post Mar 2024):
**`0x253553366Da8546fC250F225fe3d25d0C782303b`**

Signature used:

```solidity
function renew(string calldata name, uint256 duration) external payable;
```

The `name` is the **unhashed label** — i.e. `"vitalik"` for `vitalik.eth`,
NOT the keccak256 of `"vitalik"` and NOT the namehash of `vitalik.eth`.

The controller is `payable` and **refunds overpayment** to `msg.sender` (us).
Our `execute()` measures `address(this).balance` before/after to compute the
spent amount, then forwards the refund to the job owner.

## Tests

30 Foundry tests. All passing. Mock controller is a simple stub that:
- accepts ETH and records calls (name, duration, value);
- can be configured to refund N wei on the next call (mimics overpayment);
- can be configured to revert on the next call (negative path).

Run:

```sh
forge test --match-path test/EnsAutoRenewer.t.sol
```

## Gas snapshot

```
EnsAutoRenewer deployment cost: 2,067,514 gas (size 10,271 bytes)

Function           min      avg     median   max     calls
register           24,060   197,564 249,680  249,680 22
execute            26,348   108,125 130,317  189,944 12
cancel             26,059   47,293  57,911   57,911  3
updateExpectation  26,363   30,851  30,851   35,339  2
setProtocolFee     23,902   25,357  23,952   28,218  3
setTreasury        23,921   26,307  26,307   28,694  2
isExecutable       4,993    7,212   7,655    7,662   6
quoteProtocolFee   3,305    3,305   3,305    3,305   2
```

`register` is dominated by the SSTOREs of the `Job` struct (string + 5 slots
+ owner-index push). `execute` averages ~108k including the cross-contract
renew call into the mock; on mainnet against the real controller it will be
considerably higher because the real controller does its own SSTOREs and
emits its own events. Budget ~250k–350k gas for a real renewal.

## Demand notes (honest)

- **There IS a real "ENS auto-renew" market.** ENS itself doesn't auto-renew;
  you renew manually or use a third-party (Gnosis Safe modules, Push
  Protocol, "ens-renewer" community contracts). Lost names from missed
  renewals happen and are public on Twitter every cycle.
- **But the bounty model has a problem:** the holder has to pre-fund the
  renewal *plus* a bounty. If they're going to deposit ETH up-front for a
  year-out event, they could just renew it themselves right now and skip the
  bounty. The pitch only lands for users who:
  - want a long-lived "set and forget" registration (multi-year name with
    one large escrow);
  - expect to be unreachable / unwilling to manage their own keys for a
    period (estate-planning crossover);
  - want a guarantee that if their personal wallet is compromised, the name
    is still defended by an independent keeper-driven path.
- **Volume is the question, not viability.** A few hundred jobs across power
  users would be a great month. A keeper bot is trivial to build (poll
  `isExecutable` every block, decode `JobRegistered` events, call `execute`
  when window opens) — so the keeper side will fill itself.

## ENS-specific quirks worth flagging

1. **Label vs string vs labelhash vs namehash.** This contract takes the
   *label string* (`"vitalik"`, no `.eth`). The current
   ETHRegistrarController accepts a string. Older controllers used the
   labelhash (bytes32). If we ever need to support a different controller
   that takes labelhash, we'd add a sibling `executeWithHash()` or change
   the storage type — not back-compat.
2. **Legacy v1 / v2 vs current controller.** ENS has had multiple
   ETHRegistrarController deployments. The hardcoded mainnet address above
   is the current one (post-March 2024 wrapped-name update). Older names
   registered through prior controllers can still be renewed through the
   current one — ENS made `renew` agnostic by routing through
   `BaseRegistrarImplementation`. So a single controller address should
   work for all .eth names.
3. **Registrant vs owner of the ENS record.** ENS distinguishes the
   *registrant* (who owns the right to renew/transfer) from the *resolver
   owner* (who can update records). `renew()` doesn't check who calls it
   — anyone can renew anyone's name as long as they pay. This is exactly
   what makes our keeper pattern work, and it means we don't need to verify
   the job's `owner` field against ENS at all.
4. **Grace period.** Expired names enter a 90-day grace period during which
   the original holder can still renew. After that, the name is released
   to public auction. Our `_inWindow()` allows execution up to
   `expectedExpiration + 90 days` to cover the grace period.
5. **Renewal cost is dynamic and price-feed driven.** ENS pricing is in USD
   (via Chainlink) and converted to ETH at call time. Our `renewalBudget`
   has to be set generously by the user OR the call will revert with
   "insufficient funds". The user should overshoot; the controller refunds
   the difference, and we forward that refund back to the user. We do NOT
   pre-quote the price — that would require a stateful read of the
   controller's price oracle that bloats our contract for marginal UX gain.
6. **Names registered through a wrapper (NameWrapper) renew the same way.**
   `renew()` on the controller still works for wrapped names — wrapping
   only changes ownership semantics, not the renewal flow.
7. **One job per (owner, name) is NOT enforced.** Owner can register the
   same name twice. After execute()/cancel(), they register a fresh job
   for the *next* renewal cycle — there is no built-in re-arm.

## Open design choice (flag for review)

`execute()` settles the job permanently. That means a name can't be
auto-renewed for *multiple* cycles by a single registration; the owner has
to register a fresh job each year. We could allow re-arming by:

- clearing `settled` after execute,
- bumping `expectedExpiration` by `durationSecs`,
- requiring the owner to top up budget+bounty between cycles.

The single-cycle design is simpler and avoids edge cases around partial
top-ups / changing fees mid-life. If demand validates, ship a
re-armable v2.

---

Part of the THRYX on-chain primitives portfolio (14 contracts + 4 tokens, all Base
mainnet, all verified, all earning to treasury
`0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`). Sibling deployments and full
portfolio map: [`../LAB_REPORT.md`](../LAB_REPORT.md) · cross-portfolio index:
[`../../TokenLaunches/cross-reference-log.md`](../../TokenLaunches/cross-reference-log.md) ·
hub: <https://thryx.fun>
