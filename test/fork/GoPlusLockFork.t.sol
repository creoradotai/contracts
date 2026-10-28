// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {Gauge} from "../../src/Gauge.sol";
import {Launchpad} from "../../src/Launchpad.sol";
import {LaunchSwapRouter} from "../../src/LaunchSwapRouter.sol";
import {LaunchpadToken} from "../../src/LaunchpadToken.sol";
import {GoPlusLiquidityLock, IGoPlusV4Locker} from "../../src/GoPlusLiquidityLock.sol";

interface IGoPlusAdmin {
    struct LockInfo {
        uint256 lockId;
        address pendingOwner;
        address owner;
        address collector;
        uint256 collectFee;
        uint256 lpFee;
        uint256 tokenId;
        PoolKey poolKey;
        uint256 amount;
        uint256 unlockTime;
    }

    function owner() external view returns (address);
    function feeReceiver() external view returns (address);
    function getLockInfo(uint256 lockId) external view returns (LockInfo memory);
    function unlockLiquidity(uint256 lockId) external;
    function decreaseLiquidity(uint256 lockId, uint128 liquidityDecrease, uint256 amount0Min, uint256 amount1Min)
        external
        returns (uint256, uint256);
    function transferLock(uint256 lockId, address newOwner) external;
    function adminRescueTokens(address token, address receiver, uint256 amount) external;
    function addOrUpdateFee(string memory name, uint256 lpFee, uint256 collectFee, uint256 lockFee, address lockFeeToken)
        external;
    function setHookBlacklist(address hook, bool blacklisted) external;
}

contract GoPlusLockForkTest is Test {
    Launchpad constant LAUNCHPAD = Launchpad(payable(0xf87eA45bdEd500421BDAEE5bf340dfc27B3d19c7));
    LaunchSwapRouter constant ROUTER = LaunchSwapRouter(payable(0x519226C8935Ff79D958d6f821d5F5B74987Dc8C3));
    IGoPlusV4Locker constant GOPLUS = IGoPlusV4Locker(0xCb07c2fcd64c71cDb7f77a880662435f5F790b77);
    address constant FEE_WALLET = 0x522391F7FA7bF8D294C7564C470Eb927D3d2A32B;

    address creator = makeAddr("goplus-creator");
    address trader = makeAddr("goplus-trader");
    address whale = makeAddr("goplus-whale");
    address stranger = makeAddr("goplus-stranger");

    IPositionManager positionManager;
    GoPlusLiquidityLock lock;
    IGoPlusAdmin admin = IGoPlusAdmin(address(GOPLUS));

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        if (block.chainid != 4663) vm.skip(true);
        positionManager = Gauge(payable(LAUNCHPAD.gaugeImplementation())).positionManager();
        address deployed = vm.envOr("GOPLUS_LOCK", address(0));
        lock = deployed != address(0)
            ? GoPlusLiquidityLock(payable(deployed))
            : new GoPlusLiquidityLock(positionManager, GOPLUS, LAUNCHPAD.owner(), FEE_WALLET, "LVP", 64, 80);
        assertEq(address(lock.positionManager()), address(positionManager));
        assertEq(lock.feeWallet(), FEE_WALLET);
        assertEq(lock.feeName(), "LVP");
        vm.deal(creator, 1 ether);
        vm.deal(trader, 20 ether);
        vm.deal(whale, 100 ether);
    }

    function _graduate() internal returns (LaunchpadToken token, Gauge gauge, uint256 tokenId) {
        vm.prank(LAUNCHPAD.owner());
        LAUNCHPAD.setLpReceiver(address(lock));
        uint256 cost = LAUNCHPAD.creationCost();
        vm.prank(creator);
        (token, gauge) = LAUNCHPAD.createLaunchpadToken{value: cost}(
            LaunchpadToken.TokenConfig({name: "GoPlus Rehearsal", symbol: "GPLK"}),
            LaunchpadToken.TokenMetadataConfig({ipfsHash: "", website: "", twitter: "", telegram: "", description: "", metadata: ""}),
            Launchpad.AutoSnipeConfig({minAmountOut: 0})
        );
        vm.prank(whale);
        LAUNCHPAD.buyExactEth{value: 10 ether}(address(token), 0);
        assertTrue(gauge.graduated());
        tokenId = gauge.positionTokenId();
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(lock));
    }

    function test_aGraduationLocksIntoGoPlusForeverAndPaysTheFeeWallet() public {
        (LaunchpadToken token, Gauge gauge, uint256 tokenId) = _graduate();
        uint128 before = positionManager.getPositionLiquidity(tokenId);

        vm.prank(stranger);
        uint256 lockId = lock.lock(tokenId);

        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(GOPLUS));
        assertTrue(GOPLUS.isLocked(lockId));
        assertTrue(lock.isLocked(tokenId));
        assertEq(lock.lockIdOf(tokenId), lockId);
        IGoPlusAdmin.LockInfo memory info = admin.getLockInfo(lockId);
        assertEq(info.owner, address(lock));
        assertEq(info.pendingOwner, address(0));
        assertEq(info.unlockTime, type(uint256).max);
        assertEq(info.collectFee, 80);
        assertEq(info.lpFee, 64);
        assertEq(info.collector, address(lock));
        assertEq(info.tokenId, tokenId);
        uint128 kept = positionManager.getPositionLiquidity(tokenId);
        assertEq(uint256(kept), uint256(before) - (uint256(before) * 64) / 10_000);
        console2.log("liquidity kept after the GoPlus lock fee (of 10000)", uint256(kept) * 10_000 / before);

        PoolKey memory key = gauge.poolKey();
        vm.startPrank(trader);
        uint256 bought = ROUTER.swapExactIn{value: 1 ether}(key, true, 1 ether, 1, trader, block.timestamp);
        token.approve(address(ROUTER), bought / 2);
        ROUTER.swapExactIn(key, false, bought / 2, 1, trader, block.timestamp);
        vm.stopPrank();

        uint256 ethBefore = FEE_WALLET.balance;
        uint256 tokensBefore = token.balanceOf(FEE_WALLET);
        vm.prank(stranger);
        (uint256 amount0, uint256 amount1) = lock.collectFees(tokenId);
        console2.log("fees to the Creora wallet (wei): eth, tokens", amount0, amount1);
        assertApproxEqRel(amount0, 0.01 ether * 9920 / 10_000, 0.02e18);
        assertGt(amount1, 0);
        assertEq(FEE_WALLET.balance - ethBefore, amount0);
        assertEq(token.balanceOf(FEE_WALLET) - tokensBefore, amount1);
        assertEq(positionManager.getPositionLiquidity(tokenId), kept);

        _cannotBeRemoved(tokenId, lockId, key);
    }

    function _cannotBeRemoved(uint256 tokenId, uint256 lockId, PoolKey memory key) internal {
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        vm.prank(address(lock));
        vm.expectRevert();
        admin.unlockLiquidity(lockId);
        vm.prank(address(lock));
        vm.expectRevert();
        admin.decreaseLiquidity(lockId, liquidity, 0, 0);

        vm.warp(type(uint64).max);
        vm.prank(address(lock));
        vm.expectRevert();
        admin.unlockLiquidity(lockId);
        vm.prank(address(lock));
        vm.expectRevert();
        admin.decreaseLiquidity(lockId, liquidity, 0, 0);

        address goplusOwner = admin.owner();
        vm.startPrank(goplusOwner);
        vm.expectRevert();
        admin.adminRescueTokens(address(positionManager), goplusOwner, tokenId);
        vm.expectRevert();
        admin.unlockLiquidity(lockId);
        vm.expectRevert();
        admin.transferLock(lockId, goplusOwner);
        vm.stopPrank();

        address launchpadOwner = LAUNCHPAD.owner();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, launchpadOwner);
        bytes memory removeAll =
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params);
        for (uint256 i; i < 3; i++) {
            address who = i == 0 ? launchpadOwner : i == 1 ? goplusOwner : address(lock);
            vm.startPrank(who);
            vm.expectRevert();
            positionManager.modifyLiquidities(removeAll, block.timestamp);
            vm.expectRevert();
            IERC721(address(positionManager)).transferFrom(address(GOPLUS), who, tokenId);
            vm.stopPrank();
        }

        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(GOPLUS));
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
        assertEq(admin.getLockInfo(lockId).owner, address(lock));
    }

    function test_refusesToLockWhenGoPlusRaisesTheFee() public {
        (,, uint256 tokenId) = _graduate();
        vm.prank(admin.owner());
        admin.addOrUpdateFee("LVP", 500, 500, 0, address(0));
        vm.expectRevert(GoPlusLiquidityLock.GoPlusLiquidityLock__FeeTooHigh.selector);
        lock.lock(tokenId);
        assertTrue(lock.isHeld(tokenId));
    }

    function test_aBlacklistedHookLeavesThePositionHeldAndItsFeesCollectable() public {
        (, Gauge gauge, uint256 tokenId) = _graduate();
        PoolKey memory key = gauge.poolKey();
        vm.prank(admin.owner());
        admin.setHookBlacklist(address(key.hooks), true);
        vm.expectRevert();
        lock.lock(tokenId);
        assertTrue(lock.isHeld(tokenId));

        vm.prank(trader);
        ROUTER.swapExactIn{value: 1 ether}(key, true, 1 ether, 1, trader, block.timestamp);
        uint256 ethBefore = FEE_WALLET.balance;
        (uint256 amount0,) = lock.collectHeldFees(tokenId);
        assertApproxEqRel(amount0, 0.01 ether, 0.02e18);
        assertEq(FEE_WALLET.balance - ethBefore, amount0);
        assertTrue(lock.isHeld(tokenId));
    }

    function test_onlyTheOwnerChangesSettingsAndOwnershipStays() public {
        vm.prank(stranger);
        vm.expectRevert();
        lock.setFeeWallet(stranger);
        vm.prank(stranger);
        vm.expectRevert();
        lock.setFeeName("LLP");
        vm.prank(LAUNCHPAD.owner());
        vm.expectRevert(GoPlusLiquidityLock.GoPlusLiquidityLock__FeeTooHigh.selector);
        lock.setFeeName("LLP");
        vm.prank(LAUNCHPAD.owner());
        vm.expectRevert(GoPlusLiquidityLock.GoPlusLiquidityLock__CannotRenounce.selector);
        lock.renounceOwnership();
        vm.expectRevert(GoPlusLiquidityLock.GoPlusLiquidityLock__NotSweepable.selector);
        lock.sweep(Currency.wrap(address(positionManager)));
    }
}
