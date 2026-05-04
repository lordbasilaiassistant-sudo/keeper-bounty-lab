# Keeper Bounty Lab — 5 keeper-bounty patterns + floor oracle on Base

Five different "automate-it-and-earn" contracts on **Base mainnet**, each one a pure permissionless keeper market. Anyone can register a job, anyone can execute it once due, the executor takes a bounty, the protocol takes a fee. No whitelist, no admin upgrades, no off-chain coordination.

Plus a `ManualFloorOracle` that lets the NFT contract function without depending on a third-party oracle.

## Live on Base mainnet (chainId 8453)

| Contract | Purpose | Address |
|---|---|---|
| ManualFloorOracle | owner-pushed NFT floor prices | [`0xBD073CC2c610EeB0aA49FeAD7eee2ED980cbd70E`](https://basescan.org/address/0xBD073CC2c610EeB0aA49FeAD7eee2ED980cbd70E) |
| VestingAutoClaim | release vested tokens at unlock | [`0x07EC89a177c7bcBB5205A8fF274f751f1C37fe4E`](https://basescan.org/address/0x07EC89a177c7bcBB5205A8fF274f751f1C37fe4E) |
| EnsAutoRenewer | pre-fund multi-year ENS renewals | [`0x4B0486C004b34Bfe6D632d5dD329c988eDDB1aE7`](https://basescan.org/address/0x4B0486C004b34Bfe6D632d5dD329c988eDDB1aE7) |
| DaoProposalExecutor | execute timelocked DAO proposals | [`0xbC91411Ec61B9352A6CdF3a6722E89e5FB279F2E`](https://basescan.org/address/0xbC91411Ec61B9352A6CdF3a6722E89e5FB279F2E) |
| NftCancelOnFloorDrop | cancel NFT listing on floor crash | [`0xFF15F745736cfA35cf00691397584709C3Fd34b1`](https://basescan.org/address/0xFF15F745736cfA35cf00691397584709C3Fd34b1) |
| CurveGraduationPusher | finalize bonding-curve graduations | [`0x7C10082fa45c530785a123B8506623e9d3C4Ad30`](https://basescan.org/address/0x7C10082fa45c530785a123B8506623e9d3C4Ad30) |

All 6 verified on Basescan.
Treasury: `0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`.
Protocol fee: 5% (immutable, hard-cap 10%).
Total mainnet deploy spend: 0.000131 ETH.
129 tests passing.

## Builder shape

Each contract follows the same pattern:
1. User calls `register(...)` and prepays a bounty.
2. Anyone calls `execute(id)` once the trigger condition is met.
3. Executor receives the bounty; treasury gets a small fee.
4. User can `cancel(id)` before execution and recover funds.

That's it. No off-chain infra to run, no per-launchpad adapters to maintain.

## Honest demand reads

We had each builder rate their own contract. Read `LAB_REPORT.md` for the unfiltered view (we ship it because it's there, not because all 6 are guaranteed winners).

## Build / test

```bash
forge install
forge build
forge test -vv
```

## Part of the THRYX onchain surface

Companion deployments:
- DeadManSwitch: https://github.com/lordbasilaiassistant-sudo/deadman-switch
- Onchain primitives lab: https://github.com/lordbasilaiassistant-sudo/onchain-primitives-lab

Project home: https://thryx.fun

## Use these contracts

Each address above is clickable straight into Basescan. To call them from your own code:

```solidity
// example: register a vesting auto-claim job
IVestingAutoClaim(0x07EC89a177c7bcBB5205A8fF274f751f1C37fe4E).register{value: bounty}(...);
```

ABIs ship in `out/<Contract>.sol/<Contract>.json` after `forge build`. Treasury sink: `0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`. Project home with the full inventory: https://thryx.fun

## Built on

- [**Base**](https://base.org) — the Ethereum L2 this is deployed on (open-source, OP Stack).
- [**Foundry**](https://getfoundry.sh) — Solidity toolchain for build, test, and deploy.
- [**Basescan**](https://basescan.org) — block explorer used for verification.
- [**Claude Code**](https://claude.com/claude-code) by Anthropic — primary engineering assistant for the THRYX surface.

## Support this work

If any of these patterns saved you a deployment, the easiest way to fund continued maintenance is direct on-chain:

- **Treasury address (Base / Ethereum / any EVM):** `0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`
- **Etherscan:** https://etherscan.io/address/0x7a3E312Ec6e20a9F62fE2405938EB9060312E334
- **Basescan:** https://basescan.org/address/0x7a3E312Ec6e20a9F62fE2405938EB9060312E334

The repo's `Sponsor` button (top of page) wires to the same address via `.github/FUNDING.yml`.

## License

MIT.
