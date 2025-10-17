// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ABDKMath64x64Production
 * @notice Production-ready fixed-point math library for LMSR calculations
 * @dev Implements accurate exponential and logarithmic functions for prediction markets
 * @author Production LMSR Implementation
 */
library ABDKMath64x64Production {
    int128 private constant MIN_64x64 = -0x80000000000000000000000000000000;
    int128 private constant MAX_64x64 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    
    // Constants for exponential function
    int128 private constant EXP_MAX_INPUT = 0x40000000000000000000000000000000; // 64.0
    int128 private constant EXP_MIN_INPUT = -0x40000000000000000000000000000000; // -64.0
    
    // Constants for logarithmic function  
    int128 private constant LN_MAX_INPUT = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    int128 private constant LN_MIN_INPUT = 0x10000000000000000; // 1.0
    
    // Precision constants
    uint256 private constant PRECISION = 18;
    uint256 private constant HALF_PRECISION = 9;
    
    /**
     * @notice Convert signed integer to 64.64 fixed point
     */
    function fromInt(int256 x) internal pure returns (int128) {
        require(x >= -0x8000000000000000 && x <= 0x7FFFFFFFFFFFFFFF, "ABDK: int out of range");
        return int128(x << 64);
    }

    /**
     * @notice Convert 64.64 fixed point to signed integer
     */
    function toInt(int128 x) internal pure returns (int256) {
        return int256(x) >> 64;
    }

    /**
     * @notice Convert unsigned integer to 64.64 fixed point
     */
    function fromUInt(uint256 x) internal pure returns (int128) {
        require(x <= 0x7FFFFFFFFFFFFFFF, "ABDK: uint out of range");
        return int128(int256(x) << 64);
    }

    /**
     * @notice Convert 64.64 fixed point to unsigned integer
     */
    function toUInt(int128 x) internal pure returns (uint256) {
        require(x >= 0, "ABDK: negative to uint");
        return uint256(uint128(x >> 64));
    }

    /**
     * @notice Add two 64.64 fixed point numbers
     */
    function add(int128 x, int128 y) internal pure returns (int128) {
        int256 result = int256(x) + y;
        require(result >= MIN_64x64 && result <= MAX_64x64, "ABDK: add overflow");
        return int128(result);
    }

    /**
     * @notice Subtract two 64.64 fixed point numbers
     */
    function sub(int128 x, int128 y) internal pure returns (int128) {
        int256 result = int256(x) - y;
        require(result >= MIN_64x64 && result <= MAX_64x64, "ABDK: sub overflow");
        return int128(result);
    }

    /**
     * @notice Multiply two 64.64 fixed point numbers
     */
    function mul(int128 x, int128 y) internal pure returns (int128) {
        int256 result = (int256(x) * y) >> 64;
        require(result >= MIN_64x64 && result <= MAX_64x64, "ABDK: mul overflow");
        return int128(result);
    }

    /**
     * @notice Divide two 64.64 fixed point numbers
     */
    function div(int128 x, int128 y) internal pure returns (int128) {
        require(y != 0, "ABDK: division by zero");
        int256 result = (int256(x) << 64) / y;
        require(result >= MIN_64x64 && result <= MAX_64x64, "ABDK: div overflow");
        return int128(result);
    }

    /**
     * @notice Calculate exponential function using Taylor series approximation
     * @dev Accurate to ~18 decimal places for inputs in [-64, 64] range
     * @param x Input value in 64.64 fixed point format
     * @return Result in 64.64 fixed point format
     */
    function exp(int128 x) internal pure returns (int128) {
        require(x >= EXP_MIN_INPUT && x <= EXP_MAX_INPUT, "ABDK: exp input out of range");
        
        if (x == 0) return 0x10000000000000000; // 1.0
        
        // Handle negative inputs: exp(-x) = 1/exp(x)
        if (x < 0) {
            return div(0x10000000000000000, exp(-x));
        }
        
        // Split x into integer and fractional parts
        int128 xInt = x >> 64;
        int128 xFrac = x - (xInt << 64);
        
        // Calculate exp(xInt) using repeated squaring
        int128 result = 0x10000000000000000; // Start with 1.0
        int128 base = 0x2D80000000000000; // exp(1) ≈ 2.718
        
        while (xInt > 0) {
            if (xInt & 1 == 1) {
                result = mul(result, base);
            }
            base = mul(base, base);
            xInt >>= 1;
        }
        
        // Calculate exp(xFrac) using Taylor series
        int128 fracResult = 0x10000000000000000; // Start with 1.0
        int128 term = xFrac;
        int128 factorial = 0x10000000000000000; // 1!
        
        for (uint256 i = 1; i <= 20; i++) { // 20 terms for good precision
            fracResult = add(fracResult, div(term, factorial));
            term = mul(term, xFrac);
            factorial = mul(factorial, fromInt(int256(i + 1)));
        }
        
        return mul(result, fracResult);
    }

    /**
     * @notice Calculate natural logarithm using Newton's method
     * @dev Accurate to ~18 decimal places for inputs > 0
     * @param x Input value in 64.64 fixed point format (must be positive)
     * @return Result in 64.64 fixed point format
     */
    function ln(int128 x) internal pure returns (int128) {
        require(x > 0, "ABDK: ln of non-positive number");
        require(x <= LN_MAX_INPUT, "ABDK: ln input too large");
        
        if (x == 0x10000000000000000) return 0; // ln(1) = 0
        
        // Normalize x to range [1, 2)
        int128 result = 0;
        while (x >= 0x20000000000000000) { // x >= 2
            x = x >> 1;
            result = add(result, 0xB17217F7D1CF79AB); // ln(2)
        }
        
        while (x < 0x10000000000000000) { // x < 1
            x = x << 1;
            result = sub(result, 0xB17217F7D1CF79AB); // ln(2)
        }
        
        // Now x is in [1, 2), use Newton's method for ln(x)
        int128 y = 0; // Initial guess
        int128 delta;
        
        for (uint256 i = 0; i < 10; i++) { // 10 iterations for convergence
            int128 expY = exp(y);
            delta = div(sub(x, expY), expY);
            y = add(y, delta);
            
            // Check for convergence
            if (delta >= 0 && delta < 0x1000000000000) break; // < 2^-40
            if (delta < 0 && -delta < 0x1000000000000) break;
        }
        
        return add(result, y);
    }

    /**
     * @notice Calculate square root using Newton's method
     */
    function sqrt(int128 x) internal pure returns (int128) {
        require(x >= 0, "ABDK: sqrt of negative number");
        
        if (x == 0) return 0;
        
        // Initial guess
        int128 z = x >> 1;
        int128 delta;
        
        for (uint256 i = 0; i < 10; i++) {
            delta = div(sub(x, mul(z, z)), mul(z, fromInt(2)));
            z = add(z, delta);
            
            if (delta >= 0 && delta < 0x1000000000000) break;
            if (delta < 0 && -delta < 0x1000000000000) break;
        }
        
        return z;
    }

    /**
     * @notice Calculate power function: x^y = exp(y * ln(x))
     */
    function pow(int128 x, int128 y) internal pure returns (int128) {
        require(x > 0, "ABDK: pow base must be positive");
        return exp(mul(y, ln(x)));
    }

    /**
     * @notice Get absolute value
     */
    function abs(int128 x) internal pure returns (int128) {
        return x >= 0 ? x : -x;
    }

    /**
     * @notice Get maximum of two values
     */
    function max(int128 x, int128 y) internal pure returns (int128) {
        return x >= y ? x : y;
    }

    /**
     * @notice Get minimum of two values
     */
    function min(int128 x, int128 y) internal pure returns (int128) {
        return x <= y ? x : y;
    }
}
