// SPDX-License-Identifier: MIT
// Unagi Contracts v1.0.0 (TokenTransferRelay.sol)
pragma solidity 0.8.25;

import {IERC721} from "@openzeppelin/contracts/interfaces/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title TokenTransferRelay
 * @dev A two-step transfer service for native tokens, ERC20, and ERC721 tokens that supports refunds.
 * Each contract instance manages one set of ERC20/ERC721 token contracts.
 *
 * Transfer flow:
 * 1. Token holder reserves a transfer by calling `reserveTransfer`, placing funds in escrow
 * 2. Operator executes the transfer with `executeTransferFrom` to send funds to configured receivers
 * 3. Alternatively, operator can refund the transfer with `revertTransfer`
 *
 * Token holders must approve the contract before transfers.
 * Operators must have OPERATOR_ROLE to execute or revert transfers.
 * Maintenance accounts with MAINTENANCE_ROLE can configure receiver addresses.
 *
 * @custom:security-contact security@unagi.ch
 */
contract TokenTransferRelay is IERC721Receiver, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant MAINTENANCE_ROLE = keccak256("MAINTENANCE_ROLE");

    // Possible states for an existing token transfer
    bytes32 public constant TRANSFER_RESERVED = keccak256("TRANSFER_RESERVED");
    bytes32 public constant TRANSFER_EXECUTED = keccak256("TRANSFER_EXECUTED");
    bytes32 public constant TRANSFER_REVERTED = keccak256("TRANSFER_REVERTED");

    // The ERC721 origin contract from which tokens will be transferred
    IERC721 public ERC721Origin;

    // The ERC20 origin contract from which tokens will be transferred
    IERC20 public ERC20Origin;

    // Address to which Native tokens will be sent once a transfer is executed
    address public NativeReceiver;

    // Address to which ERC721 tokens will be sent once a transfer is executed
    address public ERC721Receiver;

    // Address to which ERC20 tokens will be sent once a transfer is executed
    address public ERC20Receiver;

    struct Transfer {
        address from;
        uint256 nativeAmount;
        uint256[] erc721Ids;
        uint256 erc20Amount;
        bytes32 state;
    }

    // (keccak256 UID => Transfer) mapping of transfer operations
    mapping(bytes32 => Transfer) private _transfers;

    constructor(
        address _erc721,
        address _erc20,
        address _nativeReceiver,
        address _erc721Receiver,
        address _erc20Receiver
    ) {
        ERC721Origin = IERC721(_erc721);
        ERC20Origin = IERC20(_erc20);
        NativeReceiver = _nativeReceiver;
        ERC721Receiver = _erc721Receiver;
        ERC20Receiver = _erc20Receiver;

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl) returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId || AccessControl.supportsInterface(interfaceId);
    }

    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     */
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /**
     * @dev sets the address to which ERC20 tokens should be sent to.
     * The function caller must have been granted MAINTENANCE_ROLE.
     */
    function setNativeReceiver(address _nativeReceiver) external onlyRole(MAINTENANCE_ROLE) {
        NativeReceiver = _nativeReceiver;
    }

    /**
     * @dev sets the address to which ERC20 tokens should be sent to.
     * The function caller must have been granted MAINTENANCE_ROLE.
     */
    function setERC721Receiver(address _erc721Receiver) external onlyRole(MAINTENANCE_ROLE) {
        ERC721Receiver = _erc721Receiver;
    }

    /**
     * @dev sets the address to which ERC721 tokens should be sent to.
     * The function caller must have been granted MAINTENANCE_ROLE.
     */
    function setERC20Receiver(address _erc20Receiver) external onlyRole(MAINTENANCE_ROLE) {
        ERC20Receiver = _erc20Receiver;
    }

    function getTransferKey(bytes32 UID, address from) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(UID, from));
    }

    function getTransfer(bytes32 UID, address from) public view returns (Transfer memory) {
        return _transfers[getTransferKey(UID, from)];
    }

    function isTransferReserved(bytes32 UID, address from) public view returns (bool) {
        return getTransfer(UID, from).state == TRANSFER_RESERVED;
    }

    function isTransferProcessed(bytes32 UID, address from) public view returns (bool) {
        bytes32 state = getTransfer(UID, from).state;
        return state == TRANSFER_EXECUTED || state == TRANSFER_REVERTED;
    }

    function reserveTransfer(bytes32 UID, uint256[] calldata tokenIds, uint256 amount) external payable {
        _reserveTransfer(UID, msg.sender, tokenIds, amount);
    }

    function executeTransferFrom(bytes32 UID, address from) external onlyRole(OPERATOR_ROLE) {
        _executeTransfer(UID, from);
    }

    function revertTransfer(bytes32 UID, address from) external onlyRole(OPERATOR_ROLE) {
        require(isTransferReserved(UID, from), "TokenTransferRelay: Transfer is not reserved");

        Transfer storage transfer = _transfers[getTransferKey(UID, from)];
        transfer.state = TRANSFER_REVERTED;

        (bool success,) = transfer.from.call{value: transfer.nativeAmount}("");
        require(success);
        _batchERC721Transfer(address(this), transfer.from, transfer.erc721Ids);
        _ERC20Transfer(address(this), transfer.from, transfer.erc20Amount);

        emit TransferReverted(UID, from);
    }

    /**
     * @dev sends a batch of NFT tokens from `from` to `to`.
     * Requires this contract to be approved by the tokens' holder before hand.
     */
    function _batchERC721Transfer(address from, address to, uint256[] memory tokenIds) private {
        uint256 length = tokenIds.length;
        for (uint256 i = 0; i < length;) {
            ERC721Origin.safeTransferFrom(from, to, tokenIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev sends `amount` of ERC20Origin tokens from `from` to `to`.
     * Requires this contract to be approved by the tokens' holder before hand.
     */
    function _ERC20Transfer(address from, address to, uint256 amount) private {
        if (amount > 0) {
            if (from != address(this)) {
                ERC20Origin.safeTransferFrom(from, to, amount);
            } else {
                ERC20Origin.safeTransfer(to, amount);
            }
        }
    }

    function _reserveTransfer(bytes32 UID, address from, uint256[] calldata tokenIds, uint256 amount) private {
        require(!isTransferReserved(UID, from), "TokenTransferRelay: Transfer already reserved");
        require(!isTransferProcessed(UID, from), "TokenTransferRelay: Transfer already processed");

        // Save new Transfer instance to storage
        _transfers[getTransferKey(UID, from)] = Transfer(from, msg.value, tokenIds, amount, TRANSFER_RESERVED);

        // Place tokens under escrow
        _batchERC721Transfer(from, address(this), tokenIds);
        _ERC20Transfer(from, address(this), amount);

        emit TransferReserved(UID, from, msg.value, tokenIds, amount);
    }

    function _executeTransfer(bytes32 UID, address from) private {
        require(isTransferReserved(UID, from), "TokenTransferRelay: Transfer is not reserved");

        Transfer storage transfer = _transfers[getTransferKey(UID, from)];
        transfer.state = TRANSFER_EXECUTED;

        (bool success,) = NativeReceiver.call{value: transfer.nativeAmount}("");
        require(success);
        _batchERC721Transfer(address(this), ERC721Receiver, transfer.erc721Ids);
        _ERC20Transfer(address(this), ERC20Receiver, transfer.erc20Amount);

        emit TransferExecuted(UID, from);
    }

    event TransferReserved(bytes32 UID, address from, uint256 nativeAmount, uint256[] erc721Ids, uint256 erc20Amount);
    event TransferExecuted(bytes32 UID, address from);
    event TransferReverted(bytes32 UID, address from);
}
