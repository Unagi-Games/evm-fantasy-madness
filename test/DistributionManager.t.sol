// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {DistributionManager} from "@/DistributionManager.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestERC721} from "./mocks/TestERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {NFT} from "@/NFT.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract BaseDistributionTest is Test {
    TestERC20 public token;
    NFT public nft;
    DistributionManager public distributionManager;

    address public distributor;
    uint256 public distributorKey;

    function setUp() public virtual {
        token = new TestERC20();
        nft = new NFT(0, "Test", "TST");
        distributionManager = new DistributionManager(address(token), address(nft));

        (distributor, distributorKey) = makeAddrAndKey("distributor");

        // Setup roles
        nft.grantRole(nft.MINT_ROLE(), address(distributionManager));
        distributionManager.grantRole(distributionManager.DISTRIBUTOR_ROLE(), distributor);
        distributionManager.grantRole(distributionManager.PAUSER_ROLE(), address(this));

        // Setup initial balances
        deal(address(distributionManager), 1000 ether);
        deal(address(token), address(distributionManager), 1000 ether);
        vm.startPrank(distributor);
        token.approve(address(distributionManager), type(uint256).max);
        nft.setApprovalForAll(address(distributionManager), true);
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
        distributionManager.distribute("ANY_UID", nonDistributor, 0, new DistributionManager.NFTClaim[](0), 1);
        vm.stopPrank();
    }

    function test_ValidDistribution() public {
        address receiver = makeAddr("receiver");
        string memory uid = "VALID_UID";
        uint256 tokenAmount = 50 ether;
        uint256 nativeAmount = 1 ether;

        vm.deal(distributor, nativeAmount);
        vm.startPrank(distributor);

        DistributionManager.NFTClaim[] memory claims = new DistributionManager.NFTClaim[](2);
        claims[0] = DistributionManager.NFTClaim("foo", NFT.Metadata("basic", "TEST", NFT.Rarity.EPIC, NFT.Variant.UP));
        claims[1] = DistributionManager.NFTClaim("bar", NFT.Metadata("basic", "TEST", NFT.Rarity.RARE, NFT.Variant.UP));

        DistributionManager.NFTClaimed[] memory claimed = new DistributionManager.NFTClaimed[](2);
        claimed[0] = DistributionManager.NFTClaimed(claims[0].UID, 1);
        claimed[1] = DistributionManager.NFTClaimed(claims[1].UID, 2);

        vm.expectEmit();
        emit DistributionManager.Distribute(uid, receiver, nativeAmount, claimed, tokenAmount);

        distributionManager.distribute(uid, receiver, nativeAmount, claims, tokenAmount);

        vm.stopPrank();

        // Verify distribution
        assertEq(token.balanceOf(receiver), tokenAmount);
        assertEq(receiver.balance, nativeAmount);
        assertEq(nft.ownerOf(1), receiver);
        assertEq(nft.ownerOf(2), receiver);
        assertTrue(distributionManager.isDistributed(uid));
    }

    function test_RevertDuplicateDistribution() public {
        address receiver = makeAddr("receiver");
        string memory uid = "VALID_UID";

        vm.startPrank(distributor);
        distributionManager.distribute(uid, receiver, 0, new DistributionManager.NFTClaim[](0), 0);

        vm.expectRevert("DistributionManager: UID must be free.");
        distributionManager.distribute(uid, receiver, 0, new DistributionManager.NFTClaim[](0), 0);
        vm.stopPrank();
    }
}

contract DistributionPauseTest is BaseDistributionTest {
    error EnforcedPause();

    function test_PauseDistribution() public {
        distributionManager.pause();

        vm.startPrank(distributor);
        vm.expectRevert(abi.encodeWithSelector(EnforcedPause.selector));
        distributionManager.distribute("ANY_UID", distributor, 0, new DistributionManager.NFTClaim[](0), 0);
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

contract DistributionSignatureTest is BaseDistributionTest {
    function generateSignature(
        string memory UID,
        address to,
        uint256 nativeAmount,
        DistributionManager.NFTClaim[] memory nfts,
        uint256 erc20Amount
    ) public view returns (DistributionManager.Signature memory) {
        return generateCustomSignature(
            distributorKey, uint40(block.timestamp + 1 days), UID, to, nativeAmount, nfts, erc20Amount
        );
    }

    function generateCustomSignature(
        uint256 signerKey,
        uint40 expiration,
        string memory UID,
        address to,
        uint256 nativeAmount,
        DistributionManager.NFTClaim[] memory nfts,
        uint256 erc20Amount
    ) public view returns (DistributionManager.Signature memory) {
        address signer = vm.addr(signerKey);

        bytes32 messageHash = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encode(
                    signer,
                    expiration,
                    block.chainid,
                    address(distributionManager),
                    UID,
                    to,
                    nativeAmount,
                    nfts,
                    erc20Amount
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        return DistributionManager.Signature({authorizer: signer, expiration: expiration, value: signature});
    }

    function test_RevertIfNotDistributor() public {
        address receiver = makeAddr("receiver");
        string memory UID = "CLAIM_UID";
        (, uint256 nonDistributorKey) = makeAddrAndKey("nonDistributor");

        DistributionManager.NFTClaim[] memory claims = new DistributionManager.NFTClaim[](0);

        DistributionManager.Signature memory signature = generateCustomSignature(
            nonDistributorKey, uint40(block.timestamp + 1 days), UID, receiver, 1 ether, claims, 0
        );

        deal(receiver, 1 ether);
        vm.prank(receiver);
        vm.expectRevert("DistributionManager: Missing role DISTRIBUTOR_ROLE for authorizer");
        distributionManager.claim(UID, receiver, 1 ether, claims, 0, signature);
    }

    function test_RevertIfExpiredSignature() public {
        address receiver = makeAddr("receiver");
        string memory UID = "CLAIM_UID";
        DistributionManager.NFTClaim[] memory claims = new DistributionManager.NFTClaim[](0);

        DistributionManager.Signature memory signature =
            generateCustomSignature(distributorKey, uint40(block.timestamp - 1), UID, receiver, 1 ether, claims, 0);

        vm.prank(receiver);
        vm.expectRevert("DistributionManager: Signature expired");
        distributionManager.claim(UID, receiver, 1 ether, claims, 0, signature);
    }

    function test_RevertIfWrongSignature() public {
        address receiver = makeAddr("receiver");
        string memory UID = "CLAIM_UID";
        (, uint256 nonDistributorKey) = makeAddrAndKey("nonDistributor");
        DistributionManager.NFTClaim[] memory claims = new DistributionManager.NFTClaim[](0);

        DistributionManager.Signature memory signature = generateCustomSignature(
            nonDistributorKey, uint40(block.timestamp + 1 days), UID, receiver, 1 ether, claims, 0
        );
        signature.authorizer = distributor;

        vm.prank(receiver);
        vm.expectRevert("DistributionManager: Invalid Signature");
        distributionManager.claim(UID, receiver, 1 ether, claims, 0, signature);
    }

    function test_ValidClaimWithSignature() public {
        address receiver = makeAddr("receiver");
        string memory UID = "CLAIM_UID";
        uint256 nativeAmount = 1 ether;
        uint256 tokenAmount = 50 ether;

        DistributionManager.NFTClaim[] memory claims = new DistributionManager.NFTClaim[](1);
        claims[0] = DistributionManager.NFTClaim("TEST", NFT.Metadata("basic", "TEST", NFT.Rarity.EPIC, NFT.Variant.UP));

        DistributionManager.Signature memory signature = generateCustomSignature(
            distributorKey, uint40(block.timestamp + 1 days), UID, receiver, nativeAmount, claims, tokenAmount
        );

        uint256 balanceBefore = address(receiver).balance;
        vm.prank(receiver);

        DistributionManager.NFTClaimed[] memory expectedClaimed = new DistributionManager.NFTClaimed[](1);
        expectedClaimed[0] = DistributionManager.NFTClaimed(claims[0].UID, 1);

        vm.expectEmit(address(distributionManager));
        emit DistributionManager.Distribute(UID, receiver, nativeAmount, expectedClaimed, tokenAmount);

        distributionManager.claim(UID, receiver, nativeAmount, claims, tokenAmount, signature);

        assertTrue(distributionManager.isDistributed(UID));
        assertEq(token.balanceOf(receiver), tokenAmount);
        assertEq(receiver.balance, balanceBefore + nativeAmount);
        assertEq(nft.ownerOf(1), receiver);
    }
}
