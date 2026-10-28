// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICurve} from "./ICurve.sol";

contract ConstantProductCurve is ICurve {
    uint256 internal constant Q_DENOM = 10_000;

    function checkCompatability(
        uint256 yMin,
        uint256 yMax,
        uint256 xMax,
        uint256 xTotal
    ) public pure returns (bool) {
        return yMax > yMin && yMin > 0 && xMax > 0 && xTotal > xMax;
    }

    function fPrimeX(
        uint256 x,
        uint256 yMin,
        uint256 yMax,
        uint256 xMax,
        uint256 xTotal
    ) public pure returns (uint256) {
        if (!checkCompatability(yMin, yMax, xMax, xTotal))
            revert ICurve__InvalidInput();
        uint256 k = getK(xTotal, xMax, yMax);
        uint256 q = getQ(yMin, yMax);
        return
            Math.mulDiv(
                k,
                1e18,
                (((q * xTotal) / Q_DENOM - x) ** 2),
                Math.Rounding.Floor
            );
    }

    function fX(
        uint256 x,
        uint256 yMin,
        uint256 yMax,
        uint256 xMax,
        uint256 xTotal
    ) public pure returns (uint256) {
        if (!checkCompatability(yMin, yMax, xMax, xTotal))
            revert ICurve__InvalidInput();
        uint256 k = getK(xTotal, xMax, yMax);
        uint256 q = getQ(yMin, yMax);
        return k / ((q * xTotal) / Q_DENOM - x) - k / ((q * xTotal) / Q_DENOM);
    }

    function fY(
        uint256 y,
        uint256 yMin,
        uint256 yMax,
        uint256 xMax,
        uint256 xTotal
    ) public pure returns (uint256) {
        if (!checkCompatability(yMin, yMax, xMax, xTotal))
            revert ICurve__InvalidInput();
        if (y == 0) return 0;
        uint256 k = getK(xTotal, xMax, yMax);
        uint256 q = getQ(yMin, yMax);
        return
            Math.mulDiv(
                ((q * xTotal) / Q_DENOM) ** 2,
                y,
                (q * xTotal * y) / Q_DENOM + k
            );
    }

    function evaluateDx(
        uint256 x1,
        uint256 x2,
        uint256 yMin,
        uint256 yMax,
        uint256 xMax,
        uint256 xTotal
    ) external pure returns (uint256) {
        if (x1 > x2) revert ICurve__InvalidInput();
        return
            fX(x2, yMin, yMax, xMax, xTotal) - fX(x1, yMin, yMax, xMax, xTotal);
    }

    function evaluateDy(
        uint256 y1,
        uint256 y2,
        uint256 yMin,
        uint256 yMax,
        uint256 xMax,
        uint256 xTotal
    ) external pure returns (uint256) {
        if (y1 > y2) revert ICurve__InvalidInput();
        return
            fY(y2, yMin, yMax, xMax, xTotal) - fY(y1, yMin, yMax, xMax, xTotal);
    }

    function getK(
        uint256 xTotal,
        uint256 xMax,
        uint256 yMax
    ) public pure returns (uint256) {
        return Math.mulDiv(xTotal - xMax, (xTotal - xMax) * yMax, 1e18);
    }

    function getQ(uint256 yMin, uint256 yMax) public pure returns (uint256) {
        return (yMax * Q_DENOM) / yMin;
    }
}
