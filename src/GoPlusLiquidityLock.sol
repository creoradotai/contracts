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

interface IGoPlusV4Locker {
    struct FeeStruct {
        string name;
        uint256 lpFee;
        uint256 collectFee;
        uint256 lockFee;
        address lockFeeToken;
    }

    function positionManager() external view returns (address);

    function getFee(string memory name) external view returns (FeeStruct memory);

    function isLocked(uint256 lockId) external view returns (bool);

    function lockNFTPosition(
        uint256 tokenId,
        uint256 unlockTime,
        address lockOwner,
        address collector,
        string memory feeName
    ) external payable returns (uint256 lockId);

    function collect(uint256 lockId, address recipient)
        external
        returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1);
}

contract GoPlusLiquidityLock is Ownable2Step, ReentrancyGuardTransient, IERC721Receiver {
    IPositionManager public immutable positionManager;
    IGoPlusV4Locker public immutable locker;
    uint256 public immutable maxLpFee;
    uint256 public immutable maxCollectFee;

    address public feeWallet;
    string public feeName;

    mapping(uint256 tokenId => uint256 lockIdPlusOne) private _locks;

    constructor(
        IPositionManager _positionManager,
        IGoPlusV4Locker _locker,
        address _owner,
        address _feeWallet,
        string memory _feeName,
        uint256 _maxLpFee,
        uint256 _maxCollectFee
    ) Ownable(_owner) {
        if (address(_positionManager) == address(0) || address(_locker) == address(0) || _feeWallet == address(0)) {
            revert GoPlusLiquidityLock__ZeroAddress();
        }
        if (_locker.positionManager() != address(_positionManager)) revert GoPlusLiquidityLock__WrongLocker();
        positionManager = _positionManager;
        locker = _locker;
        maxLpFee = _maxLpFee;
        maxCollectFee = _maxCollectFee;
        feeWallet = _feeWallet;
        emit FeeWalletSet(_feeWallet, address(0));
        _setFeeName(_feeName);
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert GoPlusLiquidityLock__NotPositionManager();
        return IERC721Receiver.onERC721Received.selector;
    }

    function isHeld(uint256 tokenId) public view returns (bool) {
        return IERC721(address(positionManager)).ownerOf(tokenId) == address(this);
    }

    function isLocked(uint256 tokenId) public view returns (bool) {
        uint256 stored = _locks[tokenId];
        return stored != 0 && locker.isLocked(stored - 1);
    }

    function lockIdOf(uint256 tokenId) public view returns (uint256) {
        uint256 stored = _locks[tokenId];
        if (stored == 0) revert GoPlusLiquidityLock__NotLocked();
        return stored - 1;
    }

    function lock(uint256 tokenId) external nonReentrant returns (uint256 lockId) {
        if (!isHeld(tokenId)) revert GoPlusLiquidityLock__NotHeld();
        _checkFee(feeName);
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);
        IERC721(address(positionManager)).approve(address(locker), tokenId);
        lockId = locker.lockNFTPosition(tokenId, type(uint256).max, address(this), address(this), feeName);
        _locks[tokenId] = lockId + 1;
        emit PositionLocked(tokenId, lockId);
        _forward(key.currency0);
        _forward(key.currency1);
    }

    function collectFees(uint256 tokenId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        address to = feeWallet;
        (amount0, amount1,,) = locker.collect(lockIdOf(tokenId), to);
        emit FeesCollected(tokenId, to, amount0, amount1);
    }

    function collectHeldFees(uint256 tokenId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!isHeld(tokenId)) revert GoPlusLiquidityLock__NotHeld();
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
        if (Currency.unwrap(currency) == address(positionManager)) revert GoPlusLiquidityLock__NotSweepable();
        amount = _forward(currency);
    }

    function setFeeWallet(address _feeWallet) external onlyOwner {
        if (_feeWallet == address(0)) revert GoPlusLiquidityLock__ZeroAddress();
        emit FeeWalletSet(_feeWallet, feeWallet);
        feeWallet = _feeWallet;
    }

    function setFeeName(string calldata _feeName) external onlyOwner {
        _setFeeName(_feeName);
    }

    function renounceOwnership() public pure override {
        revert GoPlusLiquidityLock__CannotRenounce();
    }

    function _setFeeName(string memory _feeName) internal {
        _checkFee(_feeName);
        emit FeeNameSet(_feeName, feeName);
        feeName = _feeName;
    }

    function _checkFee(string memory _feeName) internal view {
        IGoPlusV4Locker.FeeStruct memory fee = locker.getFee(_feeName);
        if (fee.lpFee > maxLpFee || fee.collectFee > maxCollectFee || fee.lockFee != 0) {
            revert GoPlusLiquidityLock__FeeTooHigh();
        }
    }

    function _forward(Currency currency) internal returns (uint256 amount) {
        address to = feeWallet;
        amount = currency.balanceOfSelf();
        if (amount > 0) currency.transfer(to, amount);
        emit Swept(currency, to, amount);
    }

    event PositionLocked(uint256 indexed tokenId, uint256 indexed lockId);
    event FeesCollected(uint256 indexed tokenId, address indexed feeWallet, uint256 amount0, uint256 amount1);
    event Swept(Currency indexed currency, address indexed feeWallet, uint256 amount);
    event FeeWalletSet(address newFeeWallet, address oldFeeWallet);
    event FeeNameSet(string newFeeName, string oldFeeName);

    error GoPlusLiquidityLock__ZeroAddress();
    error GoPlusLiquidityLock__WrongLocker();
    error GoPlusLiquidityLock__NotPositionManager();
    error GoPlusLiquidityLock__NotHeld();
    error GoPlusLiquidityLock__NotLocked();
    error GoPlusLiquidityLock__NotSweepable();
    error GoPlusLiquidityLock__CannotRenounce();
    error GoPlusLiquidityLock__FeeTooHigh();
}
