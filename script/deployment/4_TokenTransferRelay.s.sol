// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Script.sol";
import {DeployNFT} from "./1_NFT.s.sol";
import {TokenTransferRelay} from "@/TokenTransferRelay.sol";

contract DeployDistributionManager is Script {
    function run() external {
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address nftAddress = new DeployNFT().getAddress();
        address nativeReceiver = vm.envAddress("TOKEN_TRANSFER_RELAY_NATIVE_RECEIVER");
        address nftReceiver = vm.envAddress("TOKEN_TRANSFER_RELAY_NFT_RECEIVER");
        address tokenReceiver = vm.envAddress("TOKEN_TRANSFER_RELAY_TOKEN_RECEIVER");
        address admin = vm.envAddress("ADMIN_TIMELOCK_2D");
        address operator = vm.envAddress("BCI");

        vm.startBroadcast();

        require(msg.sender != admin, "Deployer cannot be the admin wallet");
        require(msg.sender != operator, "Deployer cannot be the operator wallet");

        TokenTransferRelay tokenRelay =
            new TokenTransferRelay(nftAddress, tokenAddress, nativeReceiver, nftReceiver, tokenReceiver);
        tokenRelay.grantRole(tokenRelay.DEFAULT_ADMIN_ROLE(), admin);
        tokenRelay.grantRole(tokenRelay.MAINTENANCE_ROLE(), admin);
        tokenRelay.grantRole(tokenRelay.OPERATOR_ROLE(), operator);
        tokenRelay.revokeRole(tokenRelay.DEFAULT_ADMIN_ROLE(), msg.sender);

        vm.stopBroadcast();
    }
}
