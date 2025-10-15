// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ABDKMath64x64
 * @notice Simplified fixed-point math library for LMSR calculations
 * @dev This is a minimal implementation for educational purposes
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

    /**
     * @notice Simplified exp function using approximation
     * @dev For production use, implement a proper exponential function
     * @param x Input value in 64.64 fixed point format
     * @return Result in 64.64 fixed point format
     */
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

    /**
     * @notice Simplified ln function using approximation
     * @dev For production use, implement a proper natural logarithm function
     * @param x Input value in 64.64 fixed point format (must be positive)
     * @return Result in 64.64 fixed point format
     */
    function ln(int128 x) internal pure returns (int128) {
        require(x > 0);

        // For simplicity, use a basic approximation
        // In production, use a proper implementation
        if (x >= 0x10000000000000000) {
            // x >= 1
            return int128(x - 0x10000000000000000); // x - 1 approximation
        } else {
            return int128(0x10000000000000000 - x); // 1 - x approximation
        }
    }
}
