// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {CreoraCcipSteps} from "../../script/CreoraCcip.s.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/contracts/pools/BurnMintTokenPool.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/LockReleaseTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {IRouter} from "@chainlink/contracts-ccip/contracts/interfaces/IRouter.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {Pool} from "@chainlink/contracts-ccip/contracts/libraries/Pool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";
import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

contract CreoraCcipForkTest is Test, CreoraCcipSteps {
    address constant OWNER = 0x352f39197C0d82bB5bAb35ADcb9548E4665b0072;
    address constant ROBINHOOD_ONRAMP = 0xE86CeddDAEfa1999AaE234C056B51877BFfBD73f;
    address constant ARBITRUM_OFFRAMP = 0xD4ad79ed3372460F1e63Feb8fC41C3b757198C6e;
    address constant ARBITRUM_ONRAMP = 0x7B73923E101950eFe098C2Eca74C8320b2813f48;
    address constant ROBINHOOD_OFFRAMP = 0x5060De90b723a7Eb705742Ff1a22a908b1D8b626;

    uint256 robinhoodFork;
    uint256 arbitrumFork;

    address deployer = makeAddr("ccip-deployer");
    address holder = makeAddr("ccip-holder");
    address friend = makeAddr("ccip-friend");
    address stranger = makeAddr("ccip-stranger");

    LockReleaseTokenPool homePool;
    BurnMintERC20 arbToken;
    BurnMintTokenPool arbPool;

    function setUp() public {
        string memory robinhoodRpc = vm.envOr("ROBINHOOD_RPC", string(""));
        string memory arbitrumRpc = vm.envOr("ARBITRUM_RPC", string(""));
        if (bytes(robinhoodRpc).length == 0 || bytes(arbitrumRpc).length == 0) vm.skip(true);
        robinhoodFork = vm.createFork(robinhoodRpc);
        arbitrumFork = vm.createFork(arbitrumRpc);

        vm.selectFork(robinhoodFork);
        vm.startPrank(deployer);
        homePool = deployRobinhoodPool();
        vm.stopPrank();

        vm.selectFork(arbitrumFork);
        vm.startPrank(deployer);
        (arbToken, arbPool) = deployArbitrum(address(homePool), OWNER, deployer);
        vm.stopPrank();

        vm.selectFork(robinhoodFork);
        vm.startPrank(deployer);
        connectRobinhood(homePool, address(arbPool), address(arbToken), OWNER);
        vm.stopPrank();
    }

    function registerHome() internal {
        vm.selectFork(robinhoodFork);
        TokenAdminRegistry registry = TokenAdminRegistry(robinhood().registry);
        vm.prank(registry.owner());
        registry.proposeAdministrator(CREORA, OWNER);
        vm.startPrank(OWNER);
        registry.acceptAdminRole(CREORA);
        registry.setPool(CREORA, address(homePool));
        homePool.acceptOwnership();
        vm.stopPrank();

        vm.selectFork(arbitrumFork);
        vm.startPrank(OWNER);
        TokenAdminRegistry(arbitrum().registry).acceptAdminRole(address(arbToken));
        arbPool.acceptOwnership();
        vm.stopPrank();
    }

    function message(address token, uint256 amount, address to) internal pure returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[] memory amounts = new Client.EVMTokenAmount[](1);
        amounts[0] = Client.EVMTokenAmount({token: token, amount: amount});
        return Client.EVM2AnyMessage({
            receiver: abi.encode(to),
            data: "",
            tokenAmounts: amounts,
            feeToken: address(0),
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 0, allowOutOfOrderExecution: true}))
        });
    }

    function send(Network memory from, uint64 to, address token, address sender, address receiver, uint256 amount)
        internal
        returns (uint256 fee)
    {
        Client.EVM2AnyMessage memory out = message(token, amount, receiver);
        fee = IRouterClient(from.router).getFee(to, out);
        vm.deal(sender, sender.balance + fee);
        vm.startPrank(sender);
        IERC20(token).approve(from.router, amount);
        IRouterClient(from.router).ccipSend{value: fee}(to, out);
        vm.stopPrank();
    }

    function deliver(
        TokenPool pool,
        address offRamp,
        uint64 sourceSelector,
        address sourcePool,
        address token,
        address sender,
        address receiver,
        uint256 amount
    ) internal {
        vm.prank(offRamp);
        pool.releaseOrMint(
            Pool.ReleaseOrMintInV1({
                originalSender: abi.encode(sender),
                remoteChainSelector: sourceSelector,
                receiver: receiver,
                sourceDenominatedAmount: amount,
                localToken: token,
                sourcePoolAddress: abi.encode(sourcePool),
                sourcePoolData: abi.encode(uint256(DECIMALS)),
                offchainTokenData: ""
            })
        );
    }

    function test_rampsMatchChainlinksDirectory() public {
        vm.selectFork(robinhoodFork);
        assertEq(IRouter(robinhood().router).getOnRamp(arbitrum().selector), ROBINHOOD_ONRAMP);
        assertTrue(IRouter(robinhood().router).isOffRamp(arbitrum().selector, ROBINHOOD_OFFRAMP));
        assertTrue(IRouterClient(robinhood().router).isChainSupported(arbitrum().selector));
        vm.selectFork(arbitrumFork);
        assertEq(IRouter(arbitrum().router).getOnRamp(robinhood().selector), ARBITRUM_ONRAMP);
        assertTrue(IRouter(arbitrum().router).isOffRamp(robinhood().selector, ARBITRUM_OFFRAMP));
        assertTrue(IRouterClient(arbitrum().router).isChainSupported(robinhood().selector));
    }

    function test_setUpLeavesEverythingToTheOwner() public {
        vm.selectFork(arbitrumFork);
        TokenAdminRegistry arbRegistry = TokenAdminRegistry(arbitrum().registry);
        TokenAdminRegistry.TokenConfig memory config = arbRegistry.getTokenConfig(address(arbToken));
        assertEq(config.administrator, deployer, "admin until the owner accepts");
        assertEq(config.pendingAdministrator, OWNER);
        assertEq(config.tokenPool, address(arbPool));
        assertEq(arbToken.getCCIPAdmin(), OWNER);
        assertTrue(arbToken.hasRole(arbToken.DEFAULT_ADMIN_ROLE(), OWNER));
        assertFalse(arbToken.hasRole(arbToken.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(arbToken.hasRole(arbToken.MINTER_ROLE(), address(arbPool)));
        assertTrue(arbToken.hasRole(arbToken.BURNER_ROLE(), address(arbPool)));
        assertEq(arbToken.maxSupply(), MAX_SUPPLY);
        assertEq(arbToken.totalSupply(), 0);
        assertEq(arbToken.decimals(), 18);
        assertEq(arbToken.symbol(), "CREORA");
        assertEq(arbPool.owner(), deployer);
        assertTrue(arbPool.isRemotePool(robinhood().selector, abi.encode(address(homePool))));
        assertEq(arbPool.getRemoteToken(robinhood().selector), abi.encode(CREORA));

        vm.selectFork(robinhoodFork);
        assertEq(address(homePool.getToken()), CREORA);
        assertEq(homePool.getRebalancer(), address(0));
        assertEq(homePool.owner(), deployer);
        assertTrue(homePool.isRemotePool(arbitrum().selector, abi.encode(address(arbPool))));
        assertEq(homePool.getRemoteToken(arbitrum().selector), abi.encode(address(arbToken)));
        RateLimiter.TokenBucket memory outbound = homePool.getCurrentOutboundRateLimiterState(arbitrum().selector);
        assertTrue(outbound.isEnabled);
        assertEq(outbound.capacity, OUTBOUND_CAPACITY);
        assertEq(outbound.rate, OUTBOUND_RATE);

        registerHome();

        vm.selectFork(robinhoodFork);
        TokenAdminRegistry homeRegistry = TokenAdminRegistry(robinhood().registry);
        config = homeRegistry.getTokenConfig(CREORA);
        assertEq(config.administrator, OWNER);
        assertEq(config.tokenPool, address(homePool));
        assertEq(homePool.owner(), OWNER);
        vm.selectFork(arbitrumFork);
        assertEq(arbRegistry.getTokenConfig(address(arbToken)).administrator, OWNER);
        assertEq(arbPool.owner(), OWNER);
    }

    function test_creoraGoesToArbitrumAndBack() public {
        registerHome();
        uint256 amount = 1_234_567e18;

        vm.selectFork(robinhoodFork);
        deal(CREORA, holder, amount);
        uint256 supply = IERC20(CREORA).totalSupply();
        uint256 fee = send(robinhood(), arbitrum().selector, CREORA, holder, friend, amount);
        console2.log("Robinhood to Arbitrum fee (wei)", fee);
        assertEq(IERC20(CREORA).balanceOf(holder), 0);
        assertEq(IERC20(CREORA).balanceOf(address(homePool)), amount, "locked on Robinhood Chain");
        assertEq(IERC20(CREORA).totalSupply(), supply, "nothing burned at home");

        vm.selectFork(arbitrumFork);
        deliver(arbPool, ARBITRUM_OFFRAMP, robinhood().selector, address(homePool), address(arbToken), holder, friend, amount);
        assertEq(arbToken.balanceOf(friend), amount, "minted on Arbitrum");
        assertEq(arbToken.totalSupply(), amount);

        uint256 back = 1_000_000e18;
        fee = send(arbitrum(), robinhood().selector, address(arbToken), friend, holder, back);
        console2.log("Arbitrum to Robinhood fee (wei)", fee);
        assertEq(arbToken.balanceOf(friend), amount - back);
        assertEq(arbToken.totalSupply(), amount - back, "burned on Arbitrum");
        assertEq(arbToken.balanceOf(address(arbPool)), 0);

        vm.selectFork(robinhoodFork);
        deliver(homePool, ROBINHOOD_OFFRAMP, arbitrum().selector, address(arbPool), CREORA, friend, holder, back);
        assertEq(IERC20(CREORA).balanceOf(holder), back, "released at home");
        assertEq(IERC20(CREORA).balanceOf(address(homePool)), amount - back);
    }

    function test_lockOrBurnTellsArbitrumWhatToMint() public {
        registerHome();
        vm.selectFork(robinhoodFork);
        deal(CREORA, address(homePool), 5e18);
        vm.prank(ROBINHOOD_ONRAMP);
        Pool.LockOrBurnOutV1 memory out = homePool.lockOrBurn(
            Pool.LockOrBurnInV1({
                receiver: abi.encode(friend),
                remoteChainSelector: arbitrum().selector,
                originalSender: holder,
                amount: 5e18,
                localToken: CREORA
            })
        );
        assertEq(out.destTokenAddress, abi.encode(address(arbToken)));
        assertEq(out.destPoolData, abi.encode(uint256(DECIMALS)));
    }

    function test_onlyTheRampsMoveTokens() public {
        registerHome();
        vm.selectFork(arbitrumFork);
        vm.expectRevert();
        deliver(arbPool, stranger, robinhood().selector, address(homePool), address(arbToken), holder, stranger, 1e18);
        vm.expectRevert();
        deliver(arbPool, ARBITRUM_OFFRAMP, robinhood().selector, stranger, address(arbToken), holder, stranger, 1e18);
        vm.prank(stranger);
        vm.expectRevert();
        arbToken.mint(stranger, 1e18);
        assertEq(arbToken.totalSupply(), 0);

        vm.selectFork(robinhoodFork);
        deal(CREORA, address(homePool), 10e18);
        vm.expectRevert();
        deliver(homePool, stranger, arbitrum().selector, address(arbPool), CREORA, holder, stranger, 1e18);
        vm.expectRevert();
        deliver(homePool, ROBINHOOD_OFFRAMP, arbitrum().selector, stranger, CREORA, holder, stranger, 1e18);
        vm.prank(stranger);
        vm.expectRevert();
        homePool.withdrawLiquidity(1e18);
        assertEq(IERC20(CREORA).balanceOf(address(homePool)), 10e18);
    }

    function test_onlyTheOwnerConfigures() public {
        registerHome();
        TokenPool.ChainUpdate[] memory none = new TokenPool.ChainUpdate[](0);
        uint64[] memory remove = new uint64[](1);

        vm.selectFork(robinhoodFork);
        remove[0] = arbitrum().selector;
        vm.startPrank(stranger);
        vm.expectRevert();
        homePool.applyChainUpdates(remove, none);
        vm.expectRevert();
        homePool.setRebalancer(stranger);
        vm.expectRevert();
        TokenAdminRegistry(robinhood().registry).setPool(CREORA, stranger);
        vm.stopPrank();

        vm.selectFork(arbitrumFork);
        remove[0] = robinhood().selector;
        vm.startPrank(stranger);
        vm.expectRevert();
        arbPool.applyChainUpdates(remove, none);
        vm.expectRevert();
        arbToken.grantMintAndBurnRoles(stranger);
        vm.expectRevert();
        TokenAdminRegistry(arbitrum().registry).setPool(address(arbToken), stranger);
        vm.stopPrank();
        vm.prank(deployer);
        vm.expectRevert();
        arbToken.grantMintAndBurnRoles(deployer);
    }

    function test_rateLimitCapsOneTransfer() public {
        registerHome();
        vm.selectFork(robinhoodFork);
        uint256 tooMuch = uint256(OUTBOUND_CAPACITY) + 1;
        deal(CREORA, holder, tooMuch);
        Client.EVM2AnyMessage memory out = message(CREORA, tooMuch, holder);
        uint256 fee = IRouterClient(robinhood().router).getFee(arbitrum().selector, out);
        vm.deal(holder, fee);
        vm.startPrank(holder);
        IERC20(CREORA).approve(robinhood().router, tooMuch);
        vm.expectRevert();
        IRouterClient(robinhood().router).ccipSend{value: fee}(arbitrum().selector, out);
        vm.stopPrank();
        assertEq(IERC20(CREORA).balanceOf(holder), tooMuch);
    }

    function test_mintingStopsAtTheHomeSupply() public {
        registerHome();
        vm.selectFork(arbitrumFork);
        vm.prank(address(arbPool));
        arbToken.mint(friend, MAX_SUPPLY);
        vm.prank(address(arbPool));
        vm.expectRevert();
        arbToken.mint(friend, 1);
    }
}
