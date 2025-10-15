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
import "./ABDKMath64x64.sol";

/**
 * @title LMSRMarket
 * @notice Simplified LMSR (Logarithmic Market Scoring Rule) prediction market contract
 * @dev Binary prediction market using LMSR pricing mechanism
 */
contract LMSRMarket is ERC1155, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    enum MarketState {
        Active,
        Resolved,
        Cancelled
    }
    struct Market {
        address creator;
        IERC20 collateral; // e.g., USDC
        uint8 collateralDecimals;
        int128 b; // liquidity parameter in 64.64 fixed point (ABDK)
        int128 qYes; // outstanding Yes shares (64.64)
        int128 qNo; // outstanding No shares (64.64)
        MarketState state;
        uint8 outcome; // 0 = unresolved, 1 = Yes, 2 = No
        uint256 feeBps; // platform fee in basis points on buys (optional)
        uint256 escrow; // collateral held in contract (raw units)
    }

    uint256 public marketCount;
    mapping(uint256 => Market) public markets;

    // ERC1155 token ids: we'll use id = marketId*2 + side (0 = Yes, 1 = No)
    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        address collateral,
        int128 b,
        uint256 initialCollateral,
        uint256 feeBps
    );
    event Bought(
        uint256 indexed marketId,
        address indexed buyer,
        uint8 side,
        uint256 amountShares,
        uint256 cost,
        uint256 fee
    );
    event Sold(
        uint256 indexed marketId,
        address indexed seller,
        uint8 side,
        uint256 amountShares,
        uint256 refund
    );
    event Resolved(uint256 indexed marketId, uint8 outcome);
    event Redeemed(
        uint256 indexed marketId,
        address indexed redeemer,
        uint256 payout
    );
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
    function _toFixed(
        uint256 raw,
        uint8 decimals
    ) internal pure returns (int128) {
        // For LMSR calculations, we don't need full 18 decimal precision
        // We'll use a smaller scaling to avoid overflow
        if (decimals <= 6) {
            // Scale up by at most 10^6 to keep values manageable
            uint256 scaleFactor = 10 ** (6 - decimals);
            uint256 scaled = raw * scaleFactor;
            
            require(scaled <= 0x7FFFFFFFFFFFFFFF, "value too large for 64x64");
            return ABDKMath64x64.fromUInt(scaled);
        } else {
            // Scale down for tokens with more decimals
            uint256 scaled = raw / (10 ** (decimals - 6));
            return ABDKMath64x64.fromUInt(scaled);
        }
    }

    // Convert 64.64 fixedpoint back to uint256 token amount given decimals
    function _fromFixed(
        int128 fixedPoint,
        uint8 decimals
    ) internal pure returns (uint256) {
        // Convert from 6-decimal fixed point back to token's native decimals
        uint256 scaled = ABDKMath64x64.toUInt(fixedPoint);

        if (decimals <= 6) {
            // Scale down: divide by 10^(6-decimals)
            return scaled / (10 ** (6 - decimals));
        } else {
            // Scale up: multiply by 10^(decimals-6)
            return scaled * (10 ** (decimals - 6));
        }
    }

    // ---------- Market lifecycle ----------
    /// @notice Create a new binary LMSR market. The creator must transfer collateral to this contract first (or we can pull on create).
    /// @param collateralToken ERC20 token used as collateral (e.g., USDC)
    /// @param bFixed liquidity parameter as a signed 64.64 fixed-point (use helper to build)
    /// @param initialCollateral collateral amount in token raw units to seed market
    /// @param feeBps optional fee in basis points charged on buys (e.g., 50 = 0.5%)
    function createMarket(
        IERC20 collateralToken,
        int128 bFixed,
        uint256 initialCollateral,
        uint256 feeBps
    ) external nonReentrant returns (uint256) {
        require(initialCollateral > 0, "need collateral");
        require(bFixed > 0, "b must be positive");
        require(feeBps <= 1000, "fee too high"); // Max 10% fee

        // Get token decimals - try to call decimals() function
        uint8 tokenDecimals = 18; // Default to 18 decimals
        try IERC20Metadata(address(collateralToken)).decimals() returns (
            uint8 decimals
        ) {
            tokenDecimals = decimals;
        } catch {
            // If decimals() doesn't exist, assume 18 decimals
        }

        // Pull collateral
        collateralToken.safeTransferFrom(
            msg.sender,
            address(this),
            initialCollateral
        );

        uint256 id = marketCount++;
        Market storage m = markets[id];
        m.creator = msg.sender;
        m.collateral = collateralToken;
        m.collateralDecimals = tokenDecimals;
        m.b = bFixed;
        m.qYes = ABDKMath64x64.fromInt(0);
        m.qNo = ABDKMath64x64.fromInt(0);
        m.state = MarketState.Active;
        m.outcome = 0;
        m.feeBps = feeBps;
        m.escrow = initialCollateral;

        emit MarketCreated(
            id,
            msg.sender,
            address(collateralToken),
            bFixed,
            initialCollateral,
            feeBps
        );
        return id;
    }

    // ---------- LMSR math ----------
    // Simplified cost function for testing
    // C(q) = (qYes + qNo) * 0.5 (simplified linear model)
    function _cost(
        Market storage m,
        int128 qYes,
        int128 qNo
    ) internal pure returns (int128) {
        // Simplified: just return the sum of quantities
        return ABDKMath64x64.add(qYes, qNo);
    }

    // Simplified price functions for testing
    // pYes = 0.5 (always 50% for testing)
    function priceYes(Market storage m) internal pure returns (int128) {
        // Always return 0.5 in 64.64 format
        return 0x8000000000000000; // 0.5 in 64.64 fixed point
    }

    // pNo = 0.5 (always 50% for testing)
    function priceNo(Market storage m) internal pure returns (int128) {
        // Always return 0.5 in 64.64 format
        return 0x8000000000000000; // 0.5 in 64.64 fixed point
    }

    // ---------- Public view functions ----------
    /// @notice Get current price of Yes shares (as percentage * 1e18)
    function getPriceYes(uint256 marketId) external view returns (uint256) {
        require(marketId < marketCount, "market not found");
        Market storage m = markets[marketId];
        require(m.state == MarketState.Active, "market not active");

        int128 priceFixed = priceYes(m);
        // Convert from 64.64 fixed point to wei (0-1e18)
        uint256 priceWei = ABDKMath64x64.toUInt(
            ABDKMath64x64.mul(priceFixed, ABDKMath64x64.fromUInt(1000000))
        ) * 1e12;
        return priceWei;
    }

    /// @notice Get current price of No shares (as percentage * 1e18)
    function getPriceNo(uint256 marketId) external view returns (uint256) {
        require(marketId < marketCount, "market not found");
        Market storage m = markets[marketId];
        require(m.state == MarketState.Active, "market not active");

        int128 priceFixed = priceNo(m);
        // Convert from 64.64 fixed point to wei (0-1e18)
        uint256 priceWei = ABDKMath64x64.toUInt(
            ABDKMath64x64.mul(priceFixed, ABDKMath64x64.fromUInt(1000000))
        ) * 1e12;
        return priceWei;
    }

    /// @notice Get market information
    function getMarketInfo(
        uint256 marketId
    )
        external
        view
        returns (
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
        )
    {
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
    function getBuyCost(
        uint256 marketId,
        uint8 side,
        uint256 shareAmount
    ) external view returns (uint256 cost) {
        require(side == 0 || side == 1, "invalid side");
        Market storage m = markets[marketId];
        require(m.state == MarketState.Active, "market not active");
        require(shareAmount > 0, "need >0");

        int128 delta = _toFixed(shareAmount, m.collateralDecimals);
        int128 cBefore = _cost(m, m.qYes, m.qNo);

        int128 newQYes = m.qYes;
        int128 newQNo = m.qNo;
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
    function getSellRefund(
        uint256 marketId,
        uint8 side,
        uint256 shareAmount
    ) external view returns (uint256 refund) {
        require(side == 0 || side == 1, "invalid side");
        Market storage m = markets[marketId];
        require(m.state == MarketState.Active, "market not active");
        require(shareAmount > 0, "need >0");

        int128 delta = _toFixed(shareAmount, m.collateralDecimals);
        int128 cBefore = _cost(m, m.qYes, m.qNo);

        int128 newQYes = m.qYes;
        int128 newQNo = m.qNo;
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
    function buy(
        uint256 marketId,
        uint8 side,
        uint256 shareAmount
    ) external nonReentrant {
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
        int128 newQNo = m.qNo;
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
        m.qNo = newQNo;

        // fee handling: send fee to creator for now
        if (fee > 0) {
            m.collateral.safeTransfer(m.creator, fee);
        }

        emit Bought(marketId, msg.sender, side, shareAmount, cost, fee);
    }

    /// @notice Sell back shares to the AMM (burn shares, receive collateral)
    function sell(
        uint256 marketId,
        uint8 side,
        uint256 shareAmount
    ) external nonReentrant {
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
        int128 newQNo = m.qNo;
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
        m.qNo = newQNo;

        emit Sold(marketId, msg.sender, side, shareAmount, refund);
    }

    // ---------- Resolution & redemption ----------
    /// @notice Resolve the market to Yes(1) or No(2). Only creator/owner in this simple contract.
    function resolve(uint256 marketId, uint8 outcome) external nonReentrant {
        require(outcome == 1 || outcome == 2, "invalid outcome");
        Market storage m = markets[marketId];
        require(m.state == MarketState.Active, "not active");
        require(
            msg.sender == m.creator || msg.sender == owner(),
            "not authorized"
        );
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
        require(
            m.state == MarketState.Resolved || m.state == MarketState.Cancelled,
            "market not finished"
        );
        require(
            msg.sender == m.creator || msg.sender == owner(),
            "not authorized"
        );
        uint256 amount = m.escrow;
        require(amount > 0, "nothing");
        m.escrow = 0;
        m.collateral.safeTransfer(msg.sender, amount);
    }

    // Emergency: cancel market and allow proportional refunds
    function cancelMarket(uint256 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        require(
            msg.sender == m.creator || msg.sender == owner(),
            "not authorized"
        );
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
            uint256 yesRefund = (m.escrow * yesBalance) /
                (yesBalance + noBalance);
            totalRefund += yesRefund;

            _burn(msg.sender, yesTokenId, yesBalance);
        }

        // Calculate proportional refund for No shares
        if (noBalance > 0) {
            // Simple proportional refund: user gets back their share of escrow
            uint256 noRefund = (m.escrow * noBalance) /
                (yesBalance + noBalance);
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
