# LMSRMarket - Logarithmic Market Scoring Rule Prediction Market

A comprehensive implementation of the Logarithmic Market Scoring Rule (LMSR) for binary prediction markets, built on Ethereum using Solidity.

## Table of Contents

1. [Overview](#overview)
2. [Core Functions](#core-functions)
3. [Market Management](#market-management)
4. [Trading Functions](#trading-functions)
5. [Resolution & Redemption](#resolution--redemption)
6. [View Functions](#view-functions)
7. [Mathematical Background](#mathematical-background)
8. [Usage Examples](#usage-examples)

## Overview

The LMSRMarket contract implements a binary prediction market using the Logarithmic Market Scoring Rule, which provides:

- **Automatic Market Making**: No need for order books
- **Liquidity Provision**: Always available to buy/sell shares
- **Price Discovery**: Prices automatically adjust based on supply/demand
- **Fair Pricing**: Mathematically sound pricing mechanism

### Key Features

- ✅ ERC1155 tokenized shares (Yes/No tokens)
- ✅ Multi-collateral support (any ERC20 token)
- ✅ Automatic decimal handling
- ✅ Fee management
- ✅ Fair cancellation with proportional refunds
- ✅ Comprehensive view functions

## Core Functions

### 1. `createMarket()`

Creates a new binary prediction market.

```solidity
function createMarket(
    IERC20 collateralToken,
    int128 bFixed,
    uint256 initialCollateral,
    uint256 feeBps
) external nonReentrant returns (uint256)
```

#### Parameters
- `collateralToken`: ERC20 token used as collateral (e.g., USDC, DAI)
- `bFixed`: Liquidity parameter in 64.64 fixed point format
- `initialCollateral`: Initial collateral amount to seed the market
- `feeBps`: Platform fee in basis points (max 1000 = 10%)

#### Example Calculation

**Scenario**: Creating a Bitcoin prediction market
```solidity
// Market: "Will Bitcoin reach $100k by end of 2024?"
// Collateral: USDC (6 decimals)
// Liquidity: b = 1000 (moderate liquidity)
// Initial collateral: 10,000 USDC
// Fee: 1% (100 basis points)

uint256 marketId = createMarket(
    usdcToken,           // USDC contract address
    1000,               // b = 1000 (in 64.64 fixed point)
    10000 * 10**6,      // 10,000 USDC (6 decimals)
    100                 // 1% fee
);
```

**What happens:**
1. Contract detects USDC has 6 decimals
2. Transfers 10,000 USDC from creator to contract
3. Creates market with ID = 0
4. Initial state: qYes = 0, qNo = 0
5. Escrow = 10,000 USDC

#### Liquidity Parameter (b) Guidelines

| b Value | Liquidity Level | Price Sensitivity | Use Case |
|---------|----------------|-------------------|----------|
| 100-500 | Low | High | Small markets, high volatility |
| 500-2000 | Medium | Moderate | Standard prediction markets |
| 2000+ | High | Low | Large markets, stable prices |

---

## Trading Functions

### 2. `buy()`

Purchases shares of a prediction market outcome.

```solidity
function buy(uint256 marketId, uint8 side, uint256 shareAmount) external nonReentrant
```

#### Parameters
- `marketId`: ID of the market
- `side`: 0 = Yes, 1 = No
- `shareAmount`: Number of shares to purchase

#### Detailed Calculation Example

**Scenario**: Buying 100 Yes shares in the Bitcoin market

```solidity
// Market state before purchase:
// qYes = 0, qNo = 0, b = 1000, escrow = 10,000 USDC
// User wants: 100 Yes shares

buy(0, 0, 100); // marketId=0, side=0 (Yes), amount=100
```

**Step-by-step calculation:**

1. **Convert to Fixed Point**
   ```solidity
   delta = _toFixed(100, 6) // USDC has 6 decimals
   // delta = 100 * 10^(18-6) = 100 * 10^12 = 100,000,000,000,000
   ```

2. **Calculate Current Cost**
   ```solidity
   cBefore = _cost(m, 0, 0)
   // C(q) = b * ln(e^(q_yes/b) + e^(q_no/b))
   // C(0,0) = 1000 * ln(e^0 + e^0) = 1000 * ln(2) ≈ 693
   ```

3. **Calculate New Quantities**
   ```solidity
   newQYes = 0 + 100,000,000,000,000 = 100,000,000,000,000
   newQNo = 0
   ```

4. **Calculate New Cost**
   ```solidity
   cAfter = _cost(m, 100,000,000,000,000, 0)
   // uYes = 100,000,000,000,000 / 1000 = 100,000,000,000
   // eYes = exp(100,000,000,000) ≈ very large number
   // eNo = exp(0) = 1
   // C ≈ 1000 * ln(eYes) ≈ 100,000,000,000,000
   ```

5. **Calculate Cost to Pay**
   ```solidity
   costFixed = 100,000,000,000,000 - 693 ≈ 100,000,000,000,000
   cost = _fromFixed(costFixed, 6) = 100,000,000,000,000 / 10^12 = 100,000 USDC
   ```

6. **Apply Fee**
   ```solidity
   fee = (100,000 * 100) / 10000 = 1,000 USDC
   total = 100,000 + 1,000 = 101,000 USDC
   ```

**Result**: User pays 101,000 USDC, receives 100 Yes shares, creator gets 1,000 USDC fee.

### 3. `sell()`

Sells shares back to the market maker.

```solidity
function sell(uint256 marketId, uint8 side, uint256 shareAmount) external nonReentrant
```

#### Example Calculation

**Scenario**: Selling 50 Yes shares

```solidity
// Market state before sale:
// qYes = 100,000,000,000,000, qNo = 0, b = 1000
// User has: 100 Yes shares, wants to sell 50

sell(0, 0, 50); // marketId=0, side=0 (Yes), amount=50
```

**Calculation:**

1. **Convert to Fixed Point**
   ```solidity
   delta = _toFixed(50, 6) = 50,000,000,000,000
   ```

2. **Calculate Current Cost**
   ```solidity
   cBefore = _cost(m, 100,000,000,000,000, 0) ≈ 100,000,000,000,000
   ```

3. **Calculate New Quantities**
   ```solidity
   newQYes = 100,000,000,000,000 - 50,000,000,000,000 = 50,000,000,000,000
   newQNo = 0
   ```

4. **Calculate New Cost**
   ```solidity
   cAfter = _cost(m, 50,000,000,000,000, 0) ≈ 50,000,000,000,000
   ```

5. **Calculate Refund**
   ```solidity
   refundFixed = 100,000,000,000,000 - 50,000,000,000,000 = 50,000,000,000,000
   refund = _fromFixed(refundFixed, 6) = 50,000 USDC
   ```

**Result**: User receives 50,000 USDC, burns 50 Yes shares.

---

## Market Management

### 4. `resolve()`

Resolves a market to a specific outcome.

```solidity
function resolve(uint256 marketId, uint8 outcome) external nonReentrant
```

#### Parameters
- `marketId`: ID of the market
- `outcome`: 1 = Yes wins, 2 = No wins

#### Example

```solidity
// Market: "Will Bitcoin reach $100k by end of 2024?"
// Outcome: Bitcoin reached $105k, so Yes wins

resolve(0, 1); // marketId=0, outcome=1 (Yes wins)
```

**What happens:**
- Market state changes to `Resolved`
- Outcome set to 1 (Yes)
- Event `Resolved(0, 1)` emitted

### 5. `redeem()`

Redeems winning shares after market resolution.

```solidity
function redeem(uint256 marketId) external nonReentrant
```

#### Example Calculation

**Scenario**: User has 100 Yes shares, market resolved to Yes

```solidity
// Market resolved to Yes (outcome = 1)
// User has: 100 Yes shares
// Escrow: 10,000 USDC

redeem(0);
```

**Calculation:**
- User has 100 Yes shares
- Market outcome = 1 (Yes wins)
- Yes shares are winning shares
- Payout = 100 USDC (1:1 ratio)
- User's Yes shares are burned
- User receives 100 USDC

### 6. `cancelMarket()`

Cancels an active market (emergency function).

```solidity
function cancelMarket(uint256 marketId) external nonReentrant
```

**Access**: Only market creator or contract owner

### 7. `redeemCancelled()`

Redeems shares after market cancellation with proportional refunds.

```solidity
function redeemCancelled(uint256 marketId) external nonReentrant
```

#### Example Calculation

**Scenario**: Market cancelled, user has 100 Yes shares and 50 No shares

```solidity
// Market cancelled
// User has: 100 Yes shares, 50 No shares
// Total escrow: 10,000 USDC
// Total shares: 100 Yes + 50 No = 150 shares

redeemCancelled(0);
```

**Calculation:**
- Total user shares = 100 + 50 = 150
- User's share of escrow = (150 / 150) * 10,000 = 10,000 USDC
- Yes refund = (100 / 150) * 10,000 = 6,666.67 USDC
- No refund = (50 / 150) * 10,000 = 3,333.33 USDC
- Total refund = 6,666.67 + 3,333.33 = 10,000 USDC

---

## View Functions

### 8. `getPriceYes()` / `getPriceNo()`

Get current prices of Yes/No shares.

```solidity
function getPriceYes(uint256 marketId) external view returns (uint256)
function getPriceNo(uint256 marketId) external view returns (uint256)
```

#### Example Calculation

**Scenario**: Market with qYes = 100, qNo = 50, b = 1000

```solidity
uint256 priceYes = getPriceYes(0);
uint256 priceNo = getPriceNo(0);
```

**Calculation:**
```solidity
// Price formula: p = exp(q/b) / (exp(q_yes/b) + exp(q_no/b))
uYes = 100 / 1000 = 0.1
uNo = 50 / 1000 = 0.05
eYes = exp(0.1) ≈ 1.105
eNo = exp(0.05) ≈ 1.051
denom = 1.105 + 1.051 = 2.156
priceYes = 1.105 / 2.156 ≈ 0.512 (51.2%)
priceNo = 1.051 / 2.156 ≈ 0.488 (48.8%)
```

**Result**: 
- `getPriceYes()` returns 5120 (51.2% in basis points)
- `getPriceNo()` returns 4880 (48.8% in basis points)

### 9. `getMarketInfo()`

Get comprehensive market information.

```solidity
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
)
```

### 10. `getBuyCost()` / `getSellRefund()`

Calculate cost/refund before executing trade.

```solidity
function getBuyCost(uint256 marketId, uint8 side, uint256 shareAmount) external view returns (uint256)
function getSellRefund(uint256 marketId, uint8 side, uint256 shareAmount) external view returns (uint256)
```

#### Example

```solidity
// Check cost before buying 100 Yes shares
uint256 cost = getBuyCost(0, 0, 100);
// Returns: 100,000 USDC (plus fees)

// Check refund before selling 50 Yes shares  
uint256 refund = getSellRefund(0, 0, 50);
// Returns: 50,000 USDC
```

---

## Mathematical Background

### LMSR Cost Function

The core of the LMSR mechanism is the cost function:

```
C(q_yes, q_no) = b * ln(e^(q_yes/b) + e^(q_no/b))
```

Where:
- `b`: Liquidity parameter
- `q_yes`: Outstanding Yes shares
- `q_no`: Outstanding No shares
- `ln`: Natural logarithm
- `e`: Euler's number

### Price Calculation

The price of Yes shares is:

```
p_yes = e^(q_yes/b) / (e^(q_yes/b) + e^(q_no/b))
```

The price of No shares is:

```
p_no = e^(q_no/b) / (e^(q_yes/b) + e^(q_no/b))
```

### Key Properties

1. **Prices sum to 1**: p_yes + p_no = 1
2. **Monotonic**: Prices increase as more shares are sold
3. **Liquidity**: Higher `b` means more liquid markets
4. **No arbitrage**: Prices are always fair based on current state

---

## Usage Examples

### Complete Market Lifecycle

```solidity
// 1. Create market
uint256 marketId = createMarket(usdc, 1000, 10000e6, 100);

// 2. Buy Yes shares
buy(marketId, 0, 100); // Buy 100 Yes shares

// 3. Check prices
uint256 priceYes = getPriceYes(marketId);
uint256 priceNo = getPriceNo(marketId);

// 4. Sell some shares
sell(marketId, 0, 50); // Sell 50 Yes shares

// 5. Resolve market
resolve(marketId, 1); // Yes wins

// 6. Redeem winning shares
redeem(marketId); // Redeem remaining Yes shares
```

### Frontend Integration

```javascript
// Get market info
const marketInfo = await contract.getMarketInfo(marketId);
console.log(`Market ${marketId}:`);
console.log(`Creator: ${marketInfo.creator}`);
console.log(`Collateral: ${marketInfo.collateral}`);
console.log(`State: ${marketInfo.state}`);

// Get current prices
const priceYes = await contract.getPriceYes(marketId);
const priceNo = await contract.getPriceNo(marketId);
console.log(`Yes price: ${priceYes/100}%`);
console.log(`No price: ${priceNo/100}%`);

// Calculate trade cost
const cost = await contract.getBuyCost(marketId, 0, 100);
console.log(`Cost for 100 Yes shares: ${cost/1e6} USDC`);
```

---

## Security Considerations

1. **Reentrancy Protection**: All external functions use `nonReentrant`
2. **Input Validation**: Comprehensive parameter validation
3. **Access Control**: Proper authorization for admin functions
4. **Overflow Protection**: Safe math operations throughout
5. **Decimal Handling**: Automatic detection and scaling

## Gas Optimization

- **Contract Size**: Currently ~25KB (close to 24KB limit)
- **Optimization**: Enable Solidity optimizer for production
- **Library Pattern**: Consider moving ABDKMath64x64 to separate library

## Testing

```bash
# Compile contracts
npx hardhat compile

# Run tests
npx hardhat test

# Deploy to testnet
npx hardhat run scripts/deploy.js --network goerli
```

---

## License

MIT License - See LICENSE file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request

## Support

For questions and support, please open an issue on GitHub.