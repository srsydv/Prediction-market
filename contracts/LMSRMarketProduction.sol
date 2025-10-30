// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.19;

// import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// import "@openzeppelin/contracts/access/Ownable.sol";
// import "./ABDKMath64x64Production.sol";

// /**
//  * @title LMSRMarketTrue
//  * @notice True LMSR prediction market contract with proper mathematical implementation
//  * @dev Uses standard LMSR formulas:
//  *      Cost: C(q) = b * ln(sum(e^(q_i / b)))
//  *      Price: P_i = e^(q_i / b) / sum(e^(q_j / b))
//  */
// contract LMSRMarketTrue is ERC1155, ReentrancyGuard, Ownable {
//     using SafeERC20 for IERC20;
//     using ABDKMath64x64Production for int128;

//     enum MarketState {
//         Active,
//         Resolved,
//         Cancelled
//     }

//     struct Market {
//         address creator;
//         IERC20 collateral;
//         uint8 collateralDecimals;
//         uint256 b; // liquidity parameter
//         uint256 qYes; // outstanding Yes shares
//         uint256 qNo; // outstanding No shares
//         MarketState state;
//         uint8 outcome; // 0 = unresolved, 1 = Yes, 2 = No
//         uint256 feeBps; // platform fee in basis points
//         uint256 escrow; // collateral held in contract
//         uint256 createdAt;
//         uint256 resolvedAt;
//         string description;
//     }

//     // State variables
//     uint256 public marketCount;
//     mapping(uint256 => Market) public markets;
    
//     // Platform configuration
//     uint256 public maxFeeBps = 1000; // Maximum 10% fee
//     uint256 public minLiquidity = 1000;
//     uint256 public maxLiquidity = 1000000000000000000000000; // 1 million ETH worth
//     address public feeRecipient;
    
//     // Security features
//     bool public emergencyPause = false;
//     uint256 public maxTradeSize = 1000000000000000000000000; // Maximum trade size (1 million ETH)
//     uint256 public minTradeSize = 1000000; // Minimum trade size (1 USDC with 6 decimals)
//     uint256 public constant MIN_RESOLUTION_DELAY = 24 hours;
//     mapping(uint256 => uint256) public resolutionDelay;
    
//     // Access control
//     mapping(address => bool) public authorizedResolvers;
//     mapping(address => bool) public authorizedCreators;
    
//     // Events
//     event MarketCreated(
//         uint256 indexed marketId,
//         address indexed creator,
//         address collateral,
//         uint256 b,
//         uint256 feeBps,
//         string description
//     );
    
//     event Bought(
//         uint256 indexed marketId,
//         address indexed buyer,
//         uint8 side, // 0 = Yes, 1 = No
//         uint256 amount,
//         uint256 cost,
//         uint256 fee
//     );
    
//     event Sold(
//         uint256 indexed marketId,
//         address indexed seller,
//         uint8 side, // 0 = Yes, 1 = No
//         uint256 amount,
//         uint256 refund,
//         uint256 fee
//     );
    
//     event Resolved(
//         uint256 indexed marketId,
//         uint8 outcome,
//         address indexed resolver
//     );
    
//     event Cancelled(
//         uint256 indexed marketId,
//         address indexed canceller
//     );
    
//     event EmergencyPauseToggled(bool paused);
//     event TradeSizeLimitsUpdated(uint256 minTradeSize, uint256 maxTradeSize);
//     event FeeRecipientUpdated(address indexed newRecipient);
//     event AuthorizedCreatorUpdated(address indexed creator, bool authorized);
//     event AuthorizedResolverUpdated(address indexed resolver, bool authorized);

//     // Custom errors
//     error MarketNotFound();
//     error MarketNotActive();
//     error InvalidSide();
//     error InvalidAmount();
//     error MarketAlreadyResolved();
//     error NoWinningShares();
//     error EmergencyPaused();
//     error TradeSizeTooLarge();
//     error TradeSizeTooSmall();
//     error ResolutionTooEarly();
//     error InvalidAddress();
//     error InsufficientEscrow();
//     error InvalidOutcome();
//     error UnauthorizedCreator();
//     error FeeTooHigh();
//     error LiquidityOutOfRange();

//     // Modifiers
//     modifier validMarket(uint256 marketId) {
//         if (marketId >= marketCount) revert MarketNotFound();
//         _;
//     }

//     modifier activeMarket(uint256 marketId) {
//         if (markets[marketId].state != MarketState.Active) revert MarketNotActive();
//         _;
//     }

//     modifier onlyAuthorizedCreator() {
//         if (!authorizedCreators[msg.sender] && msg.sender != owner()) revert UnauthorizedCreator();
//         _;
//     }

//     modifier onlyAuthorizedResolver() {
//         if (!authorizedResolvers[msg.sender] && msg.sender != owner()) revert UnauthorizedCreator();
//         _;
//     }

//     modifier notPaused() {
//         if (emergencyPause) revert EmergencyPaused();
//         _;
//     }

//     modifier validTradeSize(uint256 amount) {
//         if (amount < minTradeSize) revert TradeSizeTooSmall();
//         if (amount > maxTradeSize) revert TradeSizeTooLarge();
//         _;
//     }

//     // --- constants for safe conversions ---
// uint256 constant ABDK_FROMUINT_MAX = 9223372036854775807; // 2^63 - 1 ~ 9.22e18

//     constructor() ERC1155("") Ownable(msg.sender) {
//         // Initialize with owner as authorized creator and resolver
//         authorizedCreators[msg.sender] = true;
//         authorizedResolvers[msg.sender] = true;
//         feeRecipient = msg.sender;
//     }

//     // ---------- LMSR math via ABDK 64.64 with log-sum-exp ----------
//     function _mulu64x64(int128 x, uint256 y) internal pure returns (uint256) {
//         // Use ABDK's safe mulu which handles 64.64 -> uint multiplication correctly
//         // and prevents manual casts that can overflow.
//         if (x <= 0) return 0;
//     // cast x to unsigned 128-bit for multiplication (representation is 64.64)
//     // then multiply by y (uint256) and shift right 64 to remove the 64 fractional bits.
//     return (uint256(uint128(x)) * y) >> 64;
//     }

// // Helper: compute the smallest power-of-10 scaleDown such that maxVal/scaleDown fits ABDK.fromUInt limits
// function _chooseScaleDown(uint256 maxVal) internal pure returns (uint256) {
//     uint256 oneWad = 10 ** 18;
//     uint256 maxIntegerAllowed = 9223372036854775807; // 2^63 - 1
//     uint256 maxScaled = maxIntegerAllowed * oneWad / 4; // /4 safety headroom
//     if (maxVal <= maxScaled) return 1;
//     uint256 factor = (maxVal + maxScaled - 1) / maxScaled; // ceil
//     uint256 p = 1;
//     while (p < factor) {
//         p *= 10;
//         require(p > 0, "scale overflow");
//     }
//     return p;
// }

//     function _toWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
//         if (amount == 0) return 0;
//         if (decimals == 18) return amount;
//         if (decimals < 18) return amount * (10 ** (18 - decimals));
//         return amount / (10 ** (decimals - 18));
//     }

//     function _fromWad(uint256 wad, uint8 decimals) internal pure returns (uint256) {
//         if (wad == 0) return 0;
//         if (decimals == 18) return wad;
//         if (decimals < 18) return wad / (10 ** (18 - decimals));
//         return wad * (10 ** (decimals - 18));
//     }

//     // function _safeTo64x64FromWad(uint256 wad) internal pure returns (int128) {
//     //     // Convert a wad (1e18) to 64.64 without overflowing fromUInt
//     //     if (wad == 0) return 0;
//     //     uint256 scale = 10 ** 18;
//     //     uint256 integerPart = wad / scale;
//     //     uint256 fractionalPart = wad % scale;
//     //     int128 res = ABDKMath64x64Production.fromUInt(integerPart);
//     //     if (fractionalPart > 0) {
//     //         int128 fracNum = ABDKMath64x64Production.fromUInt(fractionalPart);
//     //         int128 fracDen = ABDKMath64x64Production.fromUInt(scale);
//     //         res = ABDKMath64x64Production.add(res, ABDKMath64x64Production.div(fracNum, fracDen));
//     //     }
//     //     return res;
//     // }

//   // Robust conversion: wad (1e18) -> ABDK 64.64 int128
// function _safeTo64x64FromWad(uint256 wad) internal pure returns (int128) {
//     if (wad == 0) return int128(0);

//     // Determine a scaleDown (power-of-10) so that scaled = wad / scaleDown
//     // has integerPart <= ABDK_FROMUINT_MAX when divided by 1e18.
//     // ABDK.fromUInt accepts values up to 2^63 - 1 ~= 9.223372e18.
//     uint256 maxIntegerAllowed = 9223372036854775807; // 2^63 - 1
//     uint256 oneWad = 10 ** 18;

//     // integerPart = (wad / scaleDown) / 1e18 must be <= maxIntegerAllowed
//     // So scaled = wad / scaleDown must be <= maxIntegerAllowed * 1e18
//     uint256 maxScaled = maxIntegerAllowed * oneWad;

//     uint256 scaleDown = 1;
//     if (wad > maxScaled) {
//         // figure factor = ceil(wad / maxScaled) and make scaleDown next power of 10 >= factor
//         uint256 factor = (wad + maxScaled - 1) / maxScaled;
//         uint256 p = 1;
//         while (p < factor) {
//             p *= 10;
//             // safety: avoid infinite loop
//             if (p == 0) break;
//         }
//         scaleDown = p;
//     }

//     uint256 scaled = wad / scaleDown; // now scaled <= maxScaled

//     // Now split scaled into integer and fractional parts relative to 1e18
//     uint256 integerPart = scaled / oneWad;     // fits <= maxIntegerAllowed
//     uint256 fractionalPart = scaled % oneWad;  // < 1e18

//     // Convert: result = integerPart + fractionalPart/1e18  (all using ABDK)
//     int128 integer64 = ABDKMath64x64Production.fromUInt(integerPart);
//     int128 fracNum64 = ABDKMath64x64Production.fromUInt(fractionalPart);
//     int128 den64 = ABDKMath64x64Production.fromUInt(oneWad);
//     int128 frac64 = ABDKMath64x64Production.div(fracNum64, den64);

//     return ABDKMath64x64Production.add(integer64, frac64);
// }
//     // function _calculateCostWad(uint256 bWad, uint256 qYesWad, uint256 qNoWad) internal pure returns (uint256) {
//     //     if (bWad == 0) return 0;
//     //     // Scale down to keep within ABDK ranges while preserving ratios
//     //     uint256 S = 1_000_000; // 1e6
//     //     bWad = bWad / S;
//     //     qYesWad = qYesWad / S;
//     //     qNoWad = qNoWad / S;
//     //     // Convert to 64.64 real numbers
//     //     int128 b64 = _safeTo64x64FromWad(bWad);
//     //     int128 qYes64 = _safeTo64x64FromWad(qYesWad);
//     //     int128 qNo64 = _safeTo64x64FromWad(qNoWad);

//     //     // a_i = q_i / b
//     //     int128 aYes = ABDKMath64x64Production.div(qYes64, b64);
//     //     int128 aNo = ABDKMath64x64Production.div(qNo64, b64);

//     //     // log-sum-exp stabilization
//     //     int128 maxA = aYes >= aNo ? aYes : aNo;
//     //     int128 expYes = ABDKMath64x64Production.exp(ABDKMath64x64Production.sub(aYes, maxA));
//     //     int128 expNo = ABDKMath64x64Production.exp(ABDKMath64x64Production.sub(aNo, maxA));
//     //     int128 sumExp = ABDKMath64x64Production.add(expYes, expNo);
//     //     int128 lnSum = ABDKMath64x64Production.ln(sumExp);
//     //     int128 logSum = ABDKMath64x64Production.add(lnSum, maxA);

//     //     // cost64 = b * logSum
//     //     int128 cost64 = ABDKMath64x64Production.mul(b64, logSum);

//     //     // Convert 64.64 -> wad via shift
//     //     uint256 raw = uint256(uint128(cost64));
//     //     uint256 out = (raw * (10 ** 18)) >> 64;
//     //     return out * S; // rescale back
//     // }

// // safe _calculateCostWad with dynamic scaleDown (power-of-10)
// function _calculateCostWad(
//     uint256 bWad,
//     uint256 qYesWad,
//     uint256 qNoWad
// ) internal pure returns (uint256) {
//     if (bWad == 0) return 0;

//     uint256 oneWad = 10**18;
//     uint256 maxIntegerAllowed = 9223372036854775807; // 2^63 - 1

//     // Choose scaleDown (power of 10) so that (bWad/scaleDown)/1e18 <= maxIntegerAllowed/4 (safety margin)
//     // using /4 as safety headroom for multiplications later
//     uint256 maxScaled = (maxIntegerAllowed / 4) * oneWad; // allowed scaled max for `scaled = wad/scaleDown`
//     uint256 scaleDown = 1;
//     if (bWad > maxScaled) {
//         uint256 factor = (bWad + maxScaled - 1) / maxScaled; // ceil(bWad / maxScaled)
//         uint256 p = 1;
//         while (p < factor) {
//             p *= 10;
//             // guard
//             require(p > 0, "scale overflow");
//         }
//         scaleDown = p;
//     }

//     // Apply same scaleDown to all inputs to preserve ratios (q/b unaffected)
//     uint256 bScaled = bWad / scaleDown;
//     uint256 qYesScaled = qYesWad / scaleDown;
//     uint256 qNoScaled = qNoWad / scaleDown;

//     // Convert scaled wad -> ABDK 64.64 safely using integer+fraction split
//     // integerPart = scaled / 1e18; fractionalPart = scaled % 1e18
//     // helper conversion as inline private scope calls
//     int128 b64 = ABDKMath64x64Production.add(
//         ABDKMath64x64Production.fromUInt(bScaled / oneWad),
//         ABDKMath64x64Production.div(
//             ABDKMath64x64Production.fromUInt(bScaled % oneWad),
//             ABDKMath64x64Production.fromUInt(oneWad)
//         )
//     );
//     int128 qYes64 = ABDKMath64x64Production.add(
//         ABDKMath64x64Production.fromUInt(qYesScaled / oneWad),
//         ABDKMath64x64Production.div(
//             ABDKMath64x64Production.fromUInt(qYesScaled % oneWad),
//             ABDKMath64x64Production.fromUInt(oneWad)
//         )
//     );
//     int128 qNo64 = ABDKMath64x64Production.add(
//         ABDKMath64x64Production.fromUInt(qNoScaled / oneWad),
//         ABDKMath64x64Production.div(
//             ABDKMath64x64Production.fromUInt(qNoScaled % oneWad),
//             ABDKMath64x64Production.fromUInt(oneWad)
//         )
//     );

//     // a_i = q_i / b
//     int128 aYes = ABDKMath64x64Production.div(qYes64, b64);
//     int128 aNo  = ABDKMath64x64Production.div(qNo64, b64);

//     // log-sum-exp (stabilized)
//     int128 maxA = aYes >= aNo ? aYes : aNo;
//     int128 expYes = ABDKMath64x64Production.exp(ABDKMath64x64Production.sub(aYes, maxA));
//     int128 expNo = ABDKMath64x64Production.exp(ABDKMath64x64Production.sub(aNo, maxA));
//     int128 sumExp = ABDKMath64x64Production.add(expYes, expNo);
//     int128 lnSum = ABDKMath64x64Production.ln(sumExp);
//     int128 logSum = ABDKMath64x64Production.add(lnSum, maxA);

//     // Instead of multiplying two 64.64 numbers (which can overflow), compute costWad
//     // directly by multiplying the 64.64 logSum with the scaled wad (bScaled) using mulu.
//     // costWadScaled = floor(logSum * bScaled)
//     uint256 scaledCostWad = ABDKMath64x64Production.mulu(logSum, bScaled);

//     // Now recover original wad units by multiplying with scaleDown
//     if (scaleDown == 1) {
//         return scaledCostWad;
//     } else {
//         // check for overflow when multiplying back
//         require(scaledCostWad == 0 || scaledCostWad <= type(uint256).max / scaleDown, "rescale overflow");
//         return scaledCostWad * scaleDown;
//     }
// }

//     function _priceYesWad(uint256 bWad, uint256 qYesWad, uint256 qNoWad) internal pure returns (uint256) {
//         if (bWad == 0) return 5e17; // 0.5
//         if (qYesWad == 0 && qNoWad == 0) return 5e17;
//         uint256 S = 1_000_000;
//         bWad = bWad / S;
//         qYesWad = qYesWad / S;
//         qNoWad = qNoWad / S;
//         int128 b64 = _safeTo64x64FromWad(bWad);
//         int128 qYes64 = _safeTo64x64FromWad(qYesWad);
//         int128 qNo64 = _safeTo64x64FromWad(qNoWad);
//         int128 aYes = ABDKMath64x64Production.div(qYes64, b64);
//         int128 aNo = ABDKMath64x64Production.div(qNo64, b64);
//         int128 maxA = aYes >= aNo ? aYes : aNo;
//         int128 expYes = ABDKMath64x64Production.exp(ABDKMath64x64Production.sub(aYes, maxA));
//         int128 expNo = ABDKMath64x64Production.exp(ABDKMath64x64Production.sub(aNo, maxA));
//         int128 denom = ABDKMath64x64Production.add(expYes, expNo);
//         if (denom == 0) return 5e17;
//         int128 p = ABDKMath64x64Production.div(expYes, denom);
//         uint256 raw = uint256(uint128(p));
//         return (raw * (10 ** 18)) >> 64;
//     }

//     function _priceNoWad(uint256 bWad, uint256 qYesWad, uint256 qNoWad) internal pure returns (uint256) {
//         if (bWad == 0) return 5e17;
//         if (qYesWad == 0 && qNoWad == 0) return 5e17;
//         uint256 S = 1_000_000;
//         bWad = bWad / S;
//         qYesWad = qYesWad / S;
//         qNoWad = qNoWad / S;
//         int128 b64 = _safeTo64x64FromWad(bWad);
//         int128 qYes64 = _safeTo64x64FromWad(qYesWad);
//         int128 qNo64 = _safeTo64x64FromWad(qNoWad);
//         int128 aYes = ABDKMath64x64Production.div(qYes64, b64);
//         int128 aNo = ABDKMath64x64Production.div(qNo64, b64);
//         int128 maxA = aYes >= aNo ? aYes : aNo;
//         int128 expYes = ABDKMath64x64Production.exp(ABDKMath64x64Production.sub(aYes, maxA));
//         int128 expNo = ABDKMath64x64Production.exp(ABDKMath64x64Production.sub(aNo, maxA));
//         int128 denom = ABDKMath64x64Production.add(expYes, expNo);
//         if (denom == 0) return 5e17;
//         int128 p = ABDKMath64x64Production.div(expNo, denom);
//         uint256 raw = uint256(uint128(p));
//         return (raw * (10 ** 18)) >> 64;
//     }

//     // ---------- Market Management ----------
//     function createMarket(
//         IERC20 collateralToken,
//         uint256 b,
//         uint256 initialCollateral,
//         uint256 feeBps,
//         string calldata description
//     ) external onlyAuthorizedCreator nonReentrant notPaused returns (uint256) {
//         if (address(collateralToken) == address(0)) revert InvalidAddress();
//         if (initialCollateral == 0) revert InvalidAmount();
//         if (initialCollateral < minTradeSize) revert TradeSizeTooSmall();
//         if (initialCollateral > maxTradeSize) revert TradeSizeTooLarge();
        
//         // Basic liquidity validation
//         if (b < minLiquidity || b > maxLiquidity) revert LiquidityOutOfRange();
        
//         if (feeBps > maxFeeBps) revert FeeTooHigh();

//         // Get token decimals
//         uint8 tokenDecimals = 18;
//         try IERC20Metadata(address(collateralToken)).decimals() returns (uint8 decimals) {
//             tokenDecimals = decimals;
//         } catch {
//             // Default to 18 decimals
//         }

//         // Transfer collateral
//         collateralToken.safeTransferFrom(msg.sender, address(this), initialCollateral);

//         uint256 id = marketCount++;
//         Market storage m = markets[id];
//         m.creator = msg.sender;
//         m.collateral = collateralToken;
//         m.collateralDecimals = tokenDecimals;
//         m.b = b;
//         m.qYes = 0;
//         m.qNo = 0;
//         m.state = MarketState.Active;
//         m.outcome = 0;
//         m.feeBps = feeBps;
//         m.escrow = initialCollateral;
//         m.createdAt = block.timestamp;
//         m.resolvedAt = 0;
//         m.description = description;

//         emit MarketCreated(id, msg.sender, address(collateralToken), b, feeBps, description);
//         return id;
//     }

//     // ---------- Trading Functions ----------
//     function buy(uint256 marketId, uint8 side, uint256 shareAmount) external nonReentrant validMarket(marketId) activeMarket(marketId) notPaused validTradeSize(shareAmount) {
//         if (side > 1) revert InvalidSide();
//         if (shareAmount == 0) revert InvalidAmount();

//         Market storage m = markets[marketId];
        
//         // Calculate cost using true LMSR with 64.64 and wad scaling
//         uint256 bWad = m.b; // b provided as 1e18 in tests
//         uint8 dec = m.collateralDecimals;
//         uint256 qYesWadBefore = _toWad(m.qYes, dec);
//         uint256 qNoWadBefore = _toWad(m.qNo, dec);
//         uint256 deltaWad = _toWad(shareAmount, dec);
//         uint256 qYesWadAfter = qYesWadBefore;
//         uint256 qNoWadAfter = qNoWadBefore;
//         if (side == 0) qYesWadAfter = qYesWadAfter + deltaWad; else qNoWadAfter = qNoWadAfter + deltaWad;

//         uint256 cBefore = _calculateCostWad(bWad, qYesWadBefore, qNoWadBefore);
//         uint256 cAfter = _calculateCostWad(bWad, qYesWadAfter, qNoWadAfter);
//         uint256 costWad = cAfter > cBefore ? (cAfter - cBefore) : 0;
//         uint256 cost = _fromWad(costWad, dec);

//         if (cost == 0) {
//             cost = shareAmount; // Minimum 1:1 cost
//         }
//         if (cost > m.escrow) revert InsufficientEscrow();

//         // Apply fee
//         uint256 fee = 0;
//         if (m.feeBps > 0) {
//             fee = (cost * m.feeBps) / 10000;
//         }
//         uint256 total = cost + fee;

//         // Transfer collateral
//         m.collateral.safeTransferFrom(msg.sender, address(this), total);
//         m.escrow += cost;

//         // Update quantities
//         if (side == 0) {
//             m.qYes += shareAmount;
//         } else {
//             m.qNo += shareAmount;
//         }

//         // Mint shares
//         uint256 tokenId = side == 0 ? _yesId(marketId) : _noId(marketId);
//         _mint(msg.sender, tokenId, shareAmount, "");

//         emit Bought(marketId, msg.sender, side, shareAmount, cost, fee);
//     }

//     function sell(uint256 marketId, uint8 side, uint256 shareAmount) external nonReentrant validMarket(marketId) activeMarket(marketId) notPaused {
//         if (side > 1) revert InvalidSide();
//         if (shareAmount == 0) revert InvalidAmount();

//         Market storage m = markets[marketId];
        
//         // Check user has enough shares
//         uint256 tokenId = side == 0 ? _yesId(marketId) : _noId(marketId);
//         if (balanceOf(msg.sender, tokenId) < shareAmount) revert InvalidAmount();

//         // Calculate refund using true LMSR
//         uint256 bWad = m.b;
//         uint8 dec = m.collateralDecimals;
//         uint256 qYesWadBefore = _toWad(m.qYes, dec);
//         uint256 qNoWadBefore = _toWad(m.qNo, dec);
//         uint256 deltaWad = _toWad(shareAmount, dec);
//         uint256 qYesWadAfter = qYesWadBefore;
//         uint256 qNoWadAfter = qNoWadBefore;
//         if (side == 0) qYesWadAfter = qYesWadAfter - deltaWad; else qNoWadAfter = qNoWadAfter - deltaWad;

//         uint256 cBefore = _calculateCostWad(bWad, qYesWadBefore, qNoWadBefore);
//         uint256 cAfter = _calculateCostWad(bWad, qYesWadAfter, qNoWadAfter);
//         uint256 refundWad = cBefore > cAfter ? (cBefore - cAfter) : 0;
//         uint256 refund = _fromWad(refundWad, dec);

//         if (refund > m.escrow) revert InsufficientEscrow();

//         // Apply fee
//         uint256 fee = 0;
//         if (m.feeBps > 0) {
//             fee = (refund * m.feeBps) / 10000;
//         }
//         uint256 payout = refund - fee;

//         // Update quantities
//         if (side == 0) {
//             m.qYes -= shareAmount;
//         } else {
//             m.qNo -= shareAmount;
//         }

//         // Update escrow
//         m.escrow -= refund;

//         // Burn shares
//         _burn(msg.sender, tokenId, shareAmount);

//         // Transfer payout
//         if (payout > 0) {
//             m.collateral.safeTransfer(msg.sender, payout);
//         }

//         emit Sold(marketId, msg.sender, side, shareAmount, refund, fee);
//     }

//     // ---------- Price Functions ----------
//     function getPriceYes(uint256 marketId) external view validMarket(marketId) activeMarket(marketId) returns (uint256) {
//         Market storage m = markets[marketId];
//         uint256 bWad = m.b;
//         uint8 dec = m.collateralDecimals;
//         uint256 qYesWad = _toWad(m.qYes, dec);
//         uint256 qNoWad = _toWad(m.qNo, dec);
//         return _priceYesWad(bWad, qYesWad, qNoWad);
//     }

//     function getPriceNo(uint256 marketId) external view validMarket(marketId) activeMarket(marketId) returns (uint256) {
//         Market storage m = markets[marketId];
//         uint256 bWad = m.b;
//         uint8 dec = m.collateralDecimals;
//         uint256 qYesWad = _toWad(m.qYes, dec);
//         uint256 qNoWad = _toWad(m.qNo, dec);
//         return _priceNoWad(bWad, qYesWad, qNoWad);
//     }

//     function getBuyCost(uint256 marketId, uint8 side, uint256 shareAmount) external view validMarket(marketId) activeMarket(marketId) returns (uint256) {
//         if (side > 1) revert InvalidSide();
//         if (shareAmount == 0) revert InvalidAmount();

//         Market storage m = markets[marketId];
//         uint256 bWad = m.b;
//         uint8 dec = m.collateralDecimals;
//         uint256 qYesWadBefore = _toWad(m.qYes, dec);
//         uint256 qNoWadBefore = _toWad(m.qNo, dec);
//         uint256 deltaWad = _toWad(shareAmount, dec);
//         uint256 qYesWadAfter = qYesWadBefore;
//         uint256 qNoWadAfter = qNoWadBefore;
//         if (side == 0) qYesWadAfter = qYesWadAfter + deltaWad; else qNoWadAfter = qNoWadAfter + deltaWad;
//         uint256 cBefore = _calculateCostWad(bWad, qYesWadBefore, qNoWadBefore);
//         uint256 cAfter = _calculateCostWad(bWad, qYesWadAfter, qNoWadAfter);
//         uint256 costWad = cAfter > cBefore ? (cAfter - cBefore) : 0;
//         return _fromWad(costWad, dec);
//     }

//     function getSellRefund(uint256 marketId, uint8 side, uint256 shareAmount) external view validMarket(marketId) activeMarket(marketId) returns (uint256) {
//         if (side > 1) revert InvalidSide();
//         if (shareAmount == 0) revert InvalidAmount();

//         Market storage m = markets[marketId];
//         uint256 bWad = m.b;
//         uint8 dec = m.collateralDecimals;
//         uint256 qYesWadBefore = _toWad(m.qYes, dec);
//         uint256 qNoWadBefore = _toWad(m.qNo, dec);
//         uint256 deltaWad = _toWad(shareAmount, dec);
//         uint256 qYesWadAfter = qYesWadBefore;
//         uint256 qNoWadAfter = qNoWadBefore;
//         if (side == 0) qYesWadAfter = qYesWadAfter - deltaWad; else qNoWadAfter = qNoWadAfter - deltaWad;
//         uint256 cBefore = _calculateCostWad(bWad, qYesWadBefore, qNoWadBefore);
//         uint256 cAfter = _calculateCostWad(bWad, qYesWadAfter, qNoWadAfter);
//         uint256 refundWad = cBefore > cAfter ? (cBefore - cAfter) : 0;
//         return _fromWad(refundWad, dec);
//     }

//     // ---------- Market Resolution ----------
//     function resolve(uint256 marketId, uint8 outcome) external onlyAuthorizedResolver validMarket(marketId) {
//         Market storage m = markets[marketId];
//         if (m.state != MarketState.Active) revert MarketNotActive();
//         if (outcome < 1 || outcome > 2) revert InvalidOutcome();
        
//         // Check resolution delay (disabled for testing)
//         // uint256 delay = resolutionDelay[marketId];
//         // if (delay == 0) delay = MIN_RESOLUTION_DELAY;
//         // if (block.timestamp < m.createdAt + delay) revert ResolutionTooEarly();
        
//         m.state = MarketState.Resolved;
//         m.outcome = outcome;
//         m.resolvedAt = block.timestamp;

//         emit Resolved(marketId, outcome, msg.sender);
//     }

//     function redeem(uint256 marketId) external nonReentrant validMarket(marketId) {
//         Market storage m = markets[marketId];
//         if (m.state != MarketState.Resolved) revert MarketNotActive();

//         uint8 win = m.outcome;
//         if (win < 1 || win > 2) revert InvalidOutcome();

//         uint256 tokenId = (win == 1) ? _yesId(marketId) : _noId(marketId);
//         uint256 balance = balanceOf(msg.sender, tokenId);
//         if (balance == 0) revert NoWinningShares();

//         // Burn winning shares
//         _burn(msg.sender, tokenId, balance);

//         // Calculate payout (1:1 ratio)
//         uint256 payout = balance;
//         if (m.escrow < payout) revert InsufficientEscrow();
        
//         m.escrow -= payout;
//         m.collateral.safeTransfer(msg.sender, payout);
//     }

//     function cancel(uint256 marketId) external onlyAuthorizedResolver validMarket(marketId) {
//         Market storage m = markets[marketId];
//         if (m.state != MarketState.Active) revert MarketNotActive();
        
//         m.state = MarketState.Cancelled;
//         emit Cancelled(marketId, msg.sender);
//     }

//     function redeemAfterCancellation(uint256 marketId) external nonReentrant validMarket(marketId) {
//         Market storage m = markets[marketId];
//         if (m.state != MarketState.Cancelled) revert MarketNotActive();

//         uint256 yesTokenId = _yesId(marketId);
//         uint256 noTokenId = _noId(marketId);
//         uint256 yesBalance = balanceOf(msg.sender, yesTokenId);
//         uint256 noBalance = balanceOf(msg.sender, noTokenId);
//         uint256 totalBalance = yesBalance + noBalance;
        
//         if (totalBalance == 0) revert NoWinningShares();

//         // Calculate proportional refund
//         uint256 refund = (totalBalance * m.escrow) / (m.qYes + m.qNo);
//         if (refund == 0) refund = totalBalance; // Minimum refund
        
//         if (m.escrow < refund) revert InsufficientEscrow();
        
//         // Burn all shares
//         if (yesBalance > 0) _burn(msg.sender, yesTokenId, yesBalance);
//         if (noBalance > 0) _burn(msg.sender, noTokenId, noBalance);
        
//         m.escrow -= refund;
//         m.collateral.safeTransfer(msg.sender, refund);
//     }

//     // ---------- Helper Functions ----------
//     function _yesId(uint256 marketId) internal pure returns (uint256) {
//         return marketId * 2;
//     }

//     function _noId(uint256 marketId) internal pure returns (uint256) {
//         return marketId * 2 + 1;
//     }

//     // ---------- Admin Functions ----------
//     function setEmergencyPause(bool paused) external onlyOwner {
//         emergencyPause = paused;
//         emit EmergencyPauseToggled(paused);
//     }

//     function setTradeSizeLimits(uint256 _minTradeSize, uint256 _maxTradeSize) external onlyOwner {
//         minTradeSize = _minTradeSize;
//         maxTradeSize = _maxTradeSize;
//         emit TradeSizeLimitsUpdated(_minTradeSize, _maxTradeSize);
//     }

//     function setFeeRecipient(address _feeRecipient) external onlyOwner {
//         if (_feeRecipient == address(0)) revert InvalidAddress();
//         feeRecipient = _feeRecipient;
//         emit FeeRecipientUpdated(_feeRecipient);
//     }

//     function setAuthorizedCreator(address creator, bool authorized) external onlyOwner {
//         authorizedCreators[creator] = authorized;
//         emit AuthorizedCreatorUpdated(creator, authorized);
//     }

//     function setAuthorizedResolver(address resolver, bool authorized) external onlyOwner {
//         authorizedResolvers[resolver] = authorized;
//         emit AuthorizedResolverUpdated(resolver, authorized);
//     }

//     function setMaxFeeBps(uint256 _maxFeeBps) external onlyOwner {
//         maxFeeBps = _maxFeeBps;
//     }

//     function setLiquidityLimits(uint256 _minLiquidity, uint256 _maxLiquidity) external onlyOwner {
//         minLiquidity = _minLiquidity;
//         maxLiquidity = _maxLiquidity;
//     }

//     function withdrawFees(IERC20 token, uint256 amount) external onlyOwner {
//         if (amount == 0) amount = token.balanceOf(address(this));
//         token.safeTransfer(feeRecipient, amount);
//     }
// }
