// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {TokenTransferRelay} from "@/TokenTransferRelay.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestERC721} from "./mocks/TestERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract BaseTransferRelayTest is Test {
    TestERC721 public nft;
    TestERC20 public token;
    TokenTransferRelay public relay;

    uint256 public operatorKey;

    address public payer = makeAddr("holder");
    address public receiver = makeAddr("receiver");

    function setUp() public virtual {
        token = new TestERC20();
        nft = new TestERC721();

        relay = new TokenTransferRelay(address(nft), address(token), receiver, receiver, receiver);

        (, operatorKey) = makeAddrAndKey("operator");
        relay.grantRole(relay.OPERATOR_ROLE(), vm.addr(operatorKey));

        vm.startPrank(payer);
        nft.setApprovalForAll(address(relay), true);
        token.approve(address(relay), type(uint256).max);
        vm.stopPrank();
    }

    function reserveTransfer(string memory UID, uint256 nativeAmount, uint256[] memory tokenIds, uint256 erc20Amount)
        public
    {
        TokenTransferRelay.Signature memory signature = generateSignature(UID, nativeAmount, tokenIds, erc20Amount);
        relay.reserveTransfer{value: nativeAmount}(UID, tokenIds, erc20Amount, signature);
    }

    function generateSignature(string memory UID, uint256 nativeAmount, uint256[] memory tokenIds, uint256 erc20Amount)
        public
        view
        returns (TokenTransferRelay.Signature memory)
    {
        return generateCustomSignature(
            operatorKey, uint40(block.timestamp + 1 days), UID, nativeAmount, tokenIds, erc20Amount
        );
    }

    function generateCustomSignature(
        uint256 operatorKey_,
        uint40 expiration,
        string memory UID,
        uint256 nativeAmount,
        uint256[] memory tokenIds,
        uint256 erc20Amount
    ) public view returns (TokenTransferRelay.Signature memory) {
        address operator_ = vm.addr(operatorKey_);

        bytes32 messageHash = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    operator_, expiration, block.chainid, address(relay), UID, nativeAmount, tokenIds, erc20Amount
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey_, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        return TokenTransferRelay.Signature({authorizer: operator_, expiration: expiration, value: signature});
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
        emit TokenTransferRelay.TransferReserved("TRANSFER_UID", nativeAmount, nfts, tokenAmount);
        reserveTransfer("TRANSFER_UID", nativeAmount, nfts, tokenAmount);

        assertTrue(relay.isTransferReserved("TRANSFER_UID"));
        assertEq(address(relay).balance, nativeAmount);
        assertEq(token.balanceOf(address(relay)), tokenAmount);
        for (uint256 i = 0; i < nfts.length; i++) {
            assertEq(nft.ownerOf(nfts[i]), address(relay));
        }
    }

    function test_RevertDuplicateReservation() public {
        vm.startPrank(payer);
        reserveTransfer("TRANSFER_UID", 0, new uint256[](0), 0);

        vm.expectRevert("TokenTransferRelay: Transfer already reserved");
        reserveTransfer("TRANSFER_UID", 0, new uint256[](0), 0);
        vm.stopPrank();
    }

    function test_RevertReserveIfProcessed() public {
        relay.grantRole(relay.OPERATOR_ROLE(), address(this));

        vm.prank(payer);
        reserveTransfer("TRANSFER_UID", 0, new uint256[](0), 0);

        vm.prank(address(this));
        relay.executeTransfer("TRANSFER_UID");

        vm.startPrank(payer);
        vm.expectRevert("TokenTransferRelay: Transfer already processed");
        reserveTransfer("TRANSFER_UID", 0, new uint256[](0), 0);
        vm.stopPrank();
    }
}

contract TransferRelayOperatorTest is BaseTransferRelayTest {
    function test_RevertNonOperatorExecute() public {
        vm.prank(payer);
        reserveTransfer("TRANSFER_UID", 0, new uint256[](0), 0);

        vm.startPrank(makeAddr("nonOperator"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, makeAddr("nonOperator"), relay.OPERATOR_ROLE()
            )
        );
        relay.executeTransfer("TRANSFER_UID");
    }

    function test_RevertNonOperatorRevert() public {
        vm.prank(payer);
        reserveTransfer("TRANSFER_UID", 0, new uint256[](0), 0);

        vm.startPrank(makeAddr("nonOperator"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, makeAddr("nonOperator"), relay.OPERATOR_ROLE()
            )
        );
        relay.revertTransfer("TRANSFER_UID");
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
        reserveTransfer("TRANSFER_UID", nativeAmount, nfts, tokenAmount);

        vm.prank(address(this));
        vm.expectEmit();
        emit TokenTransferRelay.TransferExecuted("TRANSFER_UID");
        relay.executeTransfer("TRANSFER_UID");

        assertTrue(relay.isTransferProcessed("TRANSFER_UID"));
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
        reserveTransfer("TRANSFER_UID", nativeAmount, nfts, tokenAmount);

        vm.prank(address(this));
        vm.expectEmit();
        emit TokenTransferRelay.TransferReverted("TRANSFER_UID");
        relay.revertTransfer("TRANSFER_UID");

        assertTrue(relay.isTransferProcessed("TRANSFER_UID"));
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

contract TransferRelaySignatureTest is BaseTransferRelayTest {
    function test_RevertIfNotOperator() public {
        string memory UID = "TRANSFER_UID";
        (, uint256 nonOperatorKey) = makeAddrAndKey("nonOperator");
        uint256[] memory tokenIds = new uint256[](0);

        TokenTransferRelay.Signature memory signature =
            generateCustomSignature(nonOperatorKey, uint40(block.timestamp + 1 days), UID, 1 ether, tokenIds, 0);

        deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert("TokenTransferRelay: Missing role OPERATOR_ROLE for authorizer");
        relay.reserveTransfer{value: 1 ether}(UID, tokenIds, 0, signature);
    }

    function test_RevertIfWrongSignature() public {
        string memory UID = "TRANSFER_UID";
        (, uint256 nonOperatorKey) = makeAddrAndKey("nonOperator");
        uint256[] memory tokenIds = new uint256[](0);

        // Sign with a nonOperator and try to mimic the real operator.
        TokenTransferRelay.Signature memory signature =
            generateCustomSignature(nonOperatorKey, uint40(block.timestamp + 1 days), UID, 1 ether, tokenIds, 0);
        signature.authorizer = vm.addr(operatorKey);

        deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert("TokenTransferRelay: Invalid Signature");
        relay.reserveTransfer{value: 1 ether}(UID, tokenIds, 0, signature);
    }

    function test_RevertIfExpired() public {
        string memory UID = "TRANSFER_UID";
        uint256[] memory tokenIds = new uint256[](0);
        uint40 expiredTimestamp = uint40(block.timestamp - 1);

        TokenTransferRelay.Signature memory signature =
            generateCustomSignature(operatorKey, expiredTimestamp, UID, 1 ether, tokenIds, 0);

        deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert("TokenTransferRelay: Signature expired");
        relay.reserveTransfer{value: 1 ether}(UID, tokenIds, 0, signature);
    }

    function test_RevertIfWrongAmount() public {
        string memory UID = "TRANSFER_UID";
        uint256[] memory tokenIds = new uint256[](0);
        uint256 signedAmount = 1 ether;
        uint256 sentAmount = 2 ether;

        TokenTransferRelay.Signature memory signature = generateSignature(UID, signedAmount, tokenIds, 0);

        deal(payer, sentAmount);
        vm.prank(payer);
        vm.expectRevert("TokenTransferRelay: Invalid Signature");
        relay.reserveTransfer{value: sentAmount}(UID, tokenIds, 0, signature);
    }

    function test_RevertIfDuplicateUID() public {
        string memory UID = "TRANSFER_UID";
        uint256[] memory tokenIds = new uint256[](0);
        uint256 nativeAmount = 1 ether;

        TokenTransferRelay.Signature memory signature = generateSignature(UID, nativeAmount, tokenIds, 0);

        deal(payer, nativeAmount * 2);
        // First reservation succeeds
        vm.prank(payer);
        relay.reserveTransfer{value: nativeAmount}(UID, tokenIds, 0, signature);

        // Second reservation fails
        vm.prank(payer);
        vm.expectRevert("TokenTransferRelay: Transfer already reserved");
        relay.reserveTransfer{value: nativeAmount}(UID, tokenIds, 0, signature);
    }
}
