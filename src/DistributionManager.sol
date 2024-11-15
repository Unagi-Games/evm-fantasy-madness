// SPDX-License-Identifier: MIT
// Unagi Contracts v1.0.0 (DistributionManager.sol)
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title DistributionManager
 * @dev Allow to distribute a pack of assets only once.
 * @custom:security-contact security@unagi.ch
 */
contract DistributionManager is AccessControl, Pausable {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    IERC20 public immutable _TOKEN_CONTRACT;
    IERC721 public immutable _NFT_CONTRACT;

    // (UID => used) mapping of UID
    mapping(string => bool) private _UIDs;

    constructor(address tokenAddress, address nftAddress) {
        _TOKEN_CONTRACT = IERC20(tokenAddress);
        _NFT_CONTRACT = IERC721(nftAddress);

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
     * @dev Distribute a pack of assets.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     * - Caller must have role DISTRIBUTOR_ROLE.
     * - UID must not have been already distributed.
     */
    function distribute(string memory UID, address to, uint256 tokenAmount, uint256, uint256[] memory tokenIds)
        external
        payable
        onlyRole(DISTRIBUTOR_ROLE)
        whenNotPaused
    {
        _reserveUID(UID);

        if (msg.value > 0) {
            (bool success,) = to.call{value: msg.value}("");
            require(success, "DistributionManager: Transfer failed");
        }

        if (tokenAmount > 0) {
            _TOKEN_CONTRACT.transferFrom(_msgSender(), to, tokenAmount);
        }

        for (uint256 i = 0; i < tokenIds.length; i++) {
            _NFT_CONTRACT.safeTransferFrom(_msgSender(), to, tokenIds[i]);
        }

        emit Distribute(UID);
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

    event Distribute(string UID);
}
