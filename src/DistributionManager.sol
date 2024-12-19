// SPDX-License-Identifier: MIT
// Unagi Contracts v1.0.0 (DistributionManager.sol)
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@/NFT.sol";

/**
 * @title DistributionManager
 * @dev Allow to distribute a pack of assets only once.
 * @custom:security-contact security@unagi.ch
 */
contract DistributionManager is AccessControl, Pausable {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    IERC20 public ERC20Origin;
    NFT public ERC721Origin;

    struct Signature {
        uint40 expiration;
        address authorizer;
        bytes value;
    }

    struct NFTClaim {
        string UID;
        NFT.Metadata metadata;
    }

    struct NFTClaimed {
        string UID;
        uint256 tokenId;
    }

    // (UID => used) mapping of UID
    mapping(string => bool) private _UIDs;

    constructor(address tokenAddress, address nftAddress) {
        ERC20Origin = IERC20(tokenAddress);
        ERC721Origin = NFT(nftAddress);

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /**
     * @dev Pause token transfers.
     *
     * Requirements:
     *
     * - Caller must have role PAUSER_ROLE.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause token transfers.
     *
     * Requirements:
     *
     * - Caller must have role PAUSER_ROLE.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Returns true if UID is already distributed
     */
    function isDistributed(string memory UID) public view returns (bool) {
        return _UIDs[UID];
    }

    /**
     * @dev Distribute a pack of assets including native tokens, NFTs, and ERC20 tokens.
     *
     * Requirements:
     * - The contract must not be paused.
     * - Caller must have role DISTRIBUTOR_ROLE.
     * - UID must not have been already distributed.
     * @param UID Unique identifier for this distribution
     * @param to Address receiving the assets
     * @param nativeWei Amount of native currency to send in wei
     * @param nfts Array of NFTs to mint with their metadata
     * @param erc20Wei Amount of ERC20 tokens to transfer in wei
     */
    function distribute(string memory UID, address to, uint256 nativeWei, NFTClaim[] calldata nfts, uint256 erc20Wei)
        external
        onlyRole(DISTRIBUTOR_ROLE)
    {
        _distribute(UID, to, nativeWei, nfts, erc20Wei);
    }

    /**
     * @dev Allows any address to claim a pack of assets with a valid distributor signature.
     *
     * Requirements:
     * - The contract must not be paused.
     * - Signature must be from an address with DISTRIBUTOR_ROLE.
     * - Signature must not be expired.
     * - UID must not have been already distributed.
     * @param UID Unique identifier for this claim
     * @param to Address receiving the assets
     * @param nativeWei Amount of native currency to send in wei
     * @param nfts Array of NFTs to mint with their metadata
     * @param erc20Wei Amount of ERC20 tokens to transfer in wei
     * @param signature Valid distributor signature authorizing the claim
     */
    function claim(
        string memory UID,
        address to,
        uint256 nativeWei,
        NFTClaim[] calldata nfts,
        uint256 erc20Wei,
        Signature calldata signature
    ) external {
        _verifySignature(signature, UID, to, nativeWei, nfts, erc20Wei);
        _distribute(UID, to, nativeWei, nfts, erc20Wei);
    }

    /**
     * @dev Internal implementation of distribution logic.
     * Mints NFTs, transfers native tokens and ERC20 tokens to recipient.
     * @param UID Unique identifier for this distribution
     * @param to Address receiving the assets
     * @param nativeWei Amount of native currency to send in wei
     * @param nfts Array of NFTs to mint with their metadata
     * @param erc20Wei Amount of ERC20 tokens to transfer in wei
     */
    function _distribute(string memory UID, address to, uint256 nativeWei, NFTClaim[] calldata nfts, uint256 erc20Wei)
        private
        whenNotPaused
    {
        _reserveUID(UID);

        if (nativeWei > 0) {
            (bool success,) = to.call{value: nativeWei}("");
            require(success, "DistributionManager: Transfer failed");
        }

        NFTClaimed[] memory nftsClaimed = new NFTClaimed[](nfts.length);
        for (uint256 i = 0; i < nfts.length; i++) {
            uint256 tokenId = ERC721Origin.safeMint(to, nfts[i].metadata);
            nftsClaimed[i] = NFTClaimed(nfts[i].UID, tokenId);
        }

        if (erc20Wei > 0) {
            ERC20Origin.transfer(to, erc20Wei);
        }

        emit Distribute(UID, to, nativeWei, nftsClaimed, erc20Wei);
    }

    /**
     * @dev Reserve an UID
     *
     * Requirements:
     *
     * - UID must be free.
     */
    function _reserveUID(string memory UID) private {
        require(!isDistributed(UID), "DistributionManager: UID must be free.");

        _UIDs[UID] = true;
    }

    /**
     * @notice Internal function to verify a signature
     * @dev The signature must be signed by an operator and contain:
     * - authorizer
     * - expiration timestamp
     * - contract chain id and address
     * - transfer UID
     * - native/token/nft amounts
     */
    function _verifySignature(
        Signature calldata signature,
        string memory UID,
        address to,
        uint256 nativeAmount,
        NFTClaim[] calldata nfts,
        uint256 erc20Amount
    ) internal view {
        require(
            hasRole(DISTRIBUTOR_ROLE, signature.authorizer),
            "DistributionManager: Missing role DISTRIBUTOR_ROLE for authorizer"
        );
        require(block.timestamp <= signature.expiration, "DistributionManager: Signature expired");
        require(
            SignatureChecker.isValidSignatureNow(
                signature.authorizer,
                MessageHashUtils.toEthSignedMessageHash(
                    keccak256(
                        abi.encode(
                            signature.authorizer,
                            signature.expiration,
                            block.chainid,
                            address(this),
                            UID,
                            to,
                            nativeAmount,
                            nfts,
                            erc20Amount
                        )
                    )
                ),
                signature.value
            ),
            "DistributionManager: Invalid Signature"
        );
    }

    /**
     * @dev Emitted when assets are distributed or claimed
     * @param UID Unique identifier of the distribution
     * @param to Address that received the assets
     * @param nativeWei Amount of native currency sent in wei
     * @param nfts Array of NFTs that were minted with their IDs
     * @param erc20Wei Amount of ERC20 tokens transferred in wei
     */
    event Distribute(string indexed UID, address to, uint256 nativeWei, NFTClaimed[] nfts, uint256 erc20Wei);
}
