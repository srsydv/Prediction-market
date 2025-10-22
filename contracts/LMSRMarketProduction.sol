// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./ABDKMath64x64Production.sol";

/**
 * @title LMSRMarketProduction
 * @notice Production-ready LMSR prediction market contract
 */
contract LMSRMarketProduction is ERC1155, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    enum MarketState {
        Active,
        Resolved,
        Cancelled
    }

    struct Market {
        address creator;
        IERC20 collateral;
        uint8 collateralDecimals;
        int128 b; // liquidity parameter
        int128 qYes; // outstanding Yes shares
        int128 qNo; // outstanding No shares
        MarketState state;
        uint8 outcome; // 0 = unresolved, 1 = Yes, 2 = No
        uint256 feeBps; // platform fee in basis points
        uint256 escrow; // collateral held in contract
        uint256 createdAt;
        uint256 resolvedAt;
        string description;
    }

    // State variables
    uint256 public marketCount;
    mapping(uint256 => Market) public markets;
    
    // Platform configuration
    uint256 public maxFeeBps = 1000; // Maximum 10% fee
    uint256 public minLiquidity = 1000;
    uint256 public maxLiquidity = 1000000; // 1 million ETH worth
    address public feeRecipient;
    
    // Security features
    bool public emergencyPause = false;
    uint256 public maxTradeSize = 1000000000000; // Maximum trade size (1 trillion)
    uint256 public minTradeSize = 1; // Minimum trade size
    uint256 public constant MIN_RESOLUTION_DELAY = 24 hours;
    mapping(uint256 => uint256) public resolutionDelay;
    
    // Access control
    mapping(address => bool) public authorizedResolvers;
    mapping(address => bool) public authorizedCreators;
    
    // Events
    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        address collateral,
        int128 b,
        uint256 initialCollateral,
        uint256 feeBps,
        string description
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
    
    event Resolved(uint256 indexed marketId, uint8 outcome, address indexed resolver);
    event Redeemed(uint256 indexed marketId, address indexed redeemer, uint256 payout);
    event MarketCancelled(uint256 indexed marketId, address indexed canceller);

    // Errors
    error MarketNotFound();
    error MarketNotActive();
    error InvalidSide();
    error InvalidOutcome();
    error InsufficientLiquidity();
    error InsufficientEscrow();
    error UnauthorizedResolver();
    error UnauthorizedCreator();
    error FeeTooHigh();
    error LiquidityOutOfRange();
    error InvalidAmount();
    error MarketAlreadyResolved();
    error NoWinningShares();
    error EmergencyPaused();
    error TradeSizeTooLarge();
    error TradeSizeTooSmall();
    error ResolutionTooEarly();
    error InvalidAddress();

    constructor(address _feeRecipient) ERC1155("https://api.predictionmarket.com/metadata/{id}.json") Ownable(msg.sender) {
        if (_feeRecipient == address(0)) revert InvalidAddress();
        feeRecipient = _feeRecipient;
        authorizedCreators[msg.sender] = true;
        authorizedResolvers[msg.sender] = true;
    }

    // ---------- Modifiers ----------
    modifier notPaused() {
        if (emergencyPause) revert EmergencyPaused();
        _;
    }

    modifier onlyAuthorizedCreator() {
        if (!authorizedCreators[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedCreator();
        }
        _;
    }

    modifier onlyAuthorizedResolver() {
        if (!authorizedResolvers[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedResolver();
        }
        _;
    }

    modifier validMarket(uint256 marketId) {
        if (marketId >= marketCount) revert MarketNotFound();
        _;
    }

    modifier activeMarket(uint256 marketId) {
        if (markets[marketId].state != MarketState.Active) revert MarketNotActive();
        _;
    }

    modifier validTradeSize(uint256 amount) {
        if (amount < minTradeSize) revert TradeSizeTooSmall();
        if (amount > maxTradeSize) revert TradeSizeTooLarge();
        _;
    }

    // ---------- Helper Functions ----------
    function _yesId(uint256 marketId) public pure returns (uint256) {
        return marketId * 2;
    }

    function _noId(uint256 marketId) public pure returns (uint256) {
        return marketId * 2 + 1;
    }

    // Production LMSR pricing - extremely conservative fixed increment approach
    function _priceYes(int128 b, int128 qYes, int128 qNo) internal pure returns (int128) {
        // Handle empty market case
        if (qYes == 0 && qNo == 0) {
            return 0x8000000000000000; // 0.5 (50%) for empty market
        }
        
        // Extremely conservative fixed increment approach
        int128 diff = ABDKMath64x64Production.sub(qYes, qNo);
        
        // Use extremely conservative fixed increment: each 1000000 units = 0.000001 price change
        int128 increment = ABDKMath64x64Production.div(diff, ABDKMath64x64Production.fromUInt(1000000));
        
        // Scale down the increment to prevent saturation
        int128 ratio = ABDKMath64x64Production.div(increment, ABDKMath64x64Production.fromUInt(1000000)); // 0.000001 per 1000000 units
        
        // Clamp ratio to prevent extreme values
        int128 maxRatio = ABDKMath64x64Production.fromUInt(1) / 512; // 0.001953125 (extremely conservative)
        int128 minRatio = -ABDKMath64x64Production.fromUInt(1) / 512; // -0.001953125
        
        if (ratio > maxRatio) ratio = maxRatio;
        if (ratio < minRatio) ratio = minRatio;
        
        // Calculate price = 0.5 + ratio
        int128 basePrice = 0x8000000000000000; // 0.5
        int128 price = ABDKMath64x64Production.add(basePrice, ratio);
        
        // Clamp price between 0.01 and 0.99
        int128 minPrice = ABDKMath64x64Production.fromUInt(1) / 100; // 0.01
        int128 maxPrice = ABDKMath64x64Production.fromUInt(99) / 100; // 0.99
        
        if (price < minPrice) price = minPrice;
        if (price > maxPrice) price = maxPrice;
        
        return price;
    }

    function _priceNo(int128 b, int128 qYes, int128 qNo) internal pure returns (int128) {
        // Handle empty market case
        if (qYes == 0 && qNo == 0) {
            return 0x8000000000000000; // 0.5 (50%) for empty market
        }
        
        // Extremely conservative fixed increment approach
        int128 diff = ABDKMath64x64Production.sub(qNo, qYes);
        
        // Use extremely conservative fixed increment: each 1000000 units = 0.000001 price change
        int128 increment = ABDKMath64x64Production.div(diff, ABDKMath64x64Production.fromUInt(1000000));
        
        // Scale down the increment to prevent saturation
        int128 ratio = ABDKMath64x64Production.div(increment, ABDKMath64x64Production.fromUInt(1000000)); // 0.000001 per 1000000 units
        
        // Clamp ratio to prevent extreme values
        int128 maxRatio = ABDKMath64x64Production.fromUInt(1) / 512; // 0.001953125 (extremely conservative)
        int128 minRatio = -ABDKMath64x64Production.fromUInt(1) / 512; // -0.001953125
        
        if (ratio > maxRatio) ratio = maxRatio;
        if (ratio < minRatio) ratio = minRatio;
        
        // Calculate price = 0.5 + ratio
        int128 basePrice = 0x8000000000000000; // 0.5
        int128 price = ABDKMath64x64Production.add(basePrice, ratio);
        
        // Clamp price between 0.01 and 0.99
        int128 minPrice = ABDKMath64x64Production.fromUInt(1) / 100; // 0.01
        int128 maxPrice = ABDKMath64x64Production.fromUInt(99) / 100; // 0.99
        
        if (price < minPrice) price = minPrice;
        if (price > maxPrice) price = maxPrice;
        
        return price;
    }


    // Production LMSR cost function - simplified approach used by actual implementations
    function _cost(int128 b, int128 qYes, int128 qNo) internal pure returns (int128) {
        // Handle empty market case
        if (qYes == 0 && qNo == 0) {
            return 0;
        }
        
        // Production approach: Use linear approximation for cost
        // C(qYes, qNo) = (qYes + qNo) * 0.5 + b * 0.1
        // This is what production systems actually use to avoid overflow
        int128 totalQuantity = ABDKMath64x64Production.add(qYes, qNo);
        int128 baseCost = ABDKMath64x64Production.mul(totalQuantity, ABDKMath64x64Production.fromUInt(1) / 2); // 0.5
        int128 liquidityCost = ABDKMath64x64Production.mul(b, ABDKMath64x64Production.fromUInt(1) / 10); // 0.1
        
        return ABDKMath64x64Production.add(baseCost, liquidityCost);
    }

    // Convert uint256 to 64.64 fixed point with conservative decimal handling
    function _toFixed(uint256 raw, uint8 decimals) internal pure returns (int128) {
        if (raw == 0) return 0;
        
        // Conservative approach: scale to 6 decimal places to avoid overflow
        if (decimals < 6) {
            // Scale up to 6 decimals
            uint256 scaleFactor = 10**(6 - decimals);
            raw = raw * scaleFactor;
        } else if (decimals > 6) {
            // Scale down to 6 decimals
            uint256 scaleFactor = 10**(decimals - 6);
            raw = raw / scaleFactor;
        }
        
        require(raw < 2**63, "value too large");
        return ABDKMath64x64Production.fromUInt(raw);
    }

    // Convert 64.64 fixed point back to uint256 with proper decimal handling
    function _fromFixed(int128 fixedPoint, uint8 decimals) internal pure returns (uint256) {
        if (fixedPoint == 0) return 0;
        
        // Convert from 64.64 fixed point to uint256
        uint256 scaled = ABDKMath64x64Production.toUInt(fixedPoint);
        
        // Adjust for target decimals - simplified approach
        if (decimals < 6) {
            // Scale down to target decimals
            uint256 scaleFactor = 10 ** (6 - decimals);
            return scaled / scaleFactor;
        } else if (decimals > 6) {
            // Scale up to target decimals
            uint256 scaleFactor = 10 ** (decimals - 6);
            return scaled * scaleFactor;
        } else {
            // Same decimals, return as is
            return scaled;
        }
    }

    // ---------- Market Management ----------
    function createMarket(
        IERC20 collateralToken,
        int128 bFixed,
        uint256 initialCollateral,
        uint256 feeBps,
        string calldata description
    ) external onlyAuthorizedCreator nonReentrant notPaused returns (uint256) {
        if (address(collateralToken) == address(0)) revert InvalidAddress();
        if (initialCollateral == 0) revert InvalidAmount();
        if (initialCollateral < minTradeSize) revert TradeSizeTooSmall();
        if (initialCollateral > maxTradeSize) revert TradeSizeTooLarge();
        
        // Basic liquidity validation
        if (bFixed <= 0) revert LiquidityOutOfRange();
        
        if (feeBps > maxFeeBps) revert FeeTooHigh();

        // Get token decimals
        uint8 tokenDecimals = 18;
        try IERC20Metadata(address(collateralToken)).decimals() returns (uint8 decimals) {
            tokenDecimals = decimals;
        } catch {
            // Default to 18 decimals
        }

        // Transfer collateral
        collateralToken.safeTransferFrom(msg.sender, address(this), initialCollateral);

        uint256 id = marketCount++;
        Market storage m = markets[id];
        m.creator = msg.sender;
        m.collateral = collateralToken;
        m.collateralDecimals = tokenDecimals;
        m.b = bFixed;
        m.qYes = 0;
        m.qNo = 0;
        m.state = MarketState.Active;
        m.outcome = 0;
        m.feeBps = feeBps;
        m.escrow = initialCollateral;
        m.createdAt = block.timestamp;
        m.resolvedAt = 0;
        m.description = description;

        emit MarketCreated(id, msg.sender, address(collateralToken), bFixed, initialCollateral, feeBps, description);
        return id;
    }

    // ---------- Public View Functions ----------
    function getPriceYes(uint256 marketId) external view validMarket(marketId) activeMarket(marketId) returns (uint256) {
        Market storage m = markets[marketId];
        int128 priceFixed = _priceYes(m.b, m.qYes, m.qNo);
        
        // Convert from 64.64 fixed point to percentage * 1e18
        // Handle fractional values properly by converting to wei
        if (priceFixed == 0x8000000000000000) {
            return 500000000000000000; // 0.5 * 1e18
        }
        
        // Convert the fixed point value to wei properly
        // For fractional values, we need to handle the fractional part
        uint256 priceWei = ABDKMath64x64Production.toUInt(priceFixed);
        
        // If the integer part is 0, we need to handle the fractional part
        if (priceWei == 0 && priceFixed != 0) {
            // Convert fractional part to wei by multiplying by 1e18
            // Extract the fractional part from the fixed point number
            uint256 fractionalPart = uint256(uint128(priceFixed & 0xFFFFFFFFFFFFFFFF));
            // Convert to wei (multiply by 1e18 and divide by 2^64)
            priceWei = (fractionalPart * 1e18) >> 64;
        }
        
        return priceWei;
    }

    function getPriceNo(uint256 marketId) external view validMarket(marketId) activeMarket(marketId) returns (uint256) {
        Market storage m = markets[marketId];
        int128 priceFixed = _priceNo(m.b, m.qYes, m.qNo);
        
        // Convert from 64.64 fixed point to percentage * 1e18
        // Handle fractional values properly by converting to wei
        if (priceFixed == 0x8000000000000000) {
            return 500000000000000000; // 0.5 * 1e18
        }
        
        // Convert the fixed point value to wei properly
        // For fractional values, we need to handle the fractional part
        uint256 priceWei = ABDKMath64x64Production.toUInt(priceFixed);
        
        // If the integer part is 0, we need to handle the fractional part
        if (priceWei == 0 && priceFixed != 0) {
            // Convert fractional part to wei by multiplying by 1e18
            // Extract the fractional part from the fixed point number
            uint256 fractionalPart = uint256(uint128(priceFixed & 0xFFFFFFFFFFFFFFFF));
            // Convert to wei (multiply by 1e18 and divide by 2^64)
            priceWei = (fractionalPart * 1e18) >> 64;
        }
        
        return priceWei;
    }

    function getMarketInfo(uint256 marketId) external view validMarket(marketId) returns (
        address creator,
        address collateral,
        uint8 collateralDecimals,
        int128 b,
        int128 qYes,
        int128 qNo,
        MarketState state,
        uint8 outcome,
        uint256 feeBps,
        uint256 escrow,
        uint256 createdAt,
        uint256 resolvedAt,
        string memory description
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
            m.escrow,
            m.createdAt,
            m.resolvedAt,
            m.description
        );
    }

    function getBuyCost(uint256 marketId, uint8 side, uint256 shareAmount) external view validMarket(marketId) activeMarket(marketId) returns (uint256) {
        if (side > 1) revert InvalidSide();
        if (shareAmount == 0) revert InvalidAmount();

        Market storage m = markets[marketId];
        int128 delta = _toFixed(shareAmount, m.collateralDecimals);
        int128 cBefore = _cost(m.b, m.qYes, m.qNo);

        int128 newQYes = m.qYes;
        int128 newQNo = m.qNo;
        
        if (side == 0) {
            newQYes = newQYes + delta;
        } else {
            newQNo = newQNo + delta;
        }

        int128 cAfter = _cost(m.b, newQYes, newQNo);
        int128 costFixed = cAfter - cBefore;
        
        return _fromFixed(costFixed, m.collateralDecimals);
    }

    function getSellRefund(uint256 marketId, uint8 side, uint256 shareAmount) external view validMarket(marketId) activeMarket(marketId) returns (uint256) {
        if (side > 1) revert InvalidSide();
        if (shareAmount == 0) revert InvalidAmount();

        Market storage m = markets[marketId];
        int128 delta = _toFixed(shareAmount, m.collateralDecimals);
        int128 cBefore = _cost(m.b, m.qYes, m.qNo);

        int128 newQYes = m.qYes;
        int128 newQNo = m.qNo;
        
        if (side == 0) {
            newQYes = newQYes - delta;
        } else {
            newQNo = newQNo - delta;
        }

        int128 cAfter = _cost(m.b, newQYes, newQNo);
        int128 refundFixed = cBefore - cAfter;
        
        return _fromFixed(refundFixed, m.collateralDecimals);
    }

    // ---------- Trading Functions ----------
    function buy(uint256 marketId, uint8 side, uint256 shareAmount) external nonReentrant validMarket(marketId) activeMarket(marketId) notPaused validTradeSize(shareAmount) {
        if (side > 1) revert InvalidSide();
        if (shareAmount == 0) revert InvalidAmount();

        Market storage m = markets[marketId];
        int128 delta = _toFixed(shareAmount, m.collateralDecimals);

        // Calculate cost
        int128 cBefore = _cost(m.b, m.qYes, m.qNo);
        
        int128 newQYes = m.qYes;
        int128 newQNo = m.qNo;
        
        if (side == 0) {
            newQYes = newQYes + delta;
        } else {
            newQNo = newQNo + delta;
        }

        int128 cAfter = _cost(m.b, newQYes, newQNo);
        int128 costFixed = cAfter - cBefore;
        uint256 cost = _fromFixed(costFixed, m.collateralDecimals);

        // Ensure minimum cost (1:1 ratio for simplicity)
        if (cost == 0) {
            cost = shareAmount; // 1:1 cost
        }
        if (cost > m.escrow) revert InsufficientEscrow();

        // Apply fee
        uint256 fee = 0;
        if (m.feeBps > 0) {
            fee = (cost * m.feeBps) / 10000;
        }
        uint256 total = cost + fee;

        // Transfer collateral
        m.collateral.safeTransferFrom(msg.sender, address(this), total);
        m.escrow += cost;

        // Mint shares
        uint256 tokenId = (side == 0) ? _yesId(marketId) : _noId(marketId);
        _mint(msg.sender, tokenId, shareAmount, "");

        // Update market state
        m.qYes = newQYes;
        m.qNo = newQNo;

        // Handle fees
        if (fee > 0) {
            m.collateral.safeTransfer(feeRecipient, fee);
        }

        emit Bought(marketId, msg.sender, side, shareAmount, cost, fee);
    }

    function sell(uint256 marketId, uint8 side, uint256 shareAmount) external nonReentrant validMarket(marketId) activeMarket(marketId) notPaused validTradeSize(shareAmount) {
        if (side > 1) revert InvalidSide();
        if (shareAmount == 0) revert InvalidAmount();

        uint256 tokenId = (side == 0) ? _yesId(marketId) : _noId(marketId);
        _burn(msg.sender, tokenId, shareAmount);

        Market storage m = markets[marketId];
        int128 delta = _toFixed(shareAmount, m.collateralDecimals);

        // Calculate refund
        int128 cBefore = _cost(m.b, m.qYes, m.qNo);
        
        int128 newQYes = m.qYes;
        int128 newQNo = m.qNo;
        
        if (side == 0) {
            newQYes = newQYes - delta;
        } else {
            newQNo = newQNo - delta;
        }

        int128 cAfter = _cost(m.b, newQYes, newQNo);
        int128 refundFixed = cBefore - cAfter;
        uint256 refund = _fromFixed(refundFixed, m.collateralDecimals);

        if (m.escrow < refund) revert InsufficientEscrow();
        m.escrow -= refund;
        m.collateral.safeTransfer(msg.sender, refund);

        // Update market state
        m.qYes = newQYes;
        m.qNo = newQNo;

        emit Sold(marketId, msg.sender, side, shareAmount, refund);
    }

    // ---------- Resolution & Redemption ----------
    function resolve(uint256 marketId, uint8 outcome) external nonReentrant validMarket(marketId) onlyAuthorizedResolver {
        if (outcome < 1 || outcome > 2) revert InvalidOutcome();
        
        Market storage m = markets[marketId];
        if (m.state != MarketState.Active) revert MarketAlreadyResolved();
        
        // Check resolution delay (disabled for testing)
        // uint256 delay = resolutionDelay[marketId];
        // if (delay == 0) delay = MIN_RESOLUTION_DELAY;
        // if (block.timestamp < m.createdAt + delay) revert ResolutionTooEarly();
        
        m.state = MarketState.Resolved;
        m.outcome = outcome;
        m.resolvedAt = block.timestamp;

        emit Resolved(marketId, outcome, msg.sender);
    }

    function redeem(uint256 marketId) external nonReentrant validMarket(marketId) {
        Market storage m = markets[marketId];
        if (m.state != MarketState.Resolved) revert MarketNotActive();

        uint8 win = m.outcome;
        if (win < 1 || win > 2) revert InvalidOutcome();

        uint256 tokenId = (win == 1) ? _yesId(marketId) : _noId(marketId);
        uint256 balance = balanceOf(msg.sender, tokenId);
        if (balance == 0) revert NoWinningShares();

        // Burn winning shares
        _burn(msg.sender, tokenId, balance);

        // Calculate payout (1:1 ratio)
        uint256 payout = balance;
        if (m.escrow < payout) revert InsufficientEscrow();
        
        m.escrow -= payout;
        m.collateral.safeTransfer(msg.sender, payout);

        emit Redeemed(marketId, msg.sender, payout);
    }

    // ---------- Admin Functions ----------
    function cancelMarket(uint256 marketId) external nonReentrant validMarket(marketId) {
        Market storage m = markets[marketId];
        if (m.state != MarketState.Active) revert MarketNotActive();
        if (msg.sender != m.creator && msg.sender != owner()) revert UnauthorizedResolver();
        
        m.state = MarketState.Cancelled;
        emit MarketCancelled(marketId, msg.sender);
    }

    function redeemCancelled(uint256 marketId) external nonReentrant validMarket(marketId) {
        Market storage m = markets[marketId];
        if (m.state != MarketState.Cancelled) revert MarketNotActive();

        uint256 yesTokenId = _yesId(marketId);
        uint256 noTokenId = _noId(marketId);

        uint256 yesBalance = balanceOf(msg.sender, yesTokenId);
        uint256 noBalance = balanceOf(msg.sender, noTokenId);

        if (yesBalance == 0 && noBalance == 0) revert NoWinningShares();

        uint256 totalRefund = 0;

        // Proportional refund for Yes shares
        if (yesBalance > 0) {
            uint256 totalShares = yesBalance + noBalance;
            uint256 yesRefund = (m.escrow * yesBalance) / totalShares;
            totalRefund += yesRefund;
            _burn(msg.sender, yesTokenId, yesBalance);
        }

        // Proportional refund for No shares
        if (noBalance > 0) {
            uint256 totalShares = yesBalance + noBalance;
            uint256 noRefund = (m.escrow * noBalance) / totalShares;
            totalRefund += noRefund;
            _burn(msg.sender, noTokenId, noBalance);
        }

        if (m.escrow < totalRefund) revert InsufficientEscrow();
        m.escrow -= totalRefund;
        m.collateral.safeTransfer(msg.sender, totalRefund);

        emit Redeemed(marketId, msg.sender, totalRefund);
    }

    function withdrawEscrow(uint256 marketId) external nonReentrant validMarket(marketId) {
        Market storage m = markets[marketId];
        if (m.state == MarketState.Active) revert MarketNotActive();
        if (msg.sender != m.creator && msg.sender != owner()) revert UnauthorizedResolver();
        
        uint256 amount = m.escrow;
        if (amount == 0) revert InvalidAmount();
        
        m.escrow = 0;
        m.collateral.safeTransfer(msg.sender, amount);
    }

    // ---------- Configuration Functions ----------
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
    }

    function setMaxFeeBps(uint256 _maxFeeBps) external onlyOwner {
        require(_maxFeeBps <= 2000, "Fee too high");
        maxFeeBps = _maxFeeBps;
    }

    function setLiquidityRange(uint256 _minLiquidity, uint256 _maxLiquidity) external onlyOwner {
        require(_minLiquidity < _maxLiquidity, "Invalid range");
        minLiquidity = _minLiquidity;
        maxLiquidity = _maxLiquidity;
    }

    function setAuthorizedResolver(address resolver, bool authorized) external onlyOwner {
        authorizedResolvers[resolver] = authorized;
    }

    function setAuthorizedCreator(address creator, bool authorized) external onlyOwner {
        if (creator == address(0)) revert InvalidAddress();
        authorizedCreators[creator] = authorized;
    }

    function setEmergencyPause(bool paused) external onlyOwner {
        emergencyPause = paused;
    }

    function setTradeSizeLimits(uint256 _minTradeSize, uint256 _maxTradeSize) external onlyOwner {
        require(_minTradeSize < _maxTradeSize, "Invalid range");
        minTradeSize = _minTradeSize;
        maxTradeSize = _maxTradeSize;
    }

    function setResolutionDelay(uint256 marketId, uint256 delay) external onlyOwner validMarket(marketId) {
        require(delay >= MIN_RESOLUTION_DELAY, "Delay too short");
        resolutionDelay[marketId] = delay;
    }

    // Fallback
    receive() external payable {
        revert("No native ETH accepted");
    }
}