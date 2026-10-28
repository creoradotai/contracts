// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

contract LiquidityLock is Ownable2Step, ReentrancyGuardTransient, IERC721Receiver {
    IPositionManager public immutable positionManager;

    address public feeWallet;

    constructor(IPositionManager _positionManager, address _owner, address _feeWallet) Ownable(_owner) {
        if (address(_positionManager) == address(0) || _feeWallet == address(0)) revert LiquidityLock__ZeroAddress();
        positionManager = _positionManager;
        feeWallet = _feeWallet;
        emit FeeWalletSet(_feeWallet, address(0));
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert LiquidityLock__NotPositionManager();
        return IERC721Receiver.onERC721Received.selector;
    }

    function isLocked(uint256 tokenId) public view returns (bool) {
        return IERC721(address(positionManager)).ownerOf(tokenId) == address(this);
    }

    function collectFees(uint256 tokenId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!isLocked(tokenId)) revert LiquidityLock__NotLocked();
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);
        address to = feeWallet;
        uint256 before0 = key.currency0.balanceOf(to);
        uint256 before1 = key.currency1.balanceOf(to);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, to);
        positionManager.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params),
            block.timestamp
        );

        amount0 = key.currency0.balanceOf(to) - before0;
        amount1 = key.currency1.balanceOf(to) - before1;
        emit FeesCollected(tokenId, to, amount0, amount1);
    }

    function sweep(Currency currency) external nonReentrant returns (uint256 amount) {
        if (Currency.unwrap(currency) == address(positionManager)) revert LiquidityLock__NotSweepable();
        address to = feeWallet;
        amount = currency.balanceOfSelf();
        if (amount > 0) currency.transfer(to, amount);
        emit Swept(currency, to, amount);
    }

    function setFeeWallet(address _feeWallet) external onlyOwner {
        if (_feeWallet == address(0)) revert LiquidityLock__ZeroAddress();
        emit FeeWalletSet(_feeWallet, feeWallet);
        feeWallet = _feeWallet;
    }

    function renounceOwnership() public pure override {
        revert LiquidityLock__CannotRenounce();
    }

    event FeesCollected(uint256 indexed tokenId, address indexed feeWallet, uint256 amount0, uint256 amount1);
    event Swept(Currency indexed currency, address indexed feeWallet, uint256 amount);
    event FeeWalletSet(address newFeeWallet, address oldFeeWallet);

    error LiquidityLock__ZeroAddress();
    error LiquidityLock__NotPositionManager();
    error LiquidityLock__NotLocked();
    error LiquidityLock__NotSweepable();
    error LiquidityLock__CannotRenounce();
}
