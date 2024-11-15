// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Script.sol";
import {DeployNFT} from "./1_NFT.s.sol";
import {DistributionManager} from "@/DistributionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract DeployDistributionManager is Script {
    function run() external {
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address nftAddress = new DeployNFT().getAddress();
        address admin = vm.envAddress("ADMIN_TIMELOCK_2D");
        address pauser = vm.envAddress("ADMIN");
        address distributor = vm.envAddress("BCI");

        vm.startBroadcast();

        require(msg.sender != admin, "Deployer cannot be the admin wallet");
        require(msg.sender != pauser, "Deployer cannot be the pauser wallet");
        require(msg.sender != distributor, "Deployer cannot be the distributor wallet");

        DistributionManager distributionManager = new DistributionManager(tokenAddress, nftAddress);
        distributionManager.grantRole(distributionManager.DEFAULT_ADMIN_ROLE(), admin);
        distributionManager.grantRole(distributionManager.PAUSER_ROLE(), pauser);
        distributionManager.grantRole(distributionManager.DISTRIBUTOR_ROLE(), distributor);
        distributionManager.revokeRole(distributionManager.DEFAULT_ADMIN_ROLE(), msg.sender);

        vm.stopBroadcast();
        vm.startBroadcast(vm.envUint("BCI_PRIVATE_KEY"));

        require(
            vm.addr(vm.envUint("BCI_PRIVATE_KEY")) == vm.envAddress("BCI"), "BCI_PRIVATE_KEY does not match BCI address"
        );

        IERC20 token = IERC20(tokenAddress);
        token.approve(address(distributionManager), type(uint256).max);
        IERC721 nft = IERC721(nftAddress);
        nft.setApprovalForAll(address(distributionManager), true);

        vm.stopBroadcast();
    }
}
