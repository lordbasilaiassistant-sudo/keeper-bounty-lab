# CurveGraduationPusher

Multi-user keeper-bounty contract that pushes a stalled bonding curve over its graduation threshold.

## Concept

A token creator (or any supporter) sees a curve sitting at 80–95% of graduation, momentum dead. They register a job that pre-funds:

- `ethToCommit` — ETH to spend on a final buy
- `bountyAmount` — ETH paid to whoever pulls the trigger
- `protocolFeeBps` of (commit + bounty) — paid to treasury at registration

Once the curve crosses `minProgressBps`, anyone can call `execute(jobId, minTokensOut)`. The contract:

1. Verifies the curve is not graduated and progress ≥ threshold.
2. Calls `curve.buy{value: ethToCommit}(minTokensOut)`.
3. Forwards the bought tokens to the registrant (`jobs.owner` — the supporter benefits).
4. Pays the bounty to the keeper (`msg.sender`).

The registrant gets value either way: graduation (LP unlock, listing, hype) plus the tokens from the buy. The keeper earns a clean ETH bounty for paying gas and watching mempools.

## Gas snapshot (forge --gas-report, 31 tests)

| Function              | Min     | Median  | Max     |
|-----------------------|--------:|--------:|--------:|
| `register`            | 22,700  | 247,474 | 247,486 |
| `execute`             | 26,438  | 128,062 | 156,795 |
| `cancel`              | 26,036  |  36,763 |  44,866 |
| `currentProgressBps`  | 13,495  |  13,703 |  13,911 |
| `isExecutable`        | 13,025  |  19,594 |  19,594 |
| Deployment            |         |         | 1,883,788 |

`execute` median 128k is dominated by the external `curve.buy` plus an ERC20 `transfer` — the pusher itself adds roughly 35–40k overhead.

## Complexity

- One storage struct per job, plus two index arrays (by owner, by curve) for off-keeper discovery.
- No external libs, no inheritance, no `ReentrancyGuard`. Re-entrancy is handled by checks-effects-interactions: `j.executed = true` is written before any value-bearing external call.
- All errors are custom (no string reasons), all bps math is `uint256` with a `BPS_DENOMINATOR` constant.
- Treasury is rotatable; protocol fee is mutable up to an immutable hard cap (10%, default 5%).

## Applicability to real launchpads

| Platform   | Compatibility | Notes |
|------------|--------------|-------|
| **THRYX**  | High (with adapter) | THRYX is itself a curve launchpad. The Diamond exposes buy/sell on the LaunchpadFacet. Our `IBondingCurve` is a *generic* interface; a thin adapter exposing `reserve()`, `graduationThreshold()`, `graduated()`, `token()`, and a `buy(minOut)` view from the existing facet selectors would slot in. THRYX makes more sense as the curve being *pushed* than as the platform deploying this contract. |
| **pump.fun** (Solana) | None | Different VM. A Base-deployed pusher cannot drive a Solana curve. Out of scope. |
| **pump.fun on Base** (forks like `pump.lol`, `Heaven`, `flaunch`) | Medium | Most Base-side pump.fun forks expose `buy(uint256 amountOut)` style functions, but the `reserve / graduationThreshold` pattern varies. A few use virtual reserves rather than literal ETH balance — for those, the progress math here is wrong and would need a custom adapter. |
| **clanker** (Base) | Low | Clanker doesn't use a bonding-curve graduation model — it deploys directly to a Uniswap V4 pool with anti-sniper fees. There is no "graduation" event to push toward. |
| **Doppler V4** (multicurve) | None for this contract | Doppler V4 graduation is time-based (Dutch auction), not reserve-threshold. Different keeper pattern entirely. |

The honest bottom line: this contract is a *pump.fun-on-Base-forks* product, not a clanker product, and only marginally a THRYX product (THRYX would be a dependency, not a customer).

## Demand notes

**Real**:
- Token creators rage when their curve sits at 92% with no buyers. A bounty mechanism converts that frustration into action without them needing to babysit.
- Bigger supporters (whales who already hold the bag) have aligned incentive to fund the push — they get the tokens AND the graduation upside.
- Keepers already exist on Base for liquidations, MEV, etc. Adding "watch curve X cross 80%" to a keeper's loop is trivial.

**Soft / suspect**:
- A curve stalled at 90% might be stalled because the *price is wrong*, not because nobody noticed. Pushing it to graduation could just dump the registrant's bought tokens at the LP listing.
- Most keeper-bounty markets on Base today are tiny. We'd be building infrastructure for a market that needs proof of demand first — at minimum, the deploy should ship with one curve and one registered job from a friendly supporter to validate.
- Competing solution: the curve creator can just buy themselves through their own wallet. The pitch is "you don't have to be online" + "anyone can fund the bounty, not just the creator" — fine, but not enormous.

## Edge cases handled

1. **Slippage**: `minTokensOut` is keeper-supplied. If the curve reverts due to a price move, the entire `execute` tx reverts — including the pusher's `executed = true` flag write. The job stays open and another keeper can retry. Tested in `test_Execute_SlippageRevertsAndJobIsRetryable`.
2. **Non-standard `buy` return values**: some curves mint gross but report net. The pusher forwards the lesser of `tokensOut` and the actual on-contract balance, so it never tries to send more than it holds. Remainder stays parked. Tested in `test_Execute_HandlesUnderReportedTokens`.
3. **`buy` returns zero**: explicit `BuyReturnedZero` revert. Prevents a silent burn of `ethToCommit`.
4. **Already graduated**: explicit revert before spending ETH.
5. **Below progress threshold**: explicit `ProgressTooLow` revert. Compares as `reserve * BPS >= threshold * minBps` to avoid division.
6. **Re-entrancy**: state changes finalised before `curve.buy`; bounty transfer is the last step. CEI by hand, no `nonReentrant` modifier needed.
7. **Treasury / keeper rejecting ETH**: bubble up as `TransferFailed`. Tested in `test_Execute_RevertsWhenKeeperRejectsBounty`.
8. **Cancel after execute / double cancel / execute after cancel**: all guarded by `executed || cancelled` check, single `AlreadyResolved` error.

## Edge cases NOT handled (deliberate scope cuts)

- **Token tax / rebasing tokens**: if the curve's token has a transfer tax, the registrant receives less than expected. We don't try to account for this — caveat emptor on the curve choice.
- **Multi-buy laddering**: `execute` does one buy. If `ethToCommit` is too small to actually push graduation, the job marks executed but the curve stays un-graduated. Registrants should size `ethToCommit` based on `graduationThreshold - reserve` at the moment of registration.
- **Refunding the protocol fee on cancel**: the fee is paid at registration and not refunded on cancel. Documented behaviour.
- **Front-running by the keeper**: a keeper can sandwich themselves around the `curve.buy` to extract MEV. The bounty is structured so a normal keeper has no need to, but a sophisticated one could. This is the same risk anyone faces interacting with a permissionless DEX/curve.

## Constructor

```solidity
new CurveGraduationPusher(
    0x7a3E312Ec6e20a9F62fE2405938EB9060312E334, // treasury
    500,                                          // 5% initial fee
    1_000                                         // 10% hard cap
);
```

## Interface contract sketch (caller-side)

```solidity
uint256 commit  = 1 ether;
uint256 bounty  = 0.05 ether;
uint16  minBps  = 8_000; // 80%
uint256 fee     = (commit + bounty) * 500 / 10_000;
pusher.register{ value: commit + bounty + fee }(curveAddr, commit, minBps, bounty);

// Off-chain keeper loop:
if (pusher.isExecutable(jobId)) {
    uint256 minOut = quoteFromCurve(curveAddr, commit) * 99 / 100; // 1% slippage
    pusher.execute(jobId, minOut);
}
```
