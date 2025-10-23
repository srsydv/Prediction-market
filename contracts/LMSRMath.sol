// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title LMSRMath
 * @notice True LMSR mathematical functions with proper exponential and logarithmic calculations
 * @dev Implements the standard LMSR formulas:
 *      Cost: C(q) = b * ln(sum(e^(q_i / b)))
 *      Price: P_i = e^(q_i / b) / sum(e^(q_j / b))
 */
library LMSRMath {
    // Fixed point precision constants
    uint256 constant PRECISION = 1e18;
    uint256 constant LN_PRECISION = 1e12;
    uint256 constant EXP_PRECISION = 1e12;
    
    // Mathematical constants
    int256 constant LN_2 = 6931471805599453094; // ln(2) * 1e18
    int256 constant LN_10 = 2302585092994045684; // ln(10) * 1e18
    int256 constant E = 2718281828459045235; // e * 1e18
    
    /**
     * @notice Calculate the true LMSR cost function
     * @param b Liquidity parameter
     * @param qYes Quantity of Yes shares
     * @param qNo Quantity of No shares
     * @return Cost in fixed point format
     */
    function calculateCost(
        uint256 b,
        uint256 qYes,
        uint256 qNo
    ) internal pure returns (uint256) {
        if (b == 0) return 0;
        
        // Calculate e^(qYes/b) and e^(qNo/b)
        uint256 expYes = qYes == 0 ? PRECISION : exp(qYes * PRECISION / b);
        uint256 expNo = qNo == 0 ? PRECISION : exp(qNo * PRECISION / b);
        
        // Sum of exponentials
        uint256 sumExp = expYes + expNo;
        
        // Calculate b * ln(sumExp)
        uint256 lnSum = ln(sumExp);
        return (b * lnSum) / PRECISION;
    }
    
    /**
     * @notice Calculate the price of Yes shares using true LMSR
     * @param b Liquidity parameter
     * @param qYes Quantity of Yes shares
     * @param qNo Quantity of No shares
     * @return Price as a fraction (0 to PRECISION)
     */
    function calculatePriceYes(
        uint256 b,
        uint256 qYes,
        uint256 qNo
    ) internal pure returns (uint256) {
        if (b == 0) return PRECISION / 2; // 50% if no liquidity
        
        // Calculate e^(qYes/b) and e^(qNo/b)
        uint256 expYes = qYes == 0 ? PRECISION : exp(qYes * PRECISION / b);
        uint256 expNo = qNo == 0 ? PRECISION : exp(qNo * PRECISION / b);
        
        // Calculate price = e^(qYes/b) / (e^(qYes/b) + e^(qNo/b))
        uint256 sumExp = expYes + expNo;
        return (expYes * PRECISION) / sumExp;
    }
    
    /**
     * @notice Calculate the price of No shares using true LMSR
     * @param b Liquidity parameter
     * @param qYes Quantity of Yes shares
     * @param qNo Quantity of No shares
     * @return Price as a fraction (0 to PRECISION)
     */
    function calculatePriceNo(
        uint256 b,
        uint256 qYes,
        uint256 qNo
    ) internal pure returns (uint256) {
        if (b == 0) return PRECISION / 2; // 50% if no liquidity
        
        // Calculate e^(qYes/b) and e^(qNo/b)
        uint256 expYes = qYes == 0 ? PRECISION : exp(qYes * PRECISION / b);
        uint256 expNo = qNo == 0 ? PRECISION : exp(qNo * PRECISION / b);
        
        // Calculate price = e^(qNo/b) / (e^(qYes/b) + e^(qNo/b))
        uint256 sumExp = expYes + expNo;
        return (expNo * PRECISION) / sumExp;
    }
    
    /**
     * @notice Calculate the cost of buying shares
     * @param b Liquidity parameter
     * @param qYesBefore Current Yes shares
     * @param qNoBefore Current No shares
     * @param qYesAfter New Yes shares
     * @param qNoAfter New No shares
     * @return Cost difference
     */
    function calculateBuyCost(
        uint256 b,
        uint256 qYesBefore,
        uint256 qNoBefore,
        uint256 qYesAfter,
        uint256 qNoAfter
    ) internal pure returns (uint256) {
        uint256 costBefore = calculateCost(b, qYesBefore, qNoBefore);
        uint256 costAfter = calculateCost(b, qYesAfter, qNoAfter);
        
        if (costAfter > costBefore) {
            return costAfter - costBefore;
        }
        return 0;
    }
    
    /**
     * @notice Calculate the refund from selling shares
     * @param b Liquidity parameter
     * @param qYesBefore Current Yes shares
     * @param qNoBefore Current No shares
     * @param qYesAfter New Yes shares
     * @param qNoAfter New No shares
     * @return Refund amount
     */
    function calculateSellRefund(
        uint256 b,
        uint256 qYesBefore,
        uint256 qNoBefore,
        uint256 qYesAfter,
        uint256 qNoAfter
    ) internal pure returns (uint256) {
        uint256 costBefore = calculateCost(b, qYesBefore, qNoBefore);
        uint256 costAfter = calculateCost(b, qYesAfter, qNoAfter);
        
        if (costBefore > costAfter) {
            return costBefore - costAfter;
        }
        return 0;
    }
    
    /**
     * @notice Calculate exponential function e^x using Taylor series
     * @param x Input value in fixed point format
     * @return e^x in fixed point format
     */
    function exp(uint256 x) internal pure returns (uint256) {
        if (x == 0) return PRECISION;
        
        // Handle negative values
        bool isNegative = x > PRECISION;
        if (isNegative) {
            x = PRECISION - (x - PRECISION);
        }
        
        // Scale down to prevent overflow
        x = x / EXP_PRECISION;
        
        uint256 result = PRECISION;
        uint256 term = PRECISION;
        
        // Taylor series: e^x = 1 + x + x²/2! + x³/3! + ...
        for (uint256 i = 1; i <= 20; i++) {
            term = (term * x) / PRECISION / i;
            result += term;
            
            // Stop if term becomes too small
            if (term < 1) break;
        }
        
        // Handle negative case
        if (isNegative) {
            result = (PRECISION * PRECISION) / result;
        }
        
        return result;
    }
    
    /**
     * @notice Calculate natural logarithm using Newton's method
     * @param x Input value in fixed point format
     * @return ln(x) in fixed point format
     */
    function ln(uint256 x) internal pure returns (uint256) {
        if (x == 0) revert("ln(0) undefined");
        if (x == PRECISION) return 0;
        
        // Scale down to prevent overflow
        x = x / LN_PRECISION;
        
        // Initial guess
        uint256 y = x;
        
        // Newton's method: y = y - (e^y - x) / e^y
        for (uint256 i = 0; i < 10; i++) {
            uint256 ey = exp(y);
            if (ey == 0) break;
            
            uint256 numerator = ey > x ? ey - x : x - ey;
            uint256 denominator = ey;
            
            if (numerator < denominator / 1000) break; // Converged
            
            uint256 correction = (numerator * PRECISION) / denominator;
            if (ey > x) {
                y = y > correction ? y - correction : 0;
            } else {
                y = y + correction;
            }
        }
        
        return y;
    }
    
    /**
     * @notice Convert fixed point to percentage (0-100)
     * @param price Fixed point price
     * @return Percentage value
     */
    function toPercentage(uint256 price) internal pure returns (uint256) {
        return (price * 100) / PRECISION;
    }
    
    /**
     * @notice Convert percentage to fixed point
     * @param percentage Percentage value (0-100)
     * @return Fixed point price
     */
    function fromPercentage(uint256 percentage) internal pure returns (uint256) {
        return (percentage * PRECISION) / 100;
    }
}
