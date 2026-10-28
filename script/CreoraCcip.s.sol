// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/contracts/pools/BurnMintTokenPool.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/LockReleaseTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {RegistryModuleOwnerCustom} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";
import {IBurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

abstract contract CreoraCcipSteps {
    struct Network {
        uint64 selector;
        address router;
        address rmn;
        address registry;
        address registryModule;
    }

    address constant CREORA = 0xb11384A6ac2b3708E3d25A834c8a88687Accbcd1;
    uint8 constant DECIMALS = 18;
    uint256 constant MAX_SUPPLY = 1_000_000_000e18;
    uint128 constant OUTBOUND_CAPACITY = 50_000_000e18;
    uint128 constant OUTBOUND_RATE = 500e18;
    uint128 constant INBOUND_CAPACITY = 55_000_000e18;
    uint128 constant INBOUND_RATE = 550e18;

    function robinhood() internal pure returns (Network memory) {
        return Network({
            selector: 6180753054346818345,
            router: 0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9,
            rmn: 0xe8464c353210Cc398A45dB2454FBc5BCd25fFf20,
            registry: 0x1912C3cFafE8A76A32a92861d815aC2837F237Ca,
            registryModule: 0x3237c0D7B58BEc8Dc17F00103B784Bd6678f789E
        });
    }

    function arbitrum() internal pure returns (Network memory) {
        return Network({
            selector: 4949039107694359620,
            router: 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8,
            rmn: 0xC311a21e6fEf769344EB1515588B9d535662a145,
            registry: 0x39AE1032cF4B334a1Ed41cdD0833bdD7c7E7751E,
            registryModule: 0x1f1df9f7fc939E71819F766978d8F900B816761b
        });
    }

    function deployRobinhoodPool() internal returns (LockReleaseTokenPool) {
        Network memory home = robinhood();
        return new LockReleaseTokenPool(IERC20(CREORA), DECIMALS, new address[](0), home.rmn, home.router);
    }

    function deployArbitrum(address robinhoodPool, address owner, address deployer)
        internal
        returns (BurnMintERC20 token, BurnMintTokenPool pool)
    {
        Network memory here = arbitrum();
        token = new BurnMintERC20("Creora", "CREORA", DECIMALS, MAX_SUPPLY, 0);
        pool = new BurnMintTokenPool(IBurnMintERC20(address(token)), DECIMALS, new address[](0), here.rmn, here.router);
        token.grantMintAndBurnRoles(address(pool));
        connect(pool, robinhood().selector, robinhoodPool, CREORA);

        TokenAdminRegistry registry = TokenAdminRegistry(here.registry);
        RegistryModuleOwnerCustom(here.registryModule).registerAdminViaGetCCIPAdmin(address(token));
        registry.acceptAdminRole(address(token));
        registry.setPool(address(token), address(pool));
        registry.transferAdminRole(address(token), owner);

        token.setCCIPAdmin(owner);
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), owner);
        token.renounceRole(token.DEFAULT_ADMIN_ROLE(), deployer);
        pool.transferOwnership(owner);
    }

    function connectRobinhood(LockReleaseTokenPool pool, address arbitrumPool, address arbitrumToken, address owner)
        internal
    {
        connect(pool, arbitrum().selector, arbitrumPool, arbitrumToken);
        pool.transferOwnership(owner);
    }

    function connect(TokenPool pool, uint64 remoteSelector, address remotePool, address remoteToken) internal {
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = abi.encode(remotePool);
        TokenPool.ChainUpdate[] memory chains = new TokenPool.ChainUpdate[](1);
        chains[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteSelector,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: abi.encode(remoteToken),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: OUTBOUND_CAPACITY, rate: OUTBOUND_RATE}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: INBOUND_CAPACITY, rate: INBOUND_RATE})
        });
        pool.applyChainUpdates(new uint64[](0), chains);
    }
}

contract CreoraCcip is Script, CreoraCcipSteps {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        address owner = vm.envAddress("OWNER");
        bytes32 step = keccak256(bytes(vm.envString("STEP")));

        vm.startBroadcast(key);
        if (step == keccak256("robinhood-pool")) {
            require(block.chainid == 4663, "run this step on Robinhood Chain");
            console2.log("ROBINHOOD_POOL=%s", address(deployRobinhoodPool()));
        } else if (step == keccak256("arbitrum")) {
            require(block.chainid == 42161, "run this step on Arbitrum One");
            (BurnMintERC20 token, BurnMintTokenPool pool) = deployArbitrum(vm.envAddress("ROBINHOOD_POOL"), owner, deployer);
            console2.log("ARBITRUM_TOKEN=%s", address(token));
            console2.log("ARBITRUM_POOL=%s", address(pool));
        } else if (step == keccak256("robinhood-connect")) {
            require(block.chainid == 4663, "run this step on Robinhood Chain");
            connectRobinhood(
                LockReleaseTokenPool(vm.envAddress("ROBINHOOD_POOL")),
                vm.envAddress("ARBITRUM_POOL"),
                vm.envAddress("ARBITRUM_TOKEN"),
                owner
            );
        } else {
            revert("STEP is robinhood-pool, arbitrum or robinhood-connect");
        }
        vm.stopBroadcast();
    }
}
