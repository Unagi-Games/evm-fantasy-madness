// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {TokenTransferRelay} from "@/TokenTransferRelay.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestERC721} from "./mocks/TestERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract BaseTransferRelayTest is Test {
    TestERC721 public nft;
    TestERC20 public token;
    TokenTransferRelay public relay;

    address public payer = makeAddr("holder");
    address public receiver = makeAddr("receiver");

    function setUp() public virtual {
        token = new TestERC20();
        nft = new TestERC721();

        relay = new TokenTransferRelay(address(nft), address(token), receiver, receiver, receiver);

        vm.startPrank(payer);
        nft.setApprovalForAll(address(relay), true);
        token.approve(address(relay), type(uint256).max);
        vm.stopPrank();
    }
}

contract TransferRelayUserTest is BaseTransferRelayTest {
    function test_ReserveTransfer(uint256 nativeAmount, uint8 nftCount, uint256 tokenAmount) public {
        uint256[] memory nfts = new uint256[](nftCount);
        for (uint256 i = 0; i < nfts.length; i++) {
            nfts[i] = i;
            nft.mint(payer, nfts[i]);
        }
        deal(payer, nativeAmount);
        deal(address(token), payer, tokenAmount);
        vm.startPrank(payer);

        vm.expectEmit();
        emit TokenTransferRelay.TransferReserved(keccak256("TRANSFER_UID"), payer, nativeAmount, nfts, tokenAmount);
        relay.reserveTransfer{value: nativeAmount}(keccak256("TRANSFER_UID"), nfts, tokenAmount);

        assertTrue(relay.isTransferReserved(keccak256("TRANSFER_UID"), payer));
        assertEq(address(relay).balance, nativeAmount);
        assertEq(token.balanceOf(address(relay)), tokenAmount);
        for (uint256 i = 0; i < nfts.length; i++) {
            assertEq(nft.ownerOf(nfts[i]), address(relay));
        }
    }

    function test_RevertDuplicateReservation() public {
        vm.startPrank(payer);
        relay.reserveTransfer(keccak256("TRANSFER_UID"), new uint256[](0), 0);

        vm.expectRevert("TokenTransferRelay: Transfer already reserved");
        relay.reserveTransfer(keccak256("TRANSFER_UID"), new uint256[](0), 0);
        vm.stopPrank();
    }

    function test_RevertReserveIfProcessed() public {
        relay.grantRole(relay.OPERATOR_ROLE(), address(this));

        vm.prank(payer);
        relay.reserveTransfer(keccak256("TRANSFER_UID"), new uint256[](0), 0);

        vm.prank(address(this));
        relay.executeTransferFrom(keccak256("TRANSFER_UID"), payer);

        vm.startPrank(payer);
        vm.expectRevert("TokenTransferRelay: Transfer already processed");
        relay.reserveTransfer(keccak256("TRANSFER_UID"), new uint256[](0), 0);
        vm.stopPrank();
    }
}

contract TransferRelayOperatorTest is BaseTransferRelayTest {
    function test_RevertNonOperatorExecute() public {
        vm.prank(payer);
        relay.reserveTransfer(keccak256("TRANSFER_UID"), new uint256[](0), 0);

        vm.startPrank(makeAddr("nonOperator"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, makeAddr("nonOperator"), relay.OPERATOR_ROLE()
            )
        );
        relay.executeTransferFrom(keccak256("TRANSFER_UID"), payer);
    }

    function test_RevertNonOperatorRevert() public {
        vm.prank(payer);
        relay.reserveTransfer(keccak256("TRANSFER_UID"), new uint256[](0), 0);

        vm.startPrank(makeAddr("nonOperator"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, makeAddr("nonOperator"), relay.OPERATOR_ROLE()
            )
        );
        relay.revertTransfer(keccak256("TRANSFER_UID"), payer);
    }

    function test_ExecuteTransfer(uint256 nativeAmount, uint8 nftCount, uint256 tokenAmount) public {
        relay.grantRole(relay.OPERATOR_ROLE(), address(this));
        uint256[] memory nfts = new uint256[](nftCount);
        for (uint256 i = 0; i < nfts.length; i++) {
            nfts[i] = i;
            nft.mint(payer, nfts[i]);
        }
        deal(payer, nativeAmount);
        deal(address(token), payer, tokenAmount);

        vm.prank(payer);
        relay.reserveTransfer{value: nativeAmount}(keccak256("TRANSFER_UID"), nfts, tokenAmount);

        vm.prank(address(this));
        vm.expectEmit();
        emit TokenTransferRelay.TransferExecuted(keccak256("TRANSFER_UID"), payer);
        relay.executeTransferFrom(keccak256("TRANSFER_UID"), payer);

        assertTrue(relay.isTransferProcessed(keccak256("TRANSFER_UID"), payer));
        assertEq(address(relay).balance, 0);
        assertEq(token.balanceOf(address(relay)), 0);
        assertEq(receiver.balance, nativeAmount);
        assertEq(token.balanceOf(receiver), tokenAmount);
        for (uint256 i = 0; i < nfts.length; i++) {
            assertEq(nft.ownerOf(nfts[i]), receiver);
        }
    }

    function test_RevertTransfer(uint256 nativeAmount, uint8 nftCount, uint256 tokenAmount) public {
        relay.grantRole(relay.OPERATOR_ROLE(), address(this));
        uint256[] memory nfts = new uint256[](nftCount);
        for (uint256 i = 0; i < nfts.length; i++) {
            nfts[i] = i;
            nft.mint(payer, nfts[i]);
        }
        deal(payer, nativeAmount);
        deal(address(token), payer, tokenAmount);

        vm.prank(payer);
        relay.reserveTransfer{value: nativeAmount}(keccak256("TRANSFER_UID"), nfts, tokenAmount);

        vm.prank(address(this));
        vm.expectEmit();
        emit TokenTransferRelay.TransferReverted(keccak256("TRANSFER_UID"), payer);
        relay.revertTransfer(keccak256("TRANSFER_UID"), payer);

        assertTrue(relay.isTransferProcessed(keccak256("TRANSFER_UID"), payer));
        assertEq(address(relay).balance, 0);
        assertEq(token.balanceOf(address(relay)), 0);
        assertEq(payer.balance, nativeAmount);
        assertEq(token.balanceOf(payer), tokenAmount);
        for (uint256 i = 0; i < nfts.length; i++) {
            assertEq(nft.ownerOf(nfts[i]), payer);
        }
    }
}

contract TransferRelayMaintenanceTest is BaseTransferRelayTest {
    function test_RevertSetReceiverIfNotMaintenance() public {
        address nonMaintainer = makeAddr("nonMaintainer");

        vm.startPrank(nonMaintainer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, nonMaintainer, relay.MAINTENANCE_ROLE()
            )
        );
        relay.setNativeReceiver(payable(makeAddr("newReceiver")));
    }
}
