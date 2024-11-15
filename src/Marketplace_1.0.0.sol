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
 * A NFT holder can create, update or delete a sale for one of their NFTs.
 * To create a sale, the NFT holder must give their approval for the Marketplace
 * on the NFT they want to sell. Then, the NFT holder must call the function `createSaleFrom`.
 * A reserved sale can also be created, meaning only a specific address, approved by
 * the NFT owner, can accept the sale. To remove the sale, the NFT holder must call the
 * function `destroySaleFrom`.
 *
 * A NFT holder can also update their existing sales through the `updateSaleFrom` function.
 * This function allows the NFT holder to update a given sale's price and reserved offer.
 *
 * A user can accept a sale if the sale is either public, or has a reserved offer
 * set for their address. The function `isReservationOpenFor` can be used to verify if a given address
 * can accept a specific sale. To accept a sale, the user must send the required amount of native currency
 * when calling the function `acceptSale`.
 *
 * Once a NFT is sold, sell, buy and burn fees (readable through `marketplacePercentFees()`)
 * will be applied on the payment. Sell and buy fees are forwarded to the marketplace
 * fees receiver (readable through `marketplaceFeesReceiver()`), while the burn fee is forwarded to the DEAD address.
 * The rest is sent to the seller.
 *
 * The fees are editable by FEE_MANAGER_ROLE.
 * The fee receiver is editable by FEE_MANAGER_ROLE.
 *
 * For off-chain payments, an option can be set on a sale.
 * Options are restricted to only one per sale at any time.
 * Options are rate limited per sale.
 *
 * @custom:security-contact security@unagi.ch
 */
contract Marketplace is AccessControlUpgradeable {
    using Math for uint256;

    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    IERC721 public _NFT_CONTRACT;

    // (nft ID => prices as wei) mapping of sales
    mapping(uint64 => uint256) private _sales;

    // Percent fees applied on each sale: sell, buy and burn fees.
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
    function computeSaleShares(uint256 weiPrice)
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
     * @dev See _createSaleFrom(address,uint64,uint256,address)
     */
    function createSaleFrom(address from, uint64 tokenId, uint256 weiPrice) external {
        _createSaleFrom(from, tokenId, weiPrice, address(0));
    }

    /**
     * @dev See _createSaleFrom(address,uint64,uint256,address)
     */
    function createSaleFrom(address from, uint64 tokenId, uint256 weiPrice, address reserve) external {
        require(reserve != address(0), "Marketplace: Cant not create reserved sale for 0 address");

        _createSaleFrom(from, tokenId, weiPrice, reserve);
    }

    /**
     * @dev See _acceptSale(uint64,address)
     */
    function acceptSale(uint64 tokenId) external payable {
        _acceptSale(tokenId, msg.sender);
    }

    /**
     * @dev See _acceptSale(uint64,address)
     */
    function acceptSale(uint64 tokenId, address nftReceiver) external payable {
        _acceptSale(tokenId, nftReceiver);
    }

    /**
     * @dev Allow to destroy a sale for a given NFT ID.
     *
     * Emits a {SaleDestroyed} event.
     *
     * Requirements:
     *
     * - NFT ID should be on sale.
     * - from must be the NFT owner.
     * - msg.sender should be either the NFT owner or approved by the NFT owner.
     * - Marketplace contract should be approved for the given NFT ID.
     */
    function destroySaleFrom(address from, uint64 tokenId) external {
        require(hasSale(tokenId), "Marketplace: Sale does not exists");
        address nftOwner = _NFT_CONTRACT.ownerOf(tokenId);
        require(nftOwner == from, "Marketplace: Destroy sale of NFT that is not own");
        require(
            nftOwner == msg.sender || _NFT_CONTRACT.isApprovedForAll(nftOwner, msg.sender),
            "Marketplace: Only the NFT owner or its operator are allowed to destroy a sale"
        );

        delete _sales[tokenId];

        if (_reservedOffers[tokenId] != address(0)) {
            delete _reservedOffers[tokenId];
        }

        emit SaleDestroyed(tokenId, nftOwner);
    }

    /**
     * @dev Allow to update a sale for a given NFT ID at a given TOKEN wei price.
     *
     * Emits a {SaleUpdated} event.
     *
     * Requirements:
     *
     * - NFT ID should be on sale.
     * - tokenWeiPrice should be strictly positive.
     * - reserve address must be different than from.
     * - from must be the NFT owner.
     * - msg.sender should be either the NFT owner or approved by the NFT owner.
     * - Marketplace contract should be approved for the given NFT ID.
     */
    function updateSaleFrom(address from, uint64 tokenId, uint256 weiPrice, address reserve) external {
        require(hasSale(tokenId), "Marketplace: Sale does not exists");
        address nftOwner = _NFT_CONTRACT.ownerOf(tokenId);
        require(nftOwner == from, "Marketplace: Update sale of NFT that is not own");
        require(
            nftOwner == msg.sender || _NFT_CONTRACT.isApprovedForAll(nftOwner, msg.sender),
            "Marketplace: Only the NFT owner or its operator are allowed to update a sale"
        );
        require(weiPrice > 0, "Marketplace: Price should be strictly positive");
        require(nftOwner != reserve, "Marketplace: Can not reserve sale for NFT owner");

        _sales[tokenId] = weiPrice;
        _reservedOffers[tokenId] = reserve;

        emit SaleUpdated(tokenId, weiPrice, nftOwner, reserve);
    }

    /**
     * @dev Returns the wei price to buy a given NFT ID and the address for which
     * the sale is reserved. If the returned address is the 0 address, that means the sale is public.
     *
     * If the sale does not exists, the function returns a wei price of 0.
     */
    function getSale(uint64 tokenId) public view returns (uint256, address) {
        if (_NFT_CONTRACT.getApproved(tokenId) != address(this)) {
            return (0, address(0));
        }
        return (_sales[tokenId], _reservedOffers[tokenId]);
    }

    /**
     * @dev Returns the wei price to buy a given NFT ID with included buyer fees.
     *
     * If the sale does not exist, the function returns a wei price of 0.
     */
    function getBuyerSalePrice(uint64 tokenId) public view returns (uint256) {
        if (_NFT_CONTRACT.getApproved(tokenId) != address(this)) {
            return 0;
        }

        (,, uint256 marketplaceBuyFeeShare,) = computeSaleShares(_sales[tokenId]);
        return _sales[tokenId] + marketplaceBuyFeeShare;
    }

    /**
     * Returns true if the given address has a reserved offer on a sale of the specified NFT.
     * If the sale is not reserved for a specific buyer, it means that anyone can purchase the NFT.
     *
     * @param from the address to check for a reservation
     * @param tokenId the ID of the NFT to check for a reserved offer
     * @return true if the given address has a reserved offer on the sale, or false if no reservation is set or if the reserve is held by a different address
     */
    function hasReservedOffer(address from, uint64 tokenId) public view returns (bool) {
        return _reservedOffers[tokenId] == from;
    }

    /**
     * @dev Returns true if a tokenID is on sale.
     */
    function hasSale(uint64 tokenId) public view returns (bool) {
        (uint256 salePrice,) = getSale(tokenId);
        return salePrice > 0;
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
     * Returns true if the given address is allowed to accept a sale of the given NFT.
     * If no reservation is set on the sale, it means that anyone can buy the NFT.
     *
     * @param from the address to test for the permission to buy the NFT,
     * @param tokenId the ID of the NFT to check for buy permission
     * @return true if the given address is allowed to buy the NFT, or false if a reservation is set on the sale and held by a different address
     */
    function isReservationOpenFor(address from, uint64 tokenId) public view returns (bool) {
        return _reservedOffers[tokenId] == address(0) || _reservedOffers[tokenId] == from;
    }

    /**
     * @dev Allow to create a reserved sale for a given NFT ID at a given TOKEN wei price.
     *
     * Only the `reserve` address is allowed to accept the new sale offer. If `reserve` is the 0 address
     * that means the sale is public and anyone can accept the sale offer.
     *
     * Emits a {SaleCreated} event.
     *
     * Requirements:
     *
     * - tokenWeiPrice should be strictly positive.
     * - reserve address must not be the same as NFT owner.
     * - from must be the NFT owner.
     * - msg.sender should be either the NFT owner or approved by the NFT owner.
     * - Marketplace contract should be approved for the given NFT ID.
     * - NFT ID should not be on sale.
     */
    function _createSaleFrom(address from, uint64 tokenId, uint256 weiPrice, address reserve) private {
        require(weiPrice > 0, "Marketplace: Price should be strictly positive");

        address nftOwner = _NFT_CONTRACT.ownerOf(tokenId);
        require(nftOwner != reserve, "Marketplace: Can not reserve sale for token owner");
        require(nftOwner == from, "Marketplace: Create sale of token that is not own");
        require(
            nftOwner == msg.sender || _NFT_CONTRACT.isApprovedForAll(nftOwner, msg.sender),
            "Marketplace: Only the token owner or its operator are allowed to create a sale"
        );
        require(
            _NFT_CONTRACT.getApproved(tokenId) == address(this),
            "Marketplace: Contract should be approved by the token owner"
        );
        require(!hasSale(tokenId), "Marketplace: Sale already exists. Destroy the previous sale first");

        _sales[tokenId] = weiPrice;

        if (reserve != address(0)) {
            _reservedOffers[tokenId] = reserve;
        }

        emit SaleCreated(tokenId, weiPrice, nftOwner, reserve);
    }

    /**
     * @dev Allow to accept a sale for a given NFT ID with native currency payment. NFT will be sent to nftReceiver wallet.
     *
     * This function is used to buy a NFT listed on the Marketplace contract.
     *
     * Once a NFT is sold, fees will be applied on the payment and forwarded
     * to the marketplace fees receiver and burn address.
     *
     * Emits a {SaleAccepted} event.
     *
     * Requirements:
     *
     * - NFT ID must be on sale
     * - Sent value must match sale price plus buyer fees
     * - Sale reservation must be open for nftReceiver
     */
    function _acceptSale(uint64 tokenId, address nftReceiver) private {
        (uint256 salePrice,) = getSale(tokenId);

        //
        // 1.
        // Requirements
        //
        require(hasSale(tokenId), "Marketplace: Sale does not exists");
        require(isReservationOpenFor(nftReceiver, tokenId), "Marketplace: A reservation exists for this sale");

        //
        // 2.
        // Process sale
        //
        address seller = _NFT_CONTRACT.ownerOf(tokenId);
        (
            uint256 sellerShare,
            uint256 marketplaceSellFeeShare,
            uint256 marketplaceBuyFeeShare,
            uint256 marketplaceBurnFeeShare
        ) = computeSaleShares(salePrice);

        require(msg.value == salePrice + marketplaceBuyFeeShare, "Marketplace: Value is lower than buyer sale price");

        //
        // 3.
        // Execute sale
        //
        delete _sales[tokenId];
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

        emit SaleAccepted(tokenId, salePrice, seller, nftReceiver);
    }

    event MarketplaceFeesUpdated(uint128 sellerPercentFees, uint128 buyerPercentFees, uint256 burnPercentFees);

    event MarketplaceFeesReceiverUpdated(address feesReceiver);

    event SaleCreated(uint64 tokenId, uint256 weiPrice, address seller, address reserve);

    event SaleUpdated(uint64 tokenId, uint256 weiPrice, address seller, address reserve);

    event SaleAccepted(uint64 tokenId, uint256 weiPrice, address seller, address buyer);

    event SaleDestroyed(uint64 tokenId, address seller);

    event OptionSet(uint64 tokenId, address buyer, uint256 until);

    uint256[50] __gap;
}
