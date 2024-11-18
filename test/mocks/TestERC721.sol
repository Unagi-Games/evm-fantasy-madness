// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract TestERC721 is ERC721 {
    constructor() ERC721("Test NFT", "TNFT") {}

    function mint(address account, uint256 tokenId) public {
        _mint(account, tokenId);
    }
}
