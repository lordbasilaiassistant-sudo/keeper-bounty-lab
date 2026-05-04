// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EnsAutoRenewer} from "../src/EnsAutoRenewer.sol";

/// @notice Stub stand-in for ENS ETHRegistrarController. Just records calls
///         and accepts ETH. Optionally refunds part of the payment to mimic
///         the real controller's overpayment-refund behavior.
contract MockEnsController {
    struct Call {
        string name;
        uint256 duration;
        uint256 value;
    }

    Call[] public calls;
    uint256 public refundOnNextCall;
    bool public revertOnNextCall;

    function setRefundOnNextCall(uint256 amount) external {
        refundOnNextCall = amount;
    }

    function setRevertOnNextCall(bool v) external {
        revertOnNextCall = v;
    }

    function callsLength() external view returns (uint256) {
        return calls.length;
    }

    function renew(string calldata name, uint256 duration) external payable {
        if (revertOnNextCall) {
            revertOnNextCall = false;
            revert("controller: forced revert");
        }
        calls.push(Call({name: name, duration: duration, value: msg.value}));
        if (refundOnNextCall > 0) {
            uint256 r = refundOnNextCall;
            refundOnNextCall = 0;
            (bool ok, ) = msg.sender.call{value: r}("");
            require(ok, "refund failed");
        }
    }

    receive() external payable {}
}

/// @notice Recipient that always rejects ETH transfers. Used to assert
///         TransferFailed on _send().
contract RevertingReceiver {
    receive() external payable {
        revert("nope");
    }
}

contract EnsAutoRenewerTest is Test {
    EnsAutoRenewer internal renewer;
    MockEnsController internal controller;

    address internal constant TREASURY = 0x7a3E312Ec6e20a9F62fE2405938EB9060312E334;
    address internal owner1 = address(0xA11CE);
    address internal owner2 = address(0xB0B);
    address internal keeper = address(0xC0FFEE);

    uint16 internal constant FEE_BPS = 500; // 5%
    uint16 internal constant MAX_FEE_BPS = 1000; // 10%
    uint64 internal constant WINDOW = 90 days;

    uint64 internal expectedExp;

    function setUp() public {
        renewer = new EnsAutoRenewer(TREASURY, FEE_BPS, MAX_FEE_BPS, WINDOW);
        controller = new MockEnsController();

        vm.deal(owner1, 100 ether);
        vm.deal(owner2, 100 ether);
        vm.deal(keeper, 1 ether);

        // Set "now" to a comfortable midpoint and pick an expiration
        // 180 days from now — well outside the 90-day window so we can
        // test both pre-window and in-window behavior.
        vm.warp(1_900_000_000);
        expectedExp = uint64(block.timestamp + 180 days);
    }

    function _register(address asWho, uint256 budget, uint256 bounty)
        internal
        returns (uint256 jobId, uint256 fee)
    {
        fee = (bounty * FEE_BPS) / 10_000;
        vm.prank(asWho);
        jobId = renewer.register{value: budget + bounty + fee}(
            address(controller),
            "vitalik",
            expectedExp,
            budget,
            bounty
        );
    }

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    function test_constructor_storesParams() public view {
        assertEq(renewer.treasury(), TREASURY);
        assertEq(renewer.protocolFeeBps(), FEE_BPS);
        assertEq(renewer.maxProtocolFeeBps(), MAX_FEE_BPS);
        assertEq(renewer.renewalWindow(), WINDOW);
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(EnsAutoRenewer.ZeroAddress.selector);
        new EnsAutoRenewer(address(0), FEE_BPS, MAX_FEE_BPS, WINDOW);
    }

    function test_constructor_revertsOnFeeAboveCap() public {
        vm.expectRevert(EnsAutoRenewer.FeeAboveCap.selector);
        new EnsAutoRenewer(TREASURY, MAX_FEE_BPS + 1, MAX_FEE_BPS, WINDOW);
    }

    function test_constructor_revertsOnMaxAbove50pct() public {
        vm.expectRevert(EnsAutoRenewer.FeeAboveCap.selector);
        new EnsAutoRenewer(TREASURY, 0, 5001, WINDOW);
    }

    function test_constructor_revertsOnZeroWindow() public {
        vm.expectRevert(EnsAutoRenewer.ZeroValue.selector);
        new EnsAutoRenewer(TREASURY, FEE_BPS, MAX_FEE_BPS, 0);
    }

    // -----------------------------------------------------------------
    // register
    // -----------------------------------------------------------------

    function test_register_storesJobAndPaysFee() public {
        uint256 budget = 0.05 ether;
        uint256 bounty = 0.01 ether;
        uint256 fee = (bounty * FEE_BPS) / 10_000;

        uint256 treasuryBefore = TREASURY.balance;

        vm.prank(owner1);
        uint256 jobId = renewer.register{value: budget + bounty + fee}(
            address(controller),
            "vitalik",
            expectedExp,
            budget,
            bounty
        );

        assertEq(jobId, 0);
        assertEq(renewer.totalJobs(), 1);
        assertEq(TREASURY.balance - treasuryBefore, fee);
        assertEq(address(renewer).balance, budget + bounty);

        EnsAutoRenewer.Job memory j = renewer.getJob(jobId);
        assertEq(j.owner, owner1);
        assertEq(j.controller, address(controller));
        assertEq(j.name, "vitalik");
        assertEq(j.expectedExpiration, expectedExp);
        assertEq(j.renewalBudget, budget);
        assertEq(j.bounty, bounty);
        assertEq(j.settled, false);

        uint256[] memory mine = renewer.jobsByOwner(owner1);
        assertEq(mine.length, 1);
        assertEq(mine[0], 0);
    }

    function test_register_revertsOnWrongMsgValue() public {
        uint256 budget = 0.05 ether;
        uint256 bounty = 0.01 ether;
        uint256 fee = (bounty * FEE_BPS) / 10_000;

        vm.prank(owner1);
        vm.expectRevert(EnsAutoRenewer.WrongMsgValue.selector);
        renewer.register{value: budget + bounty + fee - 1}(
            address(controller),
            "vitalik",
            expectedExp,
            budget,
            bounty
        );
    }

    function test_register_revertsOnEmptyName() public {
        uint256 budget = 0.05 ether;
        uint256 bounty = 0.01 ether;
        uint256 fee = (bounty * FEE_BPS) / 10_000;

        vm.prank(owner1);
        vm.expectRevert(EnsAutoRenewer.EmptyName.selector);
        renewer.register{value: budget + bounty + fee}(
            address(controller),
            "",
            expectedExp,
            budget,
            bounty
        );
    }

    function test_register_revertsOnZeroController() public {
        vm.prank(owner1);
        vm.expectRevert(EnsAutoRenewer.ZeroAddress.selector);
        renewer.register{value: 0.06 ether}(
            address(0),
            "vitalik",
            expectedExp,
            0.05 ether,
            0.01 ether
        );
    }

    function test_register_revertsOnZeroBudgetOrBounty() public {
        vm.prank(owner1);
        vm.expectRevert(EnsAutoRenewer.ZeroValue.selector);
        renewer.register{value: 0.01 ether}(
            address(controller),
            "vitalik",
            expectedExp,
            0,
            0.01 ether
        );

        vm.prank(owner1);
        vm.expectRevert(EnsAutoRenewer.ZeroValue.selector);
        renewer.register{value: 0.05 ether}(
            address(controller),
            "vitalik",
            expectedExp,
            0.05 ether,
            0
        );
    }

    function test_quoteProtocolFee_matchesRegister() public view {
        uint256 bounty = 0.01 ether;
        assertEq(renewer.quoteProtocolFee(bounty), (bounty * FEE_BPS) / 10_000);
        assertEq(renewer.quoteProtocolFee(0), 0);
    }

    // -----------------------------------------------------------------
    // execute
    // -----------------------------------------------------------------

    function test_execute_outOfWindow_reverts() public {
        // We're at t = ~1.9e9 and expectedExp is 180 days out, window is 90d.
        // So we are NOT yet inside the window.
        (uint256 jobId, ) = _register(owner1, 0.05 ether, 0.01 ether);

        assertFalse(renewer.isExecutable(jobId));

        vm.prank(keeper);
        vm.expectRevert(EnsAutoRenewer.OutOfWindow.selector);
        renewer.execute(jobId, 365 days);
    }

    function test_execute_paysKeeperAndForwardsToController() public {
        uint256 budget = 0.05 ether;
        uint256 bounty = 0.01 ether;
        (uint256 jobId, ) = _register(owner1, budget, bounty);

        // Move into the window: 60 days before expiration.
        vm.warp(uint256(expectedExp) - 60 days);
        assertTrue(renewer.isExecutable(jobId));

        uint256 keeperBefore = keeper.balance;
        uint256 controllerBefore = address(controller).balance;
        uint256 ownerBefore = owner1.balance;

        vm.prank(keeper);
        renewer.execute(jobId, 365 days);

        assertEq(keeper.balance - keeperBefore, bounty);
        assertEq(address(controller).balance - controllerBefore, budget);
        assertEq(owner1.balance, ownerBefore); // no refund path triggered
        assertEq(controller.callsLength(), 1);

        (string memory name, uint256 duration, uint256 value) = controller.calls(0);
        assertEq(name, "vitalik");
        assertEq(duration, 365 days);
        assertEq(value, budget);

        EnsAutoRenewer.Job memory j = renewer.getJob(jobId);
        assertTrue(j.settled);
        assertEq(j.renewalBudget, 0);
        assertEq(j.bounty, 0);
        assertEq(j.lastRenewedAt, uint64(block.timestamp));
        assertFalse(renewer.isExecutable(jobId));
    }

    function test_execute_refundsControllerOverpayment() public {
        uint256 budget = 0.05 ether;
        uint256 bounty = 0.01 ether;
        uint256 refundAmount = 0.02 ether;

        (uint256 jobId, ) = _register(owner1, budget, bounty);

        controller.setRefundOnNextCall(refundAmount);

        vm.warp(uint256(expectedExp) - 30 days);

        uint256 ownerBefore = owner1.balance;
        uint256 keeperBefore = keeper.balance;

        vm.prank(keeper);
        renewer.execute(jobId, 365 days);

        // Owner got the controller refund back.
        assertEq(owner1.balance - ownerBefore, refundAmount);
        // Keeper still got the full bounty.
        assertEq(keeper.balance - keeperBefore, bounty);
        // Controller net balance = budget - refund.
        assertEq(address(controller).balance, budget - refundAmount);
        // Renewer holds nothing.
        assertEq(address(renewer).balance, 0);
    }

    function test_execute_revertsOnControllerRevert() public {
        (uint256 jobId, ) = _register(owner1, 0.05 ether, 0.01 ether);

        controller.setRevertOnNextCall(true);

        vm.warp(uint256(expectedExp) - 10 days);

        vm.prank(keeper);
        vm.expectRevert(EnsAutoRenewer.RenewCallFailed.selector);
        renewer.execute(jobId, 365 days);

        // Job state was rolled back by the revert.
        EnsAutoRenewer.Job memory j = renewer.getJob(jobId);
        assertFalse(j.settled);
        assertEq(j.renewalBudget, 0.05 ether);
    }

    function test_execute_revertsOnZeroDuration() public {
        (uint256 jobId, ) = _register(owner1, 0.05 ether, 0.01 ether);
        vm.warp(uint256(expectedExp) - 10 days);

        vm.prank(keeper);
        vm.expectRevert(EnsAutoRenewer.ZeroDuration.selector);
        renewer.execute(jobId, 0);
    }

    function test_execute_doubleExecuteReverts() public {
        (uint256 jobId, ) = _register(owner1, 0.05 ether, 0.01 ether);
        vm.warp(uint256(expectedExp) - 10 days);

        vm.prank(keeper);
        renewer.execute(jobId, 365 days);

        vm.prank(keeper);
        vm.expectRevert(EnsAutoRenewer.AlreadySettled.selector);
        renewer.execute(jobId, 365 days);
    }

    function test_execute_inGracePeriod_works() public {
        // ENS grace period is 90 days. Execution should still be allowed
        // up to expectedExp + 90 days.
        (uint256 jobId, ) = _register(owner1, 0.05 ether, 0.01 ether);
        vm.warp(uint256(expectedExp) + 80 days);

        assertTrue(renewer.isExecutable(jobId));
        vm.prank(keeper);
        renewer.execute(jobId, 365 days);
    }

    function test_execute_pastGracePeriod_reverts() public {
        (uint256 jobId, ) = _register(owner1, 0.05 ether, 0.01 ether);
        vm.warp(uint256(expectedExp) + 91 days);

        vm.prank(keeper);
        vm.expectRevert(EnsAutoRenewer.OutOfWindow.selector);
        renewer.execute(jobId, 365 days);
    }

    // -----------------------------------------------------------------
    // cancel
    // -----------------------------------------------------------------

    function test_cancel_refundsOwner() public {
        uint256 budget = 0.05 ether;
        uint256 bounty = 0.01 ether;
        (uint256 jobId, uint256 fee) = _register(owner1, budget, bounty);

        uint256 ownerBefore = owner1.balance;
        vm.prank(owner1);
        renewer.cancel(jobId);

        // Fee is non-refundable (it left for treasury at register time).
        assertEq(owner1.balance - ownerBefore, budget + bounty);
        assertGt(fee, 0);

        EnsAutoRenewer.Job memory j = renewer.getJob(jobId);
        assertTrue(j.settled);
        assertEq(j.renewalBudget, 0);
        assertEq(j.bounty, 0);
    }

    function test_cancel_onlyOwner() public {
        (uint256 jobId, ) = _register(owner1, 0.05 ether, 0.01 ether);

        vm.prank(owner2);
        vm.expectRevert(EnsAutoRenewer.NotOwner.selector);
        renewer.cancel(jobId);
    }

    function test_cancel_thenExecuteReverts() public {
        (uint256 jobId, ) = _register(owner1, 0.05 ether, 0.01 ether);
        vm.prank(owner1);
        renewer.cancel(jobId);

        vm.warp(uint256(expectedExp) - 10 days);
        vm.prank(keeper);
        vm.expectRevert(EnsAutoRenewer.AlreadySettled.selector);
        renewer.execute(jobId, 365 days);
    }

    // -----------------------------------------------------------------
    // updateExpectation
    // -----------------------------------------------------------------

    function test_updateExpectation_onlyOwner() public {
        (uint256 jobId, ) = _register(owner1, 0.05 ether, 0.01 ether);
        vm.prank(owner2);
        vm.expectRevert(EnsAutoRenewer.NotOwner.selector);
        renewer.updateExpectation(jobId, expectedExp + 365 days);
    }

    function test_updateExpectation_movesWindow() public {
        (uint256 jobId, ) = _register(owner1, 0.05 ether, 0.01 ether);
        vm.warp(uint256(expectedExp) - 10 days);
        // Currently in-window.
        assertTrue(renewer.isExecutable(jobId));

        // Owner pushes expiration out a year.
        vm.prank(owner1);
        renewer.updateExpectation(jobId, expectedExp + 365 days);

        // No longer in-window.
        assertFalse(renewer.isExecutable(jobId));
    }

    // -----------------------------------------------------------------
    // Treasury admin
    // -----------------------------------------------------------------

    function test_setProtocolFee_treasuryOnly() public {
        vm.prank(owner1);
        vm.expectRevert(EnsAutoRenewer.NotTreasury.selector);
        renewer.setProtocolFee(100);

        vm.prank(TREASURY);
        renewer.setProtocolFee(100);
        assertEq(renewer.protocolFeeBps(), 100);
    }

    function test_setProtocolFee_revertsAboveCap() public {
        vm.prank(TREASURY);
        vm.expectRevert(EnsAutoRenewer.FeeAboveCap.selector);
        renewer.setProtocolFee(MAX_FEE_BPS + 1);
    }

    function test_setTreasury_works() public {
        address newT = address(0xDEADBEEF);
        vm.prank(TREASURY);
        renewer.setTreasury(newT);
        assertEq(renewer.treasury(), newT);
    }

    function test_setTreasury_zeroReverts() public {
        vm.prank(TREASURY);
        vm.expectRevert(EnsAutoRenewer.ZeroAddress.selector);
        renewer.setTreasury(address(0));
    }

    // -----------------------------------------------------------------
    // Multi-user
    // -----------------------------------------------------------------

    function test_multiUser_independentJobs() public {
        (uint256 j1, ) = _register(owner1, 0.05 ether, 0.01 ether);
        (uint256 j2, ) = _register(owner2, 0.07 ether, 0.02 ether);

        assertEq(j1, 0);
        assertEq(j2, 1);
        assertEq(renewer.totalJobs(), 2);

        uint256[] memory o1 = renewer.jobsByOwner(owner1);
        uint256[] memory o2 = renewer.jobsByOwner(owner2);
        assertEq(o1.length, 1);
        assertEq(o2.length, 1);
        assertEq(o1[0], 0);
        assertEq(o2[0], 1);

        vm.warp(uint256(expectedExp) - 10 days);

        vm.prank(keeper);
        renewer.execute(j1, 365 days);

        EnsAutoRenewer.Job memory a = renewer.getJob(j1);
        EnsAutoRenewer.Job memory b = renewer.getJob(j2);
        assertTrue(a.settled);
        assertFalse(b.settled);
    }

    // -----------------------------------------------------------------
    // Transfer failure
    // -----------------------------------------------------------------

    function test_send_failsWhenKeeperRejects() public {
        RevertingReceiver bad = new RevertingReceiver();
        (uint256 jobId, ) = _register(owner1, 0.05 ether, 0.01 ether);
        vm.warp(uint256(expectedExp) - 10 days);

        vm.prank(address(bad));
        vm.expectRevert(EnsAutoRenewer.TransferFailed.selector);
        renewer.execute(jobId, 365 days);
    }
}
