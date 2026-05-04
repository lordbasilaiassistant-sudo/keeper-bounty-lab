// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {NftCancelOnFloorDrop, IFloorOracle} from "../src/NftCancelOnFloorDrop.sol";

contract MockOracle is IFloorOracle {
    mapping(address => uint256) public floor;
    mapping(address => uint64) public updatedAt;

    function set(address collection, uint256 _floor, uint64 _updatedAt) external {
        floor[collection] = _floor;
        updatedAt[collection] = _updatedAt;
    }

    function getFloor(address collection) external view returns (uint256, uint64) {
        return (floor[collection], updatedAt[collection]);
    }
}

contract MockMarketplace {
    mapping(bytes32 => bool) public cancelled;
    bool public failNext;

    function setFailNext(bool v) external {
        failNext = v;
    }

    function cancelOrder(bytes32 orderHash) external {
        if (failNext) {
            failNext = false;
            revert("MARKETPLACE_FAIL");
        }
        cancelled[orderHash] = true;
    }
}

contract Reverter {
    fallback() external payable {
        revert("NO_ETH");
    }
}

contract NftCancelOnFloorDropTest is Test {
    NftCancelOnFloorDrop internal nft;
    MockOracle internal oracle;
    MockMarketplace internal marketplace;

    address internal constant TREASURY = 0x7a3E312Ec6e20a9F62fE2405938EB9060312E334;
    address internal constant COLLECTION = address(0xC0FFEE);
    address internal seller = address(0xA11CE);
    address internal keeper = address(0xB0B);

    uint16 internal constant FEE_BPS = 500;       // 5%
    uint16 internal constant MAX_FEE_BPS = 1000;  // 10% cap
    uint64 internal constant MAX_STALENESS = 3600;

    bytes32 internal constant ORDER_HASH = keccak256("listing-1");

    function setUp() public {
        oracle = new MockOracle();
        marketplace = new MockMarketplace();
        nft = new NftCancelOnFloorDrop(TREASURY, address(oracle), MAX_STALENESS, FEE_BPS, MAX_FEE_BPS);

        vm.deal(seller, 100 ether);
        vm.deal(keeper, 1 ether);

        // Set initial floor well above any test threshold so jobs start
        // out non-triggerable.
        oracle.set(COLLECTION, 5 ether, uint64(block.timestamp));
    }

    function _calldata() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockMarketplace.cancelOrder.selector, ORDER_HASH);
    }

    function _register(uint256 value, uint256 threshold) internal returns (uint256) {
        vm.prank(seller);
        return nft.register{value: value}(address(marketplace), _calldata(), COLLECTION, threshold);
    }

    function test_RegisterTakesFeeAndStoresJob() public {
        uint256 treasuryBefore = TREASURY.balance;
        uint256 id = _register(1 ether, 3 ether);

        assertEq(id, 0);
        (
            address s,
            address mkt,
            address coll,
            uint256 bounty,
            uint256 threshold,
            bytes memory cd,
            bool resolved
        ) = nft.getJob(0);

        assertEq(s, seller);
        assertEq(mkt, address(marketplace));
        assertEq(coll, COLLECTION);
        assertEq(bounty, 0.95 ether);
        assertEq(threshold, 3 ether);
        assertEq(cd, _calldata());
        assertFalse(resolved);

        assertEq(TREASURY.balance - treasuryBefore, 0.05 ether);
        assertEq(address(nft).balance, 0.95 ether);

        uint256[] memory bySeller = nft.jobsBySeller(seller);
        assertEq(bySeller.length, 1);
        assertEq(bySeller[0], 0);

        uint256[] memory byColl = nft.jobsByCollection(COLLECTION);
        assertEq(byColl.length, 1);
        assertEq(byColl[0], 0);

        assertEq(nft.totalJobs(), 1);
    }

    function test_RegisterRejectsBadInputs() public {
        // zero value
        vm.prank(seller);
        vm.expectRevert(NftCancelOnFloorDrop.ZeroBounty.selector);
        nft.register{value: 0}(address(marketplace), _calldata(), COLLECTION, 1 ether);

        // zero marketplace
        vm.prank(seller);
        vm.expectRevert(NftCancelOnFloorDrop.ZeroAddress.selector);
        nft.register{value: 1 ether}(address(0), _calldata(), COLLECTION, 1 ether);

        // empty calldata
        vm.prank(seller);
        vm.expectRevert(NftCancelOnFloorDrop.EmptyCalldata.selector);
        nft.register{value: 1 ether}(address(marketplace), bytes(""), COLLECTION, 1 ether);

        // zero threshold
        vm.prank(seller);
        vm.expectRevert(NftCancelOnFloorDrop.ZeroThreshold.selector);
        nft.register{value: 1 ether}(address(marketplace), _calldata(), COLLECTION, 0);
    }

    function test_ExecuteRevertsWhenFloorAboveThreshold() public {
        uint256 id = _register(1 ether, 3 ether);
        // Floor is 5 ether, threshold 3 ether — not triggerable.
        assertFalse(nft.isTriggerable(id));

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(NftCancelOnFloorDrop.FloorAboveThreshold.selector, 5 ether, 3 ether)
        );
        nft.execute(id);
    }

    function test_ExecuteRevertsWhenOracleStale() public {
        uint256 id = _register(1 ether, 3 ether);

        // Drop the floor below threshold but make the reading older than maxStaleness.
        uint64 staleTs = uint64(block.timestamp);
        oracle.set(COLLECTION, 1 ether, staleTs);

        // Move time forward past the staleness window.
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        assertFalse(nft.isTriggerable(id));

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(NftCancelOnFloorDrop.OracleStale.selector, staleTs, uint64(block.timestamp))
        );
        nft.execute(id);
    }

    function test_ExecuteHappyPathPaysBountyAndCallsMarketplace() public {
        uint256 id = _register(1 ether, 3 ether);

        oracle.set(COLLECTION, 2 ether, uint64(block.timestamp));
        assertTrue(nft.isTriggerable(id));

        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        nft.execute(id);

        // Marketplace cancel fired
        assertTrue(marketplace.cancelled(ORDER_HASH));

        // Keeper got the full 0.95 ether bounty
        assertEq(keeper.balance - keeperBefore, 0.95 ether);

        // Job is resolved + zeroed
        (, , , uint256 bounty, , , bool resolved) = nft.getJob(id);
        assertEq(bounty, 0);
        assertTrue(resolved);

        // Contract balance drained
        assertEq(address(nft).balance, 0);
    }

    function test_ExecuteCannotBeRunTwice() public {
        uint256 id = _register(1 ether, 3 ether);
        oracle.set(COLLECTION, 2 ether, uint64(block.timestamp));

        vm.prank(keeper);
        nft.execute(id);

        vm.prank(keeper);
        vm.expectRevert(NftCancelOnFloorDrop.AlreadyResolved.selector);
        nft.execute(id);
    }

    function test_ExecuteBubblesUpMarketplaceFailureAndPreservesJob() public {
        uint256 id = _register(1 ether, 3 ether);
        oracle.set(COLLECTION, 2 ether, uint64(block.timestamp));
        marketplace.setFailNext(true);

        vm.prank(keeper);
        vm.expectRevert();
        nft.execute(id);

        // The marketplace revert bubbles up and unwinds ALL state changes
        // (including the CEI-ordered effects above the external call). The
        // job stays open so a future keeper can retry once the marketplace
        // call would succeed (e.g. a different keeper, mempool conditions,
        // or seller intervention).
        (, , , uint256 bounty, , , bool resolved) = nft.getJob(id);
        assertEq(bounty, 0.95 ether);
        assertFalse(resolved);

        // And once the marketplace recovers, retry succeeds.
        marketplace.setFailNext(false);
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        nft.execute(id);

        assertTrue(marketplace.cancelled(ORDER_HASH));
        assertEq(keeper.balance - keeperBefore, 0.95 ether);
    }

    function test_SellerCanCancelAndRefund() public {
        uint256 sellerBefore = seller.balance;
        uint256 id = _register(1 ether, 3 ether);
        // Seller paid 1 ether, fee 0.05 → bounty 0.95.
        assertEq(seller.balance, sellerBefore - 1 ether);

        vm.prank(seller);
        nft.cancel(id);

        // Refund is the bounty (0.95 ether), not the gross deposit.
        assertEq(seller.balance, sellerBefore - 0.05 ether);

        (, , , uint256 bounty, , , bool resolved) = nft.getJob(id);
        assertEq(bounty, 0);
        assertTrue(resolved);
    }

    function test_NonSellerCannotCancel() public {
        uint256 id = _register(1 ether, 3 ether);
        vm.prank(keeper);
        vm.expectRevert(NftCancelOnFloorDrop.NotSeller.selector);
        nft.cancel(id);
    }

    function test_CancelTwiceReverts() public {
        uint256 id = _register(1 ether, 3 ether);
        vm.prank(seller);
        nft.cancel(id);

        vm.prank(seller);
        vm.expectRevert(NftCancelOnFloorDrop.AlreadyResolved.selector);
        nft.cancel(id);
    }

    function test_TreasuryCanLowerFeeButNotRaiseAboveCap() public {
        vm.prank(TREASURY);
        nft.setFees(200);
        assertEq(nft.registerFeeBps(), 200);

        vm.prank(TREASURY);
        vm.expectRevert(NftCancelOnFloorDrop.FeeAboveCap.selector);
        nft.setFees(MAX_FEE_BPS + 1);

        vm.prank(seller);
        vm.expectRevert(NftCancelOnFloorDrop.NotTreasury.selector);
        nft.setFees(100);
    }

    function test_TreasuryCanRotate() public {
        address newTreasury = address(0xDEAD);
        vm.prank(TREASURY);
        nft.setTreasury(newTreasury);
        assertEq(nft.treasury(), newTreasury);

        vm.prank(newTreasury);
        vm.expectRevert(NftCancelOnFloorDrop.ZeroAddress.selector);
        nft.setTreasury(address(0));
    }

    function test_MultipleSellersAndJobsIsolated() public {
        address seller2 = address(0xCAFE);
        vm.deal(seller2, 10 ether);

        _register(1 ether, 3 ether);
        vm.prank(seller2);
        nft.register{value: 2 ether}(address(marketplace), _calldata(), COLLECTION, 4 ether);
        _register(1 ether, 1 ether); // seller's second job

        assertEq(nft.totalJobs(), 3);
        assertEq(nft.jobsBySeller(seller).length, 2);
        assertEq(nft.jobsBySeller(seller2).length, 1);
        assertEq(nft.jobsByCollection(COLLECTION).length, 3);
    }

    function test_ConstructorRejectsBadConfig() public {
        vm.expectRevert(NftCancelOnFloorDrop.ZeroAddress.selector);
        new NftCancelOnFloorDrop(address(0), address(oracle), MAX_STALENESS, FEE_BPS, MAX_FEE_BPS);

        vm.expectRevert(NftCancelOnFloorDrop.ZeroAddress.selector);
        new NftCancelOnFloorDrop(TREASURY, address(0), MAX_STALENESS, FEE_BPS, MAX_FEE_BPS);

        vm.expectRevert(NftCancelOnFloorDrop.ZeroThreshold.selector);
        new NftCancelOnFloorDrop(TREASURY, address(oracle), 0, FEE_BPS, MAX_FEE_BPS);

        // hard cap = BPS_DENOMINATOR / 2 = 5000
        vm.expectRevert(NftCancelOnFloorDrop.FeeAboveCap.selector);
        new NftCancelOnFloorDrop(TREASURY, address(oracle), MAX_STALENESS, FEE_BPS, 5001);

        vm.expectRevert(NftCancelOnFloorDrop.FeeAboveCap.selector);
        new NftCancelOnFloorDrop(TREASURY, address(oracle), MAX_STALENESS, MAX_FEE_BPS + 1, MAX_FEE_BPS);
    }

    function test_TransferFailedSurfacedOnFeeRouting() public {
        // Treasury that rejects ETH → register() should revert via the fee path.
        Reverter rev = new Reverter();
        NftCancelOnFloorDrop bad = new NftCancelOnFloorDrop(
            address(rev), address(oracle), MAX_STALENESS, FEE_BPS, MAX_FEE_BPS
        );

        vm.prank(seller);
        vm.expectRevert(NftCancelOnFloorDrop.TransferFailed.selector);
        bad.register{value: 1 ether}(address(marketplace), _calldata(), COLLECTION, 3 ether);
    }
}
