// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {DistributionManager} from "@/DistributionManager.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestERC721} from "./mocks/TestERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract BaseDistributionTest is Test {
    TestERC20 public token;
    TestERC721 public nft;
    DistributionManager public distributionManager;

    address public distributor = makeAddr("distributor");
    uint256 public constant initialBalance = 1000 ether;
    uint256[] public nftIds;

    function setUp() public virtual {
        token = new TestERC20();
        nft = new TestERC721();
        distributionManager = new DistributionManager(address(token), address(nft));

        // Setup roles
        distributionManager.grantRole(distributionManager.DISTRIBUTOR_ROLE(), distributor);
        distributionManager.grantRole(distributionManager.PAUSER_ROLE(), address(this));

        // Setup initial balances
        deal(address(token), distributor, initialBalance);
        vm.startPrank(distributor);
        token.approve(address(distributionManager), type(uint256).max);
        nft.setApprovalForAll(address(distributionManager), true);

        // Mint NFTs
        for (uint256 i = 0; i < 2; i++) {
            nft.mint(distributor, i);
            nftIds.push(i);
        }
        vm.stopPrank();
    }
}

contract DistributionTest is BaseDistributionTest {
    function test_RevertDistributeIfNotDistributor() public {
        address nonDistributor = makeAddr("nonDistributor");
        vm.startPrank(nonDistributor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonDistributor,
                distributionManager.DISTRIBUTOR_ROLE()
            )
        );
        distributionManager.distribute("ANY_UID", nonDistributor, 1, new uint256[](0));
        vm.stopPrank();
    }

    function test_RevertDistributeWithMissingNFTs() public {
        address receiver = makeAddr("receiver");
        uint256[] memory invalidNFTs = new uint256[](3);
        invalidNFTs[0] = nftIds[0];
        invalidNFTs[1] = nftIds[1];
        invalidNFTs[2] = 500; // Non-existent NFT

        vm.startPrank(distributor);
        vm.expectRevert(); // Should revert on NFT transfer
        distributionManager.distribute("ANY_UID", receiver, 0, invalidNFTs);
        vm.stopPrank();

        // Verify state remains unchanged
        assertEq(token.balanceOf(distributor), initialBalance);
        assertEq(nft.ownerOf(nftIds[0]), distributor);
        assertEq(nft.ownerOf(nftIds[1]), distributor);
        assertFalse(distributionManager.isDistributed("ANY_UID"));
    }

    function test_ValidDistribution() public {
        address receiver = makeAddr("receiver");
        string memory uid = "VALID_UID";
        uint256 tokenAmount = 50 ether;
        uint256 nativeAmount = 1 ether;

        vm.deal(distributor, nativeAmount);
        vm.startPrank(distributor);

        vm.expectEmit();
        emit DistributionManager.Distribute(uid);

        distributionManager.distribute{value: nativeAmount}(uid, receiver, tokenAmount, nftIds);

        vm.stopPrank();

        // Verify distribution
        assertEq(token.balanceOf(receiver), tokenAmount);
        assertEq(receiver.balance, nativeAmount);
        assertEq(nft.ownerOf(nftIds[0]), receiver);
        assertEq(nft.ownerOf(nftIds[1]), receiver);
        assertTrue(distributionManager.isDistributed(uid));
    }

    function test_RevertDuplicateDistribution() public {
        address receiver = makeAddr("receiver");
        string memory uid = "VALID_UID";

        vm.startPrank(distributor);
        distributionManager.distribute(uid, receiver, 0, new uint256[](0));

        vm.expectRevert("DistributionManager: UID must be free.");
        distributionManager.distribute(uid, receiver, 0, new uint256[](0));
        vm.stopPrank();
    }
}

contract DistributionPauseTest is BaseDistributionTest {
    error EnforcedPause();

    function test_PauseDistribution() public {
        distributionManager.pause();

        vm.startPrank(distributor);
        vm.expectRevert(abi.encodeWithSelector(EnforcedPause.selector));
        distributionManager.distribute("ANY_UID", distributor, 0, new uint256[](0));
        vm.stopPrank();

        distributionManager.unpause();
    }

    function test_RevertPauseIfNotPauser() public {
        address nonPauser = makeAddr("nonPauser");
        vm.startPrank(nonPauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, nonPauser, distributionManager.PAUSER_ROLE()
            )
        );
        distributionManager.pause();
        vm.stopPrank();
    }

    function test_RevertUnpauseIfNotPauser() public {
        address nonPauser = makeAddr("nonPauser");

        distributionManager.pause();

        vm.startPrank(nonPauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, nonPauser, distributionManager.PAUSER_ROLE()
            )
        );
        distributionManager.unpause();
        vm.stopPrank();
    }
}
