// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "@/NFT.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract DeployNFT is Script {
    function run() external {
        address admin = vm.envAddress("ADMIN_TIMELOCK_2D");
        address minter = vm.envAddress("BCI");
        address pauser = vm.envAddress("ADMIN");
        uint256 initialId = vm.envUint("NFT_INITIAL_ID");
        string memory baseURI = vm.envString("NFT_BASE_URI");
        string memory name = vm.envString("NFT_NAME");
        string memory symbol = vm.envString("NFT_SYMBOL");

        vm.startBroadcast();

        require(msg.sender != admin, "Deployer cannot be the admin wallet");
        require(msg.sender != minter, "Deployer cannot be the minter wallet");
        require(msg.sender != pauser, "Deployer cannot be the pauser wallet");

        NFT nft = new NFT(initialId, name, symbol);
        nft.setBaseURI(baseURI);
        nft.grantRole(nft.DEFAULT_ADMIN_ROLE(), admin);
        nft.grantRole(nft.MINT_ROLE(), minter);
        nft.grantRole(nft.PAUSER_ROLE(), pauser);

        vm.stopBroadcast();
    }

    function getAddress() public view returns (address) {
        string memory path = string.concat(
            vm.projectRoot(), "/broadcast/1_NFT.s.sol/", Strings.toString(vm.envUint("CHAIN_ID")), "/run-latest.json"
        );
        return stdJson.readAddress(vm.readFile(path), ".transactions[0].contractAddress");
    }
}
