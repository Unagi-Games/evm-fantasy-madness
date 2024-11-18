// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract TestERC20 is ERC20 {
    constructor() ERC20("Test Token", "TEST") {}

    function mint(address account, uint256 amount) public {
        _mint(account, amount);
    }
}
