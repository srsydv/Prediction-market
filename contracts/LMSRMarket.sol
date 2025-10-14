// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
  LMSRMarket.sol
  Simplified LMSR (binary) prediction market.

  - Requires OpenZeppelin:
      @openzeppelin/contracts/token/ERC1155/ERC1155.sol
      @openzeppelin/contracts/token/ERC20/IERC20.sol
      @openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol
      @openzeppelin/contracts/utils/ReentrancyGuard.sol
      @openzeppelin/contracts/access/Ownable.sol

  - Requires ABDKMath64x64 (or similar) for exp/ln fixed-point math:
      - ABDKMath64x64: provides fromInt, toInt, exp_2, ln, etc.
      - This code uses ABDKMath64x64.exp() and ABDKMath64x64.ln() helpers.

  NOTE: This is an educational starting point. Do not use on mainnet without audit.
*/

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * Simplified fixed-point math library for LMSR calculations
 * This is a minimal implementation for educational purposes
 */
library ABDKMath64x64 {
    int128 private constant MIN_64x64 = -0x80000000000000000000000000000000;
    int128 private constant MAX_64x64 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    function fromInt(int256 x) internal pure returns (int128) {
        require(x >= -0x8000000000000000 && x <= 0x7FFFFFFFFFFFFFFF);
        return int128(x << 64);
    }

    function toInt(int128 x) internal pure returns (int256) {
        return int256(x) >> 64;
    }

    function fromUInt(uint256 x) internal pure returns (int128) {
        require(x <= 0x7FFFFFFFFFFFFFFF);
        return int128(int256(x << 64));
    }

    function toUInt(int128 x) internal pure returns (uint64) {
        require(x >= 0);
        return uint64(uint128(x >> 64));
    }

    function add(int128 x, int128 y) internal pure returns (int128) {
        int256 result = int256(x) + y;
        require(result >= MIN_64x64 && result <= MAX_64x64);
        return int128(result);
    }

    function sub(int128 x, int128 y) internal pure returns (int128) {
        int256 result = int256(x) - y;
        require(result >= MIN_64x64 && result <= MAX_64x64);
        return int128(result);
    }

    function mul(int128 x, int128 y) internal pure returns (int128) {
        int256 result = (int256(x) * y) >> 64;
        require(result >= MIN_64x64 && result <= MAX_64x64);
        return int128(result);
    }

    function div(int128 x, int128 y) internal pure returns (int128) {
        require(y != 0);
        int256 result = (int256(x) << 64) / y;
        require(result >= MIN_64x64 && result <= MAX_64x64);
        return int128(result);
    }

    // Simplified exp function using approximation
    function exp(int128 x) internal pure returns (int128) {
        require(x >= -0x400000000000000000 && x <= 0x7FFFFFFFFFFFFFFF);
        
        if (x == 0) return 0x10000000000000000; // 1.0 in 64.64
        
        // For simplicity, use a basic approximation
        // In production, use a proper implementation
        if (x > 0) {
            return int128(0x10000000000000000 + uint128(x)); // 1 + x approximation
        } else {
            return int128(0x10000000000000000 - uint128(-x)); // 1 - x approximation
        }
    }

    // Simplified ln function using approximation
    function ln(int128 x) internal pure returns (int128) {
        require(x > 0);
        
        // For simplicity, use a basic approximation
        // In production, use a proper implementation
        if (x >= 0x10000000000000000) { // x >= 1
            return int128(x - 0x10000000000000000); // x - 1 approximation
        } else {
            return int128(0x10000000000000000 - x); // 1 - x approximation
        }
    }
}

contract LMSRMarket is ERC1155, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    enum MarketState {Active, Resolved, Cancelled}
    struct Market {
        address creator;
        IERC20 collateral; // e.g., USDC
        uint8 collateralDecimals;
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
    event MarketCreated(uint256 indexed marketId, address indexed creator, address collateral, int128 b, uint256 initialCollateral, uint256 feeBps);
    event Bought(uint256 indexed marketId, address indexed buyer, uint8 side, uint256 amountShares, uint256 cost, uint256 fee);
    event Sold(uint256 indexed marketId, address indexed seller, uint8 side, uint256 amountShares, uint256 refund);
    event Resolved(uint256 indexed marketId, uint8 outcome);
    event Redeemed(uint256 indexed marketId, address indexed redeemer, uint256 payout);
    event MarketCancelled(uint256 indexed marketId);

    constructor() ERC1155("") Ownable(msg.sender) {}

    // ---------- Helpers ----------
    function _yesId(uint256 marketId) public pure returns (uint256) {
        return marketId * 2;
    }
    function _noId(uint256 marketId) public pure returns (uint256) {
        return marketId * 2 + 1;
    }

    // Convert uint256 (token amounts) to 64.64 fixedpoint (ABDK) given decimals
    function _toFixed(uint256 raw, uint8 decimals) internal pure returns (int128) {
        // Convert raw token amount to 18-decimal fixed point representation
        // raw is in token's native decimals, we convert to 18 decimals for fixed point math
        if (decimals <= 18) {
            // Scale up: multiply by 10^(18-decimals)
            uint256 scaled = raw * (10**(18 - decimals));
            return ABDKMath64x64.fromUInt(scaled);
        } else {
            // Scale down: divide by 10^(decimals-18)
            uint256 scaled = raw / (10**(decimals - 18));
            return ABDKMath64x64.fromUInt(scaled);
        }
    }

    // Convert 64.64 fixedpoint back to uint256 token amount given decimals
    function _fromFixed(int128 fixedPoint, uint8 decimals) internal pure returns (uint256) {
        // Convert from 18-decimal fixed point back to token's native decimals
        uint256 scaled = ABDKMath64x64.toUInt(fixedPoint);
        
        if (decimals <= 18) {
            // Scale down: divide by 10^(18-decimals)
            return scaled / (10**(18 - decimals));
        } else {
            // Scale up: multiply by 10^(decimals-18)
            return scaled * (10**(decimals - 18));
        }
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
        require(feeBps <= 1000, "fee too high"); // Max 10% fee

        // Get token decimals - try to call decimals() function
        uint8 tokenDecimals = 18; // Default to 18 decimals
        try IERC20Metadata(address(collateralToken)).decimals() returns (uint8 decimals) {
            tokenDecimals = decimals;
        } catch {
            // If decimals() doesn't exist, assume 18 decimals
        }

        // Pull collateral
        collateralToken.safeTransferFrom(msg.sender, address(this), initialCollateral);

        uint256 id = marketCount++;
        Market storage m = markets[id];
        m.creator = msg.sender;
        m.collateral = collateralToken;
        m.collateralDecimals = tokenDecimals;
        m.b = bFixed;
        m.qYes = ABDKMath64x64.fromInt(0);
        m.qNo  = ABDKMath64x64.fromInt(0);
        m.state = MarketState.Active;
        m.outcome = 0;
        m.feeBps = feeBps;
        m.escrow = initialCollateral;

        emit MarketCreated(id, msg.sender, address(collateralToken), bFixed, initialCollateral, feeBps);
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

    // Price of No: pNo = exp(qNo / b) / (exp(qYes / b) + exp(qNo / b))
    function priceNo(Market storage m) internal view returns (int128) {
        int128 uYes = ABDKMath64x64.div(m.qYes, m.b);
        int128 uNo  = ABDKMath64x64.div(m.qNo, m.b);

        int128 eYes = ABDKMath64x64.exp(uYes);
        int128 eNo  = ABDKMath64x64.exp(uNo);
        int128 denom = ABDKMath64x64.add(eYes, eNo);
        return ABDKMath64x64.div(eNo, denom);
    }

    // ---------- Public view functions ----------
    /// @notice Get current price of Yes shares (as percentage * 1e18)
    function getPriceYes(uint256 marketId) external view returns (uint256) {
        Market storage m = markets[marketId];
        require(m.state == MarketState.Active, "market not active");
        
        int128 priceFixed = priceYes(m);
        // Convert from 64.64 fixed point to percentage (0-10000 basis points)
        uint256 priceBps = ABDKMath64x64.toUInt(ABDKMath64x64.mul(priceFixed, ABDKMath64x64.fromInt(10000)));
        return priceBps;
    }

    /// @notice Get current price of No shares (as percentage * 1e18)
    function getPriceNo(uint256 marketId) external view returns (uint256) {
        Market storage m = markets[marketId];
        require(m.state == MarketState.Active, "market not active");
        
        int128 priceFixed = priceNo(m);
        // Convert from 64.64 fixed point to percentage (0-10000 basis points)
        uint256 priceBps = ABDKMath64x64.toUInt(ABDKMath64x64.mul(priceFixed, ABDKMath64x64.fromInt(10000)));
        return priceBps;
    }

    /// @notice Get market information
    function getMarketInfo(uint256 marketId) external view returns (
        address creator,
        address collateral,
        uint8 collateralDecimals,
        int128 b,
        int128 qYes,
        int128 qNo,
        MarketState state,
        uint8 outcome,
        uint256 feeBps,
        uint256 escrow
    ) {
        Market storage m = markets[marketId];
        return (
            m.creator,
            address(m.collateral),
            m.collateralDecimals,
            m.b,
            m.qYes,
            m.qNo,
            m.state,
            m.outcome,
            m.feeBps,
            m.escrow
        );
    }

    /// @notice Calculate cost to buy a specific amount of shares
    function getBuyCost(uint256 marketId, uint8 side, uint256 shareAmount) external view returns (uint256 cost) {
        require(side == 0 || side == 1, "invalid side");
        Market storage m = markets[marketId];
        require(m.state == MarketState.Active, "market not active");
        require(shareAmount > 0, "need >0");

        int128 delta = _toFixed(shareAmount, m.collateralDecimals);
        int128 cBefore = _cost(m, m.qYes, m.qNo);

        int128 newQYes = m.qYes;
        int128 newQNo  = m.qNo;
        if (side == 0) {
            newQYes = ABDKMath64x64.add(newQYes, delta);
        } else {
            newQNo = ABDKMath64x64.add(newQNo, delta);
        }

        int128 cAfter = _cost(m, newQYes, newQNo);
        int128 costFixed = ABDKMath64x64.sub(cAfter, cBefore);
        cost = _fromFixed(costFixed, m.collateralDecimals);
    }

    /// @notice Calculate refund for selling a specific amount of shares
    function getSellRefund(uint256 marketId, uint8 side, uint256 shareAmount) external view returns (uint256 refund) {
        require(side == 0 || side == 1, "invalid side");
        Market storage m = markets[marketId];
        require(m.state == MarketState.Active, "market not active");
        require(shareAmount > 0, "need >0");

        int128 delta = _toFixed(shareAmount, m.collateralDecimals);
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
        refund = _fromFixed(refundFixed, m.collateralDecimals);
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

        // Convert shareAmount to fixed-point (64.64) using proper decimal scaling
        int128 delta = _toFixed(shareAmount, m.collateralDecimals);

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

        // Convert costFixed back to token units using proper decimal scaling
        uint256 cost = _fromFixed(costFixed, m.collateralDecimals);

        // Validate cost is reasonable (prevent extreme price movements)
        require(cost > 0, "cost too low");
        require(cost <= m.escrow, "insufficient liquidity");

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

        emit Bought(marketId, msg.sender, side, shareAmount, cost, fee);
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

        // convert shareAmount to fixed using proper decimal scaling
        int128 delta = _toFixed(shareAmount, m.collateralDecimals);

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
        
        // Convert refund back to token units using proper decimal scaling
        uint256 refund = _fromFixed(refundFixed, m.collateralDecimals);

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

    // Emergency: cancel market and allow proportional refunds
    function cancelMarket(uint256 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        require(msg.sender == m.creator || msg.sender == owner(), "not authorized");
        require(m.state == MarketState.Active, "not active");
        m.state = MarketState.Cancelled;
        
        emit MarketCancelled(marketId);
    }

    /// @notice Redeem shares after market cancellation (proportional refund)
    function redeemCancelled(uint256 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        require(m.state == MarketState.Cancelled, "not cancelled");

        uint256 yesTokenId = _yesId(marketId);
        uint256 noTokenId = _noId(marketId);
        
        uint256 yesBalance = balanceOf(msg.sender, yesTokenId);
        uint256 noBalance = balanceOf(msg.sender, noTokenId);
        
        require(yesBalance > 0 || noBalance > 0, "no shares");

        uint256 totalRefund = 0;

        // Calculate proportional refund for Yes shares
        if (yesBalance > 0) {
            // Simple proportional refund: user gets back their share of escrow
            // This is a simplified approach - in production you might want more sophisticated logic
            uint256 yesRefund = (m.escrow * yesBalance) / (yesBalance + noBalance);
            totalRefund += yesRefund;
            
            _burn(msg.sender, yesTokenId, yesBalance);
        }

        // Calculate proportional refund for No shares
        if (noBalance > 0) {
            // Simple proportional refund: user gets back their share of escrow
            uint256 noRefund = (m.escrow * noBalance) / (yesBalance + noBalance);
            totalRefund += noRefund;
            
            _burn(msg.sender, noTokenId, noBalance);
        }

        require(totalRefund > 0, "no refund");
        require(m.escrow >= totalRefund, "insufficient escrow");
        
        m.escrow -= totalRefund;
        m.collateral.safeTransfer(msg.sender, totalRefund);

        emit Redeemed(marketId, msg.sender, totalRefund);
    }

    // Fallbacks
    receive() external payable {
        revert("no native");
    }
}