// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VestingAutoClaim} from "../src/VestingAutoClaim.sol";
import {EnsAutoRenewer} from "../src/EnsAutoRenewer.sol";
import {DaoProposalExecutor} from "../src/DaoProposalExecutor.sol";
import {NftCancelOnFloorDrop} from "../src/NftCancelOnFloorDrop.sol";
import {CurveGraduationPusher} from "../src/CurveGraduationPusher.sol";
import {ManualFloorOracle} from "../src/ManualFloorOracle.sol";

/// @notice Production mainnet deploy: 5 keeper-bounty contracts + 1 floor oracle.
///         All contracts immutable post-deploy except for treasury-gated fee
///         adjustments (always within deploy-time hard caps).
contract MainnetDeployAll is Script {
    function run() external {
        uint256 pk = vm.envUint("THRYXTREASURY_PRIVATE_KEY");
        address treasury = vm.addr(pk);

        require(block.chainid == 8453, "Base mainnet (chainId 8453) only");

        uint16 feeBps = 500;       // 5%
        uint16 maxFeeBps = 1000;   // 10% hard cap

        console2.log("Treasury:", treasury);
        console2.log("Chain ID:", block.chainid);

        vm.startBroadcast(pk);

        // 1. Floor oracle first (NFT cancel needs its address)
        ManualFloorOracle oracle = new ManualFloorOracle(treasury);
        console2.log("ManualFloorOracle:      ", address(oracle));

        // 2. Vesting Auto-Claim
        VestingAutoClaim vesting = new VestingAutoClaim(treasury, feeBps, maxFeeBps);
        console2.log("VestingAutoClaim:       ", address(vesting));

        // 3. ENS Auto-Renewer (90-day renewal window per ENS controller convention)
        EnsAutoRenewer ens = new EnsAutoRenewer(treasury, feeBps, maxFeeBps, 90 days);
        console2.log("EnsAutoRenewer:         ", address(ens));

        // 4. DAO Proposal Executor
        DaoProposalExecutor dao = new DaoProposalExecutor(treasury, feeBps, maxFeeBps);
        console2.log("DaoProposalExecutor:    ", address(dao));

        // 5. NFT Cancel-on-Floor-Drop (oracle is real, not placeholder)
        NftCancelOnFloorDrop nft = new NftCancelOnFloorDrop(treasury, address(oracle), 1 hours, feeBps, maxFeeBps);
        console2.log("NftCancelOnFloorDrop:   ", address(nft));

        // 6. Curve Graduation Pusher
        CurveGraduationPusher curve = new CurveGraduationPusher(treasury, feeBps, maxFeeBps);
        console2.log("CurveGraduationPusher:  ", address(curve));

        vm.stopBroadcast();
    }
}
