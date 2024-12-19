// SPDX-License-Identifier: MIT
// Unagi Contracts v1.0.0 (NFT.sol)
pragma solidity 0.8.25;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title NFT
 * @dev Implementation of an ERC721 token with metadata extension including rarity and variant attributes.
 * Each NFT has specific metadata containing a template, ticker, rarity level (COMMON, RARE, EPIC),
 * and variant type (UP, DOWN). Token URIs are constructed from these attributes.
 * See https://github.com/ethereum/EIPs/blob/34a2d1fcdf3185ca39969a7b076409548307b63b/EIPS/eip-721.md#specification
 * @custom:security-contact security@unagi.ch
 */
contract NFT is AccessControl, Pausable, ERC721 {
    using Strings for uint256;

    bytes32 public constant MINT_ROLE = keccak256("MINT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    enum Rarity {
        COMMON,
        RARE,
        EPIC
    }

    string[3] private RarityNames = ["COMMON", "RARE", "EPIC"];

    enum Variant {
        UP,
        DOWN
    }

    string[2] private VariantNames = ["UP", "DOWN"];

    struct Metadata {
        string template;
        string ticker;
        Rarity rarity;
        Variant variant;
    }

    uint256 private _tokenId;
    mapping(uint256 tokenId => Metadata) private _metadata;
    string private _baseURIValue;

    constructor(uint256 initialId, string memory name, string memory symbol) ERC721(name, symbol) {
        _tokenId = initialId;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, AccessControl) returns (bool) {
        return ERC721.supportsInterface(interfaceId) || AccessControl.supportsInterface(interfaceId);
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
     * @dev Allow to mint a new NFT.
     * @param to The address that will own the minted NFT
     * @param metadata The NFT metadata containing template, ticker, rarity and variant
     * @return tokenId The ID of the newly minted NFT
     *
     * Requirements:
     * - Caller must have role MINT_ROLE.
     */
    function safeMint(address to, Metadata memory metadata) public onlyRole(MINT_ROLE) returns (uint256) {
        _tokenId++;
        _safeMint(to, _tokenId);
        _metadata[_tokenId] = metadata;
        return _tokenId;
    }

    /**
     * @dev Allow to set base URI.
     * @param baseURIValue The base URI to be set for the NFTs
     *
     * Requirements:
     *
     * - Caller must have role DEFAULT_ADMIN_ROLE.
     */
    function setBaseURI(string memory baseURIValue) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseURIValue = baseURIValue;
    }

    /**
     * @dev Base URI for computing {tokenURI}.
     * @return The base URI string
     */
    function _baseURI() internal view virtual override returns (string memory) {
        return _baseURIValue;
    }

    /**
     * @dev Returns the URI for a given token ID. Format: baseURI/ticker/template/variant/rarity/metadata.json
     * @param tokenId The token ID to get the URI for
     * @return The token URI string
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        _requireOwned(tokenId);
        Metadata memory metadata = _metadata[tokenId];
        return string(
            abi.encodePacked(
                _baseURI(),
                "/",
                metadata.ticker,
                "/",
                metadata.template,
                "/",
                VariantNames[uint256(metadata.variant)],
                "/",
                RarityNames[uint256(metadata.rarity)],
                "/metadata.json"
            )
        );
    }
}
