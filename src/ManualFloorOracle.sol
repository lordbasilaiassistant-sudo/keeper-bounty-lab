// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ManualFloorOracle
/// @notice Treasury-curated NFT floor price feed. Implements the IFloorOracle
///         interface that NftCancelOnFloorDrop expects. Floors are set manually
///         by the treasury as a v1 placeholder until a real signed feed exists.
/// @dev Stale-data guard is enforced by the consumer (NftCancelOnFloorDrop checks
///      updatedAt vs maxStaleness). This contract just stores and serves prices.
contract ManualFloorOracle {
    struct Floor {
        uint256 priceWei;
        uint64 updatedAt;
    }

    address public treasury;
    mapping(address => Floor) private _floors;

    event FloorUpdated(address indexed collection, uint256 priceWei, uint64 updatedAt);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error NotTreasury();
    error ZeroAddress();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(address _treasury) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    function setFloor(address collection, uint256 priceWei) external onlyTreasury {
        _floors[collection] = Floor({priceWei: priceWei, updatedAt: uint64(block.timestamp)});
        emit FloorUpdated(collection, priceWei, uint64(block.timestamp));
    }

    function setFloorBatch(address[] calldata collections, uint256[] calldata pricesWei) external onlyTreasury {
        uint64 ts = uint64(block.timestamp);
        for (uint256 i = 0; i < collections.length; i++) {
            _floors[collections[i]] = Floor({priceWei: pricesWei[i], updatedAt: ts});
            emit FloorUpdated(collections[i], pricesWei[i], ts);
        }
    }

    function getFloor(address collection) external view returns (uint256 priceWei, uint64 updatedAt) {
        Floor storage f = _floors[collection];
        return (f.priceWei, f.updatedAt);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }
}
