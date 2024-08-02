// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.6;

import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';
import { ERC721Checkpointable } from './base/ERC721Checkpointable.sol';
import { IApiologyDAOToken } from './interfaces/IApiologyDAOToken.sol';
import { ERC721 } from './base/ERC721.sol';
import { IERC721 } from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

contract ApiologyDAOToken is IApiologyDAOToken, Ownable, ERC721Checkpointable {
    // The address of the Liquid Backing Treasury (LBT)
    address public liquidBackingTreasury;

    // The address of the Auction House
    address public auctionHouse;

    // The internal token ID tracker
    uint256 private _currentTokenId;

    // The token URI hash
    string private _tokenURIHash;

    // Events
    event TransferToLBT(address indexed from, uint256 indexed tokenId);
    event TransferFromLBT(address indexed to, uint256 indexed tokenId);
    event TransferToAuctionHouse(address indexed from, uint256 indexed tokenId);
    event TransferFromAuctionHouse(address indexed to, uint256 indexed tokenId);
    event TokenCreated(uint256 indexed tokenId);
    event TokenBurned(uint256 indexed tokenId);
    event LiquidBackingTreasuryUpdated(address indexed newLiquidBackingTreasury);
    event AuctionHouseUpdated(address indexed newAuctionHouse);
    event TokenURIHashUpdated(string newTokenURIHash);

    /**
     * @notice Require that the sender is the LBT.
     */
    modifier onlyLBT() {
        require(msg.sender == liquidBackingTreasury, 'Sender is not the LBT');
        _;
    }

    /**
     * @notice Require that the sender is the Auction House.
     */
    modifier onlyAuctionHouse() {
        require(msg.sender == auctionHouse, 'Sender is not the Auction House');
        _;
    }

    constructor(
        address _liquidBackingTreasury,
        address _auctionHouse,
        string memory initialTokenURIHash
    ) ERC721('ApiologyDAO', 'APDAO') {
        liquidBackingTreasury = _liquidBackingTreasury;
        auctionHouse = _auctionHouse;
        _tokenURIHash = initialTokenURIHash;
    }

    /**
     * @notice Override transferFrom to implement transfer restrictions and emit custom events.
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override(IERC721, ERC721) {
        require(
            to == liquidBackingTreasury || to == auctionHouse || 
            from == liquidBackingTreasury || from == auctionHouse,
            'Token can only be transferred to/from LBT or Auction House'
        );
        super.transferFrom(from, to, tokenId);

        if (to == liquidBackingTreasury) {
            emit TransferToLBT(from, tokenId);
        } else if (from == liquidBackingTreasury) {
            emit TransferFromLBT(to, tokenId);
        } else if (to == auctionHouse) {
            emit TransferToAuctionHouse(from, tokenId);
        } else if (from == auctionHouse) {
            emit TransferFromAuctionHouse(to, tokenId);
        }
    }

    /**
     * @notice Override safeTransferFrom to implement transfer restrictions and emit custom events.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) public override(IERC721, ERC721) {
        require(
            to == liquidBackingTreasury || to == auctionHouse || 
            from == liquidBackingTreasury || from == auctionHouse,
            'Token can only be transferred to/from LBT or Auction House'
        );
        super.safeTransferFrom(from, to, tokenId, _data);

        if (to == liquidBackingTreasury) {
            emit TransferToLBT(from, tokenId);
        } else if (from == liquidBackingTreasury) {
            emit TransferFromLBT(to, tokenId);
        } else if (to == auctionHouse) {
            emit TransferToAuctionHouse(from, tokenId);
        } else if (from == auctionHouse) {
            emit TransferFromAuctionHouse(to, tokenId);
        }
    }

    /**
     * @notice Mint a new token.
     * @dev This can only be called by the Auction House.
     */
    function mint() public override onlyAuctionHouse returns (uint256) {
        uint256 newTokenId = _currentTokenId++;
        _mintTo(auctionHouse, newTokenId);
        emit TransferToAuctionHouse(address(0), newTokenId);
        return newTokenId;
    }

    /**
     * @notice Burn a token.
     * @dev This can only be called by the LBT or Auction House.
     */
    function burn(uint256 tokenId) public override {
        require(msg.sender == liquidBackingTreasury || msg.sender == auctionHouse, 'Only LBT or Auction House can burn');
        address owner = ownerOf(tokenId);
        _burn(tokenId);
        emit TokenBurned(tokenId);
        if (owner == liquidBackingTreasury) {
            emit TransferFromLBT(address(0), tokenId);
        } else if (owner == auctionHouse) {
            emit TransferFromAuctionHouse(address(0), tokenId);
        }
    }

    /**
     * @notice Get the token URI for a given token ID.
     * @dev All tokens share the same metadata.
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), 'ApiologyDAOToken: URI query for nonexistent token');
        return string(abi.encodePacked('ipfs://', _tokenURIHash));
    }

    /**
     * @notice Set the token URI hash.
     * @dev This can only be called by the owner.
     */
    function setTokenURIHash(string memory newTokenURIHash) external onlyOwner {
        _tokenURIHash = newTokenURIHash;
        emit TokenURIHashUpdated(newTokenURIHash);
    }

    /**
     * @notice Set the LBT address.
     * @dev This can only be called by the owner.
     */
    function setLiquidBackingTreasury(address _liquidBackingTreasury) external onlyOwner {
        liquidBackingTreasury = _liquidBackingTreasury;
        emit LiquidBackingTreasuryUpdated(_liquidBackingTreasury);
    }

    /**
     * @notice Set the Auction House address.
     * @dev This can only be called by the owner.
     */
    function setAuctionHouse(address _auctionHouse) external onlyOwner {
        auctionHouse = _auctionHouse;
        emit AuctionHouseUpdated(_auctionHouse);
    }

    /**
     * @notice Mint a token to a specific address.
     * @dev This is an internal function used by the mint function.
     */
    function _mintTo(address to, uint256 tokenId) internal returns (uint256) {
        // Use the contract owner as the creator
        address creator = owner();
        
        _mint(creator, to, tokenId);
        emit TokenCreated(tokenId);
        
        return tokenId;
    }
}