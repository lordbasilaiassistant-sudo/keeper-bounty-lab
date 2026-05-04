// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VestingAutoClaim} from "../src/VestingAutoClaim.sol";
import {EnsAutoRenewer} from "../src/EnsAutoRenewer.sol";
import {DaoProposalExecutor} from "../src/DaoProposalExecutor.sol";
import {NftCancelOnFloorDrop} from "../src/NftCancelOnFloorDrop.sol";
import {CurveGraduationPusher} from "../src/CurveGraduationPusher.sol";

/// @notice Deploys all 5 keeper-bounty prototypes to Base Sepolia for evaluation.
///         Single broadcast = sequential nonces, no conflicts.
contract DeployAll is Script {
    function run() external {
        uint256 pk = vm.envUint("THRYXTREASURY_PRIVATE_KEY");
        address treasury = vm.addr(pk);

        require(block.chainid == 84532 || block.chainid == 31337, "Sepolia or local only");

        uint16 feeBps = 500;       // 5%
        uint16 maxFeeBps = 1000;   // 10% cap (matches VestingAutoClaim's hard ceiling)

        console2.log("Treasury:", treasury);
        console2.log("Chain ID:", block.chainid);

        vm.startBroadcast(pk);

        VestingAutoClaim vesting = new VestingAutoClaim(treasury, feeBps, maxFeeBps);
        console2.log("VestingAutoClaim:       ", address(vesting));

        EnsAutoRenewer ens = new EnsAutoRenewer(treasury, feeBps, maxFeeBps, 90 days);
        console2.log("EnsAutoRenewer:         ", address(ens));

        DaoProposalExecutor dao = new DaoProposalExecutor(treasury, feeBps, maxFeeBps);
        console2.log("DaoProposalExecutor:    ", address(dao));

        // NFT: oracle = treasury for now (placeholder; would be a real keeper-signed oracle in production)
        NftCancelOnFloorDrop nft = new NftCancelOnFloorDrop(treasury, treasury, 1 hours, feeBps, maxFeeBps);
        console2.log("NftCancelOnFloorDrop:   ", address(nft));

        CurveGraduationPusher curve = new CurveGraduationPusher(treasury, feeBps, maxFeeBps);
        console2.log("CurveGraduationPusher:  ", address(curve));

        vm.stopBroadcast();
    }
}
