// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
  LMSRMarket.sol
  Simplified LMSR (binary) prediction market.

  - Requires OpenZeppelin:
      @openzeppelin/contracts/token/ERC1155/ERC1155.sol
      @openzeppelin/contracts/token/ERC20/IERC20.sol
      @openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol
      @openzeppelin/contracts/security/ReentrancyGuard.sol
      @openzeppelin/contracts/access/Ownable.sol

  - Requires ABDKMath64x64 (or similar) for exp/ln fixed-point math:
      - ABDKMath64x64: provides fromInt, toInt, exp_2, ln, etc.
      - This code uses ABDKMath64x64.exp() and ABDKMath64x64.ln() helpers.

  NOTE: This is an educational starting point. Do not use on mainnet without audit.
*/

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal subset of ABDKMath64x64 interface used here.
/// Copy the full ABDKMath64x64 implementation into contracts/libs/ABDKMath64x64.sol
library ABDKMath64x64 {
    // We'll assume the full library is available; here are the function signatures used:
    function fromInt(int256 x) internal pure returns (int128) {}
    function toInt(int128 x) internal pure returns (int256) {}
    function exp(int128 x) internal pure returns (int128) {}
    function ln(int128 x) internal pure returns (int128) {}
    function mul(int128 x, int128 y) internal pure returns (int128) {}
    function div(int128 x, int128 y) internal pure returns (int128) {}
    function add(int128 x, int128 y) internal pure returns (int128) {}
    function sub(int128 x, int128 y) internal pure returns (int128) {}
}

/*
 NOTE: The above minimal library declaration is only a placeholder; you must replace it
 with the full ABDKMath64x64.sol content for compilation.
*/

contract LMSRMarket is ERC1155, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    enum MarketState {Active, Resolved, Cancelled}
    struct Market {
        address creator;
        IERC20 collateral; // e.g., USDC
        uint256 collateralDecimals;
        int128 b;           // liquidity parameter in 64.64 fixed point (ABDK)
        int128 qYes;        // outstanding Yes shares (64.64)
        int128 qNo;         // outstanding No shares (64.64)
        MarketState state;
        uint8 outcome;      // 0 = unresolved, 1 = Yes, 2 = No
        uint256 feeBps;     // platform fee in basis points on buys (optional)
        uint256 escrow;     // collateral held in contract (raw units)
    }

    uint256 public marketCount;
    mapping(uint256 => Market) public markets;

    // ERC1155 token ids: we'll use id = marketId*2 + side (0 = Yes, 1 = No)
    event MarketCreated(uint256 indexed marketId, address indexed creator, address collateral, int128 b);
    event Bought(uint256 indexed marketId, address indexed buyer, uint8 side, uint256 amountShares, uint256 cost);
    event Sold(uint256 indexed marketId, address indexed seller, uint8 side, uint256 amountShares, uint256 refund);
    event Resolved(uint256 indexed marketId, uint8 outcome);
    event Redeemed(uint256 indexed marketId, address indexed redeemer, uint256 payout);

    constructor() ERC1155("") {}

    // ---------- Helpers ----------
    function _yesId(uint256 marketId) public pure returns (uint256) {
        return marketId * 2;
    }
    function _noId(uint256 marketId) public pure returns (uint256) {
        return marketId * 2 + 1;
    }

    // Convert uint256 (token amounts) to 64.64 fixedpoint (ABDK) given decimals
    function _toFixed(uint256 raw, uint256 decimals) internal pure returns (int128) {
        // raw * (1e18) / (10**decimals) maybe; but we'll keep units consistent:
        // We treat "shares" as 1e18 per share (ERC1155 uses integers). Convert accordingly.
        // For simplicity in this starter, assume raw is already in 1e18 units.
        return ABDKMath64x64.fromInt(int256(raw / 1)); // placeholder; use precise scaling in production
    }

    // ---------- Market lifecycle ----------
    /// @notice Create a new binary LMSR market. The creator must transfer collateral to this contract first (or we can pull on create).
    /// @param collateralToken ERC20 token used as collateral (e.g., USDC)
    /// @param bFixed liquidity parameter as a signed 64.64 fixed-point (use helper to build)
    /// @param initialCollateral collateral amount in token raw units to seed market
    /// @param feeBps optional fee in basis points charged on buys (e.g., 50 = 0.5%)
    function createMarket(IERC20 collateralToken, int128 bFixed, uint256 initialCollateral, uint256 feeBps) external nonReentrant returns (uint256) {
        require(initialCollateral > 0, "need collateral");
        require(bFixed > 0, "b must be positive");

        // Pull collateral
        collateralToken.safeTransferFrom(msg.sender, address(this), initialCollateral);

        uint256 id = marketCount++;
        Market storage m = markets[id];
        m.creator = msg.sender;
        m.collateral = collateralToken;
        m.b = bFixed;
        m.qYes = ABDKMath64x64.fromInt(0);
        m.qNo  = ABDKMath64x64.fromInt(0);
        m.state = MarketState.Active;
        m.outcome = 0;
        m.feeBps = feeBps;
        m.escrow = initialCollateral;

        emit MarketCreated(id, msg.sender, address(collateralToken), bFixed);
        return id;
    }

    // ---------- LMSR math ----------
    // Cost function: C(q) = b * ln( e^{q_yes / b} + e^{q_no / b} )
    // Here we use ABDKMath64x64 fixed-point operations.
    function _cost(Market storage m, int128 qYes, int128 qNo) internal view returns (int128) {
        // uYes = qYes / b
        int128 uYes = ABDKMath64x64.div(qYes, m.b);
        int128 uNo  = ABDKMath64x64.div(qNo, m.b);

        // exp(uYes) + exp(uNo)
        int128 eYes = ABDKMath64x64.exp(uYes);
        int128 eNo  = ABDKMath64x64.exp(uNo);

        int128 sumExp = ABDKMath64x64.add(eYes, eNo);
        int128 lnSum = ABDKMath64x64.ln(sumExp);

        // b * ln(sumExp)
        return ABDKMath64x64.mul(m.b, lnSum);
    }

    // Price of Yes: pYes = exp(qYes / b) / (exp(qYes / b) + exp(qNo / b))
    function priceYes(Market storage m) internal view returns (int128) {
        int128 uYes = ABDKMath64x64.div(m.qYes, m.b);
        int128 uNo  = ABDKMath64x64.div(m.qNo, m.b);

        int128 eYes = ABDKMath64x64.exp(uYes);
        int128 eNo  = ABDKMath64x64.exp(uNo);
        int128 denom = ABDKMath64x64.add(eYes, eNo);
        return ABDKMath64x64.div(eYes, denom);
    }

    // ---------- Trading ----------
    /// @notice Buy shares of a side (0 = Yes, 1 = No).
    /// @param marketId id
    /// @param side 0 = Yes, 1 = No
    /// @param shareAmount raw integer representing desired shares (assume 1e18 units)
    function buy(uint256 marketId, uint8 side, uint256 shareAmount) external nonReentrant {
        require(side == 0 || side == 1, "invalid side");
        Market storage m = markets[marketId];
        require(m.state == MarketState.Active, "market not active");
        require(shareAmount > 0, "need >0");

        // Convert shareAmount to fixed-point (64.64)
        // NOTE: This conversion must be precise; here it's left as conceptual.
        int128 delta = ABDKMath64x64.fromInt(int256(shareAmount));

        // current cost
        int128 cBefore = _cost(m, m.qYes, m.qNo);

        // new q values
        int128 newQYes = m.qYes;
        int128 newQNo  = m.qNo;
        if (side == 0) {
            newQYes = ABDKMath64x64.add(newQYes, delta);
        } else {
            newQNo = ABDKMath64x64.add(newQNo, delta);
        }

        int128 cAfter = _cost(m, newQYes, newQNo);

        // costToPay = cAfter - cBefore (in 64.64). Convert to token units.
        int128 costFixed = ABDKMath64x64.sub(cAfter, cBefore);

        // convert costFixed (64.64) -> uint256 token amount (raw units). This conversion must match _toFixed scaling.
        // For starter code we assume 1 fixed unit = 1 token unit (NOT TRUE IN PRODUCTION).
        uint256 cost = uint256(uint128(ABDKMath64x64.toInt(costFixed))); // naive

        // apply fee if configured
        uint256 fee = 0;
        if (m.feeBps > 0) {
            fee = (cost * m.feeBps) / 10000;
        }
        uint256 total = cost + fee;

        // transfer collateral from buyer
        m.collateral.safeTransferFrom(msg.sender, address(this), total);
        m.escrow += cost;

        // mint shares to buyer (ERC1155)
        uint256 tokenId = (side == 0) ? _yesId(marketId) : _noId(marketId);
        _mint(msg.sender, tokenId, shareAmount, "");

        // update qYes/qNo
        m.qYes = newQYes;
        m.qNo  = newQNo;

        // fee handling: send fee to creator for now
        if (fee > 0) {
            m.collateral.safeTransfer(m.creator, fee);
        }

        emit Bought(marketId, msg.sender, side, shareAmount, cost);
    }

    /// @notice Sell back shares to the AMM (burn shares, receive collateral)
    function sell(uint256 marketId, uint8 side, uint256 shareAmount) external nonReentrant {
        require(side == 0 || side == 1, "invalid side");
        Market storage m = markets[marketId];
        require(m.state == MarketState.Active, "market not active");
        require(shareAmount > 0, "need >0");

        uint256 tokenId = (side == 0) ? _yesId(marketId) : _noId(marketId);
        // burn user's tokens
        _burn(msg.sender, tokenId, shareAmount);

        // convert shareAmount to fixed
        int128 delta = ABDKMath64x64.fromInt(int256(shareAmount));

        // compute refund = cost(before) - cost(after) where after = q - delta
        int128 cBefore = _cost(m, m.qYes, m.qNo);
        int128 newQYes = m.qYes;
        int128 newQNo  = m.qNo;
        if (side == 0) {
            newQYes = ABDKMath64x64.sub(newQYes, delta);
        } else {
            newQNo = ABDKMath64x64.sub(newQNo, delta);
        }
        int128 cAfter = _cost(m, newQYes, newQNo);
        int128 refundFixed = ABDKMath64x64.sub(cBefore, cAfter);
        uint256 refund = uint256(uint128(ABDKMath64x64.toInt(refundFixed))); // naive conversion

        require(m.escrow >= refund, "insufficient escrow");
        m.escrow -= refund;
        m.collateral.safeTransfer(msg.sender, refund);

        // update q's
        m.qYes = newQYes;
        m.qNo  = newQNo;

        emit Sold(marketId, msg.sender, side, shareAmount, refund);
    }

    // ---------- Resolution & redemption ----------
    /// @notice Resolve the market to Yes(1) or No(2). Only creator/owner in this simple contract.
    function resolve(uint256 marketId, uint8 outcome) external nonReentrant {
        require(outcome == 1 || outcome == 2, "invalid outcome");
        Market storage m = markets[marketId];
        require(m.state == MarketState.Active, "not active");
        require(msg.sender == m.creator || msg.sender == owner(), "not authorized");
        m.state = MarketState.Resolved;
        m.outcome = outcome;

        emit Resolved(marketId, outcome);
    }

    /// @notice Redeem winning shares after resolution. Burns winning tokens and transfers collateral.
    function redeem(uint256 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        require(m.state == MarketState.Resolved, "not resolved");

        uint8 win = m.outcome;
        require(win == 1 || win == 2, "no outcome");

        uint256 tokenId = (win == 1) ? _yesId(marketId) : _noId(marketId);
        uint256 balance = balanceOf(msg.sender, tokenId);
        require(balance > 0, "no winning shares");

        // Burn winning shares and pay out 1 token per share (1:1 payout)
        _burn(msg.sender, tokenId, balance);

        // payout amount = balance (assuming 1 share = 1 token unit of collateral)
        uint256 payout = balance;

        require(m.escrow >= payout, "insufficient escrow");
        m.escrow -= payout;
        m.collateral.safeTransfer(msg.sender, payout);

        emit Redeemed(marketId, msg.sender, payout);
    }

    // ---------- Admin helpers ----------
    /// @notice Withdraw leftover escrow after resolution (only creator)
    function withdrawEscrow(uint256 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        require(m.state == MarketState.Resolved || m.state == MarketState.Cancelled, "market not finished");
        require(msg.sender == m.creator || msg.sender == owner(), "not authorized");
        uint256 amount = m.escrow;
        require(amount > 0, "nothing");
        m.escrow = 0;
        m.collateral.safeTransfer(msg.sender, amount);
    }

    // Emergency: cancel market and allow proportional refunds (simplified)
    function cancelMarket(uint256 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        require(msg.sender == m.creator || msg.sender == owner(), "not authorized");
        require(m.state == MarketState.Active, "not active");
        m.state = MarketState.Cancelled;
        // In a production contract you'd need to allow everyone to redeem proportionally or return seeds.
    }

    // Fallbacks
    receive() external payable {
        revert("no native");
    }
}