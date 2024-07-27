// SPDX-License-Identifier: GPL-3.0

/// @title The Nouns DAO auction house

// LICENSE
// NounsAuctionHouse.sol is a modified version of Zora's AuctionHouse.sol:
// https://github.com/ourzora/auction-house/blob/54a12ec1a6cf562e49f0a4917990474b11350a2d/contracts/AuctionHouse.sol
//
// AuctionHouse.sol source code Copyright Zora licensed under the GPL-3.0 license.
// With modifications by Nounders DAO.

pragma solidity ^0.8.19;

import { PausableUpgradeable } from '@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol';
import { ReentrancyGuardUpgradeable } from '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import { OwnableUpgradeable } from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { INounsAuctionHouseV2 } from './interfaces/INounsAuctionHouseV2.sol';
import { INounsToken } from './interfaces/INounsToken.sol';
import { IWETH } from './interfaces/IWETH.sol';
import { IEntropy } from '@pythnetwork/entropy-sdk-solidity/IEntropy.sol';
import { IEntropyConsumer } from '@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol';

/**
 * @dev The contract inherits from PausableUpgradeable & ReentrancyGuardUpgradeable most of all the keep the same
 * storage layout as the NounsAuctionHouse contract
 */
contract NounsAuctionHouseV2 is
    INounsAuctionHouseV2,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    IEntropyConsumer
{
    /// @notice A hard-coded cap on time buffer to prevent accidental auction disabling if set with a very high value.
    uint56 public constant MAX_TIME_BUFFER = 1 days;

    /// @notice The Nouns ERC721 token contract
    INounsToken public immutable nouns;

    /// @notice The address of the WETH contract
    address public immutable weth;

    /// @notice The duration of a single auction
    uint256 public duration;

    /// @notice The minimum price accepted in an auction
    uint192 public reservePrice;

    /// @notice The minimum amount of time left in an auction after a new bid is created
    uint56 public timeBuffer;

    /// @notice The minimum percentage difference between the last bid amount and the current bid
    uint8 public minBidIncrementPercentage;

    /// @notice The active auction
    INounsAuctionHouseV2.AuctionV2 public auctionStorage;

    /// @notice The Nouns price feed state
    mapping(uint256 => SettlementState) settlementHistory;

     /// @notice Queue of NFTs to be auctioned from members wanting to sell
    uint256[] public auctionQueue;

    /// @notice Mapping to track the owner of each NFT in the queue
    mapping(uint256 => address) public nftOwners;

    /// @notice The address of the DAO treasury
    address public treasury;

    /// @notice The fee percentage taken from each sale
    uint8 public feePercentage;

    /// @notice The Pyth Entropy contract
    IEntropy public entropy;

    /// @notice The address of the entropy provider
    address public provider;

    /// @notice Emitted when a random number is requested
    event RandomNumberRequested(uint64 sequenceNumber);

    /// @notice Emitted when a random number is received
    event RandomNumberReceived(uint64 sequenceNumber, bytes32 randomNumber);

    // @notice Emitted when auction duration is updated
    event AuctionDurationUpdated(uint256 duration);

    /**
     * @notice Constructor to initialize the contract with required parameters
     * @param _nouns The Nouns ERC721 token contract
     * @param _weth The address of the WETH contract
     * @param _entropy The address of the Pyth Entropy contract
     * @param _provider The address of the entropy provider
     */
    constructor(INounsToken _nouns, address _weth, address _entropy, address _provider) initializer {
        nouns = _nouns;
        weth = _weth;
        entropy = IEntropy(_entropy);
        provider = _provider;
    }

    /**
     * @notice Initialize the auction house and base contracts,
     * populate configuration values, and pause the contract.
     * @dev This function can only be called once.
     */
    function initialize(
        uint256 _duration,
        uint192 _reservePrice,
        uint56 _timeBuffer,
        uint8 _minBidIncrementPercentage
    ) external initializer {
        __Pausable_init();
        __ReentrancyGuard_init();
        __Ownable_init();

        _pause();

        duration = _duration;
        reservePrice = _reservePrice;
        timeBuffer = _timeBuffer;
        minBidIncrementPercentage = _minBidIncrementPercentage;
        treasury = owner(); // By default, the treasury is the owner
        feePercentage = 0;
    }

    /**
     * @notice Settle the current auction, mint a new Noun, and put it up for auction.
     */
    function settleCurrentAndCreateNewAuction() external override whenNotPaused {
        _settleAuction();
        _createAuction();
    }

    /**
     * @notice Settle the current auction.
     * @dev This function can only be called when the contract is paused.
     */
    function settleAuction() external override whenPaused {
        _settleAuction();
    }

    /**
     * @notice Add an NFT to the auction queue.
     * @param tokenId The ID of the NFT to add to the queue.
     */
    function addToAuctionQueue(uint256 tokenId) external payable{
        require(nouns.ownerOf(tokenId) == msg.sender, "Not the owner of the NFT");
        auctionQueue.push(tokenId);
        nftOwners[tokenId] = msg.sender;

        // Add burning of Station X governance tokens from users wallet here

        nouns.transferFrom(msg.sender, address(this), tokenId);
    }

    /**
     * @notice Remove an NFT from the auction queue.
     * @param tokenId The ID of the NFT to remove from the queue.
     */
    function removeFromAuctionQueue(uint256 tokenId) external {
        require(nftOwners[tokenId] == msg.sender, "Not the owner of the NFT");

        // Find the index of the tokenId in the queue
        uint256 index;
        bool found = false;
        for (uint256 i = 0; i < auctionQueue.length; i++) {
            if (auctionQueue[i] == tokenId) {
                index = i;
                found = true;
                break;
            }
        }
        require(found, "NFT not found in the queue");

        // Remove the NFT from the queue
        auctionQueue[index] = auctionQueue[auctionQueue.length - 1];
        auctionQueue.pop();

        // Remove the owner mapping
        delete nftOwners[tokenId];

        nouns.transferFrom(address(this), msg.sender, tokenId);
    }

    /**
     * @notice Create a bid for a Noun, with a given amount.
     * @dev This contract only accepts payment in ETH.
     */
    function createBid(uint256 nounId) external payable override {
        createBid(nounId, 0);
    }

    /**
     * @notice Create a bid for a Noun, with a given amount.
     * @param nounId id of the Noun to bid on
     * @param clientId the client which facilitate this action
     * @dev This contract only accepts payment in ETH.
     */
    function createBid(uint256 nounId, uint32 clientId) public payable override {
        INounsAuctionHouseV2.AuctionV2 memory _auction = auctionStorage;

        (uint192 _reservePrice, uint56 _timeBuffer, uint8 _minBidIncrementPercentage) = (
            reservePrice,
            timeBuffer,
            minBidIncrementPercentage
        );

        require(_auction.nounId == nounId, 'Noun not up for auction');
        require(block.timestamp < _auction.endTime, 'Auction expired');
        require(msg.value >= _reservePrice, 'Must send at least reservePrice');
        require(
            msg.value >= _auction.amount + ((_auction.amount * _minBidIncrementPercentage) / 100),
            'Must send more than last bid by minBidIncrementPercentage amount'
        );

        auctionStorage.clientId = clientId;
        auctionStorage.amount = uint128(msg.value);
        auctionStorage.bidder = payable(msg.sender);

        // Extend the auction if the bid was received within `timeBuffer` of the auction end time
        bool extended = _auction.endTime - block.timestamp < _timeBuffer;

        emit AuctionBid(_auction.nounId, msg.sender, msg.value, extended);
        if (clientId > 0) emit AuctionBidWithClientId(_auction.nounId, msg.value, clientId);

        if (extended) {
            auctionStorage.endTime = _auction.endTime = uint40(block.timestamp + _timeBuffer);
            emit AuctionExtended(_auction.nounId, _auction.endTime);
        }

        address payable lastBidder = _auction.bidder;

        // Refund the last bidder, if applicable
        if (lastBidder != address(0)) {
            _safeTransferETHWithFallback(lastBidder, _auction.amount);
        }
    }

    /**
     * @notice Get the current auction.
     */
    function auction() external view returns (AuctionV2View memory) {
        return
            AuctionV2View({
                nounId: auctionStorage.nounId,
                amount: auctionStorage.amount,
                startTime: auctionStorage.startTime,
                endTime: auctionStorage.endTime,
                bidder: auctionStorage.bidder,
                settled: auctionStorage.settled
            });
    }

    /**
     * @notice Pause the Nouns auction house.
     * @dev This function can only be called by the owner when the
     * contract is unpaused. While no new auctions can be started when paused,
     * anyone can settle an ongoing auction.
     */
    function pause() external override onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the Nouns auction house.
     * @dev This function can only be called by the owner when the
     * contract is paused. If required, this function will start a new auction.
     */
    function unpause() external override onlyOwner {
        _unpause();

        if (auctionStorage.startTime == 0 || auctionStorage.settled) {
            _createAuction();
        }
    }

    /**
     * @notice Set the auction time buffer.
     * @dev Only callable by the owner.
     */
    function setTimeBuffer(uint56 _timeBuffer) external override onlyOwner {
        require(_timeBuffer <= MAX_TIME_BUFFER, 'timeBuffer too large');

        timeBuffer = _timeBuffer;

        emit AuctionTimeBufferUpdated(_timeBuffer);
    }

    /**
     * @notice Set the DAO treasury address.
     * @dev Only callable by the owner.
     */
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    // /**
    // * @notice Set the auction duration.
    // * @dev Only callable by the owner.
    // * @param _duration The new duration for the auction
    // */
    // function setDuration(uint256 _duration) external onlyOwner {
    //     require(_duration > 0, "Duration must be greater than zero");
    //     duration = _duration;
    //     emit AuctionDurationUpdated(_duration);
    // }

    /**
    * @notice Set the fee percentage taken from each sale.
    * @dev Only callable by the owner.
    * @param _feePercentage The new fee percentage
    */
    function setFeePercentage(uint8 _feePercentage) external onlyOwner {
        require(_feePercentage <= 100, "Fee percentage too high");
        feePercentage = _feePercentage;
        emit FeePercentageUpdated(_feePercentage);
    }

    /**
     * @notice Set the auction reserve price.
     * @dev Only callable by the owner.
     */
    function setReservePrice(uint192 _reservePrice) external override onlyOwner {
        reservePrice = _reservePrice;

        emit AuctionReservePriceUpdated(_reservePrice);
    }

    /**
     * @notice Internally set the auction reserve price.
     */
    function _setReservePrice(uint192 _reservePrice) internal {
        reservePrice = _reservePrice;

        emit AuctionReservePriceUpdated(_reservePrice);
    }

    /**
     * @notice Set the auction minimum bid increment percentage.
     * @dev Only callable by the owner.
     */
    function setMinBidIncrementPercentage(uint8 _minBidIncrementPercentage) external override onlyOwner {
        require(_minBidIncrementPercentage > 0, 'must be greater than zero');

        minBidIncrementPercentage = _minBidIncrementPercentage;

        emit AuctionMinBidIncrementPercentageUpdated(_minBidIncrementPercentage);
    }

    /**
     * @notice Request a random number from the Pyth Entropy contract
     */
    function requestRandomNumber() internal {
        bytes32 userRandomNumber = keccak256(abi.encodePacked(block.timestamp, msg.sender));
        uint128 requestFee = entropy.getFee(provider);
        uint64 sequenceNumber = entropy.requestWithCallback{ value: requestFee }(provider, userRandomNumber);
        emit RandomNumberRequested(sequenceNumber);
    }

    /**
     * @notice Callback function to handle the random number response from the Pyth Entropy contract
     * @param sequenceNumber The sequence number of the request
     * @param _providerAddress The address of the entropy provider
     * @param randomNumber The random number received
     */
    function entropyCallback(
        uint64 sequenceNumber,
        address _providerAddress,
        bytes32 randomNumber
    ) internal override {
        emit RandomNumberReceived(sequenceNumber, randomNumber);
        _createAuctionWithRandomNumber(randomNumber);
    }

    /**
     * @notice Create a new auction, requesting a random number if the auction queue is not empty
     */
    function _createAuction() internal {
        if (auctionQueue.length > 0) {
            requestRandomNumber();
        } else {
            _createAuctionWithRandomNumber(0);
        }
    }

    /**
     * @notice Create a new auction using the provided random number
     * @param randomNumber The random number to use for selecting an ID from the auction queue
     */
    function _createAuctionWithRandomNumber(bytes32 randomNumber) internal {
        uint256 nounId;
        if (auctionQueue.length > 0) {
            uint256 randomIndex = uint256(randomNumber) % auctionQueue.length;
            nounId = auctionQueue[randomIndex];
            auctionQueue[randomIndex] = auctionQueue[auctionQueue.length - 1];
            auctionQueue.pop();
        } else {
            try nouns.mint() returns (uint256 mintedNounId) {
                nounId = mintedNounId;
                nftOwners[nounId] = address(0);
            } catch Error(string memory) {
                _pause();
                return;
            }
        }

        uint40 startTime = uint40(block.timestamp);
        uint40 endTime = startTime + uint40(duration);

        auctionStorage = AuctionV2({
            nounId: uint96(nounId),
            clientId: 0,
            amount: 0,
            startTime: startTime,
            endTime: endTime,
            bidder: payable(0),
            settled: false
        });

        emit AuctionCreated(nounId, startTime, endTime);
    }

    /** 
    * @notice Settle an auction, finalizing the bid and paying out to the owner.
    * @dev If there are no bids, the Noun is burned. If the NFT came from the queue, a fee is taken and sent to the treasury.
    */
    function _settleAuction() internal {
        INounsAuctionHouseV2.AuctionV2 memory _auction = auctionStorage;

        require(_auction.startTime != 0, "Auction hasn't begun");
        require(!_auction.settled, 'Auction has already been settled');
        require(block.timestamp >= _auction.endTime, "Auction hasn't completed");

        auctionStorage.settled = true;

        if (_auction.bidder == address(0)) { // If there are no bids
            if (nftOwners[_auction.nounId] != address(0)) {
                // NEED TO UPDATE to call the liquid backing treasury contract to transfer backing to owner
                // then burn the NFT


                // Re-add the NFT to the queue if it came from the queue
                auctionQueue.push(_auction.nounId);
            } else {
                // Burn the NFT if it was minted
                nouns.burn(_auction.nounId);
            }
        } else {
            if (_auction.amount > 0) {
                address payable recipient = nftOwners[_auction.nounId] != address(0) ? payable(nftOwners[_auction.nounId]) : payable(treasury);
                
                // Calculate the fee and the amount to send to the recipient
                uint256 fee = (_auction.amount * feePercentage) / 100;
                uint256 amountAfterFee = _auction.amount - fee;

                // Clear the owner mapping before making the external call
                delete nftOwners[_auction.nounId];

                // Transfer the fee to the treasury
                _safeTransferETHWithFallback(payable(treasury), fee);

                // Transfer the remaining amount to the recipient
                _safeTransferETHWithFallback(recipient, amountAfterFee);
            }
            nouns.transferFrom(address(this), _auction.bidder, _auction.nounId);

            // Add in minting station X governance tokens to the winning bidder
        }

        SettlementState storage settlementState = settlementHistory[_auction.nounId];
        settlementState.blockTimestamp = uint32(block.timestamp);
        settlementState.amount = ethPriceToUint64(_auction.amount);
        settlementState.winner = _auction.bidder;
        if (_auction.clientId > 0) settlementState.clientId = _auction.clientId;

        emit AuctionSettled(_auction.nounId, _auction.bidder, _auction.amount);
        if (_auction.clientId > 0) emit AuctionSettledWithClientId(_auction.nounId, _auction.clientId);
    }

    /**
     * @notice Transfer ETH. If the ETH transfer fails, wrap the ETH and try send it as WETH.
     */
    function _safeTransferETHWithFallback(address to, uint256 amount) internal {
        if (!_safeTransferETH(to, amount)) {
            IWETH(weth).deposit{ value: amount }();
            IERC20(weth).transfer(to, amount);
        }
    }

    /**
     * @notice Transfer ETH and return the success status.
     * @dev This function only forwards 30,000 gas to the callee.
     */
    function _safeTransferETH(address to, uint256 value) internal returns (bool) {
        bool success;
        assembly {
            success := call(30000, to, value, 0, 0, 0, 0)
        }
        return success;
    }

    /**
     * @notice Set historic prices; only callable by the owner, which in Nouns is the treasury (timelock) contract.
     * @dev This function lowers auction price accuracy from 18 decimals to 10 decimals, as part of the price history
     * bit packing, to save gas.
     * @param settlements The list of historic prices to set.
     */
    function setPrices(SettlementNoClientId[] memory settlements) external onlyOwner {
        for (uint256 i = 0; i < settlements.length; ++i) {
            SettlementState storage settlementState = settlementHistory[settlements[i].nounId];
            settlementState.blockTimestamp = settlements[i].blockTimestamp;
            settlementState.amount = ethPriceToUint64(settlements[i].amount);
            settlementState.winner = settlements[i].winner;
        }
    }

    /**
     * @notice Warm up the settlement state for a range of Noun IDs.
     * @dev Helps lower the gas cost of auction settlement when storing settlement data
     * thanks to the state slot being non-zero.
     * @dev Only writes to slots where blockTimestamp is zero, meaning it will not overwrite existing data.
     * @dev Skips Nounder reward nouns.
     * @param startId the first Noun ID to warm up.
     * @param endId end Noun ID (up to, but not including).
     */
    function warmUpSettlementState(uint256 startId, uint256 endId) external {
        for (uint256 i = startId; i < endId; ++i) {
            // Skipping Nounder rewards, no need to warm up those slots since they are never used.
            if (i <= 1820 && i % 10 == 0) continue;

            SettlementState storage settlementState = settlementHistory[i];
            if (settlementState.blockTimestamp == 0) {
                settlementState.blockTimestamp = 1;
                settlementState.slotWarmedUp = true;
            }
        }
    }

    /**
     * @notice Get past auction settlements.
     * @dev Returns up to `auctionCount` settlements in reverse order, meaning settlements[0] will be the most recent auction price.
     * Includes auctions with no bids (blockTimestamp will be > 1)
     * @param auctionCount The number of price observations to get.
     * @param skipEmptyValues if true, skips nounder reward ids and ids with missing data
     * @return settlements An array of type `Settlement`, where each Settlement includes a timestamp,
     * the Noun ID of that auction, the winning bid amount, and the winner's address.
     */
    function getSettlements(
        uint256 auctionCount,
        bool skipEmptyValues
    ) external view returns (Settlement[] memory settlements) {
        uint256 latestNounId = auctionStorage.nounId;
        if (!auctionStorage.settled && latestNounId > 0) {
            latestNounId -= 1;
        }

        settlements = new Settlement[](auctionCount);
        uint256 actualCount = 0;

        SettlementState memory settlementState;
        for (uint256 id = latestNounId; actualCount < auctionCount; --id) {
            settlementState = settlementHistory[id];

            if (skipEmptyValues && settlementState.blockTimestamp <= 1) {
                if (id == 0) break;
                continue;
            }

            settlements[actualCount] = Settlement({
                blockTimestamp: settlementState.blockTimestamp,
                amount: uint64PriceToUint256(settlementState.amount),
                winner: settlementState.winner,
                nounId: id,
                clientId: settlementState.clientId
            });
            ++actualCount;

            if (id == 0) break;
        }

        if (auctionCount > actualCount) {
            // this assembly trims the observations array, getting rid of unused cells
            assembly {
                mstore(settlements, actualCount)
            }
        }
    }

    /**
     * @notice Get past auction prices.
     * @dev Returns prices in reverse order, meaning prices[0] will be the most recent auction price.
     * Skips auctions where there was no winner, i.e. no bids.
     * Skips nounder rewards noun ids.
     * Reverts if getting a empty data for an auction that happened, e.g. historic data not filled
     * Reverts if there's not enough auction data, i.e. reached noun id 0
     * @param auctionCount The number of price observations to get.
     * @return prices An array of uint256 prices.
     */
    function getPrices(uint256 auctionCount) external view returns (uint256[] memory prices) {
        uint256 latestNounId = auctionStorage.nounId;
        if (!auctionStorage.settled && latestNounId > 0) {
            latestNounId -= 1;
        }

        prices = new uint256[](auctionCount);
        uint256 actualCount = 0;

        SettlementState memory settlementState;
        for (uint256 id = latestNounId; id > 0 && actualCount < auctionCount; --id) {
            if (id <= 1820 && id % 10 == 0) continue; // Skip Nounder reward nouns

            settlementState = settlementHistory[id];
            require(settlementState.blockTimestamp > 1, 'Missing data');
            if (settlementState.winner == address(0)) continue; // Skip auctions with no bids

            prices[actualCount] = uint64PriceToUint256(settlementState.amount);
            ++actualCount;
        }

        require(auctionCount == actualCount, 'Not enough history');
    }

    /**
     * @notice Get all past auction settlements starting at `startId` and settled before or at `endTimestamp`.
     * @param startId the first Noun ID to get prices for.
     * @param endTimestamp the latest timestamp for auctions
     * @param skipEmptyValues if true, skips nounder reward ids and ids with missing data
     * @return settlements An array of type `Settlement`, where each Settlement includes a timestamp,
     * the Noun ID of that auction, the winning bid amount, and the winner's address.
     */
    function getSettlementsFromIdtoTimestamp(
        uint256 startId,
        uint256 endTimestamp,
        bool skipEmptyValues
    ) public view returns (Settlement[] memory settlements) {
        uint256 maxId = auctionStorage.nounId;
        require(startId <= maxId, 'startId too large');
        settlements = new Settlement[](maxId - startId + 1);
        uint256 actualCount = 0;
        SettlementState memory settlementState;
        for (uint256 id = startId; id <= maxId; ++id) {
            settlementState = settlementHistory[id];

            if (skipEmptyValues && settlementState.blockTimestamp <= 1) continue;

            // don't include the currently auctioned noun if it hasn't settled
            if ((id == maxId) && (settlementState.blockTimestamp <= 1)) continue;

            if (settlementState.blockTimestamp > endTimestamp) break;

            settlements[actualCount] = Settlement({
                blockTimestamp: settlementState.blockTimestamp,
                amount: uint64PriceToUint256(settlementState.amount),
                winner: settlementState.winner,
                nounId: id,
                clientId: settlementState.clientId
            });
            ++actualCount;
        }

        if (settlements.length > actualCount) {
            // this assembly trims the settlements array, getting rid of unused cells
            assembly {
                mstore(settlements, actualCount)
            }
        }
    }

    /**
     * @notice Get a range of past auction settlements.
     * @dev Returns prices in chronological order, as opposed to `getSettlements(count)` which returns prices in reverse order.
     * Includes auctions with no bids (blockTimestamp will be > 1)
     * @param startId the first Noun ID to get prices for.
     * @param endId end Noun ID (up to, but not including).
     * @param skipEmptyValues if true, skips nounder reward ids and ids with missing data
     * @return settlements An array of type `Settlement`, where each Settlement includes a timestamp,
     * the Noun ID of that auction, the winning bid amount, and the winner's address.
     */
    function getSettlements(
        uint256 startId,
        uint256 endId,
        bool skipEmptyValues
    ) external view returns (Settlement[] memory settlements) {
        settlements = new Settlement[](endId - startId);
        uint256 actualCount = 0;

        SettlementState memory settlementState;
        for (uint256 id = startId; id < endId; ++id) {
            settlementState = settlementHistory[id];

            if (skipEmptyValues && settlementState.blockTimestamp <= 1) continue;

            settlements[actualCount] = Settlement({
                blockTimestamp: settlementState.blockTimestamp,
                amount: uint64PriceToUint256(settlementState.amount),
                winner: settlementState.winner,
                nounId: id,
                clientId: settlementState.clientId
            });
            ++actualCount;
        }

        if (settlements.length > actualCount) {
            // this assembly trims the settlements array, getting rid of unused cells
            assembly {
                mstore(settlements, actualCount)
            }
        }
    }

    /***
     * @notice Get the client ID that facilitated the winning bid for a Noun. Returns 0 if there is no settlement data
     * for the Noun in question, or if the winning bid was not facilitated by a registered client.
     */
    function biddingClient(uint256 nounId) external view returns (uint32) {
        return settlementHistory[nounId].clientId;
    }

    /**
     * @dev Convert an ETH price of 256 bits with 18 decimals, to 64 bits with 10 decimals.
     * Max supported value is 1844674407.3709551615 ETH.
     *
     */
    function ethPriceToUint64(uint256 ethPrice) internal pure returns (uint64) {
        return uint64(ethPrice / 1e8);
    }

    /**
     * @dev Convert a 64 bit 10 decimal price to a 256 bit 18 decimal price.
     */
    function uint64PriceToUint256(uint64 price) internal pure returns (uint256) {
        return uint256(price) * 1e8;
    }

    function getAuctionQueueLength() external view returns (uint256) {
        return auctionQueue.length;
    }

    // This method is required by the IEntropyConsumer interface
    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    function setEntropy(address _entropy) external onlyOwner {
        entropy = IEntropy(_entropy);
    }
}
