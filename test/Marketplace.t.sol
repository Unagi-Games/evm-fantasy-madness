// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Marketplace} from "@/Marketplace_1.0.0.sol";
import {NFT} from "@/NFT.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TestERC721} from "./mocks/TestERC721.sol";

contract BaseMarketplaceTest is Test {
    TestERC721 public erc721;
    Marketplace public marketplace;
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");
    uint64 public nft = 1;
    uint256 public listingPrice = 100;

    function setUp() public virtual {
        erc721 = new TestERC721();

        marketplace = new Marketplace();
        marketplace.initialize(address(erc721));
    }
}

contract MarketplaceCreateListing is BaseMarketplaceTest {
    function test_CreateListing() public {
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);

        vm.expectEmit();
        emit Marketplace.ListingCreated(nft, listingPrice, seller, address(0));
        marketplace.createListingFrom(seller, nft, listingPrice);
        (uint256 mListingPrice, address reservedFor) = marketplace.getListing(nft);
        assertEq(mListingPrice, listingPrice);
        assertEq(reservedFor, address(0));
        assertTrue(marketplace.isReservationOpenFor(makeAddr("Any buyer"), nft));
    }

    function test_CreateListingReserved() public {
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);

        marketplace.createListingFrom(seller, nft, listingPrice, buyer);
        (uint256 mListingPrice, address reservedFor) = marketplace.getListing(nft);
        assertEq(mListingPrice, listingPrice);
        assertEq(reservedFor, buyer);
        assertTrue(marketplace.isReservationOpenFor(buyer, nft));
        assertTrue(marketplace.hasReservedOffer(buyer, nft));
        assertFalse(marketplace.isReservationOpenFor(makeAddr("Any buyer"), nft));
    }

    function test_CreateListingOperator() public {
        address operator = makeAddr("operator");
        erc721.mint(seller, nft);
        vm.prank(seller);
        erc721.setApprovalForAll(operator, true);
        vm.startPrank(operator);
        erc721.approve(address(marketplace), nft);

        vm.expectEmit();
        emit Marketplace.ListingCreated(nft, listingPrice, seller, address(0));
        marketplace.createListingFrom(seller, nft, listingPrice);

        assertTrue(marketplace.hasListing(nft));
    }

    function test_CreateListingRevertIfMarketplaceNotApproved() public {
        erc721.mint(seller, nft);

        vm.startPrank(seller);
        vm.expectRevert("Marketplace: Contract should be approved by the token owner");
        marketplace.createListingFrom(seller, nft, listingPrice);
    }

    function test_CreateListingRevertIfSellerNotOwner() public {
        erc721.mint(makeAddr("Any wallet"), nft);

        vm.startPrank(seller);
        vm.expectRevert("Marketplace: Create listing of token that is not own");
        marketplace.createListingFrom(seller, nft, listingPrice);
    }

    function test_CreateListingRevertIfOperatorNotApproved() public {
        erc721.mint(seller, nft);
        vm.prank(seller);
        erc721.approve(address(marketplace), nft);

        vm.startPrank(makeAddr("operator"));
        vm.expectRevert("Marketplace: Only the token owner or its operator are allowed to create a listing");
        marketplace.createListingFrom(seller, nft, listingPrice);
    }

    function test_CreateListingRevertIfPriceZero() public {
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);

        vm.expectRevert("Marketplace: Price should be strictly positive");
        marketplace.createListingFrom(seller, nft, 0);
    }
}

contract MarketplaceUpdateListing is BaseMarketplaceTest {
    function setUp() public override {
        super.setUp();
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);
        marketplace.createListingFrom(seller, nft, listingPrice);
        vm.stopPrank();
    }

    function test_UpdateListing() public {
        uint256 updatedListingPrice = 100;
        address updatedReservedFor = makeAddr("Updated reserved for");
        vm.startPrank(seller);

        vm.expectEmit();
        emit Marketplace.ListingUpdated(nft, updatedListingPrice, seller, updatedReservedFor);
        marketplace.updateListingFrom(seller, nft, updatedListingPrice, updatedReservedFor);
        (uint256 mListingPrice, address reservedFor) = marketplace.getListing(nft);
        assertEq(mListingPrice, updatedListingPrice);
        assertEq(reservedFor, updatedReservedFor);
    }

    function test_UpdateListingOperator() public {
        address operator = makeAddr("operator");
        vm.prank(seller);
        erc721.setApprovalForAll(operator, true);

        vm.startPrank(operator);
        uint256 updatedListingPrice = 100;
        address updatedReservedFor = makeAddr("Updated reserved for");

        vm.expectEmit();
        emit Marketplace.ListingUpdated(nft, updatedListingPrice, seller, updatedReservedFor);
        marketplace.updateListingFrom(seller, nft, updatedListingPrice, updatedReservedFor);
        (uint256 mListingPrice, address reservedFor) = marketplace.getListing(nft);
        assertEq(mListingPrice, updatedListingPrice);
        assertEq(reservedFor, updatedReservedFor);
    }

    function test_UpdateListingRevertIfNotOwner() public {
        vm.startPrank(makeAddr("Any wallet"));

        vm.expectRevert("Marketplace: Only the NFT owner or its operator are allowed to update a listing");
        marketplace.updateListingFrom(seller, nft, 1, address(0));
    }

    function test_UpdateListingRevertIfZero() public {
        vm.startPrank(seller);

        vm.expectRevert("Marketplace: Price should be strictly positive");
        marketplace.updateListingFrom(seller, nft, 0, address(0));
    }
}

contract MarketplaceAcceptListing is BaseMarketplaceTest {
    function setUp() public override {
        super.setUp();
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);
        marketplace.createListingFrom(seller, nft, listingPrice);
        vm.stopPrank();
    }

    function test_AcceptListing() public {
        startHoax(buyer, listingPrice);

        vm.expectEmit();
        emit Marketplace.ListingAccepted(nft, listingPrice, seller, buyer);
        marketplace.acceptListing{value: listingPrice}(nft);

        assertFalse(marketplace.hasListing(nft));
        assertEq(erc721.ownerOf(nft), buyer);
        assertEq(buyer.balance, 0);
        assertEq(seller.balance, listingPrice);
    }

    function test_AcceptListingForSomeone() public {
        address anyWallet = makeAddr("Any wallet");
        startHoax(buyer, listingPrice);
        marketplace.acceptListing{value: listingPrice}(nft, anyWallet);

        assertFalse(marketplace.hasListing(nft));
        assertEq(erc721.ownerOf(nft), anyWallet);
        assertEq(buyer.balance, 0);
        assertEq(seller.balance, listingPrice);
    }

    function test_AcceptListingRevertWithoutPayment() public {
        startHoax(buyer, listingPrice - 1);

        vm.expectRevert("Marketplace: Value is lower than buyer listing price");
        marketplace.acceptListing{value: listingPrice - 1}(nft);
    }

    function test_AcceptListingRevertIfReserved() public {
        vm.prank(seller);
        marketplace.updateListingFrom(seller, nft, listingPrice, makeAddr("Reserved for"));

        startHoax(buyer, listingPrice);
        vm.expectRevert("Marketplace: A reservation exists for this listing");
        marketplace.acceptListing{value: listingPrice}(nft);
    }

    function test_AcceptListingRevertIfDestroyed() public {
        vm.prank(seller);
        marketplace.destroyListingFrom(seller, nft);
        startHoax(buyer, listingPrice);

        vm.expectRevert("Marketplace: Listing does not exist");
        marketplace.acceptListing{value: listingPrice}(nft);
    }
}

contract MarketplaceDestroyListing is BaseMarketplaceTest {
    function setUp() public override {
        super.setUp();
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);
        marketplace.createListingFrom(seller, nft, listingPrice);
        vm.stopPrank();
    }

    function test_DestroyListing() public {
        vm.startPrank(seller);
        vm.expectEmit();
        emit Marketplace.ListingDestroyed(nft, seller);
        marketplace.destroyListingFrom(seller, nft);

        assertFalse(marketplace.hasListing(nft));
    }

    function test_DestroyListingOperator() public {
        address operator = makeAddr("operator");
        vm.prank(seller);
        erc721.setApprovalForAll(operator, true);

        vm.startPrank(operator);
        vm.expectEmit();
        emit Marketplace.ListingDestroyed(nft, seller);
        marketplace.destroyListingFrom(seller, nft);

        assertFalse(marketplace.hasListing(nft));
    }

    function test_DestroyListingRevertIfNotOwner() public {
        address anyWallet = makeAddr("Any wallet");
        vm.startPrank(anyWallet);

        vm.expectRevert("Marketplace: Destroy listing of NFT that is not own");
        marketplace.destroyListingFrom(anyWallet, nft);
    }

    function test_DestroyListingRevertIfNotApproved() public {
        vm.startPrank(makeAddr("Any wallet"));

        vm.expectRevert("Marketplace: Only the NFT owner or its operator are allowed to destroy a listing");
        marketplace.destroyListingFrom(seller, nft);
    }
}

contract MarketplaceGetters is BaseMarketplaceTest {
    function test_NFTNotListed() public {
        uint64 anyNft = 25;
        erc721.mint(seller, anyNft);
        (uint256 mListingPrice, address mReservedFor) = marketplace.getListing(anyNft);
        assertEq(mListingPrice, 0);
        assertEq(mReservedFor, address(0));
        assertFalse(marketplace.hasListing(anyNft));
    }

    function test_NFTNotApproved() public {
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);
        marketplace.createListingFrom(seller, nft, listingPrice);

        assertTrue(marketplace.hasListing(nft));
        erc721.approve(address(0), nft);
        assertFalse(marketplace.hasListing(nft));
    }
}

contract MarketplaceFeeManagement is BaseMarketplaceTest {
    address public feeReceiver = makeAddr("feeReceiver");
    address public constant BURN_ADDRESS = address(0xdEaD);

    struct TestCase {
        string name;
        uint256 listingPrice;
        uint8[3] fees; // [sellFee, buyFee, burnFee]
        uint256 expectedSeller;
        uint256 expectedFees;
        uint256 expectedBurn;
    }

    function setUp() public override {
        super.setUp();

        vm.startPrank(address(this));
        marketplace.grantRole(marketplace.FEE_MANAGER_ROLE(), address(this));
        vm.stopPrank();

        erc721.mint(seller, nft);
        vm.prank(seller);
        erc721.approve(address(marketplace), nft);
    }

    function test_SetMarketplaceFeesReceiver() public {
        vm.expectEmit();
        emit Marketplace.MarketplaceFeesReceiverUpdated(feeReceiver);
        marketplace.setMarketplaceFeesReceiver(feeReceiver);

        assertEq(marketplace.marketplaceFeesReceiver(), feeReceiver);
    }

    function test_SetMarketplaceFeesReceiverRevertIfNotFeeManager() public {
        address nonManager = makeAddr("nonManager");
        vm.startPrank(nonManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, nonManager, marketplace.FEE_MANAGER_ROLE()
            )
        );
        marketplace.setMarketplaceFeesReceiver(feeReceiver);
        vm.stopPrank();
    }

    function test_SetMarketplaceFees() public {
        uint8 sellFee = 9;
        uint8 buyFee = 5;
        uint8 burnFee = 1;

        vm.expectEmit();
        emit Marketplace.MarketplaceFeesUpdated(sellFee, buyFee, burnFee);
        marketplace.setMarketplacePercentFees(sellFee, buyFee, burnFee);

        (uint8 mSellFee, uint8 mBuyFee, uint8 mBurnFee) = marketplace.marketplacePercentFees();
        assertEq(mSellFee, sellFee);
        assertEq(mBuyFee, buyFee);
        assertEq(mBurnFee, burnFee);
    }

    function test_SetMarketplaceFeesRevertIfNotFeeManager() public {
        address nonManager = makeAddr("nonManager");
        vm.startPrank(nonManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, nonManager, marketplace.FEE_MANAGER_ROLE()
            )
        );
        marketplace.setMarketplacePercentFees(1, 1, 1);
        vm.stopPrank();
    }

    function test_RevertIfFeesExceed100Percent() public {
        vm.expectRevert("Marketplace: total marketplace sell and burn fees should be below 100");
        marketplace.setMarketplacePercentFees(101, 0, 0);

        vm.expectRevert("Marketplace: total marketplace sell and burn fees should be below 100");
        marketplace.setMarketplacePercentFees(90, 0, 11);
    }

    function createTestCases() internal pure returns (TestCase[] memory) {
        TestCase[] memory tests = new TestCase[](7);

        tests[0] = TestCase({
            name: "Common case",
            listingPrice: 100,
            fees: [4, 1, 1],
            expectedSeller: 95,
            expectedFees: 5,
            expectedBurn: 1
        });

        tests[1] = TestCase({
            name: "Price too low",
            listingPrice: 2,
            fees: [5, 5, 2],
            expectedSeller: 2,
            expectedFees: 0,
            expectedBurn: 0
        });

        tests[2] = TestCase({
            name: "Round favor seller",
            listingPrice: 99,
            fees: [5, 2, 2],
            expectedSeller: 94,
            expectedFees: 5,
            expectedBurn: 1
        });

        tests[3] = TestCase({
            name: "Zero fees",
            listingPrice: 50,
            fees: [0, 0, 0],
            expectedSeller: 50,
            expectedFees: 0,
            expectedBurn: 0
        });

        tests[4] = TestCase({
            name: "100% sell fees",
            listingPrice: 50,
            fees: [100, 0, 0],
            expectedSeller: 0,
            expectedFees: 50,
            expectedBurn: 0
        });

        tests[5] = TestCase({
            name: "100% buy fees",
            listingPrice: 50,
            fees: [0, 100, 0],
            expectedSeller: 50,
            expectedFees: 50,
            expectedBurn: 0
        });

        tests[6] = TestCase({
            name: "100% burn fees",
            listingPrice: 50,
            fees: [0, 0, 100],
            expectedSeller: 0,
            expectedFees: 0,
            expectedBurn: 50
        });

        return tests;
    }

    function test_FeeDistribution() public {
        // Setup fee receiver
        marketplace.setMarketplaceFeesReceiver(feeReceiver);

        TestCase[] memory tests = createTestCases();
        for (uint256 i = 0; i < tests.length; i++) {
            TestCase memory tc = tests[i];

            marketplace.setMarketplacePercentFees(tc.fees[0], tc.fees[1], tc.fees[2]);

            vm.prank(seller);
            marketplace.createListingFrom(seller, nft, tc.listingPrice);

            // Record initial balances
            uint256 initialSellerBalance = seller.balance;
            uint256 initialFeeBalance = feeReceiver.balance;
            uint256 initialBurnBalance = BURN_ADDRESS.balance;

            // Execute listing
            uint256 buyerPrice = tc.listingPrice + (tc.listingPrice * tc.fees[1]) / 100;
            hoax(buyer, buyerPrice);
            marketplace.acceptListing{value: buyerPrice}(nft);

            // Verify balances
            assertEq(
                seller.balance - initialSellerBalance,
                tc.expectedSeller,
                string.concat("Seller balance incorrect for case: ", tc.name)
            );
            assertEq(
                feeReceiver.balance - initialFeeBalance,
                tc.expectedFees,
                string.concat("Fee receiver balance incorrect for case: ", tc.name)
            );
            assertEq(
                BURN_ADDRESS.balance - initialBurnBalance,
                tc.expectedBurn,
                string.concat("Burn address balance incorrect for case: ", tc.name)
            );

            // Reset
            vm.prank(buyer);
            erc721.safeTransferFrom(buyer, seller, nft);

            vm.prank(seller);
            erc721.approve(address(marketplace), nft);
        }
    }

    function test_FeeCalculationFuzz(uint8 sellFee, uint8 buyFee, uint8 burnFee, uint256 listingPrice) public {
        vm.assume(sellFee <= 100);
        vm.assume(burnFee <= 100);
        vm.assume(sellFee + burnFee <= 100);
        vm.assume(listingPrice > 0 && listingPrice < 1_000_000 ether);

        marketplace.setMarketplaceFeesReceiver(feeReceiver);
        marketplace.setMarketplacePercentFees(sellFee, buyFee, burnFee);

        vm.prank(seller);
        marketplace.createListingFrom(seller, nft, listingPrice);

        uint256 initialSellerBalance = seller.balance;
        uint256 initialFeeBalance = feeReceiver.balance;
        uint256 initialBurnBalance = BURN_ADDRESS.balance;

        uint256 finalPrice = listingPrice + (listingPrice * buyFee) / 100;
        hoax(buyer, finalPrice);
        marketplace.acceptListing{value: finalPrice}(nft);

        uint256 sellerAmount = listingPrice - (listingPrice * sellFee) / 100 - (listingPrice * burnFee) / 100;
        uint256 feeAmount = (listingPrice * sellFee) / 100 + (listingPrice * buyFee) / 100;
        uint256 burnAmount = (listingPrice * burnFee) / 100;

        assertEq(seller.balance - initialSellerBalance, sellerAmount, "Incorrect seller balance");
        assertEq(feeReceiver.balance - initialFeeBalance, feeAmount, "Incorrect fee receiver balance");
        assertEq(BURN_ADDRESS.balance - initialBurnBalance, burnAmount, "Incorrect burn address balance");

        assertEq(sellerAmount + feeAmount + burnAmount, finalPrice, "Total distribution does not match buyer payment");
    }
}
