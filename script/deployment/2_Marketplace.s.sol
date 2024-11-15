// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Script.sol";
import {DeployNFT} from "./1_NFT.s.sol";
import {Marketplace} from "@/Marketplace_1.0.0.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployMarketplace is Script {
    function run() external {
        address nftAddress = new DeployNFT().getAddress();
        address admin = vm.envAddress("ADMIN_TIMELOCK_2D");
        address feeManager = admin;
        address feeReceiver = vm.envAddress("MARKETPLACE_FEE_RECEIVER");
        uint8 sellPercentFee = uint8(vm.envUint("MARKETPLACE_SELL_PERCENT_FEE"));
        uint8 buyPercentFee = uint8(vm.envUint("MARKETPLACE_BUY_PERCENT_FEE"));
        uint8 burnPercentFee = uint8(vm.envUint("MARKETPLACE_BURN_PERCENT_FEE"));

        vm.startBroadcast();

        require(msg.sender != admin, "Deployer cannot be the admin wallet");
        require(msg.sender != feeManager, "Deployer cannot be the feeManager wallet");

        address proxy = Upgrades.deployTransparentProxy(
            "Marketplace_1.0.0.sol:Marketplace", admin, abi.encodeCall(Marketplace.initialize, (nftAddress))
        );
        Marketplace marketplace = Marketplace(proxy);
        require(
            marketplace.hasRole(marketplace.DEFAULT_ADMIN_ROLE(), msg.sender), "Expect DEFAULT_ADMIN_ROLE on Deployer"
        );
        marketplace.grantRole(marketplace.FEE_MANAGER_ROLE(), msg.sender);
        marketplace.setMarketplaceFeesReceiver(feeReceiver);
        marketplace.setMarketplacePercentFees(sellPercentFee, buyPercentFee, burnPercentFee);
        marketplace.renounceRole(marketplace.FEE_MANAGER_ROLE(), msg.sender);
        marketplace.grantRole(marketplace.DEFAULT_ADMIN_ROLE(), admin);
        marketplace.grantRole(marketplace.FEE_MANAGER_ROLE(), feeManager);
        marketplace.renounceRole(marketplace.DEFAULT_ADMIN_ROLE(), msg.sender);

        vm.stopBroadcast();
    }
}
