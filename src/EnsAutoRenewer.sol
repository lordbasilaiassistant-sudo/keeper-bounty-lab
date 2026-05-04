// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title EnsAutoRenewer
/// @notice Multi-user ENS auto-renewal vault. ENS holders pre-fund a renewal
///         (rent budget + keeper bounty + protocol fee). Once the name enters
///         its renewal window, anyone can call execute() to push the renewal
///         to the configured ENS controller and earn the bounty.
/// @dev    The contract is intentionally agnostic to which controller is used,
///         since ENS has shipped multiple ETHRegistrarController deployments.
///         The mainnet ETHRegistrarController is documented in the README at
///         0x253553366Da8546fC250F225fe3d25d0C782303b. Its renew signature is
///         renew(string name, uint256 duration) external payable.
///         Owners pass the *unhashed* label (e.g. "vitalik" for vitalik.eth).
interface IEthRegistrarController {
    function renew(string calldata name, uint256 duration) external payable;
}

contract EnsAutoRenewer {
    struct Job {
        address owner;
        address controller;
        string name;
        uint64 expectedExpiration;
        uint64 lastRenewedAt;
        uint256 renewalBudget;
        uint256 bounty;
        bool settled;
    }

    Job[] private _jobs;
    mapping(address => uint256[]) private _byOwner;

    address public treasury;
    uint16 public protocolFeeBps;

    uint16 public immutable maxProtocolFeeBps;
    uint64 public immutable renewalWindow;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    event JobRegistered(
        uint256 indexed jobId,
        address indexed owner,
        address indexed controller,
        string name,
        uint64 expectedExpiration,
        uint256 renewalBudget,
        uint256 bounty,
        uint256 protocolFee
    );
    event JobExecuted(
        uint256 indexed jobId,
        address indexed keeper,
        uint256 durationSecs,
        uint256 renewalSpent,
        uint256 keeperPaid,
        uint256 refundedToOwner
    );
    event JobCancelled(uint256 indexed jobId, uint256 refunded);
    event ExpectationUpdated(uint256 indexed jobId, uint64 newExpectedExpiration);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeeUpdated(uint16 newProtocolFeeBps);

    error NotOwner();
    error NotTreasury();
    error AlreadySettled();
    error OutOfWindow();
    error ZeroAddress();
    error ZeroValue();
    error EmptyName();
    error ZeroDuration();
    error FeeAboveCap();
    error WrongMsgValue();
    error TransferFailed();
    error RenewCallFailed();

    modifier onlyJobOwner(uint256 jobId) {
        if (_jobs[jobId].owner != msg.sender) revert NotOwner();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(
        address _treasury,
        uint16 _protocolFeeBps,
        uint16 _maxProtocolFeeBps,
        uint64 _renewalWindow
    ) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_maxProtocolFeeBps > BPS_DENOMINATOR / 2) revert FeeAboveCap();
        if (_protocolFeeBps > _maxProtocolFeeBps) revert FeeAboveCap();
        if (_renewalWindow == 0) revert ZeroValue();

        treasury = _treasury;
        protocolFeeBps = _protocolFeeBps;
        maxProtocolFeeBps = _maxProtocolFeeBps;
        renewalWindow = _renewalWindow;
    }

    /// @notice Register an auto-renewal job. msg.value must equal
    ///         renewalEthBudget + bountyAmount + protocolFee, where
    ///         protocolFee = bountyAmount * protocolFeeBps / BPS_DENOMINATOR.
    /// @param ensController The ENS ETHRegistrarController to call. See README
    ///        for the canonical mainnet address.
    /// @param name The unhashed label, e.g. "vitalik" for vitalik.eth.
    /// @param expectedExpirationTs The owner's belief about when the name
    ///        expires. Used to compute the renewal window. Owners can update
    ///        this with updateExpectation() if a renewal happens off-band.
    /// @param renewalEthBudget Max ETH the keeper can forward to the
    ///        controller's renew() call. Anything not consumed by the
    ///        controller (it refunds overpayment) flows back to the owner.
    /// @param bountyAmount Flat ETH paid to the keeper on successful execute().
    function register(
        address ensController,
        string calldata name,
        uint64 expectedExpirationTs,
        uint256 renewalEthBudget,
        uint256 bountyAmount
    ) external payable returns (uint256 jobId) {
        if (ensController == address(0)) revert ZeroAddress();
        if (bytes(name).length == 0) revert EmptyName();
        if (renewalEthBudget == 0) revert ZeroValue();
        if (bountyAmount == 0) revert ZeroValue();

        uint256 fee = (bountyAmount * protocolFeeBps) / BPS_DENOMINATOR;
        if (msg.value != renewalEthBudget + bountyAmount + fee) revert WrongMsgValue();

        jobId = _jobs.length;
        _jobs.push(Job({
            owner: msg.sender,
            controller: ensController,
            name: name,
            expectedExpiration: expectedExpirationTs,
            lastRenewedAt: 0,
            renewalBudget: renewalEthBudget,
            bounty: bountyAmount,
            settled: false
        }));
        _byOwner[msg.sender].push(jobId);

        emit JobRegistered(
            jobId,
            msg.sender,
            ensController,
            name,
            expectedExpirationTs,
            renewalEthBudget,
            bountyAmount,
            fee
        );

        if (fee > 0) _send(treasury, fee);
    }

    /// @notice Execute a renewal job. Anyone can call within the renewal
    ///         window. Forwards renewalBudget to the ENS controller and pays
    ///         the keeper their bounty. Any ETH refunded by the controller
    ///         (overpayment) is returned to the job owner.
    function execute(uint256 jobId, uint256 durationSecs) external {
        Job storage j = _jobs[jobId];
        if (j.settled) revert AlreadySettled();
        if (durationSecs == 0) revert ZeroDuration();
        if (!_inWindow(j.expectedExpiration)) revert OutOfWindow();

        address controller = j.controller;
        string memory name = j.name;
        uint256 budget = j.renewalBudget;
        uint256 bounty = j.bounty;
        address jobOwner = j.owner;

        // Effects: settle before any external call.
        j.settled = true;
        j.renewalBudget = 0;
        j.bounty = 0;
        j.lastRenewedAt = uint64(block.timestamp);

        // Interactions.
        uint256 balanceBefore = address(this).balance;
        try IEthRegistrarController(controller).renew{value: budget}(name, durationSecs) {
            // ok
        } catch {
            revert RenewCallFailed();
        }
        uint256 balanceAfter = address(this).balance;

        // Refund whatever the controller sent back (some controllers refund
        // overpayment via msg.sender.call). balanceBefore - balanceAfter is
        // the actual spend; the difference vs budget is the refund.
        uint256 spent = balanceBefore - balanceAfter;
        uint256 refund = budget - spent;

        emit JobExecuted(jobId, msg.sender, durationSecs, spent, bounty, refund);

        _send(msg.sender, bounty);
        if (refund > 0) _send(jobOwner, refund);
    }

    /// @notice Owner-only refund. Returns escrowed renewalBudget + bounty.
    function cancel(uint256 jobId) external onlyJobOwner(jobId) {
        Job storage j = _jobs[jobId];
        if (j.settled) revert AlreadySettled();

        uint256 refund = j.renewalBudget + j.bounty;
        j.renewalBudget = 0;
        j.bounty = 0;
        j.settled = true;

        emit JobCancelled(jobId, refund);

        _send(msg.sender, refund);
    }

    /// @notice Owner can update their stored expectation of the expiration
    ///         (e.g., after a manual renewal somewhere else moved the date).
    function updateExpectation(uint256 jobId, uint64 newExpectedExpirationTs)
        external
        onlyJobOwner(jobId)
    {
        Job storage j = _jobs[jobId];
        if (j.settled) revert AlreadySettled();
        j.expectedExpiration = newExpectedExpirationTs;
        emit ExpectationUpdated(jobId, newExpectedExpirationTs);
    }

    function setProtocolFee(uint16 newProtocolFeeBps) external onlyTreasury {
        if (newProtocolFeeBps > maxProtocolFeeBps) revert FeeAboveCap();
        protocolFeeBps = newProtocolFeeBps;
        emit ProtocolFeeUpdated(newProtocolFeeBps);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function totalJobs() external view returns (uint256) {
        return _jobs.length;
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        return _jobs[jobId];
    }

    function jobsByOwner(address owner) external view returns (uint256[] memory) {
        return _byOwner[owner];
    }

    function isExecutable(uint256 jobId) external view returns (bool) {
        Job storage j = _jobs[jobId];
        if (j.settled) return false;
        return _inWindow(j.expectedExpiration);
    }

    function quoteProtocolFee(uint256 bountyAmount) external view returns (uint256) {
        return (bountyAmount * protocolFeeBps) / BPS_DENOMINATOR;
    }

    function _inWindow(uint64 expectedExpiration) private view returns (bool) {
        // Window = [expectedExpiration - renewalWindow, expectedExpiration + 90 days].
        // ENS grace period is 90 days, so even an expired-but-not-released
        // name can still be renewed by the holder.
        uint256 exp = uint256(expectedExpiration);
        uint256 win = uint256(renewalWindow);
        uint256 windowStart = exp > win ? exp - win : 0;
        uint256 windowEnd = exp + 90 days;
        return block.timestamp >= windowStart && block.timestamp <= windowEnd;
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Required to receive controller refunds for overpayment.
    receive() external payable {}
}
