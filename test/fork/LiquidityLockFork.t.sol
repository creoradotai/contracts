// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {Gauge} from "../../src/Gauge.sol";
import {Launchpad} from "../../src/Launchpad.sol";
import {LaunchSwapRouter} from "../../src/LaunchSwapRouter.sol";
import {LaunchpadToken} from "../../src/LaunchpadToken.sol";
import {LiquidityLock} from "../../src/LiquidityLock.sol";

contract LiquidityLockForkTest is Test {
    Launchpad constant LAUNCHPAD = Launchpad(payable(0xf87eA45bdEd500421BDAEE5bf340dfc27B3d19c7));
    LaunchSwapRouter constant ROUTER = LaunchSwapRouter(payable(0x519226C8935Ff79D958d6f821d5F5B74987Dc8C3));
    Gauge constant CREORAAI_GAUGE = Gauge(payable(0x2C021cc0A421BB49bcFeF2E4aE29826C7dE459e3));
    address constant FEE_WALLET = 0x522391F7FA7bF8D294C7564C470Eb927D3d2A32B;

    address creator = makeAddr("lock-creator");
    address trader = makeAddr("lock-trader");
    address whale = makeAddr("lock-whale");

    IPositionManager positionManager;
    LiquidityLock lock;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        positionManager = Gauge(payable(LAUNCHPAD.gaugeImplementation())).positionManager();
        address deployed = vm.envOr("LIQUIDITY_LOCK", address(0));
        lock = deployed != address(0)
            ? LiquidityLock(payable(deployed))
            : new LiquidityLock(positionManager, LAUNCHPAD.owner(), FEE_WALLET);
        assertEq(address(lock.positionManager()), address(positionManager));
        assertEq(lock.feeWallet(), FEE_WALLET);
        assertEq(lock.owner(), LAUNCHPAD.owner());
        vm.deal(creator, 1 ether);
        vm.deal(trader, 20 ether);
        vm.deal(whale, 100 ether);
    }

    function test_aLiveLaunchGraduatesIntoTheLockAndPaysTheFeeWallet() public {
        vm.prank(LAUNCHPAD.owner());
        LAUNCHPAD.setLpReceiver(address(lock));

        uint256 cost = LAUNCHPAD.creationCost();
        vm.prank(creator);
        (LaunchpadToken token, Gauge gauge) = LAUNCHPAD.createLaunchpadToken{value: cost}(
            LaunchpadToken.TokenConfig({name: "Lock Rehearsal", symbol: "LOCK"}),
            LaunchpadToken.TokenMetadataConfig({ipfsHash: "", website: "", twitter: "", telegram: "", description: "", metadata: ""}),
            Launchpad.AutoSnipeConfig({minAmountOut: 0})
        );
        vm.prank(whale);
        LAUNCHPAD.buyExactEth{value: 10 ether}(address(token), 0);
        assertTrue(gauge.graduated());

        uint256 tokenId = gauge.positionTokenId();
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(lock));
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidity, 0);

        PoolKey memory key = gauge.poolKey();
        vm.startPrank(trader);
        uint256 bought = ROUTER.swapExactIn{value: 1 ether}(key, true, 1 ether, 1, trader, block.timestamp);
        token.approve(address(ROUTER), bought / 2);
        ROUTER.swapExactIn(key, false, bought / 2, 1, trader, block.timestamp);
        vm.stopPrank();

        uint256 ethBefore = FEE_WALLET.balance;
        uint256 tokensBefore = token.balanceOf(FEE_WALLET);
        (uint256 amount0, uint256 amount1) = lock.collectFees(tokenId);
        console2.log("pool fee collected to the fee wallet (wei): eth, tokens", amount0, amount1);
        assertApproxEqRel(amount0, 0.01 ether, 0.02e18);
        assertGt(amount1, 0);
        assertEq(FEE_WALLET.balance - ethBefore, amount0);
        assertEq(token.balanceOf(FEE_WALLET) - tokensBefore, amount1);
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);

        _cannotBeRemoved(tokenId, key, LAUNCHPAD.owner());
    }

    function test_creoraaiCanBeLockedForever() public {
        if (block.chainid != 4663) vm.skip(true);
        uint256 tokenId = CREORAAI_GAUGE.positionTokenId();
        address holder = IERC721(address(positionManager)).ownerOf(tokenId);
        if (holder != address(lock)) {
            assertEq(holder, LAUNCHPAD.owner());
            vm.prank(holder);
            IERC721(address(positionManager)).safeTransferFrom(holder, address(lock), tokenId);
        }
        assertTrue(lock.isLocked(tokenId));

        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        (uint256 amount0, uint256 amount1) = lock.collectFees(tokenId);
        console2.log("CREORAAI fees waiting (wei): eth, tokens", amount0, amount1);
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);

        _cannotBeRemoved(tokenId, CREORAAI_GAUGE.poolKey(), LAUNCHPAD.owner());
    }

    function _cannotBeRemoved(uint256 tokenId, PoolKey memory key, address formerHolder) internal {
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, formerHolder);
        bytes memory removeAll =
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params);

        vm.startPrank(formerHolder);
        vm.expectRevert();
        positionManager.modifyLiquidities(removeAll, block.timestamp);
        vm.expectRevert();
        IERC721(address(positionManager)).transferFrom(address(lock), formerHolder, tokenId);
        vm.stopPrank();
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(lock));
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
    }
}
