// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.6;

import { IERC721 } from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

interface IApiologyDAOToken is IERC721 {
    function mint() external returns (uint256);
    function burn(uint256 tokenId) external;
    function setTokenURIHash(string memory newTokenURIHash) external;
    function setLiquidBackingTreasury(address _liquidBackingTreasury) external;
    function setAuctionHouse(address _auctionHouse) external;

}