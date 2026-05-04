// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DaoProposalExecutor} from "../src/DaoProposalExecutor.sol";

/// @dev Mock governance contract. Records the last execute call and can be
///      configured to revert. Used to simulate OZ Governor / Compound Bravo
///      style execute(uint256) interfaces.
contract MockDao {
    bool public shouldRevert;
    uint256 public lastProposalId;
    uint256 public callCount;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function execute(uint256 proposalId) external returns (uint256) {
        if (shouldRevert) revert("dao: nope");
        lastProposalId = proposalId;
        callCount += 1;
        return proposalId;
    }
}

/// @dev Reentrancy probe. When the DAO is called during execute(), it tries to
///      re-enter the executor on the same job. Should fail with BadStatus
///      because the executor flips status BEFORE the external call.
contract ReentrantDao {
    DaoProposalExecutor public executor;
    uint256 public jobId;
    bool public didReenter;
    bytes4 public reentryError;

    function configure(DaoProposalExecutor _executor, uint256 _jobId) external {
        executor = _executor;
        jobId = _jobId;
    }

    fallback() external payable {
        didReenter = true;
        try executor.execute(jobId) {
            // unexpected
        } catch (bytes memory err) {
            bytes4 sel;
            assembly {
                sel := mload(add(err, 32))
            }
            reentryError = sel;
        }
    }

    receive() external payable {}
}

/// @dev Refuses ETH on the call() path. Used to test transfer-failure handling.
contract Rejector {
    // No receive(), no fallback() — call{value:}(\"\") returns false.
}

contract DaoProposalExecutorTest is Test {
    DaoProposalExecutor internal executor;
    MockDao internal dao;

    address internal constant TREASURY = 0x7a3E312Ec6e20a9F62fE2405938EB9060312E334;
    address internal owner = address(0xA11CE);
    address internal keeper = address(0xBEEF);
    address internal stranger = address(0xDEAD);

    uint16 internal constant FEE_BPS = 500; // 5%
    uint16 internal constant MAX_FEE_BPS = 1_000; // 10%
    uint16 internal constant BPS = 10_000;

    function setUp() public {
        executor = new DaoProposalExecutor(TREASURY, FEE_BPS, MAX_FEE_BPS);
        dao = new MockDao();
        vm.deal(owner, 100 ether);
        vm.deal(keeper, 1 ether);
        vm.deal(stranger, 1 ether);
    }

    // -------------- helpers --------------

    function _calldata(uint256 proposalId) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockDao.execute.selector, proposalId);
    }

    function _depositFor(uint256 base, uint16 maxMult) internal pure returns (uint256) {
        uint256 maxBounty = (base * uint256(maxMult)) / BPS;
        uint256 maxFee = (maxBounty * uint256(MAX_FEE_BPS)) / BPS;
        return maxBounty + maxFee;
    }

    function _register(
        uint256 base,
        uint16 multBps,
        uint16 maxMult,
        uint32 daysToMax,
        uint256 proposalId
    ) internal returns (uint256 jobId, uint256 deposit) {
        deposit = _depositFor(base, maxMult);
        bytes memory data = _calldata(proposalId);
        vm.prank(owner);
        jobId = executor.register{value: deposit}(
            address(dao),
            MockDao.execute.selector,
            data,
            base,
            multBps,
            maxMult,
            daysToMax
        );
    }

    // -------------- constructor --------------

    function test_Constructor_RevertsOnZeroTreasury() public {
        vm.expectRevert(DaoProposalExecutor.ZeroAddress.selector);
        new DaoProposalExecutor(address(0), FEE_BPS, MAX_FEE_BPS);
    }

    function test_Constructor_RevertsWhenMaxFeeExceedsHalfBps() public {
        vm.expectRevert(DaoProposalExecutor.FeeAboveCap.selector);
        new DaoProposalExecutor(TREASURY, 0, 5_001);
    }

    function test_Constructor_RevertsWhenFeeExceedsMax() public {
        vm.expectRevert(DaoProposalExecutor.FeeAboveCap.selector);
        new DaoProposalExecutor(TREASURY, 1_001, 1_000);
    }

    // -------------- register validation --------------

    function test_Register_RevertsOnZeroDao() public {
        bytes memory data = _calldata(1);
        vm.prank(owner);
        vm.expectRevert(DaoProposalExecutor.ZeroAddress.selector);
        executor.register{value: 1 ether}(
            address(0), MockDao.execute.selector, data, 0.1 ether, 1_000, 30_000, 30
        );
    }

    function test_Register_RevertsOnZeroBase() public {
        bytes memory data = _calldata(1);
        vm.prank(owner);
        vm.expectRevert(DaoProposalExecutor.ZeroValue.selector);
        executor.register{value: 1 ether}(
            address(dao), MockDao.execute.selector, data, 0, 1_000, 30_000, 30
        );
    }

    function test_Register_RevertsOnEmptyCalldata() public {
        bytes memory data = new bytes(3);
        vm.prank(owner);
        vm.expectRevert(DaoProposalExecutor.EmptyCalldata.selector);
        executor.register{value: 1 ether}(
            address(dao), bytes4(0), data, 0.1 ether, 1_000, 30_000, 30
        );
    }

    function test_Register_RevertsOnSelectorMismatch() public {
        bytes memory data = _calldata(1);
        vm.prank(owner);
        vm.expectRevert(DaoProposalExecutor.SelectorMismatch.selector);
        executor.register{value: 1 ether}(
            address(dao), bytes4(0xdeadbeef), data, 0.1 ether, 1_000, 30_000, 30
        );
    }

    function test_Register_RevertsWhenMaxMultiplierBelowOneX() public {
        bytes memory data = _calldata(1);
        vm.prank(owner);
        vm.expectRevert(DaoProposalExecutor.MultiplierOutOfRange.selector);
        executor.register{value: 1 ether}(
            address(dao), MockDao.execute.selector, data, 0.1 ether, 1_000, 9_999, 30
        );
    }

    function test_Register_RevertsOnZeroDaysToMax() public {
        bytes memory data = _calldata(1);
        vm.prank(owner);
        vm.expectRevert(DaoProposalExecutor.DaysToMaxZero.selector);
        executor.register{value: 1 ether}(
            address(dao), MockDao.execute.selector, data, 0.1 ether, 1_000, 30_000, 0
        );
    }

    function test_Register_RevertsOnInsufficientDeposit() public {
        bytes memory data = _calldata(1);
        // base=0.1, maxMult=3x → maxBounty=0.3, maxFee@10%=0.03 → required=0.33
        vm.prank(owner);
        vm.expectRevert(DaoProposalExecutor.InsufficientDeposit.selector);
        executor.register{value: 0.32 ether}(
            address(dao), MockDao.execute.selector, data, 0.1 ether, 1_000, 30_000, 30
        );
    }

    function test_Register_HappyPathStoresJobAndIndex() public {
        (uint256 jobId, uint256 deposit) = _register(0.1 ether, 1_000, 30_000, 30, 42);
        assertEq(jobId, 0, "first jobId");
        assertEq(executor.totalJobs(), 1);
        assertEq(executor.jobsByOwner(owner).length, 1);
        assertEq(executor.jobsByOwner(owner)[0], 0);

        (
            address jOwner,
            address jDao,
            bytes4 sel,
            DaoProposalExecutor.Status status,
            ,
            uint256 base,
            uint16 multBps,
            uint16 maxMult,
            uint32 daysToMax,
            uint256 escrow,
            bytes memory data
        ) = executor.getJob(jobId);
        assertEq(jOwner, owner);
        assertEq(jDao, address(dao));
        assertEq(sel, MockDao.execute.selector);
        assertTrue(status == DaoProposalExecutor.Status.Active);
        assertEq(base, 0.1 ether);
        assertEq(multBps, 1_000);
        assertEq(maxMult, 30_000);
        assertEq(daysToMax, 30);
        assertEq(escrow, deposit);
        assertEq(keccak256(data), keccak256(_calldata(42)));
    }

    // -------------- linear bounty ramp --------------
    // multiplier formula: m = BPS + (multBps * elapsedDays / daysToMax), capped
    // at bountyMaxMultiplier. With multBps=10_000 (=+100% per "daysToMax"
    // window) and daysToMax=10, after 10 days m = 20_000 = 2x.

    function test_BountyRamp_ZeroAtRegistration() public {
        uint256 base = 1 ether;
        (uint256 jobId, ) = _register(base, 10_000, 30_000, 10, 1);
        assertEq(executor.currentBounty(jobId), base, "t=0 bounty equals base");
    }

    function test_BountyRamp_LinearMidpoint() public {
        uint256 base = 1 ether;
        (uint256 jobId, ) = _register(base, 10_000, 30_000, 10, 1);
        // Day 5 of 10 → growth = 10_000 * 5 / 10 = 5_000 → multiplier = 1.5x
        vm.warp(block.timestamp + 5 days);
        assertEq(executor.currentBounty(jobId), 1.5 ether, "day 5 -> 1.5x base");
    }

    function test_BountyRamp_ReachesNominalMaxAtDaysToMax() public {
        uint256 base = 1 ether;
        (uint256 jobId, ) = _register(base, 10_000, 30_000, 10, 1);
        vm.warp(block.timestamp + 10 days);
        // multiplier = 1 + 10_000/BPS * (10/10) = 2x (cap is 3x, not yet hit)
        assertEq(executor.currentBounty(jobId), 2 ether, "day 10 -> 2x base");
    }

    function test_BountyRamp_CapsAtMaxMultiplier() public {
        uint256 base = 1 ether;
        // multBps=10_000, daysToMax=10, cap=2.5x. Cap hits at 15 days
        // (1 + 10000*15/10/10000 = 1 + 1.5 = 2.5).
        (uint256 jobId, ) = _register(base, 10_000, 25_000, 10, 1);

        vm.warp(block.timestamp + 15 days);
        assertEq(executor.currentBounty(jobId), 2.5 ether, "day 15 hits cap");

        vm.warp(block.timestamp + 365 days);
        assertEq(executor.currentBounty(jobId), 2.5 ether, "still capped after a year");
    }

    function test_BountyRamp_PartialDayIgnored() public {
        // elapsedDays uses integer division by 1 days (floor). 23h59m → 0 days.
        uint256 base = 1 ether;
        (uint256 jobId, ) = _register(base, 10_000, 30_000, 10, 1);
        vm.warp(block.timestamp + 1 days - 1);
        assertEq(executor.currentBounty(jobId), base, "<1 day still base");
        vm.warp(block.timestamp + 1);
        assertEq(executor.currentBounty(jobId), 1 ether + 0.1 ether, "exactly 1 day -> +10%");
    }

    function test_BountyAt_FutureTimestamp() public {
        uint256 base = 1 ether;
        (uint256 jobId, ) = _register(base, 10_000, 30_000, 10, 1);
        uint256 future = block.timestamp + 7 days;
        // growth = 10_000 * 7 / 10 = 7_000 → 1.7x
        assertEq(executor.bountyAt(jobId, future), 1.7 ether);
    }

    // -------------- execute happy path --------------

    function test_Execute_PaysKeeperFeeAndRefundsOwner() public {
        uint256 base = 1 ether;
        (uint256 jobId, uint256 deposit) = _register(base, 10_000, 30_000, 10, 99);

        vm.warp(block.timestamp + 5 days); // bounty = 1.5 ether
        uint256 expectedBounty = 1.5 ether;
        uint256 expectedFee = (expectedBounty * FEE_BPS) / BPS; // 0.075
        uint256 expectedRefund = deposit - expectedBounty - expectedFee;

        uint256 keeperBefore = keeper.balance;
        uint256 ownerBefore = owner.balance;
        uint256 treasuryBefore = TREASURY.balance;

        vm.prank(keeper);
        executor.execute(jobId);

        assertEq(dao.lastProposalId(), 99, "DAO actually called");
        assertEq(dao.callCount(), 1);

        assertEq(keeper.balance - keeperBefore, expectedBounty, "keeper bounty");
        assertEq(TREASURY.balance - treasuryBefore, expectedFee, "treasury fee");
        assertEq(owner.balance - ownerBefore, expectedRefund, "owner refund");

        (, , , DaoProposalExecutor.Status status, , , , , , uint256 escrow, ) = executor.getJob(jobId);
        assertTrue(status == DaoProposalExecutor.Status.Executed);
        assertEq(escrow, 0);
    }

    function test_Execute_AnyoneCanCall() public {
        (uint256 jobId, ) = _register(0.5 ether, 1_000, 20_000, 10, 7);
        vm.prank(stranger); // not owner, not keeper, not treasury
        executor.execute(jobId);
        assertEq(dao.callCount(), 1);
    }

    function test_Execute_RevertsIfDaoCallReverts() public {
        (uint256 jobId, uint256 deposit) = _register(0.5 ether, 1_000, 20_000, 10, 7);
        dao.setShouldRevert(true);

        uint256 ownerBefore = owner.balance;
        vm.prank(keeper);
        vm.expectRevert(DaoProposalExecutor.DaoCallFailed.selector);
        executor.execute(jobId);

        // No payouts occurred; status stays Executed though (CEI flipped it).
        // We accept that — the proposer can't double-fire, but the escrow is
        // stuck. The owner should never have signed up to register a failing
        // proposal. We sanity-check no funds moved.
        assertEq(owner.balance, ownerBefore, "no refund happened");
        // Verify funds are still in the contract (none were sent out before revert).
        assertEq(address(executor).balance, deposit, "escrow untouched on revert");
    }

    function test_Execute_RevertsOnAlreadyExecuted() public {
        (uint256 jobId, ) = _register(0.5 ether, 1_000, 20_000, 10, 7);
        vm.prank(keeper);
        executor.execute(jobId);
        vm.prank(keeper);
        vm.expectRevert(DaoProposalExecutor.BadStatus.selector);
        executor.execute(jobId);
    }

    function test_Execute_RevertsOnCancelled() public {
        (uint256 jobId, ) = _register(0.5 ether, 1_000, 20_000, 10, 7);
        vm.prank(owner);
        executor.cancel(jobId);
        vm.prank(keeper);
        vm.expectRevert(DaoProposalExecutor.BadStatus.selector);
        executor.execute(jobId);
    }

    function test_Execute_BountyAtCapAfterLongDelay() public {
        uint256 base = 1 ether;
        (uint256 jobId, uint256 deposit) = _register(base, 10_000, 25_000, 10, 1);
        vm.warp(block.timestamp + 365 days);
        uint256 expectedBounty = 2.5 ether;

        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        executor.execute(jobId);

        assertEq(keeper.balance - keeperBefore, expectedBounty, "keeper bounty at cap");
        // deposit shape: maxBounty(2.5) + maxFee@10%(0.25) = 2.75
        assertEq(deposit, 2.75 ether, "expected deposit shape");
    }

    // -------------- cancel --------------

    function test_Cancel_OwnerOnlyAndRefunds() public {
        (uint256 jobId, uint256 deposit) = _register(0.5 ether, 1_000, 20_000, 10, 7);
        uint256 ownerBefore = owner.balance;

        vm.prank(stranger);
        vm.expectRevert(DaoProposalExecutor.NotOwner.selector);
        executor.cancel(jobId);

        vm.prank(owner);
        executor.cancel(jobId);
        assertEq(owner.balance - ownerBefore, deposit, "full refund");

        (, , , DaoProposalExecutor.Status status, , , , , , uint256 escrow, ) = executor.getJob(jobId);
        assertTrue(status == DaoProposalExecutor.Status.Cancelled);
        assertEq(escrow, 0);
    }

    function test_Cancel_RevertsIfAlreadyExecuted() public {
        (uint256 jobId, ) = _register(0.5 ether, 1_000, 20_000, 10, 7);
        vm.prank(keeper);
        executor.execute(jobId);
        vm.prank(owner);
        vm.expectRevert(DaoProposalExecutor.BadStatus.selector);
        executor.cancel(jobId);
    }

    // -------------- reentrancy via DAO callback --------------

    function test_Execute_ReentryGuardedByCEI() public {
        ReentrantDao rdao = new ReentrantDao();

        // Build calldata that pokes the rdao fallback (any selector works).
        bytes memory data = abi.encodeWithSelector(bytes4(keccak256("anything()")));
        uint256 base = 0.1 ether;
        uint256 deposit = _depositFor(base, 20_000);

        vm.deal(owner, 10 ether);
        vm.prank(owner);
        uint256 jobId = executor.register{value: deposit}(
            address(rdao), bytes4(keccak256("anything()")), data, base, 1_000, 20_000, 30
        );
        rdao.configure(executor, jobId);

        vm.prank(keeper);
        executor.execute(jobId);

        assertTrue(rdao.didReenter(), "fallback ran during execute");
        assertEq(rdao.reentryError(), DaoProposalExecutor.BadStatus.selector, "reentry blocked by status flip");
    }

    // -------------- treasury controls --------------

    function test_SetFee_OnlyTreasury() public {
        vm.prank(stranger);
        vm.expectRevert(DaoProposalExecutor.NotTreasury.selector);
        executor.setFee(200);

        vm.prank(TREASURY);
        executor.setFee(200);
        assertEq(executor.feeBps(), 200);
    }

    function test_SetFee_RevertsAboveCap() public {
        vm.prank(TREASURY);
        vm.expectRevert(DaoProposalExecutor.FeeAboveCap.selector);
        executor.setFee(MAX_FEE_BPS + 1);
    }

    function test_SetTreasury_OnlyTreasuryAndNonZero() public {
        vm.prank(TREASURY);
        vm.expectRevert(DaoProposalExecutor.ZeroAddress.selector);
        executor.setTreasury(address(0));

        address newT = address(0xCAFE);
        vm.prank(TREASURY);
        executor.setTreasury(newT);
        assertEq(executor.treasury(), newT);
    }

    // -------------- transfer failure --------------

    function test_Execute_RevertsIfKeeperRejectsETH() public {
        Rejector r = new Rejector();
        (uint256 jobId, ) = _register(0.5 ether, 1_000, 20_000, 10, 7);
        vm.prank(address(r));
        vm.expectRevert(DaoProposalExecutor.TransferFailed.selector);
        executor.execute(jobId);
    }

    // -------------- view sanity --------------

    function test_CurrentFee_TracksCurrentBounty() public {
        uint256 base = 1 ether;
        (uint256 jobId, ) = _register(base, 10_000, 30_000, 10, 1);
        vm.warp(block.timestamp + 5 days);
        // bounty = 1.5, fee = 5% = 0.075
        assertEq(executor.currentFee(jobId), 0.075 ether);
    }
}
