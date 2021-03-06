/// collateralForDaiAuction.sol -- Collateral auction

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.0;

import "./lib.sol";

contract cdpDatabaseInterface {
    function move(address,address,uint) public;
    function transferCollateral(bytes32,address,address,uint) public;
}

/*
   This thing lets you sell some collateralTokens for a given amount of dai.
   Once the given amount of dai is raised, collateralTokens are forgone instead.

 - `lot` collateralTokens for sale
 - `totalDaiWanted` total dai wanted
 - `bid` dai paid
 - `incomeRecipient` receives dai income
 - `cdp` receives collateralTokens forgone
 - `ttl` single bid lifetime
 - `beg` minimum bid increase
 - `auctionEndTimestamp` max auction duration
*/

contract CollateralForDaiAuction is DSNote {
    // --- Data ---
    struct Bid {
        uint256 bid;
        uint256 lot;
        address highBidder;  // high bidder
        uint48  expiryTime;  // expiry time
        uint48  auctionEndTimestamp;
        address cdp;
        address incomeRecipient;
        uint256 totalDaiWanted;
    }

    mapping (uint => Bid) public bids;

    cdpDatabaseInterface public   cdpDatabase;
    bytes32 public   collateralType;

    uint256 constant ONE = 1.00E27;
    uint256 public   beg = 1.05E27;  // 5% minimum bid increase
    uint48  public   ttl = 3 hours;  // 3 hours bid duration
    uint48  public   maximumAuctionDuration = 2 days;   // 2 days total auction length
    uint256 public startAuctions = 0;

    // --- Events ---
    event StartAuction(
      uint256 id,
      uint256 lot,
      uint256 bid,
      uint256 totalDaiWanted,
      address indexed cdp,
      address indexed incomeRecipient
    );

    // --- Init ---
    constructor(address vat_, bytes32 collateralType_) public {
        cdpDatabase = cdpDatabaseInterface(vat_);
        collateralType = collateralType_;
    }

    // --- Math ---
    function add(uint48 x, uint48 y) internal pure returns (uint48 z) {
        require((z = x + y) >= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Auction ---
    function startAuction(address cdp, address incomeRecipient, uint debtPlusStabilityFee, uint lot, uint bid)
        public note returns (uint id)
    {
        require(startAuctions < uint(-1));
        id = ++startAuctions;

        bids[id].bid = bid;
        bids[id].lot = lot;
        bids[id].highBidder = msg.sender; // configurable??
        bids[id].auctionEndTimestamp = add(uint48(now), maximumAuctionDuration);
        bids[id].cdp = cdp;
        bids[id].incomeRecipient = incomeRecipient;
        bids[id].debtPlusStabilityFee = debtPlusStabilityFee;

        cdpDatabase.transferCollateral(collateralType, msg.sender, address(this), lot);

        emit StartAuction(id, lot, bid, debtPlusStabilityFee, cdp, incomeRecipient);
    }
    function restartAuction(uint id) public note {
        require(bids[id].auctionEndTimestamp < now);
        require(bids[id].expiryTime == 0);
        bids[id].auctionEndTimestamp = add(uint48(now), maximumAuctionDuration);
    }
    function makeBidIncreaseBidSize(uint id, uint lot, uint bid) public note {
        require(bids[id].highBidder != address(0));
        require(bids[id].expiryTime > now || bids[id].expiryTime == 0);
        require(bids[id].auctionEndTimestamp > now);

        require(lot == bids[id].lot);
        require(bid <= bids[id].debtPlusStabilityFee);
        require(bid > bids[id].bid);
        require(mul(bid, ONE) >= mul(beg, bids[id].bid) || bid == bids[id].debtPlusStabilityFee);

        cdpDatabase.move(msg.sender, bids[id].highBidder, bids[id].bid);
        cdpDatabase.move(msg.sender, bids[id].incomeRecipient, bid - bids[id].bid);

        bids[id].highBidder = msg.sender;
        bids[id].bid = bid;
        bids[id].expiryTime = add(uint48(now), ttl);
    }
    function makeBidDecreaseLotSize(uint id, uint lot, uint bid) public note {
        require(bids[id].highBidder != address(0));
        require(bids[id].expiryTime > now || bids[id].expiryTime == 0);
        require(bids[id].auctionEndTimestamp > now);

        require(bid == bids[id].bid);
        require(bid == bids[id].debtPlusStabilityFee);
        require(lot < bids[id].lot);
        require(mul(beg, lot) <= mul(bids[id].lot, ONE));

        cdpDatabase.move(msg.sender, bids[id].highBidder, bid);
        cdpDatabase.transferCollateral(collateralType, address(this), bids[id].cdp, bids[id].lot - lot);

        bids[id].highBidder = msg.sender;
        bids[id].lot = lot;
        bids[id].expiryTime = add(uint48(now), ttl);
    }
    function claimWinningBid(uint id) public note {
        require(bids[id].expiryTime != 0 && (bids[id].expiryTime < now || bids[id].auctionEndTimestamp < now));
        cdpDatabase.transferCollateral(collateralType, address(this), bids[id].highBidder, bids[id].lot);
        delete bids[id];
    }
}
