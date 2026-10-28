# Creora Launchpad contracts

Smart contracts behind the Creora launchpad at [creora.ai/pad](https://creora.ai/pad). Tokens launch on a bonding curve, graduate into a Uniswap v4 pool, and the pool's liquidity is locked for good.

## How a launch works

1. `Launchpad` creates a `LaunchpadToken` and a `Gauge` for it. The gauge sells the token along a `ConstantProductCurve` and keeps 30% of every curve fee for the token's creator.
2. When the gauge has raised its target it graduates: it adds the raised ETH and the remaining tokens as a full range position in a Uniswap v4 pool (ETH / token, 1% static fee, tick spacing 200).
3. Every pool carries the `GraduationHook`. Only the token's own gauge can open its pool, and swaps and liquidity revert until the gauge has graduated, so nobody can move the price of the empty pool before the curve's ETH arrives. After graduation the hook returns a zero delta and no fee override, so swaps are plain v4 swaps. It has no owner, no admin functions and no upgrade path.
4. The graduated position goes to the liquidity lock and can never be withdrawn.
   * `GoPlusLiquidityLock` locks it in the GoPlus SafeToken Locker with the largest possible unlock time and owns the lock itself, with no way to release it. Scanners that read GoPlus show the liquidity as locked.
   * `LiquidityLock` holds positions directly, forever.

   Either way the pool's 1% trading fee is collected into the Creora fee wallet.

`LaunchSwapRouter` is a small stateless router for trading graduated pools, and `ReferralRouter` / `ReferralHandler` split curve fees with referrers.

## Deployments

| Contract | Robinhood Chain (4663) | Arbitrum One (42161) |
|---|---|---|
| Launchpad | `0xf87eA45bdEd500421BDAEE5bf340dfc27B3d19c7` | `0xf87eA45bdEd500421BDAEE5bf340dfc27B3d19c7` |
| Gauge implementation | `0x776725E60a3549e453359499486534C608bECbF0` | `0x776725E60a3549e453359499486534C608bECbF0` |
| GraduationHook | `0x23ccF25787c0df2dab3EdaB05ed8CC08A4ff2880` | `0x0d43aAC2b26bc078AE77e66e57B37A7C616FE880` |
| LaunchpadToken implementation | `0x085FaAFfb2B0e66DE1844E3540585D3b698483F4` | `0x085FaAFfb2B0e66DE1844E3540585D3b698483F4` |
| ConstantProductCurve | `0xFdDFaa83a7DC828e0168fb6B929650B7a8186a8f` | `0xFdDFaa83a7DC828e0168fb6B929650B7a8186a8f` |
| LaunchSwapRouter | `0x519226C8935Ff79D958d6f821d5F5B74987Dc8C3` | `0x519226C8935Ff79D958d6f821d5F5B74987Dc8C3` |
| ReferralRouter | `0x44d5CB3021a2f3Ec8207F6c6EAbB0E442cB3b788` | `0x44d5CB3021a2f3Ec8207F6c6EAbB0E442cB3b788` |
| ReferralHandler | `0x8F6dA108Fcd22A07e727acEE9f2335a1C64FBd08` | `0x8F6dA108Fcd22A07e727acEE9f2335a1C64FBd08` |
| AccessRegistry | `0x9199CF813e1688A949F2BB73DC6cf0d558e71553` | `0x9199CF813e1688A949F2BB73DC6cf0d558e71553` |
| LiquidityLock | `0xA15d237E65811F237Cb47cb4FDFdace2310c14A0` | `0xA15d237E65811F237Cb47cb4FDFdace2310c14A0` |
| GoPlusLiquidityLock | `0xFD477c1A87A8097AbbD33Ed77361918ad2671D46` | |

All of them are verified on [Sourcify](https://sourcify.dev). On Robinhood Chain the hook, the gauge and both locks are also verified on [robin.etherscan.io](https://robin.etherscan.io).

## Build and test

Requires [Foundry](https://getfoundry.sh).

```sh
git clone --recurse-submodules https://github.com/creoradotai/contracts.git
cd contracts
forge build
forge test
```

The fork tests in `test/fork` run against a live chain and are skipped unless `FORK_RPC` is set:

```sh
FORK_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-path 'test/fork/*'
```

Remappings are pinned in `remappings.txt`, so a build reproduces the deployed bytecode of the hook, the gauge and the locks byte for byte, metadata included.

## License

MIT. The launchpad core is derived from an MIT licensed launchpad; see [NOTICE](NOTICE). Libraries in `lib` keep their own licenses.
