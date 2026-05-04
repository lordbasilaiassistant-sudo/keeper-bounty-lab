# Keeper Bounty Lab — Mainnet + Sepolia

5 keeper-bounty contract patterns built in parallel by 5 Opus 4.7 agents, plus a manual floor oracle to make the NFT contract actually functional. All deployed to Base mainnet (and Sepolia for prior testing).

## LIVE ON BASE MAINNET (chainId 8453)

| Contract | Address | Verified |
|---|---|---|
| ManualFloorOracle | [`0xBD073CC2c610EeB0aA49FeAD7eee2ED980cbd70E`](https://basescan.org/address/0xBD073CC2c610EeB0aA49FeAD7eee2ED980cbd70E) | ✓ |
| VestingAutoClaim | [`0x07EC89a177c7bcBB5205A8fF274f751f1C37fe4E`](https://basescan.org/address/0x07EC89a177c7bcBB5205A8fF274f751f1C37fe4E) | ✓ |
| EnsAutoRenewer | [`0x4B0486C004b34Bfe6D632d5dD329c988eDDB1aE7`](https://basescan.org/address/0x4B0486C004b34Bfe6D632d5dD329c988eDDB1aE7) | ✓ |
| DaoProposalExecutor | [`0xbC91411Ec61B9352A6CdF3a6722E89e5FB279F2E`](https://basescan.org/address/0xbC91411Ec61B9352A6CdF3a6722E89e5FB279F2E) | ✓ |
| NftCancelOnFloorDrop | [`0xFF15F745736cfA35cf00691397584709C3Fd34b1`](https://basescan.org/address/0xFF15F745736cfA35cf00691397584709C3Fd34b1) | ✓ |
| CurveGraduationPusher | [`0x7C10082fa45c530785a123B8506623e9d3C4Ad30`](https://basescan.org/address/0x7C10082fa45c530785a123B8506623e9d3C4Ad30) | ✓ |

Treasury: `0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`
All contracts: 5% protocol fee, 10% hard cap (immutable).
Total mainnet deploy cost: 0.000131 ETH.

## Sepolia (testing — same params except 60s minIntervals where applicable)

## Live on Base Sepolia (chainId 84532)

| Contract | Address | Tests | Verified |
|---|---|---|---|
| VestingAutoClaim | [`0xedDeD663b3536421acC301b57c82A2Da885DD0Af`](https://sepolia.basescan.org/address/0xedDeD663b3536421acC301b57c82A2Da885DD0Af) | 22 | ✓ |
| EnsAutoRenewer | [`0xb4a67BCCF90BBa61A76beBb06F6A8f8AcD7405b7`](https://sepolia.basescan.org/address/0xb4a67BCCF90BBa61A76beBb06F6A8f8AcD7405b7) | 30 | ✓ |
| DaoProposalExecutor | [`0x20C94df4b0d1D80a6411B29521D8cB0798843C37`](https://sepolia.basescan.org/address/0x20C94df4b0d1D80a6411B29521D8cB0798843C37) | 31 | ✓ |
| NftCancelOnFloorDrop | [`0x90Af22A204197ab62Ad9e1Acca65989432027618`](https://sepolia.basescan.org/address/0x90Af22A204197ab62Ad9e1Acca65989432027618) | 15 | ✓ |
| CurveGraduationPusher | [`0x3f445058B6484280Cb2596633311A33Dfe423A70`](https://sepolia.basescan.org/address/0x3f445058B6484280Cb2596633311A33Dfe423A70) | 31 | ✓ |

**Total: 129 tests passing, all 5 deployed + verified, $0.00053 ETH spent.**

## Builder demand reads (own honest assessment, in their words)

| Contract | Builder rating | Killer concern |
|---|---|---|
| Vesting | Narrow wedge | OZ/Sablier/Hedgey already allow permissionless `release()` — bots already do this for valuable claims |
| ENS | "single-digit-to-low-hundreds jobs/mo" | Frontrunnable — anyone can renew anyone's name, griefer keeps keeper from earning |
| DAO | **"Don't pick this for mainnet"** | Healthy DAOs already have permissionless `execute()`; stalled DAOs have no treasury to fund bounties |
| NFT | Self-rated 4/5 | Seaport gates `cancel()` by `msg.sender == offerer` — cannot cancel existing OpenSea listings |
| Curve | Compatibility narrower than it looks | Per-launchpad adapter needed; pump.fun-on-Base forks use virtual reserves; clanker has no graduation event |

## Gas comparison

| Contract | Deploy | register | execute | cancel |
|---|---|---|---|---|
| Vesting | 1.27M | 141k | 146k | 43k |
| ENS | 2.07M | 197k | 108k (mock) / ~300k (real) | 47k |
| DAO | 2.10M | 279k | 155k overhead | 41k |
| NFT | 2.00M | 317k | 85k | 43k |
| Curve | 1.88M | 247k | 128k–156k | 36k |

## Synthesis: which one deserves mainnet

**Don't pick:**
- **DAO** — its own builder said no. The buyer doesn't exist.
- **NFT** — marketplace integration wall is a hard no without re-listing flow. Partnership-bottlenecked = peopling.

**Borderline:**
- **Vesting** — sticky but the wedge is too narrow. Most users have other paths.

**Real candidates:**
- **ENS** — cleanest implementation, zero oracle dep, well-defined target user. Frontrunning grief is real but recoverable (owner can `cancel()`). Best fit for "no peopling, no infra, just earn." But the "why pre-fund instead of just renew now" question is genuine — needs a sharper pitch (estate planning, wallet-compromise hedge, multi-year forget-it).
- **Curve** — emotional buyer (project creators want their tokens to graduate), THRYX-adjacent so distribution exists. But every launchpad needs its own adapter and the thesis ("dead curves are stalled because nobody noticed") might just be wrong (they're stalled because the price is wrong).

**My recommendation:**

**Don't ship a second mainnet contract right now.** The DeadManSwitch is sitting there with zero discovery, earning zero. The bottleneck isn't "more contracts" — it's distribution for the one we already have. Adding more contracts dilutes attention without solving the demand-side problem.

If we *do* ship one, **ENS** is the cleanest pick because:
- Zero external dependencies (no oracle, no marketplace API, no per-launchpad adapter)
- Target user has a clear name (ENS holder)
- Distribution channel exists (ENS aggregators, dashboards, awesome-lists)
- Pitch can be sharpened toward the right buyer (multi-year/estate)

**Actually higher-EV move:** Build a single-page static frontend for DeadManSwitch (no signup, no backend, just a wallet connect + form). Hosting on GitHub Pages = $0/mo. That solves the discovery problem for the contract that's *already* mainnet. If DeadManSwitch gets any traction, we have signal that this category has a market — then ship ENS as the second contract.

## See also — sibling deployments (all Base mainnet, all verified)

The 6 contracts above are part of a 14-contract + 4-token portfolio deployed by the
same treasury (`0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`). Portfolio hub:
https://thryx.fun

### DeadManSwitch (`AnonContractBase/deployments.md`)

| Contract | Address |
|---|---|
| DeadManSwitch | [`0x40f1AAb4c82D48260Ab1207e27329d51290025DB`](https://basescan.org/address/0x40f1aab4c82d48260ab1207e27329d51290025db) |

### Onchain Primitives (`OnchainPrimitives/LAB_REPORT.md`)

| Contract | Address |
|---|---|
| StealthAddressRegistry (EIP-5564) | [`0xD227B45aF37591E6227EB30B757232c1D541c016`](https://basescan.org/address/0xD227B45aF37591E6227EB30B757232c1D541c016) |
| SlashablePromiseVault | [`0xe2b5AfF3e1e05f999BbF48EDD27C4c872b953268`](https://basescan.org/address/0xe2b5AfF3e1e05f999BbF48EDD27C4c872b953268) |
| ConditionalTokenDrop | [`0x8Fb1224e814fcfE4dcd952a6d3DFF722d86862Ae`](https://basescan.org/address/0x8Fb1224e814fcfE4dcd952a6d3DFF722d86862Ae) |
| TimeCapsule | [`0x52E5829b8C71A8F4878B5569Df4255dfeB909a0C`](https://basescan.org/address/0x52E5829b8C71A8F4878B5569Df4255dfeB909a0C) |
| AddressTaggingMarket | [`0x0288DfE67bE8876D92c0EA41c190b506cd99eD63`](https://basescan.org/address/0x0288DfE67bE8876D92c0EA41c190b506cd99eD63) |
| GroupBountyPool | [`0xaB4C7B22B952f99cC8Bf280D17230E8CaDd6CbD4`](https://basescan.org/address/0xaB4C7B22B952f99cC8Bf280D17230E8CaDd6CbD4) |
| AtomicSwapHTLC | [`0xc3D0CBC815DE1938D4714bf2603b33400f588433`](https://basescan.org/address/0xc3D0CBC815DE1938D4714bf2603b33400f588433) |

### Tokens (`TokenLaunches/launched-tokens.json`) — Clanker v4, 80% LP fees → treasury

| Token | Address |
|---|---|
| Aletheia (ALETH) | [`0x1896354e4729C689B27CbDFdE5F8192eD0115B07`](https://basescan.org/token/0x1896354e4729C689B27CbDFdE5F8192eD0115B07) |
| Mnemosyne (MNEM) | [`0x6358208342Be88A6D8bDC7c00D09fB43C49DdB07`](https://basescan.org/token/0x6358208342Be88A6D8bDC7c00D09fB43C49DdB07) |
| Huginn (HUGIN) | [`0x75BB9e3eB32747D7A9eEEf8467f5f4C44C977B07`](https://basescan.org/token/0x75BB9e3eB32747D7A9eEEf8467f5f4C44C977B07) |
| Custos (CUSTOS) | [`0x3EFf9f255B5a1891a8003A2Bf46dE45247a8aB07`](https://basescan.org/token/0x3EFf9f255B5a1891a8003A2Bf46dE45247a8aB07) |

