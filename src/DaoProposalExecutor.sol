// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DaoProposalExecutor
/// @notice Keeper-bounty registry for executing passed-but-stalled DAO proposals.
///         A proposer (or any third party) pre-funds a bounty for executing a
///         specific governance call. The bounty ramps up linearly with time so
///         long-stalled proposals become increasingly attractive to keepers.
/// @dev Generic across governance frameworks — caller supplies (dao, selector,
///      calldata). Strict checks-effects-interactions around the external
///      dao.execute() call (no reentrancy guard import).
contract DaoProposalExecutor {
    enum Status {
        None,
        Active,
        Executed,
        Cancelled
    }

    struct Job {
        address owner;
        address dao;
        bytes4 executeSelector;
        Status status;
        uint64 registeredAt;
        uint256 bountyBase;
        uint16 multiplierBps;
        uint16 bountyMaxMultiplier;
        uint32 daysToMax;
        uint256 escrow;
        bytes executeCalldata;
    }

    Job[] private _jobs;
    mapping(address => uint256[]) private _byOwner;

    address public treasury;
    uint16 public feeBps;

    uint16 public immutable maxFeeBps;
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @dev bountyMaxMultiplier is expressed in bps where 10_000 = 1x. So
    ///      30_000 means bounty can grow up to 3x the base. Upper bound is
    ///      the natural uint16 ceiling of 65_535 (6.5535x growth) which keeps
    ///      escrow math sane and prevents accidental "100x" mistakes.

    event Registered(
        uint256 indexed jobId,
        address indexed owner,
        address indexed dao,
        bytes4 executeSelector,
        uint256 bountyBase,
        uint16 multiplierBps,
        uint16 bountyMaxMultiplier,
        uint32 daysToMax,
        uint256 escrow
    );
    event Executed(
        uint256 indexed jobId,
        address indexed keeper,
        uint256 bountyPaid,
        uint256 feePaid,
        uint256 refundedToOwner
    );
    event Cancelled(uint256 indexed jobId, address indexed owner, uint256 refunded);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeeUpdated(uint16 newFeeBps);

    error NotOwner();
    error NotTreasury();
    error ZeroAddress();
    error ZeroValue();
    error BadStatus();
    error FeeAboveCap();
    error MultiplierOutOfRange();
    error DaysToMaxZero();
    error EmptyCalldata();
    error SelectorMismatch();
    error InsufficientDeposit();
    error DaoCallFailed();
    error TransferFailed();

    modifier onlyOwnerOf(uint256 jobId) {
        if (_jobs[jobId].owner != msg.sender) revert NotOwner();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(address _treasury, uint16 _feeBps, uint16 _maxFeeBps) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_maxFeeBps > BPS_DENOMINATOR / 2) revert FeeAboveCap();
        if (_feeBps > _maxFeeBps) revert FeeAboveCap();
        treasury = _treasury;
        feeBps = _feeBps;
        maxFeeBps = _maxFeeBps;
    }

    /// @notice Register a bounty for executing a governance proposal.
    /// @dev Caller must send msg.value >= maxBounty + maxFeeOnMaxBounty so the
    ///      contract is always solvent regardless of when the keeper claims.
    ///      Any unused escrow refunds to the owner on execute().
    /// @param dao Governance contract that will receive the execute call.
    /// @param executeSelector First 4 bytes of executeCalldata, supplied
    ///        explicitly so anyone reading registry events can index by it.
    /// @param executeCalldata Full calldata for the dao.execute() call.
    /// @param bountyBase Bounty paid if a keeper executes immediately (t=0).
    /// @param multiplierBps Linear growth per day, in bps relative to base.
    ///        e.g. 1_000 = +10% of base per day, applied as days/daysToMax.
    /// @param bountyMaxMultiplier Hard cap on the multiplier in bps where
    ///        10_000 = 1x. Must be >= BPS_DENOMINATOR.
    /// @param daysToMax Days at which the multiplier reaches (1 + multiplierBps/BPS).
    ///        Past this point the linear term keeps growing until the cap.
    function register(
        address dao,
        bytes4 executeSelector,
        bytes calldata executeCalldata,
        uint256 bountyBase,
        uint16 multiplierBps,
        uint16 bountyMaxMultiplier,
        uint32 daysToMax
    ) external payable returns (uint256 jobId) {
        if (dao == address(0)) revert ZeroAddress();
        if (bountyBase == 0) revert ZeroValue();
        if (executeCalldata.length < 4) revert EmptyCalldata();
        if (bytes4(executeCalldata[:4]) != executeSelector) revert SelectorMismatch();
        // bountyMaxMultiplier must be >= 1x. Upper bound is enforced by uint16
        // (max 6.5535x growth — escrow ceiling stays sane).
        if (bountyMaxMultiplier < BPS_DENOMINATOR) revert MultiplierOutOfRange();
        if (daysToMax == 0) revert DaysToMaxZero();

        uint256 maxBounty = (bountyBase * uint256(bountyMaxMultiplier)) / BPS_DENOMINATOR;
        uint256 maxFeeAtMax = (maxBounty * uint256(maxFeeBps)) / BPS_DENOMINATOR;
        uint256 required = maxBounty + maxFeeAtMax;
        if (msg.value < required) revert InsufficientDeposit();

        jobId = _jobs.length;
        _jobs.push(
            Job({
                owner: msg.sender,
                dao: dao,
                executeSelector: executeSelector,
                status: Status.Active,
                registeredAt: uint64(block.timestamp),
                bountyBase: bountyBase,
                multiplierBps: multiplierBps,
                bountyMaxMultiplier: bountyMaxMultiplier,
                daysToMax: daysToMax,
                escrow: msg.value,
                executeCalldata: executeCalldata
            })
        );
        _byOwner[msg.sender].push(jobId);

        emit Registered(
            jobId,
            msg.sender,
            dao,
            executeSelector,
            bountyBase,
            multiplierBps,
            bountyMaxMultiplier,
            daysToMax,
            msg.value
        );
    }

    /// @notice Compute the bounty payable to a keeper at the current timestamp.
    function currentBounty(uint256 jobId) public view returns (uint256) {
        Job storage j = _jobs[jobId];
        return _bountyAt(j, block.timestamp);
    }

    /// @notice Compute the bounty payable at an arbitrary timestamp. Useful
    ///         for keepers deciding whether to wait.
    function bountyAt(uint256 jobId, uint256 timestamp) external view returns (uint256) {
        Job storage j = _jobs[jobId];
        return _bountyAt(j, timestamp);
    }

    function _bountyAt(Job storage j, uint256 timestamp) internal view returns (uint256) {
        if (timestamp <= j.registeredAt) {
            return j.bountyBase;
        }
        uint256 elapsedDays = (timestamp - j.registeredAt) / 1 days;
        // multiplier in bps = BPS_DENOMINATOR + multiplierBps * elapsedDays / daysToMax
        // Cap at j.bountyMaxMultiplier.
        uint256 growth = (uint256(j.multiplierBps) * elapsedDays) / uint256(j.daysToMax);
        uint256 multiplier = uint256(BPS_DENOMINATOR) + growth;
        if (multiplier > uint256(j.bountyMaxMultiplier)) {
            multiplier = uint256(j.bountyMaxMultiplier);
        }
        return (j.bountyBase * multiplier) / BPS_DENOMINATOR;
    }

    /// @notice Compute the protocol fee payable on top of the keeper bounty.
    function currentFee(uint256 jobId) public view returns (uint256) {
        return (currentBounty(jobId) * uint256(feeBps)) / BPS_DENOMINATOR;
    }

    /// @notice Anyone can call. Forwards the registered calldata to the DAO.
    ///         If the DAO call succeeds, keeper is paid the current bounty,
    ///         treasury is paid the protocol fee, and any leftover escrow
    ///         is refunded to the job owner.
    function execute(uint256 jobId) external {
        Job storage j = _jobs[jobId];
        if (j.status != Status.Active) revert BadStatus();

        // ---- effects ----
        // Snapshot all values, mark executed, zero escrow BEFORE any external call.
        uint256 bounty = _bountyAt(j, block.timestamp);
        uint256 fee = (bounty * uint256(feeBps)) / BPS_DENOMINATOR;
        uint256 escrow = j.escrow;
        // Defensive: escrow must cover bounty+fee. Required at register() given
        // the multiplier cap, but if treasury later raised feeBps... wait,
        // feeBps is bounded by maxFeeBps and we pre-funded at maxFeeBps, so
        // bounty + fee <= maxBounty + maxFeeOnMaxBounty <= escrow. Always safe.
        uint256 payout = bounty + fee;
        if (payout > escrow) revert InsufficientDeposit();
        uint256 refund = escrow - payout;

        address dao = j.dao;
        address owner = j.owner;
        bytes memory data = j.executeCalldata;

        j.status = Status.Executed;
        j.escrow = 0;

        // ---- interactions ----
        // DAO call FIRST so a failing proposal cannot trigger payouts.
        // Status is already flipped, escrow is already zero — the DAO callee
        // re-entering execute() will hit BadStatus.
        (bool ok, ) = dao.call(data);
        if (!ok) revert DaoCallFailed();

        emit Executed(jobId, msg.sender, bounty, fee, refund);

        if (bounty > 0) _send(msg.sender, bounty);
        if (fee > 0) _send(treasury, fee);
        if (refund > 0) _send(owner, refund);
    }

    /// @notice Owner-only refund. Anytime before execute().
    function cancel(uint256 jobId) external onlyOwnerOf(jobId) {
        Job storage j = _jobs[jobId];
        if (j.status != Status.Active) revert BadStatus();
        uint256 refund = j.escrow;
        j.escrow = 0;
        j.status = Status.Cancelled;
        emit Cancelled(jobId, msg.sender, refund);
        if (refund > 0) _send(msg.sender, refund);
    }

    function setFee(uint16 newFeeBps) external onlyTreasury {
        if (newFeeBps > maxFeeBps) revert FeeAboveCap();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function getJob(uint256 jobId)
        external
        view
        returns (
            address owner,
            address dao,
            bytes4 executeSelector,
            Status status,
            uint64 registeredAt,
            uint256 bountyBase,
            uint16 multiplierBps,
            uint16 bountyMaxMultiplier,
            uint32 daysToMax,
            uint256 escrow,
            bytes memory executeCalldata
        )
    {
        Job storage j = _jobs[jobId];
        return (
            j.owner,
            j.dao,
            j.executeSelector,
            j.status,
            j.registeredAt,
            j.bountyBase,
            j.multiplierBps,
            j.bountyMaxMultiplier,
            j.daysToMax,
            j.escrow,
            j.executeCalldata
        );
    }

    function totalJobs() external view returns (uint256) {
        return _jobs.length;
    }

    function jobsByOwner(address owner) external view returns (uint256[] memory) {
        return _byOwner[owner];
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
