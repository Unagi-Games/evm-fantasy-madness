// SPDX-License-Identifier: MIT
// Unagi Contracts v1.0.0 (Marketplace.sol)
pragma solidity 0.8.25;

import "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title Marketplace
 * @dev This contract allows native currency and ERC721 (NFT)
 * holders to exchange their assets.
 *
 * A NFT holder can create, update or delete a listing for one of their NFTs.
 * To create a listing, the NFT holder must give their approval for the Marketplace
 * on the NFT they want to list. Then, the NFT holder must call the function `createListingFrom`.
 * A reserved listing can also be created, meaning only a specific address, approved by
 * the NFT owner, can accept the listing. To remove the listing, the NFT holder must call the
 * function `destroyListingFrom`.
 *
 * A NFT holder can also update their existing listings through the `updateListingFrom` function.
 * This function allows the NFT holder to update a given listing's price and reserved offer.
 *
 * A user can accept a listing if the listing is either public, or has a reserved offer
 * set for their address. The function `isReservationOpenFor` can be used to verify if a given address
 * can accept a specific listing. To accept a listing, the user must send the required amount of native currency
 * when calling the function `acceptListing`.
 *
 * Once a NFT is sold, sell, buy and burn fees (readable through `marketplacePercentFees()`)
 * will be applied on the payment. Sell and buy fees are forwarded to the marketplace
 * fees receiver (readable through `marketplaceFeesReceiver()`), while the burn fee is forwarded to the DEAD address.
 * The rest is sent to the seller.
 *
 * The fees are editable by FEE_MANAGER_ROLE.
 * The fee receiver is editable by FEE_MANAGER_ROLE.
 *
 * For off-chain payments, an option can be set on a listing.
 * Options are restricted to only one per listing at any time.
 * Options are rate limited per listing.
 *
 * @custom:security-contact security@unagi.ch
 */
contract Marketplace is AccessControlUpgradeable {
    using Math for uint256;

    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    IERC721 public _NFT_CONTRACT;

    // (nft ID => prices as wei) mapping of listings
    mapping(uint64 => uint256) private _listings;

    // Percent fees applied on each listing: sell, buy and burn fees.
    uint8 private _marketplaceSellPercentFee;
    uint8 private _marketplaceBuyPercentFee;
    uint8 private _marketplaceBurnPercentFee;

    // Fees receiver address
    address private _marketplaceFeesReceiver;

    // (nft ID => address) mapping of reserved offers
    mapping(uint64 => address) private _reservedOffers;

    function initialize(address nftAddress) public initializer {
        _NFT_CONTRACT = IERC721(nftAddress);

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /**
     * @dev Compute the current share for a given price.
     * Remainder is given to the seller.
     * Return a tuple of wei:
     * - First element is wei for the seller
     * - Second element is wei fee for marketplace (sell)
     * - Third element is wei fee for marketplace (buy)
     * - Fourth element is wei fee for burn address
     */
    function computeListingShares(uint256 weiPrice)
        public
        view
        returns (
            uint256 sellerShare,
            uint256 marketplaceSellFeeShare,
            uint256 marketplaceBuyFeeShare,
            uint256 marketplaceBurnFeeShare
        )
    {
        (uint8 sellFee, uint8 buyFee, uint8 burnFee) = marketplacePercentFees();
        marketplaceSellFeeShare = weiPrice.mulDiv(sellFee, 100);
        marketplaceBuyFeeShare = weiPrice.mulDiv(buyFee, 100);
        marketplaceBurnFeeShare = weiPrice.mulDiv(burnFee, 100);
        sellerShare = weiPrice - marketplaceSellFeeShare - marketplaceBurnFeeShare;
    }

    /**
     * @dev See _createListingFrom(address,uint64,uint256,address)
     */
    function createListingFrom(address from, uint64 tokenId, uint256 weiPrice) external {
        _createListingFrom(from, tokenId, weiPrice, address(0));
    }

    /**
     * @dev See _createListingFrom(address,uint64,uint256,address)
     */
    function createListingFrom(address from, uint64 tokenId, uint256 weiPrice, address reserve) external {
        require(reserve != address(0), "Marketplace: Cannot create reserved listing for 0 address");

        _createListingFrom(from, tokenId, weiPrice, reserve);
    }

    /**
     * @dev See _acceptListing(uint64,address)
     */
    function acceptListing(uint64 tokenId) external payable {
        _acceptListing(tokenId, msg.sender);
    }

    /**
     * @dev See _acceptListing(uint64,address)
     */
    function acceptListing(uint64 tokenId, address nftReceiver) external payable {
        _acceptListing(tokenId, nftReceiver);
    }

    /**
     * @dev Allow to destroy a listing for a given NFT ID.
     *
     * Emits a {ListingDestroyed} event.
     *
     * Requirements:
     *
     * - NFT ID should be listed.
     * - from must be the NFT owner.
     * - msg.sender should be either the NFT owner or approved by the NFT owner.
     * - Marketplace contract should be approved for the given NFT ID.
     */
    function destroyListingFrom(address from, uint64 tokenId) external {
        require(hasListing(tokenId), "Marketplace: Listing does not exist");
        address nftOwner = _NFT_CONTRACT.ownerOf(tokenId);
        require(nftOwner == from, "Marketplace: Destroy listing of NFT that is not own");
        require(
            nftOwner == msg.sender || _NFT_CONTRACT.isApprovedForAll(nftOwner, msg.sender),
            "Marketplace: Only the NFT owner or its operator are allowed to destroy a listing"
        );

        delete _listings[tokenId];

        if (_reservedOffers[tokenId] != address(0)) {
            delete _reservedOffers[tokenId];
        }

        emit ListingDestroyed(tokenId, nftOwner);
    }

    /**
     * @dev Allow to update a listing for a given NFT ID at a given TOKEN wei price.
     *
     * Emits a {ListingUpdated} event.
     *
     * Requirements:
     *
     * - NFT ID should be listed.
     * - tokenWeiPrice should be strictly positive.
     * - reserve address must be different than from.
     * - from must be the NFT owner.
     * - msg.sender should be either the NFT owner or approved by the NFT owner.
     * - Marketplace contract should be approved for the given NFT ID.
     */
    function updateListingFrom(address from, uint64 tokenId, uint256 weiPrice, address reserve) external {
        require(hasListing(tokenId), "Marketplace: Listing does not exist");
        address nftOwner = _NFT_CONTRACT.ownerOf(tokenId);
        require(nftOwner == from, "Marketplace: Update listing of NFT that is not own");
        require(
            nftOwner == msg.sender || _NFT_CONTRACT.isApprovedForAll(nftOwner, msg.sender),
            "Marketplace: Only the NFT owner or its operator are allowed to update a listing"
        );
        require(weiPrice > 0, "Marketplace: Price should be strictly positive");
        require(nftOwner != reserve, "Marketplace: Cannot reserve listing for NFT owner");

        _listings[tokenId] = weiPrice;
        _reservedOffers[tokenId] = reserve;

        emit ListingUpdated(tokenId, weiPrice, nftOwner, reserve);
    }

    /**
     * @dev Returns the wei price to buy a given NFT ID and the address for which
     * the listing is reserved. If the returned address is the 0 address, that means the listing is public.
     *
     * If the listing does not exist, the function returns a wei price of 0.
     */
    function getListing(uint64 tokenId) public view returns (uint256, address) {
        if (_NFT_CONTRACT.getApproved(tokenId) != address(this)) {
            return (0, address(0));
        }
        return (_listings[tokenId], _reservedOffers[tokenId]);
    }

    /**
     * @dev Returns the wei price to buy a given NFT ID with included buyer fees.
     *
     * If the listing does not exist, the function returns a wei price of 0.
     */
    function getBuyerListingPrice(uint64 tokenId) public view returns (uint256) {
        if (_NFT_CONTRACT.getApproved(tokenId) != address(this)) {
            return 0;
        }

        (,, uint256 marketplaceBuyFeeShare,) = computeListingShares(_listings[tokenId]);
        return _listings[tokenId] + marketplaceBuyFeeShare;
    }

    /**
     * Returns true if the given address has a reserved offer on a listing of the specified NFT.
     * If the listing is not reserved for a specific buyer, it means that anyone can purchase the NFT.
     *
     * @param from the address to check for a reservation
     * @param tokenId the ID of the NFT to check for a reserved offer
     * @return true if the given address has a reserved offer on the listing, or false if no reservation is set or if the reserve is held by a different address
     */
    function hasReservedOffer(address from, uint64 tokenId) public view returns (bool) {
        return _reservedOffers[tokenId] == from;
    }

    /**
     * @dev Returns true if a tokenID is listed.
     */
    function hasListing(uint64 tokenId) public view returns (bool) {
        (uint256 listingPrice,) = getListing(tokenId);
        return listingPrice > 0;
    }

    /**
     * @dev Getter for the marketplace fees receiver address.
     */
    function marketplaceFeesReceiver() public view returns (address) {
        return _marketplaceFeesReceiver;
    }

    /**
     * @dev Getter for the marketplace fees.
     */
    function marketplacePercentFees() public view returns (uint8, uint8, uint8) {
        return (_marketplaceSellPercentFee, _marketplaceBuyPercentFee, _marketplaceBurnPercentFee);
    }

    /**
     * @dev Setter for the marketplace fees receiver address.
     *
     * Emits a {MarketplaceFeesReceiverUpdated} event.
     *
     * Requirements:
     *
     * - Caller must have role FEE_MANAGER_ROLE.
     */
    function setMarketplaceFeesReceiver(address nMarketplaceFeesReceiver) external onlyRole(FEE_MANAGER_ROLE) {
        _marketplaceFeesReceiver = nMarketplaceFeesReceiver;

        emit MarketplaceFeesReceiverUpdated(_marketplaceFeesReceiver);
    }

    /**
     * @dev Setter for the marketplace fees.
     *
     * Emits a {MarketplaceFeesUpdated} event.
     *
     * Requirements:
     *
     * - Sum of nMarketplaceSellPercentFees and nMarketplaceBurnPercentFees must be an integer between 0 and 100 included.
     * - Caller must have role FEE_MANAGER_ROLE.
     */
    function setMarketplacePercentFees(
        uint8 nMarketplaceSellPercentFee,
        uint8 nMarketplaceBuyPercentFee,
        uint8 nMarketplaceBurnPercentFee
    ) external onlyRole(FEE_MANAGER_ROLE) {
        require(
            nMarketplaceSellPercentFee + nMarketplaceBurnPercentFee <= 100,
            "Marketplace: total marketplace sell and burn fees should be below 100"
        );
        _marketplaceSellPercentFee = nMarketplaceSellPercentFee;
        _marketplaceBuyPercentFee = nMarketplaceBuyPercentFee;
        _marketplaceBurnPercentFee = nMarketplaceBurnPercentFee;

        emit MarketplaceFeesUpdated(nMarketplaceSellPercentFee, nMarketplaceBuyPercentFee, nMarketplaceBurnPercentFee);
    }

    /**
     * Returns true if the given address is allowed to accept a listing of the given NFT.
     * If no reservation is set on the listing, it means that anyone can buy the NFT.
     *
     * @param from the address to test for the permission to buy the NFT,
     * @param tokenId the ID of the NFT to check for buy permission
     * @return true if the given address is allowed to buy the NFT, or false if a reservation is set on the listing and held by a different address
     */
    function isReservationOpenFor(address from, uint64 tokenId) public view returns (bool) {
        return _reservedOffers[tokenId] == address(0) || _reservedOffers[tokenId] == from;
    }

    /**
     * @dev Allow to create a reserved listing for a given NFT ID at a given TOKEN wei price.
     *
     * Only the `reserve` address is allowed to accept the new listing offer. If `reserve` is the 0 address
     * that means the listing is public and anyone can accept the listing offer.
     *
     * Emits a {ListingCreated} event.
     *
     * Requirements:
     *
     * - tokenWeiPrice should be strictly positive.
     * - reserve address must not be the same as NFT owner.
     * - from must be the NFT owner.
     * - msg.sender should be either the NFT owner or approved by the NFT owner.
     * - Marketplace contract should be approved for the given NFT ID.
     * - NFT ID should not be listed.
     */
    function _createListingFrom(address from, uint64 tokenId, uint256 weiPrice, address reserve) private {
        require(weiPrice > 0, "Marketplace: Price should be strictly positive");

        address nftOwner = _NFT_CONTRACT.ownerOf(tokenId);
        require(nftOwner != reserve, "Marketplace: Cannot reserve listing for token owner");
        require(nftOwner == from, "Marketplace: Create listing of token that is not own");
        require(
            nftOwner == msg.sender || _NFT_CONTRACT.isApprovedForAll(nftOwner, msg.sender),
            "Marketplace: Only the token owner or its operator are allowed to create a listing"
        );
        require(
            _NFT_CONTRACT.getApproved(tokenId) == address(this),
            "Marketplace: Contract should be approved by the token owner"
        );
        require(!hasListing(tokenId), "Marketplace: Listing already exists. Destroy the previous listing first");

        _listings[tokenId] = weiPrice;

        if (reserve != address(0)) {
            _reservedOffers[tokenId] = reserve;
        }

        emit ListingCreated(tokenId, weiPrice, nftOwner, reserve);
    }

    /**
     * @dev Allow to accept a listing for a given NFT ID with native currency payment. NFT will be sent to nftReceiver wallet.
     *
     * This function is used to buy a NFT listed on the Marketplace contract.
     *
     * Once a NFT is sold, fees will be applied on the payment and forwarded
     * to the marketplace fees receiver and burn address.
     *
     * Emits a {ListingAccepted} event.
     *
     * Requirements:
     *
     * - NFT ID must be listed
     * - Sent value must match listing price plus buyer fees
     * - Listing reservation must be open for nftReceiver
     */
    function _acceptListing(uint64 tokenId, address nftReceiver) private {
        (uint256 listingPrice,) = getListing(tokenId);

        //
        // 1.
        // Requirements
        //
        require(hasListing(tokenId), "Marketplace: Listing does not exist");
        require(isReservationOpenFor(nftReceiver, tokenId), "Marketplace: A reservation exists for this listing");

        //
        // 2.
        // Process listing
        //
        address seller = _NFT_CONTRACT.ownerOf(tokenId);
        (
            uint256 sellerShare,
            uint256 marketplaceSellFeeShare,
            uint256 marketplaceBuyFeeShare,
            uint256 marketplaceBurnFeeShare
        ) = computeListingShares(listingPrice);

        require(
            msg.value == listingPrice + marketplaceBuyFeeShare, "Marketplace: Value is lower than buyer listing price"
        );

        //
        // 3.
        // Execute listing
        //
        delete _listings[tokenId];
        delete _reservedOffers[tokenId];

        _NFT_CONTRACT.safeTransferFrom(seller, nftReceiver, tokenId);
        (bool sellerTransferResult,) = seller.call{value: sellerShare}("");
        require(sellerTransferResult, "Marketplace: Transfer to seller failed");

        uint256 marketplaceFeesShare = marketplaceSellFeeShare + marketplaceBuyFeeShare;
        if (marketplaceFeesShare > 0) {
            (bool feeTransferResult,) = marketplaceFeesReceiver().call{value: marketplaceFeesShare}("");
            require(feeTransferResult, "Marketplace: Transfer of fees failed");
        }
        if (marketplaceBurnFeeShare > 0) {
            (bool burnTransferResult,) =
                address(0x000000000000000000000000000000000000dEaD).call{value: marketplaceBurnFeeShare}("");
            require(burnTransferResult, "Marketplace: Burn transfer failed");
        }

        emit ListingAccepted(tokenId, listingPrice, seller, nftReceiver);
    }

    event MarketplaceFeesUpdated(uint128 sellerPercentFees, uint128 buyerPercentFees, uint256 burnPercentFees);

    event MarketplaceFeesReceiverUpdated(address feesReceiver);

    event ListingCreated(uint64 tokenId, uint256 weiPrice, address seller, address reserve);

    event ListingUpdated(uint64 tokenId, uint256 weiPrice, address seller, address reserve);

    event ListingAccepted(uint64 tokenId, uint256 weiPrice, address seller, address buyer);

    event ListingDestroyed(uint64 tokenId, address seller);

    event OptionSet(uint64 tokenId, address buyer, uint256 until);

    uint256[50] __gap;
}
