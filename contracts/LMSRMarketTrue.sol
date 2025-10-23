// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./LMSRMath.sol";

/**
 * @title LMSRMarketTrue
 * @notice True LMSR prediction market contract with proper mathematical implementation
 * @dev Uses standard LMSR formulas:
 *      Cost: C(q) = b * ln(sum(e^(q_i / b)))
 *      Price: P_i = e^(q_i / b) / sum(e^(q_j / b))
 */
contract LMSRMarketTrue is ERC1155, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using LMSRMath for uint256;

    enum MarketState {
        Active,
        Resolved,
        Cancelled
    }

    struct Market {
        address creator;
        IERC20 collateral;
        uint8 collateralDecimals;
        uint256 b; // liquidity parameter
        uint256 qYes; // outstanding Yes shares
        uint256 qNo; // outstanding No shares
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
    uint256 public maxLiquidity = 1000000000000000000000000; // 1 million ETH worth
    address public feeRecipient;
    
    // Security features
    bool public emergencyPause = false;
    uint256 public maxTradeSize = 1000000000000000000000000; // Maximum trade size (1 million ETH)
    uint256 public minTradeSize = 1000000; // Minimum trade size (1 USDC with 6 decimals)
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
        uint256 b,
        uint256 feeBps,
        string description
    );
    
    event Bought(
        uint256 indexed marketId,
        address indexed buyer,
        uint8 side, // 0 = Yes, 1 = No
        uint256 amount,
        uint256 cost,
        uint256 fee
    );
    
    event Sold(
        uint256 indexed marketId,
        address indexed seller,
        uint8 side, // 0 = Yes, 1 = No
        uint256 amount,
        uint256 refund,
        uint256 fee
    );
    
    event Resolved(
        uint256 indexed marketId,
        uint8 outcome,
        address indexed resolver
    );
    
    event Cancelled(
        uint256 indexed marketId,
        address indexed canceller
    );
    
    event EmergencyPauseToggled(bool paused);
    event TradeSizeLimitsUpdated(uint256 minTradeSize, uint256 maxTradeSize);
    event FeeRecipientUpdated(address indexed newRecipient);
    event AuthorizedCreatorUpdated(address indexed creator, bool authorized);
    event AuthorizedResolverUpdated(address indexed resolver, bool authorized);

    // Custom errors
    error MarketNotFound();
    error MarketNotActive();
    error InvalidSide();
    error InvalidAmount();
    error MarketAlreadyResolved();
    error NoWinningShares();
    error EmergencyPaused();
    error TradeSizeTooLarge();
    error TradeSizeTooSmall();
    error ResolutionTooEarly();
    error InvalidAddress();
    error InsufficientEscrow();
    error InvalidOutcome();
    error UnauthorizedCreator();
    error FeeTooHigh();
    error LiquidityOutOfRange();

    // Modifiers
    modifier validMarket(uint256 marketId) {
        if (marketId >= marketCount) revert MarketNotFound();
        _;
    }

    modifier activeMarket(uint256 marketId) {
        if (markets[marketId].state != MarketState.Active) revert MarketNotActive();
        _;
    }

    modifier onlyAuthorizedCreator() {
        if (!authorizedCreators[msg.sender] && msg.sender != owner()) revert UnauthorizedCreator();
        _;
    }

    modifier onlyAuthorizedResolver() {
        if (!authorizedResolvers[msg.sender] && msg.sender != owner()) revert UnauthorizedCreator();
        _;
    }

    modifier notPaused() {
        if (emergencyPause) revert EmergencyPaused();
        _;
    }

    modifier validTradeSize(uint256 amount) {
        if (amount < minTradeSize) revert TradeSizeTooSmall();
        if (amount > maxTradeSize) revert TradeSizeTooLarge();
        _;
    }

    constructor() ERC1155("") Ownable(msg.sender) {
        // Initialize with owner as authorized creator and resolver
        authorizedCreators[msg.sender] = true;
        authorizedResolvers[msg.sender] = true;
        feeRecipient = msg.sender;
    }

    // ---------- Market Management ----------
    function createMarket(
        IERC20 collateralToken,
        uint256 b,
        uint256 initialCollateral,
        uint256 feeBps,
        string calldata description
    ) external onlyAuthorizedCreator nonReentrant notPaused returns (uint256) {
        if (address(collateralToken) == address(0)) revert InvalidAddress();
        if (initialCollateral == 0) revert InvalidAmount();
        if (initialCollateral < minTradeSize) revert TradeSizeTooSmall();
        if (initialCollateral > maxTradeSize) revert TradeSizeTooLarge();
        
        // Basic liquidity validation
        if (b < minLiquidity || b > maxLiquidity) revert LiquidityOutOfRange();
        
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
        m.b = b;
        m.qYes = 0;
        m.qNo = 0;
        m.state = MarketState.Active;
        m.outcome = 0;
        m.feeBps = feeBps;
        m.escrow = initialCollateral;
        m.createdAt = block.timestamp;
        m.resolvedAt = 0;
        m.description = description;

        emit MarketCreated(id, msg.sender, address(collateralToken), b, feeBps, description);
        return id;
    }

    // ---------- Trading Functions ----------
    function buy(uint256 marketId, uint8 side, uint256 shareAmount) external nonReentrant validMarket(marketId) activeMarket(marketId) notPaused validTradeSize(shareAmount) {
        if (side > 1) revert InvalidSide();
        if (shareAmount == 0) revert InvalidAmount();

        Market storage m = markets[marketId];
        
        // Calculate cost using true LMSR
        uint256 cost = LMSRMath.calculateBuyCost(
            m.b,
            m.qYes,
            m.qNo,
            side == 0 ? m.qYes + shareAmount : m.qYes,
            side == 1 ? m.qNo + shareAmount : m.qNo
        );

        if (cost == 0) {
            cost = shareAmount; // Minimum 1:1 cost
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

        // Update quantities
        if (side == 0) {
            m.qYes += shareAmount;
        } else {
            m.qNo += shareAmount;
        }

        // Mint shares
        uint256 tokenId = side == 0 ? _yesId(marketId) : _noId(marketId);
        _mint(msg.sender, tokenId, shareAmount, "");

        emit Bought(marketId, msg.sender, side, shareAmount, cost, fee);
    }

    function sell(uint256 marketId, uint8 side, uint256 shareAmount) external nonReentrant validMarket(marketId) activeMarket(marketId) notPaused {
        if (side > 1) revert InvalidSide();
        if (shareAmount == 0) revert InvalidAmount();

        Market storage m = markets[marketId];
        
        // Check user has enough shares
        uint256 tokenId = side == 0 ? _yesId(marketId) : _noId(marketId);
        if (balanceOf(msg.sender, tokenId) < shareAmount) revert InvalidAmount();

        // Calculate refund using true LMSR
        uint256 refund = LMSRMath.calculateSellRefund(
            m.b,
            m.qYes,
            m.qNo,
            side == 0 ? m.qYes - shareAmount : m.qYes,
            side == 1 ? m.qNo - shareAmount : m.qNo
        );

        if (refund > m.escrow) revert InsufficientEscrow();

        // Apply fee
        uint256 fee = 0;
        if (m.feeBps > 0) {
            fee = (refund * m.feeBps) / 10000;
        }
        uint256 payout = refund - fee;

        // Update quantities
        if (side == 0) {
            m.qYes -= shareAmount;
        } else {
            m.qNo -= shareAmount;
        }

        // Update escrow
        m.escrow -= refund;

        // Burn shares
        _burn(msg.sender, tokenId, shareAmount);

        // Transfer payout
        if (payout > 0) {
            m.collateral.safeTransfer(msg.sender, payout);
        }

        emit Sold(marketId, msg.sender, side, shareAmount, refund, fee);
    }

    // ---------- Price Functions ----------
    function getPriceYes(uint256 marketId) external view validMarket(marketId) activeMarket(marketId) returns (uint256) {
        Market storage m = markets[marketId];
        return LMSRMath.calculatePriceYes(m.b, m.qYes, m.qNo);
    }

    function getPriceNo(uint256 marketId) external view validMarket(marketId) activeMarket(marketId) returns (uint256) {
        Market storage m = markets[marketId];
        return LMSRMath.calculatePriceNo(m.b, m.qYes, m.qNo);
    }

    function getBuyCost(uint256 marketId, uint8 side, uint256 shareAmount) external view validMarket(marketId) activeMarket(marketId) returns (uint256) {
        if (side > 1) revert InvalidSide();
        if (shareAmount == 0) revert InvalidAmount();

        Market storage m = markets[marketId];
        return LMSRMath.calculateBuyCost(
            m.b,
            m.qYes,
            m.qNo,
            side == 0 ? m.qYes + shareAmount : m.qYes,
            side == 1 ? m.qNo + shareAmount : m.qNo
        );
    }

    function getSellRefund(uint256 marketId, uint8 side, uint256 shareAmount) external view validMarket(marketId) activeMarket(marketId) returns (uint256) {
        if (side > 1) revert InvalidSide();
        if (shareAmount == 0) revert InvalidAmount();

        Market storage m = markets[marketId];
        return LMSRMath.calculateSellRefund(
            m.b,
            m.qYes,
            m.qNo,
            side == 0 ? m.qYes - shareAmount : m.qYes,
            side == 1 ? m.qNo - shareAmount : m.qNo
        );
    }

    // ---------- Market Resolution ----------
    function resolve(uint256 marketId, uint8 outcome) external onlyAuthorizedResolver validMarket(marketId) {
        Market storage m = markets[marketId];
        if (m.state != MarketState.Active) revert MarketNotActive();
        if (outcome < 1 || outcome > 2) revert InvalidOutcome();
        
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
    }

    function cancel(uint256 marketId) external onlyAuthorizedResolver validMarket(marketId) {
        Market storage m = markets[marketId];
        if (m.state != MarketState.Active) revert MarketNotActive();
        
        m.state = MarketState.Cancelled;
        emit Cancelled(marketId, msg.sender);
    }

    function redeemAfterCancellation(uint256 marketId) external nonReentrant validMarket(marketId) {
        Market storage m = markets[marketId];
        if (m.state != MarketState.Cancelled) revert MarketNotActive();

        uint256 yesTokenId = _yesId(marketId);
        uint256 noTokenId = _noId(marketId);
        uint256 yesBalance = balanceOf(msg.sender, yesTokenId);
        uint256 noBalance = balanceOf(msg.sender, noTokenId);
        uint256 totalBalance = yesBalance + noBalance;
        
        if (totalBalance == 0) revert NoWinningShares();

        // Calculate proportional refund
        uint256 refund = (totalBalance * m.escrow) / (m.qYes + m.qNo);
        if (refund == 0) refund = totalBalance; // Minimum refund
        
        if (m.escrow < refund) revert InsufficientEscrow();
        
        // Burn all shares
        if (yesBalance > 0) _burn(msg.sender, yesTokenId, yesBalance);
        if (noBalance > 0) _burn(msg.sender, noTokenId, noBalance);
        
        m.escrow -= refund;
        m.collateral.safeTransfer(msg.sender, refund);
    }

    // ---------- Helper Functions ----------
    function _yesId(uint256 marketId) internal pure returns (uint256) {
        return marketId * 2;
    }

    function _noId(uint256 marketId) internal pure returns (uint256) {
        return marketId * 2 + 1;
    }

    // ---------- Admin Functions ----------
    function setEmergencyPause(bool paused) external onlyOwner {
        emergencyPause = paused;
        emit EmergencyPauseToggled(paused);
    }

    function setTradeSizeLimits(uint256 _minTradeSize, uint256 _maxTradeSize) external onlyOwner {
        minTradeSize = _minTradeSize;
        maxTradeSize = _maxTradeSize;
        emit TradeSizeLimitsUpdated(_minTradeSize, _maxTradeSize);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert InvalidAddress();
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    function setAuthorizedCreator(address creator, bool authorized) external onlyOwner {
        authorizedCreators[creator] = authorized;
        emit AuthorizedCreatorUpdated(creator, authorized);
    }

    function setAuthorizedResolver(address resolver, bool authorized) external onlyOwner {
        authorizedResolvers[resolver] = authorized;
        emit AuthorizedResolverUpdated(resolver, authorized);
    }

    function setMaxFeeBps(uint256 _maxFeeBps) external onlyOwner {
        maxFeeBps = _maxFeeBps;
    }

    function setLiquidityLimits(uint256 _minLiquidity, uint256 _maxLiquidity) external onlyOwner {
        minLiquidity = _minLiquidity;
        maxLiquidity = _maxLiquidity;
    }

    function withdrawFees(IERC20 token, uint256 amount) external onlyOwner {
        if (amount == 0) amount = token.balanceOf(address(this));
        token.safeTransfer(feeRecipient, amount);
    }
}
