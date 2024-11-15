// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Marketplace} from "@/Marketplace_1.0.0.sol";
import {NFT} from "@/NFT.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TestERC721 is ERC721 {
    constructor() ERC721("Test", "TST") {}

    function mint(address account, uint256 tokenId) public {
        _mint(account, tokenId);
    }
}

contract BaseMarketplaceTest is Test {
    TestERC721 public erc721;
    Marketplace public marketplace;
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");
    uint64 public nft = 1;
    uint256 public salePrice = 100;

    function setUp() public virtual {
        erc721 = new TestERC721();

        marketplace = new Marketplace();
        marketplace.initialize(address(erc721));
    }
}

contract MarketplaceCreateSale is BaseMarketplaceTest {
    function test_CreateSale() public {
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);

        vm.expectEmit();
        emit Marketplace.SaleCreated(nft, salePrice, seller, address(0));
        marketplace.createSaleFrom(seller, nft, salePrice);
        (uint256 mSalePrice, address reservedFor) = marketplace.getSale(nft);
        assertEq(mSalePrice, salePrice);
        assertEq(reservedFor, address(0));
        assertTrue(marketplace.isReservationOpenFor(makeAddr("Any buyer"), nft));
    }

    function test_CreateSaleReserved() public {
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);

        marketplace.createSaleFrom(seller, nft, salePrice, buyer);
        (uint256 mSalePrice, address reservedFor) = marketplace.getSale(nft);
        assertEq(mSalePrice, salePrice);
        assertEq(reservedFor, buyer);
        assertTrue(marketplace.isReservationOpenFor(buyer, nft));
        assertTrue(marketplace.hasReservedOffer(buyer, nft));
        assertFalse(marketplace.isReservationOpenFor(makeAddr("Any buyer"), nft));
    }

    function test_CreateSaleOperator() public {
        address operator = makeAddr("operator");
        erc721.mint(seller, nft);
        vm.prank(seller);
        erc721.setApprovalForAll(operator, true);
        vm.startPrank(operator);
        erc721.approve(address(marketplace), nft);

        vm.expectEmit();
        emit Marketplace.SaleCreated(nft, salePrice, seller, address(0));
        marketplace.createSaleFrom(seller, nft, salePrice);

        assertTrue(marketplace.hasSale(nft));
    }

    function test_CreateSaleRevertIfMarketplaceNotApproved() public {
        erc721.mint(seller, nft);

        vm.startPrank(seller);
        vm.expectRevert("Marketplace: Contract should be approved by the token owner");
        marketplace.createSaleFrom(seller, nft, salePrice);
    }

    function test_CreateSaleRevertIfSellerNotOwner() public {
        erc721.mint(makeAddr("Any wallet"), nft);

        vm.startPrank(seller);
        vm.expectRevert("Marketplace: Create sale of token that is not own");
        marketplace.createSaleFrom(seller, nft, salePrice);
    }

    function test_CreateSaleRevertIfOperatorNotApproved() public {
        erc721.mint(seller, nft);
        vm.prank(seller);
        erc721.approve(address(marketplace), nft);

        vm.startPrank(makeAddr("operator"));
        vm.expectRevert("Marketplace: Only the token owner or its operator are allowed to create a sale");
        marketplace.createSaleFrom(seller, nft, salePrice);
    }

    function test_CreateSaleRevertIfPriceZero() public {
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);

        vm.expectRevert("Marketplace: Price should be strictly positive");
        marketplace.createSaleFrom(seller, nft, 0);
    }
}

contract MarketplaceUpdateSale is BaseMarketplaceTest {
    function setUp() public override {
        super.setUp();
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);
        marketplace.createSaleFrom(seller, nft, salePrice);
        vm.stopPrank();
    }

    function test_UpdateSale() public {
        uint256 updatedSalePrice = 100;
        address updatedReservedFor = makeAddr("Updated reserved for");
        vm.startPrank(seller);

        vm.expectEmit();
        emit Marketplace.SaleUpdated(nft, updatedSalePrice, seller, updatedReservedFor);
        marketplace.updateSaleFrom(seller, nft, updatedSalePrice, updatedReservedFor);
        (uint256 mSalePrice, address reservedFor) = marketplace.getSale(nft);
        assertEq(mSalePrice, updatedSalePrice);
        assertEq(reservedFor, updatedReservedFor);
    }

    function test_UpdateSaleOperator() public {
        address operator = makeAddr("operator");
        vm.prank(seller);
        erc721.setApprovalForAll(operator, true);

        vm.startPrank(operator);
        uint256 updatedSalePrice = 100;
        address updatedReservedFor = makeAddr("Updated reserved for");

        vm.expectEmit();
        emit Marketplace.SaleUpdated(nft, updatedSalePrice, seller, updatedReservedFor);
        marketplace.updateSaleFrom(seller, nft, updatedSalePrice, updatedReservedFor);
        (uint256 mSalePrice, address reservedFor) = marketplace.getSale(nft);
        assertEq(mSalePrice, updatedSalePrice);
        assertEq(reservedFor, updatedReservedFor);
    }

    function test_UpdateSaleRevertIfNotOwner() public {
        vm.startPrank(makeAddr("Any wallet"));

        vm.expectRevert("Marketplace: Only the NFT owner or its operator are allowed to update a sale");
        marketplace.updateSaleFrom(seller, nft, 1, address(0));
    }

    function test_UpdateSaleRevertIfZero() public {
        vm.startPrank(seller);

        vm.expectRevert("Marketplace: Price should be strictly positive");
        marketplace.updateSaleFrom(seller, nft, 0, address(0));
    }
}

contract MarketplaceAcceptSale is BaseMarketplaceTest {
    function setUp() public override {
        super.setUp();
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);
        marketplace.createSaleFrom(seller, nft, salePrice);
        vm.stopPrank();
    }

    function test_AcceptSale() public {
        startHoax(buyer, salePrice);

        vm.expectEmit();
        emit Marketplace.SaleAccepted(nft, salePrice, seller, buyer);
        marketplace.acceptSale{value: salePrice}(nft);

        assertFalse(marketplace.hasSale(nft));
        assertEq(erc721.ownerOf(nft), buyer);
        assertEq(buyer.balance, 0);
        assertEq(seller.balance, salePrice);
    }

    function test_AcceptSaleForSomeone() public {
        address anyWallet = makeAddr("Any wallet");
        startHoax(buyer, salePrice);
        marketplace.acceptSale{value: salePrice}(nft, anyWallet);

        assertFalse(marketplace.hasSale(nft));
        assertEq(erc721.ownerOf(nft), anyWallet);
        assertEq(buyer.balance, 0);
        assertEq(seller.balance, salePrice);
    }

    function test_AcceptSaleRevertWithoutPayment() public {
        startHoax(buyer, salePrice - 1);

        vm.expectRevert("Marketplace: Value is lower than buyer sale price");
        marketplace.acceptSale{value: salePrice - 1}(nft);
    }

    function test_AcceptSaleRevertIfReserved() public {
        vm.prank(seller);
        marketplace.updateSaleFrom(seller, nft, salePrice, makeAddr("Reserved for"));

        startHoax(buyer, salePrice);
        vm.expectRevert("Marketplace: A reservation exists for this sale");
        marketplace.acceptSale{value: salePrice}(nft);
    }

    function test_AcceptSaleRevertIfDestroyed() public {
        vm.prank(seller);
        marketplace.destroySaleFrom(seller, nft);
        startHoax(buyer, salePrice);

        vm.expectRevert("Marketplace: Sale does not exists");
        marketplace.acceptSale{value: salePrice}(nft);
    }
}

contract MarketplaceDestroySale is BaseMarketplaceTest {
    function setUp() public override {
        super.setUp();
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);
        marketplace.createSaleFrom(seller, nft, salePrice);
        vm.stopPrank();
    }

    function test_DestroySale() public {
        vm.startPrank(seller);
        vm.expectEmit();
        emit Marketplace.SaleDestroyed(nft, seller);
        marketplace.destroySaleFrom(seller, nft);

        assertFalse(marketplace.hasSale(nft));
    }

    function test_DestroySaleOperator() public {
        address operator = makeAddr("operator");
        vm.prank(seller);
        erc721.setApprovalForAll(operator, true);

        vm.startPrank(operator);
        vm.expectEmit();
        emit Marketplace.SaleDestroyed(nft, seller);
        marketplace.destroySaleFrom(seller, nft);

        assertFalse(marketplace.hasSale(nft));
    }

    function test_DestroySaleRevertIfNotOwner() public {
        address anyWallet = makeAddr("Any wallet");
        vm.startPrank(anyWallet);

        vm.expectRevert("Marketplace: Destroy sale of NFT that is not own");
        marketplace.destroySaleFrom(anyWallet, nft);
    }

    function test_DestroySaleRevertIfNotApproved() public {
        vm.startPrank(makeAddr("Any wallet"));

        vm.expectRevert("Marketplace: Only the NFT owner or its operator are allowed to destroy a sale");
        marketplace.destroySaleFrom(seller, nft);
    }
}

contract MarketplaceGetters is BaseMarketplaceTest {
    function test_NFTNotOnSale() public {
        uint64 anyNft = 25;
        erc721.mint(seller, anyNft);
        (uint256 mSalePrice, address mReservedFor) = marketplace.getSale(anyNft);
        assertEq(mSalePrice, 0);
        assertEq(mReservedFor, address(0));
        assertFalse(marketplace.hasSale(anyNft));
    }

    function test_NFTNotApproved() public {
        erc721.mint(seller, nft);
        vm.startPrank(seller);
        erc721.approve(address(marketplace), nft);
        marketplace.createSaleFrom(seller, nft, salePrice);

        assertTrue(marketplace.hasSale(nft));
        erc721.approve(address(0), nft);
        assertFalse(marketplace.hasSale(nft));
    }
}

contract MarketplaceFeeManagement is BaseMarketplaceTest {
    address public feeReceiver = makeAddr("feeReceiver");
    address public constant BURN_ADDRESS = address(0xdEaD);

    struct TestCase {
        string name;
        uint256 salePrice;
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
            salePrice: 100,
            fees: [4, 1, 1],
            expectedSeller: 95,
            expectedFees: 5,
            expectedBurn: 1
        });

        tests[1] = TestCase({
            name: "Price too low",
            salePrice: 2,
            fees: [5, 5, 2],
            expectedSeller: 2,
            expectedFees: 0,
            expectedBurn: 0
        });

        tests[2] = TestCase({
            name: "Round favor seller",
            salePrice: 99,
            fees: [5, 2, 2],
            expectedSeller: 94,
            expectedFees: 5,
            expectedBurn: 1
        });

        tests[3] = TestCase({
            name: "Zero fees",
            salePrice: 50,
            fees: [0, 0, 0],
            expectedSeller: 50,
            expectedFees: 0,
            expectedBurn: 0
        });

        tests[4] = TestCase({
            name: "100% sell fees",
            salePrice: 50,
            fees: [100, 0, 0],
            expectedSeller: 0,
            expectedFees: 50,
            expectedBurn: 0
        });

        tests[5] = TestCase({
            name: "100% buy fees",
            salePrice: 50,
            fees: [0, 100, 0],
            expectedSeller: 50,
            expectedFees: 50,
            expectedBurn: 0
        });

        tests[6] = TestCase({
            name: "100% burn fees",
            salePrice: 50,
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
            marketplace.createSaleFrom(seller, nft, tc.salePrice);

            // Record initial balances
            uint256 initialSellerBalance = seller.balance;
            uint256 initialFeeBalance = feeReceiver.balance;
            uint256 initialBurnBalance = BURN_ADDRESS.balance;

            // Execute sale
            uint256 buyerPrice = tc.salePrice + (tc.salePrice * tc.fees[1]) / 100;
            hoax(buyer, buyerPrice);
            marketplace.acceptSale{value: buyerPrice}(nft);

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

    function test_FeeCalculationFuzz(uint8 sellFee, uint8 buyFee, uint8 burnFee, uint256 salePrice) public {
        vm.assume(sellFee <= 100);
        vm.assume(burnFee <= 100);
        vm.assume(sellFee + burnFee <= 100);
        vm.assume(salePrice > 0 && salePrice < 1_000_000 ether);

        marketplace.setMarketplaceFeesReceiver(feeReceiver);
        marketplace.setMarketplacePercentFees(sellFee, buyFee, burnFee);

        vm.prank(seller);
        marketplace.createSaleFrom(seller, nft, salePrice);

        uint256 initialSellerBalance = seller.balance;
        uint256 initialFeeBalance = feeReceiver.balance;
        uint256 initialBurnBalance = BURN_ADDRESS.balance;

        uint256 finalPrice = salePrice + (salePrice * buyFee) / 100;
        hoax(buyer, finalPrice);
        marketplace.acceptSale{value: finalPrice}(nft);

        uint256 sellerAmount = salePrice - (salePrice * sellFee) / 100 - (salePrice * burnFee) / 100;
        uint256 feeAmount = (salePrice * sellFee) / 100 + (salePrice * buyFee) / 100;
        uint256 burnAmount = (salePrice * burnFee) / 100;

        assertEq(seller.balance - initialSellerBalance, sellerAmount, "Incorrect seller balance");
        assertEq(feeReceiver.balance - initialFeeBalance, feeAmount, "Incorrect fee receiver balance");
        assertEq(BURN_ADDRESS.balance - initialBurnBalance, burnAmount, "Incorrect burn address balance");

        assertEq(sellerAmount + feeAmount + burnAmount, finalPrice, "Total distribution does not match buyer payment");
    }
}
