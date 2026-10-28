// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract LaunchSwapRouter is IUnlockCallback {
    IPoolManager public immutable poolManager;

    struct SwapData {
        address recipient;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
    }

    event Swapped(
        address indexed payer,
        address indexed recipient,
        address indexed token,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    );

    error NotPoolManager();
    error Expired();
    error ZeroAmount();
    error WrongValue();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error TransferFailed();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        if (msg.value != (zeroForOne ? amountIn : 0)) revert WrongValue();

        IERC20Minimal token = IERC20Minimal(Currency.unwrap(key.currency1));
        if (!zeroForOne && !token.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();

        bytes memory result = poolManager.unlock(abi.encode(SwapData(recipient, key, zeroForOne, amountIn)));
        amountOut = abi.decode(result, (uint256));
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        if (zeroForOne) {
            if (address(this).balance > 0) {
                (bool ok,) = payable(msg.sender).call{value: address(this).balance}("");
                if (!ok) revert TransferFailed();
            }
        } else {
            uint256 left = token.balanceOf(address(this));
            if (left > 0 && !token.transfer(msg.sender, left)) revert TransferFailed();
        }

        emit Swapped(msg.sender, recipient, Currency.unwrap(key.currency1), zeroForOne, amountIn, amountOut);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        SwapData memory data = abi.decode(rawData, (SwapData));

        BalanceDelta delta = poolManager.swap(
            data.key,
            SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: -int256(data.amountIn),
                sqrtPriceLimitX96: data.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        uint256 amountOut;
        if (data.zeroForOne) {
            uint256 owed = uint256(uint128(-delta.amount0()));
            poolManager.settle{value: owed}();
            amountOut = uint256(uint128(delta.amount1()));
            poolManager.take(data.key.currency1, data.recipient, amountOut);
        } else {
            uint256 owed = uint256(uint128(-delta.amount1()));
            poolManager.sync(data.key.currency1);
            if (!IERC20Minimal(Currency.unwrap(data.key.currency1)).transfer(address(poolManager), owed)) revert TransferFailed();
            poolManager.settle();
            amountOut = uint256(uint128(delta.amount0()));
            poolManager.take(data.key.currency0, data.recipient, amountOut);
        }
        return abi.encode(amountOut);
    }
}
