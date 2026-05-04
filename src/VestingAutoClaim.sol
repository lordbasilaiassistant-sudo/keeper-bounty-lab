// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title VestingAutoClaim
/// @notice Multi-user keeper-bounty registry for auto-claiming vesting tokens.
///         A vesting recipient pre-funds an ETH bounty + names the vesting contract
///         and claim selector. After the cliff/conditions pass, any keeper can call
///         execute(jobId) — this contract calls the vesting contract's claim
///         function (tokens land in the recipient's wallet directly), then pays
///         the keeper a bounty and skims a protocol fee to treasury.
/// @dev Bounties are pre-funded, fees auto-route on execute, treasury can lower
///      fees but never above the immutable hard cap set at deploy. CEI pattern
///      throughout — no ReentrancyGuard needed.
contract VestingAutoClaim {
    struct Job {
        address owner;
        address vestingContract;
        bytes4 claimSelector;
        uint256 bounty;
        bool done;
    }

    Job[] public jobs;
    mapping(address => uint256[]) private _byOwner;

    address public treasury;
    uint16 public feeBps;

    uint16 public immutable maxFeeBps;
    uint16 public constant BPS_DENOMINATOR = 10_000;

    event Registered(
        uint256 indexed id,
        address indexed owner,
        address indexed vestingContract,
        bytes4 claimSelector,
        uint256 bounty
    );
    event Executed(
        uint256 indexed id,
        address indexed keeper,
        uint256 keeperBounty,
        uint256 protocolFee
    );
    event Cancelled(uint256 indexed id, uint256 refunded);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesUpdated(uint16 newFeeBps);

    error NotOwner();
    error NotTreasury();
    error AlreadyDone();
    error ZeroValue();
    error ZeroAddress();
    error ZeroSelector();
    error FeeAboveCap();
    error VestingCallFailed();
    error TransferFailed();

    modifier onlyOwner(uint256 id) {
        if (jobs[id].owner != msg.sender) revert NotOwner();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(address _treasury, uint16 _feeBps, uint16 _maxFeeBps) {
        if (_treasury == address(0)) revert ZeroAddress();
        // Hard ceiling: max fee can never exceed 10% (1000 bps) per spec.
        if (_maxFeeBps > 1_000) revert FeeAboveCap();
        if (_feeBps > _maxFeeBps) revert FeeAboveCap();

        treasury = _treasury;
        feeBps = _feeBps;
        maxFeeBps = _maxFeeBps;
    }

    /// @notice Register an auto-claim job. msg.value funds the keeper bounty + protocol fee.
    /// @param vestingContract The vesting contract that holds the user's tokens.
    /// @param claimSelector   The 4-byte selector of the no-arg claim function on that contract.
    function register(address vestingContract, bytes4 claimSelector)
        external
        payable
        returns (uint256 id)
    {
        if (msg.value == 0) revert ZeroValue();
        if (vestingContract == address(0)) revert ZeroAddress();
        if (claimSelector == bytes4(0)) revert ZeroSelector();

        id = jobs.length;
        jobs.push(Job({
            owner: msg.sender,
            vestingContract: vestingContract,
            claimSelector: claimSelector,
            bounty: msg.value,
            done: false
        }));
        _byOwner[msg.sender].push(id);

        emit Registered(id, msg.sender, vestingContract, claimSelector, msg.value);
    }

    /// @notice Anyone can call this once cliff/conditions on the vesting contract are met.
    ///         Calls vestingContract.claimSelector() — tokens go to job owner directly
    ///         (vesting contracts typically read msg.sender or a stored beneficiary;
    ///         a recipient registers a contract that pays *them*, not us).
    ///         Then pays keeper bounty + protocol fee.
    function execute(uint256 id) external {
        Job storage j = jobs[id];
        if (j.done) revert AlreadyDone();

        uint256 bounty = j.bounty;
        uint256 fee = (bounty * feeBps) / BPS_DENOMINATOR;
        uint256 toKeeper = bounty - fee;
        address vesting = j.vestingContract;
        bytes4 sel = j.claimSelector;

        // EFFECTS first.
        j.bounty = 0;
        j.done = true;

        emit Executed(id, msg.sender, toKeeper, fee);

        // INTERACTIONS — external call to user-specified vesting contract first.
        // This is the only attack-surface call; state is already finalized so reentry
        // into execute(id) hits AlreadyDone, and other functions are bounty-isolated per id.
        (bool ok, ) = vesting.call(abi.encodeWithSelector(sel));
        if (!ok) revert VestingCallFailed();

        if (fee > 0) _send(treasury, fee);
        if (toKeeper > 0) _send(msg.sender, toKeeper);
    }

    /// @notice Owner refunds their bounty before any keeper executes.
    function cancel(uint256 id) external onlyOwner(id) {
        Job storage j = jobs[id];
        if (j.done) revert AlreadyDone();
        uint256 refund = j.bounty;
        j.bounty = 0;
        j.done = true;
        emit Cancelled(id, refund);
        _send(msg.sender, refund);
    }

    /// @notice Treasury can lower fees but never above the immutable cap.
    function setFees(uint16 newFeeBps) external onlyTreasury {
        if (newFeeBps > maxFeeBps) revert FeeAboveCap();
        feeBps = newFeeBps;
        emit FeesUpdated(newFeeBps);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function totalJobs() external view returns (uint256) {
        return jobs.length;
    }

    function jobsByOwner(address owner) external view returns (uint256[] memory) {
        return _byOwner[owner];
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
