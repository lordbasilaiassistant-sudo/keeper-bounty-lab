# VestingAutoClaim — keeper-bounty registry for token vesting

## What it does
A vesting recipient pre-funds an ETH bounty and registers `(vestingContract, claimSelector)` with this contract. After the cliff/conditions pass, any keeper can call `execute(jobId)` — this contract then calls `vestingContract.claimSelector()`. Tokens land in the recipient's wallet (vesting contracts read `msg.sender` or a stored beneficiary, so users register a vesting contract that pays *them*, not us). The keeper is paid the bounty minus a 5% protocol fee.

## Design notes
- **Multi-user**: jobs in `Job[]`, indexed by owner via `jobsByOwner(addr)`.
- **CEI everywhere**: `execute()` zeroes `bounty` and sets `done = true` *before* any external call. The vesting call happens before keeper/treasury payouts; if it reverts the whole tx unwinds and the job remains claimable. A `ReentrantKeeper` test confirms re-entry into `execute(id)` from the bounty payout reverts with `AlreadyDone`.
- **Fee math**: `uint256` math, `uint16` bps with the spec hard cap of **10% (1000 bps)** enforced at deploy in the constructor (`_maxFeeBps > 1_000` reverts). Treasury can lower or raise within the immutable cap, never above it.
- **Custom errors only**: `NotOwner`, `NotTreasury`, `AlreadyDone`, `ZeroValue`, `ZeroAddress`, `ZeroSelector`, `FeeAboveCap`, `VestingCallFailed`, `TransferFailed`. No revert strings.
- **Vesting failure visibility**: if the underlying claim call reverts (cliff not reached, contract paused, wrong selector), `execute()` reverts with `VestingCallFailed` and state is preserved — the keeper just wasted gas, the user keeps their bounty for a later attempt.

## Tests
22 tests, all passing. Run with:
```
forge test --match-path test/VestingAutoClaim.t.sol --skip DaoProposalExecutor --skip EnsAutoRenewer --skip NftCancelOnFloorDrop --skip CurveGraduationPusher
```
(`--skip` flags work around in-progress sibling contracts in the same `src/` tree. Drop them once those compile.)

Coverage: constructor caps, register validation, multi-user indexing, execute happy-path with fee+bounty math, execute reverts (already-done, vesting-failure, before-cliff), zero-fee path, reentry-into-execute (proves AlreadyDone guard), cancel happy/not-owner/already-done, treasury-gated setFees with cap re-check, treasury rotation, transfer-failure path on cancel, and a 256-run fuzz over bounty amount.

## Gas snapshot (`forge test --gas-report`)
| Function   | Min     | Avg     | Median  | Max     |
|-----------|---------|---------|---------|---------|
| register   | 22,168  | 140,026 | 141,376 | 144,176 |
| execute    | 26,095  | 142,206 | 146,060 | 146,060 |
| cancel     | 26,058  | 43,575  | 42,958  | 62,328  |
| setFees    | 23,835  | 26,432  | 28,139  | 28,163  |
| setTreasury| 23,955  | 25,544  | 23,965  | 28,714  |

Deployment: **1,271,497 gas** / 6,263 bytes runtime. Well under EIP-170.

`execute` median ≈ 146k gas. At 0.05 gwei (Base typical) that's ~$0.000018 per execute at $3000 ETH — keeper margin is dominated by the bounty itself, not gas.

## Honest concerns about real demand

1. **Most production vesting contracts already have a `release()` that anyone can call.** OpenZeppelin's `VestingWallet`, Sablier, Hedgey, all let any address poke the contract — tokens go to the immutable beneficiary. So keeper bots already do this for free if there's a token reward (airdrops with vesting), or not at all. We're paying keepers for a job that's already a public good for valuable claims, and that nobody bothers with for low-value claims because the gas isn't worth it. The wedge is narrow: claims big enough for someone to want them auto-pulled but small enough that no MEV bot is already watching. That's a real but thin slice — mostly individuals with team-token vesting in the $100–$10k range who don't want to babysit a calendar.

2. **Selector-only registration is dangerously generic.** We let users register *any* function selector on *any* contract. A malicious user could register `transfer(address,uint256)` on a token they don't own — but the call is from *our contract's* msg.sender, so they can't drain anyone but themselves. More realistically: someone registers a claim function that requires args, our 0-arg call reverts forever, their bounty is locked until they `cancel()`. We should probably document this prominently or add an off-chain registry of vetted vesting contracts. Adding an arbitrary-calldata version would be a footgun amplifier.

## What's hard / uncertain
- **Pricing the bounty.** Too low: nobody runs the keeper bot. Too high: user overpays vs just clicking claim themselves. There's no on-chain way to estimate the right number — we'd need an off-chain oracle of "current keeper market rate" which is itself a chicken-and-egg.
- **No partial-claim support.** If the vesting contract releases tokens linearly (not all at once), our one-shot `done = true` model means a keeper can only get paid once even though there will be many claim opportunities over the vesting period. To support linear vesting we'd need either repeatable jobs (pay-per-execute with a refill model) or `execute()` to leave the job claimable on a cooldown. Current design fits cliff-style vesting only.
- **Keeper monitoring is off-chain and unspecified.** This contract assumes someone is watching cliff dates. We provide no event subscription helper, no Chainlink Automation registration, nothing. A keeper has to write their own watcher per registered job. That's not necessarily our problem to solve, but it caps adoption to people who can spin up a bot or pay a keeper service.

---

Part of the THRYX on-chain primitives portfolio (14 contracts + 4 tokens, all Base
mainnet, all verified, all earning to treasury
`0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`). Sibling deployments and full
portfolio map: [`../LAB_REPORT.md`](../LAB_REPORT.md) · cross-portfolio index:
[`../../TokenLaunches/cross-reference-log.md`](../../TokenLaunches/cross-reference-log.md) ·
hub: <https://thryx.fun>
