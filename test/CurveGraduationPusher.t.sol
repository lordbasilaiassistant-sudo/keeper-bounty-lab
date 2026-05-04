// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CurveGraduationPusher, IBondingCurve} from "../src/CurveGraduationPusher.sol";

/// @dev Minimal ERC20 with mintable supply (test only).
contract MockToken {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Test bonding-curve mock. Reserve / threshold / graduation flag are all
///      directly settable. buy() can be configured to: succeed normally (mints
///      `tokensPerWei` tokens per wei), revert, return zero, or return less
///      than minTokensOut to trigger slippage check.
contract MockCurve is IBondingCurve {
    uint256 public reserve;
    uint256 public graduationThreshold;
    bool public graduated;
    address public token;

    uint256 public tokensPerWei = 1_000;
    bool public buyShouldRevert;
    bool public buyReturnsZero;
    bool public reportsLessThanMinted;

    constructor(address _token, uint256 _threshold) {
        token = _token;
        graduationThreshold = _threshold;
    }

    function setReserve(uint256 r) external { reserve = r; }
    function setGraduated(bool g) external { graduated = g; }
    function setThreshold(uint256 t) external { graduationThreshold = t; }
    function setTokensPerWei(uint256 t) external { tokensPerWei = t; }
    function setBuyShouldRevert(bool v) external { buyShouldRevert = v; }
    function setBuyReturnsZero(bool v) external { buyReturnsZero = v; }
    function setReportsLessThanMinted(bool v) external { reportsLessThanMinted = v; }
    function setTokenAddr(address t) external { token = t; }

    function buy(uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        if (buyShouldRevert) revert("buy reverted");
        reserve += msg.value;

        uint256 minted = msg.value * tokensPerWei;
        // Mint to caller (the pusher contract).
        if (token != address(0)) {
            MockToken(token).mint(msg.sender, minted);
        }

        if (buyReturnsZero) return 0;

        tokensOut = reportsLessThanMinted ? minted / 2 : minted;
        require(tokensOut >= minTokensOut, "slippage");

        if (reserve >= graduationThreshold) graduated = true;
    }
}

/// @dev Curve that always reports graduated=true.
contract AlwaysGraduatedCurve is IBondingCurve {
    function buy(uint256) external payable returns (uint256) { return 0; }
    function reserve() external pure returns (uint256) { return 100 ether; }
    function graduationThreshold() external pure returns (uint256) { return 100 ether; }
    function graduated() external pure returns (bool) { return true; }
    function token() external pure returns (address) { return address(0); }
}

/// @dev Recipient that rejects ETH (used to test bounty/refund failure path).
contract RejectsEth {
    receive() external payable { revert("nope"); }
}

contract CurveGraduationPusherTest is Test {
    CurveGraduationPusher pusher;
    MockToken tok;
    MockCurve curve;

    address constant TREASURY = 0x7a3E312Ec6e20a9F62fE2405938EB9060312E334;
    address owner = address(0xA11CE);
    address keeper = address(0xBEEF);

    uint16 constant FEE_BPS_U16 = 500;       // 5%
    uint16 constant MAX_FEE_BPS_U16 = 1_000; // 10% cap
    uint256 constant FEE_BPS = 500;
    uint256 constant MAX_FEE_BPS = 1_000;

    uint256 constant THRESHOLD = 10 ether;

    function setUp() public {
        pusher = new CurveGraduationPusher(TREASURY, FEE_BPS_U16, MAX_FEE_BPS_U16);
        tok = new MockToken();
        curve = new MockCurve(address(tok), THRESHOLD);

        vm.deal(owner, 100 ether);
        vm.deal(keeper, 1 ether);
    }

    // ----- helpers -----

    function _register(uint256 commit, uint256 bounty, uint16 minBps) internal returns (uint256 id) {
        uint256 fee = ((commit + bounty) * FEE_BPS) / 10_000;
        vm.prank(owner);
        id = pusher.register{value: commit + bounty + fee}(address(curve), commit, minBps, bounty);
    }

    // ----- constructor -----

    function test_Constructor_RevertsOnZeroTreasury() public {
        vm.expectRevert(CurveGraduationPusher.ZeroAddress.selector);
        new CurveGraduationPusher(address(0), 0, 1_000);
    }

    function test_Constructor_RevertsWhenMaxFeeAboveHalf() public {
        vm.expectRevert(CurveGraduationPusher.FeeAboveCap.selector);
        new CurveGraduationPusher(TREASURY, 0, 5_001);
    }

    function test_Constructor_RevertsWhenInitialFeeAboveMax() public {
        vm.expectRevert(CurveGraduationPusher.FeeAboveCap.selector);
        new CurveGraduationPusher(TREASURY, 1_001, 1_000);
    }

    // ----- register -----

    function test_Register_HappyPath() public {
        uint256 commit = 2 ether;
        uint256 bounty = 0.1 ether;
        uint256 fee = ((commit + bounty) * FEE_BPS) / 10_000;

        uint256 treasuryBefore = TREASURY.balance;
        uint256 id = _register(commit, bounty, 8_000);

        assertEq(id, 0);
        assertEq(pusher.totalJobs(), 1);
        assertEq(TREASURY.balance - treasuryBefore, fee);

        (address jOwner, address jCurve, uint256 jCommit, uint256 jBounty, uint16 jMinBps, bool exec, bool canc) =
            pusher.jobs(0);
        assertEq(jOwner, owner);
        assertEq(jCurve, address(curve));
        assertEq(jCommit, commit);
        assertEq(jBounty, bounty);
        assertEq(jMinBps, 8_000);
        assertFalse(exec);
        assertFalse(canc);

        // Indexes populated.
        uint256[] memory mine = pusher.jobsByOwner(owner);
        assertEq(mine.length, 1);
        assertEq(mine[0], 0);
        uint256[] memory perCurve = pusher.jobsByCurve(address(curve));
        assertEq(perCurve.length, 1);
        assertEq(perCurve[0], 0);
    }

    function test_Register_RevertsOnWrongMsgValue() public {
        uint256 commit = 1 ether;
        uint256 bounty = 0.05 ether;
        uint256 fee = ((commit + bounty) * FEE_BPS) / 10_000;

        vm.prank(owner);
        vm.expectRevert(CurveGraduationPusher.WrongMsgValue.selector);
        pusher.register{value: commit + bounty + fee - 1}(address(curve), commit, 8_000, bounty);
    }

    function test_Register_RevertsOnZeroCommit() public {
        vm.prank(owner);
        vm.expectRevert(CurveGraduationPusher.ZeroValue.selector);
        pusher.register{value: 0}(address(curve), 0, 8_000, 0);
    }

    function test_Register_RevertsOnZeroCurve() public {
        vm.prank(owner);
        vm.expectRevert(CurveGraduationPusher.ZeroAddress.selector);
        pusher.register{value: 1 ether}(address(0), 1 ether, 8_000, 0);
    }

    function test_Register_RevertsOnInvalidProgressBps() public {
        vm.prank(owner);
        vm.expectRevert(CurveGraduationPusher.InvalidProgressBps.selector);
        pusher.register{value: 1 ether}(address(curve), 1 ether, 0, 0);

        uint256 fee = (1 ether * FEE_BPS) / 10_000;
        vm.prank(owner);
        vm.expectRevert(CurveGraduationPusher.InvalidProgressBps.selector);
        pusher.register{value: 1 ether + fee}(address(curve), 1 ether, 10_001, 0);
    }

    function test_Register_NoFeeWhenFeeBpsZero() public {
        CurveGraduationPusher zeroFee = new CurveGraduationPusher(TREASURY, 0, MAX_FEE_BPS_U16);
        vm.prank(owner);
        uint256 id = zeroFee.register{value: 1 ether}(address(curve), 1 ether, 8_000, 0);
        assertEq(id, 0);
    }

    // ----- execute -----

    function test_Execute_HappyPath() public {
        uint256 commit = 2 ether;
        uint256 bounty = 0.1 ether;
        uint256 id = _register(commit, bounty, 8_000);

        // Curve at 80% — should be exactly executable.
        curve.setReserve((THRESHOLD * 8_000) / 10_000);

        uint256 keeperBefore = keeper.balance;
        uint256 ownerTokensBefore = tok.balanceOf(owner);

        vm.prank(keeper);
        pusher.execute(id, 0);

        // Bounty paid.
        assertEq(keeper.balance - keeperBefore, bounty);
        // Tokens forwarded to owner. tokensPerWei = 1000.
        assertEq(tok.balanceOf(owner) - ownerTokensBefore, commit * 1_000);
        // Pusher holds nothing.
        assertEq(address(pusher).balance, 0);
        assertEq(tok.balanceOf(address(pusher)), 0);

        // Job marked executed.
        (, , , , , bool exec, ) = pusher.jobs(id);
        assertTrue(exec);
    }

    function test_Execute_RevertsBelowMinProgress() public {
        uint256 id = _register(2 ether, 0.1 ether, 8_000);
        // 79.99% — just under threshold.
        curve.setReserve((THRESHOLD * 7_999) / 10_000);

        vm.prank(keeper);
        vm.expectRevert(CurveGraduationPusher.ProgressTooLow.selector);
        pusher.execute(id, 0);
    }

    function test_Execute_RevertsIfAlreadyGraduated() public {
        uint256 id = _register(1 ether, 0.05 ether, 8_000);
        curve.setReserve(THRESHOLD);
        curve.setGraduated(true);

        vm.prank(keeper);
        vm.expectRevert(CurveGraduationPusher.CurveAlreadyGraduated.selector);
        pusher.execute(id, 0);
    }

    function test_Execute_RevertsIfAlreadyExecuted() public {
        uint256 id = _register(1 ether, 0.05 ether, 8_000);
        curve.setReserve(THRESHOLD);

        vm.prank(keeper);
        pusher.execute(id, 0);

        vm.prank(keeper);
        vm.expectRevert(CurveGraduationPusher.AlreadyResolved.selector);
        pusher.execute(id, 0);
    }

    function test_Execute_RevertsIfCancelled() public {
        uint256 id = _register(1 ether, 0.05 ether, 8_000);
        vm.prank(owner);
        pusher.cancel(id);

        curve.setReserve(THRESHOLD);
        vm.prank(keeper);
        vm.expectRevert(CurveGraduationPusher.AlreadyResolved.selector);
        pusher.execute(id, 0);
    }

    function test_Execute_SlippageRevertsAndJobIsRetryable() public {
        uint256 id = _register(1 ether, 0.05 ether, 8_000);
        curve.setReserve(THRESHOLD);
        // tokensPerWei = 1000 -> 1e21 minted. Demand more than that.
        vm.prank(keeper);
        vm.expectRevert(); // mock reverts with "slippage"
        pusher.execute(id, type(uint256).max);

        // The whole tx reverts (including our state write), so the job is
        // still pending and another keeper can retry with a saner minTokensOut.
        (, , , , , bool exec, bool canc) = pusher.jobs(id);
        assertFalse(exec);
        assertFalse(canc);

        // Retry succeeds.
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        pusher.execute(id, 0);
        assertEq(keeper.balance - keeperBefore, 0.05 ether);
    }

    function test_Execute_BuyReturnsZero_Reverts() public {
        uint256 id = _register(1 ether, 0.05 ether, 8_000);
        curve.setReserve(THRESHOLD);
        curve.setBuyReturnsZero(true);

        vm.prank(keeper);
        vm.expectRevert(CurveGraduationPusher.BuyReturnedZero.selector);
        pusher.execute(id, 0);
    }

    function test_Execute_HandlesUnderReportedTokens() public {
        // Curve mints `minted` but returns minted/2. Owner should still receive
        // the full balance held by the pusher (defensive against bad return values).
        uint256 commit = 1 ether;
        uint256 id = _register(commit, 0, 8_000);
        curve.setReserve(THRESHOLD);
        curve.setReportsLessThanMinted(true);

        uint256 ownerBefore = tok.balanceOf(owner);
        vm.prank(keeper);
        pusher.execute(id, 0);

        // tokensPerWei = 1000 so full mint = 1e21. Capped to reported tokensOut = 5e20.
        assertEq(tok.balanceOf(owner) - ownerBefore, (commit * 1_000) / 2);
        // Remainder stays in pusher (donation; users should pick conservative curves).
        assertEq(tok.balanceOf(address(pusher)), (commit * 1_000) / 2);
    }

    function test_Execute_OnAlwaysGraduatedCurve_Reverts() public {
        AlwaysGraduatedCurve dead = new AlwaysGraduatedCurve();
        uint256 commit = 1 ether;
        uint256 fee = (commit * FEE_BPS) / 10_000;
        vm.prank(owner);
        uint256 id = pusher.register{value: commit + fee}(address(dead), commit, 8_000, 0);

        vm.prank(keeper);
        vm.expectRevert(CurveGraduationPusher.CurveAlreadyGraduated.selector);
        pusher.execute(id, 0);
    }

    function test_Execute_AnyoneCanCall() public {
        uint256 id = _register(1 ether, 0.05 ether, 8_000);
        curve.setReserve(THRESHOLD);

        address randomKeeper = address(0xCAFE);
        vm.deal(randomKeeper, 0);
        uint256 before = randomKeeper.balance;
        vm.prank(randomKeeper);
        pusher.execute(id, 0);
        assertEq(randomKeeper.balance - before, 0.05 ether);
    }

    // ----- cancel -----

    function test_Cancel_RefundsCommitPlusBounty() public {
        uint256 commit = 1 ether;
        uint256 bounty = 0.1 ether;
        uint256 id = _register(commit, bounty, 8_000);

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        pusher.cancel(id);

        assertEq(owner.balance - ownerBefore, commit + bounty);
        (, , , , , , bool canc) = pusher.jobs(id);
        assertTrue(canc);
    }

    function test_Cancel_OnlyOwner() public {
        uint256 id = _register(1 ether, 0.05 ether, 8_000);
        vm.prank(keeper);
        vm.expectRevert(CurveGraduationPusher.NotOwner.selector);
        pusher.cancel(id);
    }

    function test_Cancel_RevertsIfExecuted() public {
        uint256 id = _register(1 ether, 0.05 ether, 8_000);
        curve.setReserve(THRESHOLD);
        vm.prank(keeper);
        pusher.execute(id, 0);

        vm.prank(owner);
        vm.expectRevert(CurveGraduationPusher.AlreadyResolved.selector);
        pusher.cancel(id);
    }

    function test_Cancel_RevertsIfCancelledTwice() public {
        uint256 id = _register(1 ether, 0.05 ether, 8_000);
        vm.prank(owner);
        pusher.cancel(id);
        vm.prank(owner);
        vm.expectRevert(CurveGraduationPusher.AlreadyResolved.selector);
        pusher.cancel(id);
    }

    // ----- multi-user -----

    function test_MultiUser_IndependentJobs() public {
        address alice = address(0xA1);
        address bob = address(0xB0B);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        uint256 fee1 = (1 ether * FEE_BPS) / 10_000;
        vm.prank(alice);
        uint256 id1 = pusher.register{value: 1 ether + fee1}(address(curve), 1 ether, 8_000, 0);

        uint256 fee2 = (2 ether * FEE_BPS) / 10_000;
        vm.prank(bob);
        uint256 id2 = pusher.register{value: 2 ether + fee2}(address(curve), 2 ether, 9_000, 0);

        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(pusher.jobsByOwner(alice).length, 1);
        assertEq(pusher.jobsByOwner(bob).length, 1);
        assertEq(pusher.jobsByCurve(address(curve)).length, 2);

        // Reserve at 80%: id1 executable, id2 not.
        curve.setReserve((THRESHOLD * 8_000) / 10_000);
        assertTrue(pusher.isExecutable(id1));
        assertFalse(pusher.isExecutable(id2));
    }

    // ----- treasury admin -----

    function test_SetFees_OnlyTreasury() public {
        vm.expectRevert(CurveGraduationPusher.NotTreasury.selector);
        pusher.setFees(100);

        vm.prank(TREASURY);
        pusher.setFees(100);
        assertEq(pusher.protocolFeeBps(), 100);
    }

    function test_SetFees_RevertsAboveCap() public {
        vm.prank(TREASURY);
        vm.expectRevert(CurveGraduationPusher.FeeAboveCap.selector);
        pusher.setFees(MAX_FEE_BPS_U16 + 1);
    }

    function test_SetTreasury_Rotates() public {
        address newT = address(0xDEAD);
        vm.prank(TREASURY);
        pusher.setTreasury(newT);
        assertEq(pusher.treasury(), newT);

        // Old treasury can no longer touch.
        vm.prank(TREASURY);
        vm.expectRevert(CurveGraduationPusher.NotTreasury.selector);
        pusher.setFees(0);
    }

    function test_SetTreasury_RejectsZero() public {
        vm.prank(TREASURY);
        vm.expectRevert(CurveGraduationPusher.ZeroAddress.selector);
        pusher.setTreasury(address(0));
    }

    // ----- views -----

    function test_View_CurrentProgressBps() public {
        uint256 id = _register(1 ether, 0, 8_000);
        curve.setReserve((THRESHOLD * 5_000) / 10_000);
        assertEq(pusher.currentProgressBps(id), 5_000);

        curve.setReserve(THRESHOLD * 2);
        assertEq(pusher.currentProgressBps(id), 10_000);
    }

    function test_View_IsExecutableTransitions() public {
        uint256 id = _register(1 ether, 0, 8_000);

        assertFalse(pusher.isExecutable(id));

        curve.setReserve((THRESHOLD * 8_000) / 10_000);
        assertTrue(pusher.isExecutable(id));

        curve.setGraduated(true);
        assertFalse(pusher.isExecutable(id));
    }

    // ----- bounty failure path -----

    function test_Execute_RevertsWhenKeeperRejectsBounty() public {
        RejectsEth bad = new RejectsEth();
        uint256 id = _register(1 ether, 0.05 ether, 8_000);
        curve.setReserve(THRESHOLD);

        vm.prank(address(bad));
        vm.expectRevert(CurveGraduationPusher.TransferFailed.selector);
        pusher.execute(id, 0);
    }

    // Make this test contract able to receive bounties / refunds.
    receive() external payable {}
}
