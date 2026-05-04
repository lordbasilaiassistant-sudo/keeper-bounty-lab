// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Trusted floor-price oracle. Callers MUST treat updatedAt as the
///         age boundary; this contract rejects readings older than maxStaleness.
interface IFloorOracle {
    function getFloor(address collection) external view returns (uint256 floorWei, uint64 updatedAt);
}

/// @title NftCancelOnFloorDrop
/// @notice Multi-user keeper-bounty contract. An NFT seller pre-funds a bounty
///         and registers a marketplace cancel-call (target + calldata) that
///         should fire if the collection's floor price drops below their
///         threshold. Any keeper can trigger the cancel and earn the bounty
///         once the trusted oracle confirms the drop.
/// @dev    v1 design: single trusted price oracle set at construction (the
///         README documents this trust assumption explicitly). Treasury fee
///         is taken at registration. Bounty is paid to the keeper at trigger.
///         Checks-effects-interactions ordering on every external call.
contract NftCancelOnFloorDrop {
    struct Job {
        address seller;
        address marketplace;
        address collection;
        uint256 bounty;
        uint256 floorThresholdWei;
        bytes cancelCalldata;
        bool resolved;
    }

    Job[] private _jobs;
    mapping(address => uint256[]) private _bySeller;
    mapping(address => uint256[]) private _byCollection;

    address public treasury;
    IFloorOracle public immutable oracle;
    uint64 public immutable maxStaleness;

    uint16 public registerFeeBps;
    uint16 public immutable maxRegisterFeeBps;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    event Registered(
        uint256 indexed id,
        address indexed seller,
        address indexed collection,
        address marketplace,
        uint256 bounty,
        uint256 floorThresholdWei,
        uint256 fee
    );
    event Executed(
        uint256 indexed id,
        address indexed keeper,
        uint256 oracleFloor,
        uint64 oracleUpdatedAt,
        uint256 bountyPaid
    );
    event Cancelled(uint256 indexed id, uint256 refunded);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesUpdated(uint16 registerFeeBps);

    error NotSeller();
    error NotTreasury();
    error AlreadyResolved();
    error ZeroAddress();
    error ZeroBounty();
    error ZeroThreshold();
    error EmptyCalldata();
    error FeeAboveCap();
    error OracleStale(uint64 updatedAt, uint64 nowTs);
    error FloorAboveThreshold(uint256 oracleFloor, uint256 threshold);
    error MarketplaceCallFailed(bytes returnData);
    error TransferFailed();

    modifier onlySeller(uint256 id) {
        if (_jobs[id].seller != msg.sender) revert NotSeller();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(
        address _treasury,
        address _oracle,
        uint64 _maxStaleness,
        uint16 _registerFeeBps,
        uint16 _maxRegisterFeeBps
    ) {
        if (_treasury == address(0) || _oracle == address(0)) revert ZeroAddress();
        if (_maxStaleness == 0) revert ZeroThreshold();
        if (_maxRegisterFeeBps > BPS_DENOMINATOR / 2) revert FeeAboveCap();
        if (_registerFeeBps > _maxRegisterFeeBps) revert FeeAboveCap();

        treasury = _treasury;
        oracle = IFloorOracle(_oracle);
        maxStaleness = _maxStaleness;
        registerFeeBps = _registerFeeBps;
        maxRegisterFeeBps = _maxRegisterFeeBps;
    }

    /// @notice Register a cancel-on-floor-drop job. msg.value funds the bounty
    ///         (after fee). The marketplace call will be executed verbatim
    ///         using `cancelCalldata` once the floor is verified below threshold.
    function register(
        address marketplace,
        bytes calldata cancelCalldata,
        address collection,
        uint256 floorThresholdWei
    ) external payable returns (uint256 id) {
        if (msg.value == 0) revert ZeroBounty();
        if (marketplace == address(0) || collection == address(0)) revert ZeroAddress();
        if (cancelCalldata.length == 0) revert EmptyCalldata();
        if (floorThresholdWei == 0) revert ZeroThreshold();

        uint256 fee = (msg.value * registerFeeBps) / BPS_DENOMINATOR;
        uint256 bounty = msg.value - fee;
        if (bounty == 0) revert ZeroBounty();

        id = _jobs.length;
        _jobs.push(Job({
            seller: msg.sender,
            marketplace: marketplace,
            collection: collection,
            bounty: bounty,
            floorThresholdWei: floorThresholdWei,
            cancelCalldata: cancelCalldata,
            resolved: false
        }));
        _bySeller[msg.sender].push(id);
        _byCollection[collection].push(id);

        emit Registered(id, msg.sender, collection, marketplace, bounty, floorThresholdWei, fee);

        if (fee > 0) _send(treasury, fee);
    }

    /// @notice Keeper executes the cancel. Reverts if the oracle floor is not
    ///         below the seller's threshold or the reading is stale.
    /// @dev    The marketplace cancel call MUST be authorized for this contract
    ///         on the target marketplace (e.g. Seaport requires either an order
    ///         that lists this contract as offerer, or a `cancel`-equivalent
    ///         flow that accepts a third-party caller — see README).
    function execute(uint256 id) external {
        Job storage j = _jobs[id];
        if (j.resolved) revert AlreadyResolved();

        (uint256 oracleFloor, uint64 updatedAt) = oracle.getFloor(j.collection);
        uint64 nowTs = uint64(block.timestamp);
        if (updatedAt + maxStaleness < nowTs) revert OracleStale(updatedAt, nowTs);
        if (oracleFloor >= j.floorThresholdWei) revert FloorAboveThreshold(oracleFloor, j.floorThresholdWei);

        uint256 bounty = j.bounty;
        address marketplace = j.marketplace;
        bytes memory data = j.cancelCalldata;

        // Effects before interactions.
        j.bounty = 0;
        j.resolved = true;

        emit Executed(id, msg.sender, oracleFloor, updatedAt, bounty);

        // External cancel call. We don't require success-equals-true because
        // marketplaces vary; reverts bubble up so the keeper sees the failure.
        (bool ok, bytes memory ret) = marketplace.call(data);
        if (!ok) revert MarketplaceCallFailed(ret);

        if (bounty > 0) _send(msg.sender, bounty);
    }

    /// @notice Seller cancels the job and reclaims the unspent bounty.
    function cancel(uint256 id) external onlySeller(id) {
        Job storage j = _jobs[id];
        if (j.resolved) revert AlreadyResolved();

        uint256 refund = j.bounty;
        j.bounty = 0;
        j.resolved = true;

        emit Cancelled(id, refund);
        _send(msg.sender, refund);
    }

    function setFees(uint16 newRegisterFeeBps) external onlyTreasury {
        if (newRegisterFeeBps > maxRegisterFeeBps) revert FeeAboveCap();
        registerFeeBps = newRegisterFeeBps;
        emit FeesUpdated(newRegisterFeeBps);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function getJob(uint256 id)
        external
        view
        returns (
            address seller,
            address marketplace,
            address collection,
            uint256 bounty,
            uint256 floorThresholdWei,
            bytes memory cancelCalldata,
            bool resolved
        )
    {
        Job storage j = _jobs[id];
        return (j.seller, j.marketplace, j.collection, j.bounty, j.floorThresholdWei, j.cancelCalldata, j.resolved);
    }

    /// @notice Convenience view: would `execute(id)` succeed right now?
    function isTriggerable(uint256 id) external view returns (bool) {
        Job storage j = _jobs[id];
        if (j.resolved) return false;
        (uint256 oracleFloor, uint64 updatedAt) = oracle.getFloor(j.collection);
        if (updatedAt + maxStaleness < uint64(block.timestamp)) return false;
        return oracleFloor < j.floorThresholdWei;
    }

    function totalJobs() external view returns (uint256) {
        return _jobs.length;
    }

    function jobsBySeller(address seller) external view returns (uint256[] memory) {
        return _bySeller[seller];
    }

    function jobsByCollection(address collection) external view returns (uint256[] memory) {
        return _byCollection[collection];
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
