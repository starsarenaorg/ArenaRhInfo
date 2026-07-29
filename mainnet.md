# Arena Contracts on Robinhood Chain Mainnet

This is the production contract registry for Arena on Robinhood Chain.

| Network | Value |
| --- | --- |
| Chain | Robinhood Chain mainnet |
| Chain ID | `4663` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` |
| Machine-readable registry | [`addresses.json`](addresses.json) |
| ABI registry | [`abis/index.json`](abis/index.json) |

## Verification

As checked on 2026-07-29, all 46 fixed Arena launchpad, manager, proxy,
price-helper, routing-helper, THROBBIN, and LP compounder deployments are
source-verified on Robinhood Blockscout.

Two additional Arena deployments are not included in that verified count yet:
`BridgedArenaOFT` and the completed one-use `RobinhoodArenaEthLiquidityLauncher`.
Their exact sources and ABIs are included here, but Blockscout source publication
is still pending. External Uniswap, WETH, Permit2, stock-token, and LayerZero
contracts are third-party dependencies and are not covered by Arena's
verification statement.

## Core Contracts

All addresses in this table are Arena deployments. Except for the two rows
explicitly marked `Pending`, their source is verified on Blockscout.

| Contract | Address | Use | Verification |
| --- | --- | --- | --- |
| `BridgedArenaOFT` | [`0x50832d74a7160E2f7d361F5E678E107D228B9Aa6`](https://robinhoodchain.blockscout.com/address/0x50832d74a7160E2f7d361F5E678E107D228B9Aa6?tab=contract) | LayerZero OFT representation of ARENA on Robinhood Chain; also the ARENA Prism quote token. | Pending |
| `RobinhoodArenaEthLiquidityLauncher` | [`0xF83d9bb6f76a18d9De2DeE85ECf6Bd668a94cD9C`](https://robinhoodchain.blockscout.com/address/0xF83d9bb6f76a18d9De2DeE85ECf6Bd668a94cD9C?tab=contract) | One-use launcher that initialized and seeded the full-range ARENA/ETH v4 position. Authorization was revoked after launch. | Pending |
| `RobinhoodArenaReferralRegistry` | [`0xE526e9f9860EeAD6f59BAA0913B7c624Ea0d29c4`](https://robinhoodchain.blockscout.com/address/0xE526e9f9860EeAD6f59BAA0913B7c624Ea0d29c4?tab=contract) | Referral attribution and authorized referrer administration. | Verified |
| `RobinhoodArenaFeeHelper` | [`0xab56cD18f3200Fb82BFE79bEFc2D8FE19528E950`](https://robinhoodchain.blockscout.com/address/0xab56cD18f3200Fb82BFE79bEFc2D8FE19528E950?tab=contract) | Stores and routes post-bond protocol, creator, and referral fees. | Verified |
| `RobinhoodLaunchTokenFactory` | [`0x4ec0d15BC8D2f5a7eb4d14e789c92C7F7B96425D`](https://robinhoodchain.blockscout.com/address/0x4ec0d15BC8D2f5a7eb4d14e789c92C7F7B96425D?tab=contract) | Deploys one `RobinhoodLaunchToken` for each launch. | Verified |
| `RobinhoodArenaFeeHookFactory` | [`0x4e8005ce21b857200B4E581F247E76765249143A`](https://robinhoodchain.blockscout.com/address/0x4e8005ce21b857200B4E581F247E76765249143A?tab=contract) | CREATE2 factory used to deploy the shared Uniswap v4 fee hook at a permission-compatible address. | Verified |
| `RobinhoodArenaFeeHook` | [`0x99d4C5Cf21d8F00b627AFe2Bf1eE2840f886e044`](https://robinhoodchain.blockscout.com/address/0x99d4C5Cf21d8F00b627AFe2Bf1eE2840f886e044?tab=contract) | Shared v4 hook that assesses and routes post-bond fees for Arena launch pools. | Verified |
| `RobinhoodArenaFeePoolDeployer` | [`0x20E399396F031a26374aAD956AA8D7Fb241d6852`](https://robinhoodchain.blockscout.com/address/0x20E399396F031a26374aAD956AA8D7Fb241d6852?tab=contract) | Initializes launch pools and mints their initial Uniswap v4 LP NFTs. | Verified |
| `RobinhoodPrismRegistry` | [`0x0a8d2cA44CbD6cce055fEeafA8f51DeeA0Ae99AB`](https://robinhoodchain.blockscout.com/address/0x0a8d2cA44CbD6cce055fEeafA8f51DeeA0Ae99AB?tab=contract) | Maps approved Prism quote tokens to their manager proxies. | Verified |
| `RobinhoodSingleTxBuyer` | [`0x565d6549249f363cF1575d2C4ce3F34a451F1931`](https://robinhoodchain.blockscout.com/address/0x565d6549249f363cF1575d2C4ce3F34a451F1931?tab=contract) | One-transaction Native launch and initial purchase helper. | Verified |
| `RobinhoodSingleTxQuoter` | [`0x54BF5B497c36a2Ac2D24A07fF648B0241f25E0e4`](https://robinhoodchain.blockscout.com/address/0x54BF5B497c36a2Ac2D24A07fF648B0241f25E0e4?tab=contract) | Quotes Native launch and initial purchase flows. | Verified |
| `RobinhoodPrismBuyer` | [`0x7705AE5d708a44424e1974ac069C744Df6dAe3D0`](https://robinhoodchain.blockscout.com/address/0x7705AE5d708a44424e1974ac069C744Df6dAe3D0?tab=contract) | One-transaction Prism launch and initial purchase helper. | Verified |
| `RobinhoodPrismQuoter` | [`0x6c3bBCF851cB0eb50dd01D6eA53FD3b5Bf811890`](https://robinhoodchain.blockscout.com/address/0x6c3bBCF851cB0eb50dd01D6eA53FD3b5Bf811890?tab=contract) | Quotes registered Prism launch and purchase flows. | Verified |
| `RobinhoodPrismNativeRouter` | [`0xE6d6902D804940C3011C17E505B00A08330aa0bC`](https://robinhoodchain.blockscout.com/address/0xE6d6902D804940C3011C17E505B00A08330aa0bC?tab=contract) | ETH entry and exit router for every registered Prism pair. | Verified |
| `RobinhoodPostBondQuoter` | [`0xA2C1571748c7fA2ce8F46a6CC2e41B0f6BbAbAEE`](https://robinhoodchain.blockscout.com/address/0xA2C1571748c7fA2ce8F46a6CC2e41B0f6BbAbAEE?tab=contract) | Quotes Uniswap v4 trading after a token bonds. | Verified |
| `RobinhoodPostBondRouter` | [`0x04eda72FA05772bEa3D516F446b5aFBf55b74CdF`](https://robinhoodchain.blockscout.com/address/0x04eda72FA05772bEa3D516F446b5aFBf55b74CdF?tab=contract) | Executes post-bond swaps through Uniswap's Universal Router. | Verified |
| `RobinhoodTokenDataHelper` | [`0x32A7956228D2610e499d4841B833C3A6b7496a21`](https://robinhoodchain.blockscout.com/address/0x32A7956228D2610e499d4841B833C3A6b7496a21?tab=contract) | Aggregates launch-token, manager, and v4 position state for clients and indexers. | Verified |
| `RobinhoodLPFeeCompounder` | [`0x7a64a25e6EBaaD37Ae81cCD7E57c6BE0BD513347`](https://robinhoodchain.blockscout.com/address/0x7a64a25e6EBaaD37Ae81cCD7E57c6BE0BD513347?tab=contract) | Claims Safe-owned v4 LP fees, reinvests the balanced amount, and returns dust to the Safe. | Verified |

## Launch Managers

The proxy is the stable user-facing manager address. Integrations should call
the proxy using the manager implementation ABI. Implementations can change
through a Safe-authorized UUPS upgrade, while the proxy address remains stable.
Every proxy, current implementation, and price helper below is source-verified.

| Pair | Type and quote token | Manager proxy | Current implementation | Price helper | Status |
| --- | --- | --- | --- | --- | --- |
| NATIVE | Native, WETH `0x0Bd7...AD73` | [`0x8E217cd9F90B30c0f8A0c85337912eeF29AeCe0a`](https://robinhoodchain.blockscout.com/address/0x8E217cd9F90B30c0f8A0c85337912eeF29AeCe0a?tab=contract) | [`0x37ABE71a3f8DaCAE65C940608f0F5409a6b1e4aa`](https://robinhoodchain.blockscout.com/address/0x37ABE71a3f8DaCAE65C940608f0F5409a6b1e4aa?tab=contract) | [`0x4bAEfc1A42367A0F465EB2da84c1A44bAED7A803`](https://robinhoodchain.blockscout.com/address/0x4bAEfc1A42367A0F465EB2da84c1A44bAED7A803?tab=contract) | Active |
| ARENA | Prism, `0x50832d74a7160E2f7d361F5E678E107D228B9Aa6` | [`0x1F2e88D968A5B80608d3718A12Ac5a8925a65F23`](https://robinhoodchain.blockscout.com/address/0x1F2e88D968A5B80608d3718A12Ac5a8925a65F23?tab=contract) | [`0x145Be2bf1FB53c4ee5Af250D072d3A046b9C4c6b`](https://robinhoodchain.blockscout.com/address/0x145Be2bf1FB53c4ee5Af250D072d3A046b9C4c6b?tab=contract) | [`0x5084c71106D8B68f85E79e1A72Fdb3573fD599F2`](https://robinhoodchain.blockscout.com/address/0x5084c71106D8B68f85E79e1A72Fdb3573fD599F2?tab=contract) | Active |
| NVDA | Prism, `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | [`0xBA4a7FC7A4622573160c310B57b2581651436Ae3`](https://robinhoodchain.blockscout.com/address/0xBA4a7FC7A4622573160c310B57b2581651436Ae3?tab=contract) | [`0x859C69A864E7670695Bbc0D49EdE6a2909AD524A`](https://robinhoodchain.blockscout.com/address/0x859C69A864E7670695Bbc0D49EdE6a2909AD524A?tab=contract) | [`0x89Ebd7711f719Cc6C1c260FdB352C11d9FC2C78D`](https://robinhoodchain.blockscout.com/address/0x89Ebd7711f719Cc6C1c260FdB352C11d9FC2C78D?tab=contract) | Active |
| SPCX | Prism, `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` | [`0xFC3D2af46D127567b7E867af3a2Af70139d2F9d2`](https://robinhoodchain.blockscout.com/address/0xFC3D2af46D127567b7E867af3a2Af70139d2F9d2?tab=contract) | [`0x1A6C84EeE8398804956B1D4B15B21C4BB03c4719`](https://robinhoodchain.blockscout.com/address/0x1A6C84EeE8398804956B1D4B15B21C4BB03c4719?tab=contract) | [`0x89CD1DDF226DB4a39aD9A67e35c3FC7f4e54db06`](https://robinhoodchain.blockscout.com/address/0x89CD1DDF226DB4a39aD9A67e35c3FC7f4e54db06?tab=contract) | Active |
| AAPL | Prism, `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | [`0x163F8DAA94641bCD3dA3CA1D8993BD73596315D9`](https://robinhoodchain.blockscout.com/address/0x163F8DAA94641bCD3dA3CA1D8993BD73596315D9?tab=contract) | [`0x489D39d8268448123076C6A6116dee11269E6E64`](https://robinhoodchain.blockscout.com/address/0x489D39d8268448123076C6A6116dee11269E6E64?tab=contract) | [`0x74B2E0cc4176FE227aD5bFD7Ed838738125a8445`](https://robinhoodchain.blockscout.com/address/0x74B2E0cc4176FE227aD5bFD7Ed838738125a8445?tab=contract) | Active |
| META | Prism, `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35` | [`0x0912d92A448835676952b4fDf656cc33644b516b`](https://robinhoodchain.blockscout.com/address/0x0912d92A448835676952b4fDf656cc33644b516b?tab=contract) | [`0x82341AAB18a74DBa03DfEBa63465Eb1A31331D04`](https://robinhoodchain.blockscout.com/address/0x82341AAB18a74DBa03DfEBa63465Eb1A31331D04?tab=contract) | [`0x8275e85d9407A71Da9F483DD7C61C5090efb8A59`](https://robinhoodchain.blockscout.com/address/0x8275e85d9407A71Da9F483DD7C61C5090efb8A59?tab=contract) | Active |
| TSLA | Prism, `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | [`0x0383b874c8301f7bFD7dA00Fd379aB1c72a67BDa`](https://robinhoodchain.blockscout.com/address/0x0383b874c8301f7bFD7dA00Fd379aB1c72a67BDa?tab=contract) | [`0x30476C859B729f506484d4EBed4BeE7885c655b6`](https://robinhoodchain.blockscout.com/address/0x30476C859B729f506484d4EBed4BeE7885c655b6?tab=contract) | [`0x091Dfe501263D5C208C997674daAB01ADAFD81A5`](https://robinhoodchain.blockscout.com/address/0x091Dfe501263D5C208C997674daAB01ADAFD81A5?tab=contract) | Active |
| GOOGL | Prism, `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` | [`0x0f93f0a23b70db46aEcD758219edb6AC0688a821`](https://robinhoodchain.blockscout.com/address/0x0f93f0a23b70db46aEcD758219edb6AC0688a821?tab=contract) | [`0x1D3c9d60e8a78c0911aCe1f07c3c50961e17A72D`](https://robinhoodchain.blockscout.com/address/0x1D3c9d60e8a78c0911aCe1f07c3c50961e17A72D?tab=contract) | [`0x43624342c44e1D2b5049aACe8dd4f2b013a2CDA4`](https://robinhoodchain.blockscout.com/address/0x43624342c44e1D2b5049aACe8dd4f2b013a2CDA4?tab=contract) | Active |
| GME | Prism, `0x1b0E319c6A659F002271B69dB8A7df2F911c153E` | [`0xdeBCF25f95d410a7b73383446D85E35a48CD2c5d`](https://robinhoodchain.blockscout.com/address/0xdeBCF25f95d410a7b73383446D85E35a48CD2c5d?tab=contract) | [`0x680f2D01beFB145A12168Cc822bCdfaeF64A18df`](https://robinhoodchain.blockscout.com/address/0x680f2D01beFB145A12168Cc822bCdfaeF64A18df?tab=contract) | [`0xc47Ef93B4AF435ffF740Eb9D7cD48A1918458197`](https://robinhoodchain.blockscout.com/address/0xc47Ef93B4AF435ffF740Eb9D7cD48A1918458197?tab=contract) | Active |
| THROBBIN | Prism WIP, `0xe8fB470E0685437d7739BD2AacBA60b228800335` | [`0x8FAB988EF068D0f100c5812f56559dEFC7695641`](https://robinhoodchain.blockscout.com/address/0x8FAB988EF068D0f100c5812f56559dEFC7695641?tab=contract) | [`0xbf6CdAe05d9Bc062080453E43F484C65Ae4A70Cc`](https://robinhoodchain.blockscout.com/address/0xbf6CdAe05d9Bc062080453E43F484C65Ae4A70Cc?tab=contract) | [`0xdb1651284D3430f5264F5aF53B0BA0f9b01c8069`](https://robinhoodchain.blockscout.com/address/0xdb1651284D3430f5264F5aF53B0BA0f9b01c8069?tab=contract) | Paused, unregistered, LP disabled |

THROBBIN is documented because it is a deployed and verified production
contract set, but it is intentionally not an active launch pair.

## Dynamic Launch Tokens

`RobinhoodLaunchToken` has no single contract address. The token factory deploys
a new instance for every Native or Prism launch. Its canonical source is:

[`contracts/robinhood/RobinhoodLaunchToken.sol`](contracts/robinhood/RobinhoodLaunchToken.sol)

Its frontend/indexer ABI is:

[`abis/RobinhoodLaunchToken.json`](abis/RobinhoodLaunchToken.json)

Individual launch-token addresses, such as BOYZ, are generated protocol output
and are not fixed infrastructure addresses.

## External Dependencies

These contracts were deployed by Uniswap, Robinhood/third parties, or on
Avalanche. Arena uses them but did not deploy them as part of this launchpad
contract set.

| Dependency | Address | Use |
| --- | --- | --- |
| WETH | [`0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`](https://robinhoodchain.blockscout.com/address/0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73) | Wrapped native ETH and Native launch quote asset. |
| Uniswap v4 PoolManager | [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://robinhoodchain.blockscout.com/address/0x8366a39CC670B4001A1121B8F6A443A643e40951?tab=contract) | Core singleton that stores v4 pool state and liquidity. |
| Uniswap v4 PositionManager | [`0x58daec3116aae6D93017bAAea7749052E8a04fA7`](https://robinhoodchain.blockscout.com/address/0x58daec3116aae6D93017bAAea7749052E8a04fA7?tab=contract) | Mints and manages v4 LP NFTs; Safe approvals for compounding are made here. |
| Uniswap v4 StateView | [`0xF3334192D15450CdD385c8B70e03f9A6bD9E673b`](https://robinhoodchain.blockscout.com/address/0xF3334192D15450CdD385c8B70e03f9A6bD9E673b?tab=contract) | Read-only v4 pool and position state. |
| Uniswap Universal Router | [`0x8876789976dEcBfCbBbe364623C63652db8C0904`](https://robinhoodchain.blockscout.com/address/0x8876789976dEcBfCbBbe364623C63652db8C0904?tab=contract) | Routes post-bond swaps. |
| Permit2 | [`0x000000000022D473030F116dDEE9F6B43aC78BA3`](https://robinhoodchain.blockscout.com/address/0x000000000022D473030F116dDEE9F6B43aC78BA3?tab=contract) | Token allowance and transfer layer used by Uniswap routing. |
| Canonical ARENA on Avalanche | [`0xB8d7710f7d8349A506b75dD184F05777c82dAd0C`](https://snowtrace.io/address/0xB8d7710f7d8349A506b75dD184F05777c82dAd0C) | Canonical ARENA token backing bridged ARENA. |
| ARENA OFT adapter on Avalanche | [`0xA59Ad32dAd425250ca3601F964d92611818F86f7`](https://snowtrace.io/address/0xA59Ad32dAd425250ca3601F964d92611818F86f7) | LayerZero bridge adapter paired with `BridgedArenaOFT`. |

The full PositionManager ABI, including `setApprovalForAll`, is included at
[`abis/UniswapV4PositionManager.json`](abis/UniswapV4PositionManager.json).

## Governance And Recipients

| Role | Address |
| --- | --- |
| LP custody and active-manager Safe | `0x0c6aCd89b5fFec5D2a5505aA5e7A3aEFC4E1Cff1` |
| Production deployer / remaining direct owner | `0x4D8E431f3d93B57E3CDd3FA9cc4e6D248678933B` |
| Compounder automation admin | `0x53229a27dE1E4e263375351Db4492C1E4bf0Ed48` |
| Initial launch-fee recipient | `0x160b4D8fe9D6fe1d10ABd5E18097676948d288A5` |
| Pre-bond protocol-fee recipient | `0x7C85Be2F4043201461EF98124Dd5d273B2f575fF` |
| Post-bond DEX-fee recipient | `0x5Ab2d4181aaE405Cf12DA8E6a0b7596c252F7679` |

## Source And ABI Layout

The Solidity archive preserves its original paths under `contracts/`. It
contains every Arena-local source transitively imported by the deployed entry
contracts. Package imports such as OpenZeppelin, Uniswap v4, LayerZero, and
Solady remain package imports and are not vendored into this folder.

ABI files are raw JSON arrays and can be passed directly to ethers, viem, or
web3 libraries. Use:

- `RobinhoodNativePairTokenManager.json` for the NATIVE proxy.
- `RobinhoodPrismTokenManager.json` for every Prism proxy.
- `RobinhoodLaunchToken.json` for tokens deployed by the launchpad.
- `RobinhoodLPFeeCompounder.json` for fee compounding.
- `UniswapV4PositionManager.json` for LP NFT ownership and approvals.

Superseded manager implementations are intentionally omitted from the main
tables. The listed implementation address is the implementation currently
selected by each production proxy.
