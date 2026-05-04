// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBondingCurve {
    function buy(uint256 minTokensOut) external payable returns (uint256 tokensOut);
    function reserve() external view returns (uint256);
    function graduationThreshold() external view returns (uint256);
    function graduated() external view returns (bool);
    function token() external view returns (address);
}

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title CurveGraduationPusher
/// @notice Multi-user keeper-bounty job. A supporter pre-funds ETH (committed
///         buy + bounty) on a stalled bonding curve. Anyone may execute the
///         buy once the curve crosses a configurable progress threshold; the
///         keeper earns the bounty, the bought tokens go to the registrant.
/// @dev    Treasury fee is taken on (ethToCommit + bounty) at registration.
///         All external calls follow checks-effects-interactions; curve.buy
///         is the one untrusted call and is made after state is finalised.
contract CurveGraduationPusher {
    struct Job {
        address owner;
        address curve;
        uint256 ethToCommit;
        uint256 bountyAmount;
        uint16 minProgressBps;
        bool executed;
        bool cancelled;
    }

    Job[] public jobs;
    mapping(address => uint256[]) private _byOwner;
    mapping(address => uint256[]) private _byCurve;

    address public treasury;
    uint16 public protocolFeeBps;

    uint16 public immutable maxProtocolFeeBps;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    event Registered(
        uint256 indexed id,
        address indexed owner,
        address indexed curve,
        uint256 ethToCommit,
        uint256 bountyAmount,
        uint16 minProgressBps,
        uint256 fee
    );
    event Executed(
        uint256 indexed id,
        address indexed keeper,
        uint256 ethSpent,
        uint256 tokensBought,
        uint256 bounty
    );
    event Cancelled(uint256 indexed id, uint256 refunded);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesUpdated(uint16 protocolFeeBps);

    error NotOwner();
    error NotTreasury();
    error AlreadyResolved();
    error ZeroValue();
    error ZeroAddress();
    error FeeAboveCap();
    error WrongMsgValue();
    error InvalidProgressBps();
    error CurveAlreadyGraduated();
    error ProgressTooLow();
    error TransferFailed();
    error TokenTransferFailed();
    error BuyReturnedZero();

    modifier onlyOwner(uint256 id) {
        if (jobs[id].owner != msg.sender) revert NotOwner();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(
        address _treasury,
        uint16 _protocolFeeBps,
        uint16 _maxProtocolFeeBps
    ) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_maxProtocolFeeBps > BPS_DENOMINATOR / 2) revert FeeAboveCap();
        if (_protocolFeeBps > _maxProtocolFeeBps) revert FeeAboveCap();

        treasury = _treasury;
        protocolFeeBps = _protocolFeeBps;
        maxProtocolFeeBps = _maxProtocolFeeBps;
    }

    /// @notice Register a graduation-push job.
    /// @param  curve              bonding-curve contract to buy from
    /// @param  ethToCommit        ETH that will be sent into curve.buy on execute
    /// @param  minProgressBps     minimum reserve/threshold ratio (bps) before execute is allowed
    /// @param  bountyAmount       ETH paid to whoever calls execute
    /// @dev    msg.value MUST equal ethToCommit + bountyAmount + ceil(fee).
    ///         Fee is computed on the working notional (ethToCommit + bountyAmount).
    function register(
        address curve,
        uint256 ethToCommit,
        uint16 minProgressBps,
        uint256 bountyAmount
    ) external payable returns (uint256 id) {
        if (curve == address(0)) revert ZeroAddress();
        if (ethToCommit == 0) revert ZeroValue();
        if (minProgressBps == 0 || minProgressBps > BPS_DENOMINATOR) revert InvalidProgressBps();

        uint256 working = ethToCommit + bountyAmount;
        uint256 fee = (working * protocolFeeBps) / BPS_DENOMINATOR;
        if (msg.value != working + fee) revert WrongMsgValue();

        id = jobs.length;
        jobs.push(Job({
            owner: msg.sender,
            curve: curve,
            ethToCommit: ethToCommit,
            bountyAmount: bountyAmount,
            minProgressBps: minProgressBps,
            executed: false,
            cancelled: false
        }));
        _byOwner[msg.sender].push(id);
        _byCurve[curve].push(id);

        emit Registered(id, msg.sender, curve, ethToCommit, bountyAmount, minProgressBps, fee);

        if (fee > 0) _send(treasury, fee);
    }

    /// @notice Execute a registered job. Anyone may call.
    /// @param  id          job id
    /// @param  minTokensOut slippage protection forwarded to curve.buy.
    ///                      Keeper picks this; if too tight the call reverts and
    ///                      the bounty is not paid (no state change).
    function execute(uint256 id, uint256 minTokensOut) external {
        Job storage j = jobs[id];
        if (j.executed || j.cancelled) revert AlreadyResolved();

        IBondingCurve curve = IBondingCurve(j.curve);
        if (curve.graduated()) revert CurveAlreadyGraduated();

        uint256 threshold = curve.graduationThreshold();
        uint256 reserve = curve.reserve();
        // progress = reserve * BPS / threshold; require >= minProgressBps
        // rearranged to avoid overflow on small thresholds:
        //   reserve * BPS_DENOMINATOR < threshold * minProgressBps  -> too low
        if (reserve * BPS_DENOMINATOR < threshold * uint256(j.minProgressBps)) revert ProgressTooLow();

        // Effects: mark executed before any external value-bearing call.
        j.executed = true;

        uint256 ethToCommit = j.ethToCommit;
        uint256 bounty = j.bountyAmount;
        address owner_ = j.owner;
        address tokenAddr = curve.token();

        emit Executed(id, msg.sender, ethToCommit, 0, bounty);

        // Interactions: external buy. We trust reserve/threshold/graduated to be
        // honest — same trust assumption as anyone interacting with the curve.
        uint256 tokensBought = curve.buy{value: ethToCommit}(minTokensOut);
        if (tokensBought == 0) revert BuyReturnedZero();

        // Forward the bought tokens to the registrant.
        if (tokenAddr != address(0)) {
            // Use the actual on-contract balance in case curve.buy under-reports
            // (some curves return netOfFee but mint gross). This makes us robust
            // to non-standard return values without trusting them.
            uint256 bal = IERC20Minimal(tokenAddr).balanceOf(address(this));
            uint256 toSend = bal < tokensBought ? bal : tokensBought;
            if (toSend > 0) {
                bool ok = IERC20Minimal(tokenAddr).transfer(owner_, toSend);
                if (!ok) revert TokenTransferFailed();
            }
        }

        if (bounty > 0) _send(msg.sender, bounty);
    }

    /// @notice Cancel a job and refund (ethToCommit + bountyAmount). Owner only.
    /// @dev    Protocol fee is non-refundable (already paid to treasury).
    function cancel(uint256 id) external onlyOwner(id) {
        Job storage j = jobs[id];
        if (j.executed || j.cancelled) revert AlreadyResolved();

        uint256 refund = j.ethToCommit + j.bountyAmount;
        j.cancelled = true;

        emit Cancelled(id, refund);
        _send(msg.sender, refund);
    }

    function setFees(uint16 newProtocolFeeBps) external onlyTreasury {
        if (newProtocolFeeBps > maxProtocolFeeBps) revert FeeAboveCap();
        protocolFeeBps = newProtocolFeeBps;
        emit FeesUpdated(newProtocolFeeBps);
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

    function jobsByOwner(address owner_) external view returns (uint256[] memory) {
        return _byOwner[owner_];
    }

    function jobsByCurve(address curve) external view returns (uint256[] memory) {
        return _byCurve[curve];
    }

    /// @notice Helper: current progress of a job's curve in bps. Returns
    ///         BPS_DENOMINATOR if reserve >= threshold.
    function currentProgressBps(uint256 id) external view returns (uint256) {
        Job storage j = jobs[id];
        IBondingCurve curve = IBondingCurve(j.curve);
        uint256 threshold = curve.graduationThreshold();
        if (threshold == 0) return BPS_DENOMINATOR;
        uint256 reserve = curve.reserve();
        if (reserve >= threshold) return BPS_DENOMINATOR;
        return (reserve * BPS_DENOMINATOR) / threshold;
    }

    /// @notice Quote whether execute(id) would currently be valid (not exhaustive
    ///         — slippage on the buy can still revert it).
    function isExecutable(uint256 id) external view returns (bool) {
        Job storage j = jobs[id];
        if (j.executed || j.cancelled) return false;
        IBondingCurve curve = IBondingCurve(j.curve);
        if (curve.graduated()) return false;
        uint256 threshold = curve.graduationThreshold();
        uint256 reserve = curve.reserve();
        return reserve * BPS_DENOMINATOR >= threshold * uint256(j.minProgressBps);
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
