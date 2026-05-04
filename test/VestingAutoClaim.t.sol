// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VestingAutoClaim} from "../src/VestingAutoClaim.sol";

/// @notice Mock vesting contract — records who triggered the claim and at what time.
contract MockVesting {
    uint64 public cliff;
    uint256 public claimCount;
    address public lastCaller;
    bool public shouldRevert;

    error CliffNotReached();

    constructor(uint64 _cliff) {
        cliff = _cliff;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    /// selector: 0x4e71d92d
    function claim() external {
        if (shouldRevert) revert();
        if (block.timestamp < cliff) revert CliffNotReached();
        claimCount += 1;
        lastCaller = msg.sender;
    }
}

/// @notice Reverter — used to verify execute() bubbles up VestingCallFailed.
contract AlwaysRevert {
    function claim() external pure {
        revert("nope");
    }
}

/// @notice Treasury that rejects ETH — proves _send TransferFailed path.
contract NoReceive {
    // No receive/fallback → rejects ETH transfers.
}

/// @notice Reentrant attacker keeper — tries to call execute again from receive().
contract ReentrantKeeper {
    VestingAutoClaim public target;
    uint256 public jobId;
    bool public reentered;
    bool public reentryReverted;

    constructor(VestingAutoClaim _target) {
        target = _target;
    }

    function attack(uint256 id) external {
        jobId = id;
        target.execute(id);
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            try target.execute(jobId) {
                // should not succeed
            } catch {
                reentryReverted = true;
            }
        }
    }
}

contract VestingAutoClaimTest is Test {
    VestingAutoClaim public vac;
    MockVesting public vesting;

    address constant TREASURY = 0x7a3E312Ec6e20a9F62fE2405938EB9060312E334;
    address constant ALICE = address(0xA11CE);
    address constant KEEPER = address(0xBEEF);
    address constant BOB = address(0xB0B);

    uint16 constant FEE_BPS = 500;       // 5%
    uint16 constant MAX_FEE_BPS = 1_000; // 10% — spec hard cap

    bytes4 constant CLAIM_SEL = bytes4(keccak256("claim()"));

    event Registered(uint256 indexed id, address indexed owner, address indexed vestingContract, bytes4 claimSelector, uint256 bounty);
    event Executed(uint256 indexed id, address indexed keeper, uint256 keeperBounty, uint256 protocolFee);
    event Cancelled(uint256 indexed id, uint256 refunded);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesUpdated(uint16 newFeeBps);

    function setUp() public {
        vac = new VestingAutoClaim(TREASURY, FEE_BPS, MAX_FEE_BPS);
        vesting = new MockVesting(uint64(block.timestamp + 7 days));
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(KEEPER, 1 ether);
    }

    // ---------- constructor ----------

    function test_constructor_setsImmutables() public view {
        assertEq(vac.treasury(), TREASURY);
        assertEq(vac.feeBps(), FEE_BPS);
        assertEq(vac.maxFeeBps(), MAX_FEE_BPS);
    }

    function test_constructor_revertsZeroTreasury() public {
        vm.expectRevert(VestingAutoClaim.ZeroAddress.selector);
        new VestingAutoClaim(address(0), FEE_BPS, MAX_FEE_BPS);
    }

    function test_constructor_revertsMaxFeeAboveSpecCap() public {
        // Spec hard cap is 10% — 1001 bps must revert.
        vm.expectRevert(VestingAutoClaim.FeeAboveCap.selector);
        new VestingAutoClaim(TREASURY, 0, 1_001);
    }

    function test_constructor_revertsFeeAboveMax() public {
        vm.expectRevert(VestingAutoClaim.FeeAboveCap.selector);
        new VestingAutoClaim(TREASURY, 600, 500);
    }

    // ---------- register ----------

    function test_register_storesJobAndIndexes() public {
        vm.prank(ALICE);
        vm.expectEmit(true, true, true, true);
        emit Registered(0, ALICE, address(vesting), CLAIM_SEL, 1 ether);
        uint256 id = vac.register{value: 1 ether}(address(vesting), CLAIM_SEL);

        assertEq(id, 0);
        assertEq(vac.totalJobs(), 1);
        (address owner, address vest, bytes4 sel, uint256 bounty, bool done) = vac.jobs(0);
        assertEq(owner, ALICE);
        assertEq(vest, address(vesting));
        assertEq(sel, CLAIM_SEL);
        assertEq(bounty, 1 ether);
        assertEq(done, false);

        uint256[] memory mine = vac.jobsByOwner(ALICE);
        assertEq(mine.length, 1);
        assertEq(mine[0], 0);

        // Bounty is held by the contract until execute/cancel.
        assertEq(address(vac).balance, 1 ether);
    }

    function test_register_revertsZeroValue() public {
        vm.prank(ALICE);
        vm.expectRevert(VestingAutoClaim.ZeroValue.selector);
        vac.register{value: 0}(address(vesting), CLAIM_SEL);
    }

    function test_register_revertsZeroVestingAddress() public {
        vm.prank(ALICE);
        vm.expectRevert(VestingAutoClaim.ZeroAddress.selector);
        vac.register{value: 1 ether}(address(0), CLAIM_SEL);
    }

    function test_register_revertsZeroSelector() public {
        vm.prank(ALICE);
        vm.expectRevert(VestingAutoClaim.ZeroSelector.selector);
        vac.register{value: 1 ether}(address(vesting), bytes4(0));
    }

    function test_register_multipleJobsIndependent() public {
        vm.prank(ALICE);
        vac.register{value: 1 ether}(address(vesting), CLAIM_SEL);
        vm.prank(BOB);
        vac.register{value: 2 ether}(address(vesting), CLAIM_SEL);
        vm.prank(ALICE);
        vac.register{value: 3 ether}(address(vesting), CLAIM_SEL);

        assertEq(vac.totalJobs(), 3);
        assertEq(vac.jobsByOwner(ALICE).length, 2);
        assertEq(vac.jobsByOwner(BOB).length, 1);
        assertEq(vac.jobsByOwner(BOB)[0], 1);
    }

    // ---------- execute ----------

    function test_execute_paysKeeperAndTreasury_andCallsVesting() public {
        vm.prank(ALICE);
        uint256 id = vac.register{value: 1 ether}(address(vesting), CLAIM_SEL);

        vm.warp(block.timestamp + 7 days);

        uint256 expectedFee = (uint256(1 ether) * uint256(FEE_BPS)) / 10_000; // 0.05 ether
        uint256 expectedBounty = 1 ether - expectedFee;

        uint256 keeperBefore = KEEPER.balance;
        uint256 treasuryBefore = TREASURY.balance;

        vm.prank(KEEPER);
        vm.expectEmit(true, true, false, true);
        emit Executed(id, KEEPER, expectedBounty, expectedFee);
        vac.execute(id);

        // Mock confirms the contract called it.
        assertEq(vesting.claimCount(), 1);
        assertEq(vesting.lastCaller(), address(vac));

        assertEq(KEEPER.balance - keeperBefore, expectedBounty);
        assertEq(TREASURY.balance - treasuryBefore, expectedFee);
        assertEq(address(vac).balance, 0);

        (, , , uint256 bounty, bool done) = vac.jobs(id);
        assertEq(bounty, 0);
        assertTrue(done);
    }

    function test_execute_revertsIfAlreadyDone() public {
        vm.prank(ALICE);
        uint256 id = vac.register{value: 1 ether}(address(vesting), CLAIM_SEL);
        vm.warp(block.timestamp + 7 days);

        vm.prank(KEEPER);
        vac.execute(id);

        vm.prank(KEEPER);
        vm.expectRevert(VestingAutoClaim.AlreadyDone.selector);
        vac.execute(id);
    }

    function test_execute_bubblesUpVestingFailure() public {
        AlwaysRevert bad = new AlwaysRevert();
        vm.prank(ALICE);
        uint256 id = vac.register{value: 1 ether}(address(bad), CLAIM_SEL);

        vm.prank(KEEPER);
        vm.expectRevert(VestingAutoClaim.VestingCallFailed.selector);
        vac.execute(id);

        // State was rolled back by the revert — keeper can retry once vesting works.
        (, , , uint256 bounty, bool done) = vac.jobs(id);
        assertEq(bounty, 1 ether);
        assertFalse(done);
    }

    function test_execute_revertsBeforeCliff() public {
        vm.prank(ALICE);
        uint256 id = vac.register{value: 1 ether}(address(vesting), CLAIM_SEL);

        // Cliff at +7d, we're at +0 — vesting will revert with CliffNotReached.
        vm.prank(KEEPER);
        vm.expectRevert(VestingAutoClaim.VestingCallFailed.selector);
        vac.execute(id);
    }

    function test_execute_zeroFeeRoutesAllToKeeper() public {
        // Lower fee to zero.
        vm.prank(TREASURY);
        vac.setFees(0);

        vm.prank(ALICE);
        uint256 id = vac.register{value: 1 ether}(address(vesting), CLAIM_SEL);
        vm.warp(block.timestamp + 7 days);

        uint256 keeperBefore = KEEPER.balance;
        uint256 treasuryBefore = TREASURY.balance;

        vm.prank(KEEPER);
        vac.execute(id);

        assertEq(KEEPER.balance - keeperBefore, 1 ether);
        assertEq(TREASURY.balance - treasuryBefore, 0);
    }

    function test_execute_reentryHitsAlreadyDone() public {
        ReentrantKeeper attacker = new ReentrantKeeper(vac);
        vm.deal(address(attacker), 0);

        vm.prank(ALICE);
        uint256 id = vac.register{value: 1 ether}(address(vesting), CLAIM_SEL);
        vm.warp(block.timestamp + 7 days);

        attacker.attack(id);

        // Reentrant call must have happened AND must have been rejected by AlreadyDone.
        assertTrue(attacker.reentered(), "reentry path not triggered");
        assertTrue(attacker.reentryReverted(), "reentry should have reverted");
        // Attacker ended up with the keeper bounty, but only once.
        uint256 expectedFee = (uint256(1 ether) * uint256(FEE_BPS)) / 10_000;
        assertEq(address(attacker).balance, 1 ether - expectedFee);
    }

    // ---------- cancel ----------

    function test_cancel_refundsOwner() public {
        vm.prank(ALICE);
        uint256 id = vac.register{value: 1 ether}(address(vesting), CLAIM_SEL);

        uint256 aliceBefore = ALICE.balance;
        vm.prank(ALICE);
        vm.expectEmit(true, false, false, true);
        emit Cancelled(id, 1 ether);
        vac.cancel(id);

        assertEq(ALICE.balance - aliceBefore, 1 ether);
        (, , , uint256 bounty, bool done) = vac.jobs(id);
        assertEq(bounty, 0);
        assertTrue(done);
    }

    function test_cancel_revertsNotOwner() public {
        vm.prank(ALICE);
        uint256 id = vac.register{value: 1 ether}(address(vesting), CLAIM_SEL);

        vm.prank(BOB);
        vm.expectRevert(VestingAutoClaim.NotOwner.selector);
        vac.cancel(id);
    }

    function test_cancel_revertsIfDone() public {
        vm.prank(ALICE);
        uint256 id = vac.register{value: 1 ether}(address(vesting), CLAIM_SEL);
        vm.warp(block.timestamp + 7 days);
        vm.prank(KEEPER);
        vac.execute(id);

        vm.prank(ALICE);
        vm.expectRevert(VestingAutoClaim.AlreadyDone.selector);
        vac.cancel(id);
    }

    // ---------- admin ----------

    function test_setFees_treasuryOnlyAndCapped() public {
        // Non-treasury rejected.
        vm.prank(ALICE);
        vm.expectRevert(VestingAutoClaim.NotTreasury.selector);
        vac.setFees(100);

        // Above cap rejected.
        vm.prank(TREASURY);
        vm.expectRevert(VestingAutoClaim.FeeAboveCap.selector);
        vac.setFees(MAX_FEE_BPS + 1);

        // Lowering succeeds.
        vm.prank(TREASURY);
        vm.expectEmit(false, false, false, true);
        emit FeesUpdated(0);
        vac.setFees(0);
        assertEq(vac.feeBps(), 0);

        // Raising up to the cap is allowed (treasury can re-raise within cap).
        vm.prank(TREASURY);
        vac.setFees(MAX_FEE_BPS);
        assertEq(vac.feeBps(), MAX_FEE_BPS);
    }

    function test_setTreasury_onlyTreasuryAndNonZero() public {
        vm.prank(ALICE);
        vm.expectRevert(VestingAutoClaim.NotTreasury.selector);
        vac.setTreasury(BOB);

        vm.prank(TREASURY);
        vm.expectRevert(VestingAutoClaim.ZeroAddress.selector);
        vac.setTreasury(address(0));

        vm.prank(TREASURY);
        vm.expectEmit(true, true, false, false);
        emit TreasuryUpdated(TREASURY, BOB);
        vac.setTreasury(BOB);
        assertEq(vac.treasury(), BOB);
    }

    // ---------- transfer failure ----------

    function test_cancel_revertsIfOwnerCannotReceive() public {
        NoReceive deadbeat = new NoReceive();
        vm.deal(address(deadbeat), 5 ether);

        vm.prank(address(deadbeat));
        uint256 id = vac.register{value: 1 ether}(address(vesting), CLAIM_SEL);

        vm.prank(address(deadbeat));
        vm.expectRevert(VestingAutoClaim.TransferFailed.selector);
        vac.cancel(id);
    }

    // ---------- fuzz ----------

    function testFuzz_register_thenExecute(uint96 amount) public {
        amount = uint96(bound(uint256(amount), 1, 100 ether));
        vm.deal(ALICE, amount);

        vm.prank(ALICE);
        uint256 id = vac.register{value: amount}(address(vesting), CLAIM_SEL);
        vm.warp(block.timestamp + 7 days);

        uint256 fee = (uint256(amount) * FEE_BPS) / 10_000;
        uint256 toKeeper = uint256(amount) - fee;
        uint256 keeperBefore = KEEPER.balance;
        uint256 treasuryBefore = TREASURY.balance;

        vm.prank(KEEPER);
        vac.execute(id);

        assertEq(KEEPER.balance - keeperBefore, toKeeper);
        assertEq(TREASURY.balance - treasuryBefore, fee);
        assertEq(address(vac).balance, 0);
    }
}
