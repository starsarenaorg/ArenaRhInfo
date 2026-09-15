# Arena V2 Contracts on Robinhood Chain Mainnet

This is the fixed production-infrastructure registry for Arena launchpad V2.
The complete former V1 archive is retained under [`v1/`](v1/README.md).

| Network | Value |
| --- | --- |
| Chain | Robinhood Chain mainnet |
| Chain ID | `4663` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | [Robinhood Blockscout](https://robinhoodchain.blockscout.com) |
| Machine registry | [`addresses.json`](addresses.json) |
| ABI index | [`abis/index.json`](abis/index.json) |
| Deployment evidence | [`manifests/`](manifests/) |

## Verification snapshot

The production verification report was updated at
`2026-09-10T19:02:54.567Z` and records **70 exact-match verified deployments**.
That includes the current fixed V2 stack, all current manager proxies and price
helpers, plus the five intentionally deferred expansion managers. Dynamic
launch tokens are separate deployments and are not counted as fixed infrastructure.

## Core contracts

| Key | Address | Contract | Purpose | Verification |
| --- | --- | --- | --- | --- |
| `lpVault` | [`0x7d4A72C6EF99E935c1e723b8eD6e38Ac51C8190b`](https://robinhoodchain.blockscout.com/address/0x7d4A72C6EF99E935c1e723b8eD6e38Ac51C8190b?tab=contract) | RobinhoodTimelockedLpVault | 48-hour timelocked custody and automation vault for Uniswap v4 LP NFTs. | verified |
| `dividendController` | [`0xa8F6Cb031C5f0f923909842D4435687e250559bC`](https://robinhoodchain.blockscout.com/address/0xa8F6Cb031C5f0f923909842D4435687e250559bC?tab=contract) | RobinhoodDividendController | Registers launch tokens and coordinates dividend accounting/distribution. | verified |
| `dividendProcessor` | [`0x69AeE265043ab8Fa5AcEB721537bb9aED5B4b7A9`](https://robinhoodchain.blockscout.com/address/0x69AeE265043ab8Fa5AcEB721537bb9aED5B4b7A9?tab=contract) | RobinhoodDividendProcessor | Upgradeable processor used for holder dividend distributions. | verified |
| `tokenFactory` | [`0x3d1170c9ea8Bb49A58bAAf3378C7c97E59Bb2800`](https://robinhoodchain.blockscout.com/address/0x3d1170c9ea8Bb49A58bAAf3378C7c97E59Bb2800?tab=contract) | RobinhoodMixedFeeLaunchTokenFactory | Deploys RobinhoodMixedFeeLaunchToken instances for V2 launches. | verified |
| `poolDeployer` | [`0x4B400e1AcC76729BE6A86C3fC73Ab2b8d80B78EF`](https://robinhoodchain.blockscout.com/address/0x4B400e1AcC76729BE6A86C3fC73Ab2b8d80B78EF?tab=contract) | RobinhoodDividendFeePoolDeployer | Initializes post-bond pools and deposits LP NFTs into the V2 vault. | verified |
| `dividendFeeHelper` | [`0xB28DD2fC871BA2960a4c84b81a13Facca87051bB`](https://robinhoodchain.blockscout.com/address/0xB28DD2fC871BA2960a4c84b81a13Facca87051bB?tab=contract) | RobinhoodDividendFeeHelper | Splits and routes post-bond protocol, referral, and dividend fees. | verified |
| `mixedFeeHook` | [`0xa4555952075BDFD473521f3d754d13442EE3e0Cc`](https://robinhoodchain.blockscout.com/address/0xa4555952075BDFD473521f3d754d13442EE3e0Cc?tab=contract) | RobinhoodMixedFeeHook | Shared Uniswap v4 hook for protocol fees and token-holder dividends. | verified |
| `referralRegistry` | [`0xE526e9f9860EeAD6f59BAA0913B7c624Ea0d29c4`](https://robinhoodchain.blockscout.com/address/0xE526e9f9860EeAD6f59BAA0913B7c624Ea0d29c4?tab=contract) | RobinhoodArenaReferralRegistry | V1 referral registry reused by the V2 managers and fee helper. | verified-reused-v1-deployment |

## Periphery

| Key | Address | Contract | Purpose | Verification |
| --- | --- | --- | --- | --- |
| `prismRegistry` | [`0xF50316b2174c605F53aC37812D83b031D162AD70`](https://robinhoodchain.blockscout.com/address/0xF50316b2174c605F53aC37812D83b031D162AD70?tab=contract) | RobinhoodV2PrismRegistry | Maps supported Prism pair tokens to their active manager proxies. | verified |
| `prismQuoter` | [`0x9818Da8f49a9a5Ee47bc2F8Fee9582dd9044a805`](https://robinhoodchain.blockscout.com/address/0x9818Da8f49a9a5Ee47bc2F8Fee9582dd9044a805?tab=contract) | RobinhoodV2PrismQuoter | Read-only quoting for V2 Prism launch and purchase flows. | verified |
| `prismBuyer` | [`0x07f75a4bb6D1D9de880e71F4259bB877D794dA5B`](https://robinhoodchain.blockscout.com/address/0x07f75a4bb6D1D9de880e71F4259bB877D794dA5B?tab=contract) | RobinhoodV2PrismBuyer | Atomic V2 Prism launch and initial purchase helper. | verified |
| `prismNativeRouterV4` | [`0x53Fa410b729aa4a632a6d84F0e907A137534Bfc7`](https://robinhoodchain.blockscout.com/address/0x53Fa410b729aa4a632a6d84F0e907A137534Bfc7?tab=contract) | RobinhoodV2PrismNativeRouter | Native-asset entry and exit router through Uniswap v4. | verified |
| `prismNativeRouterV3` | [`0x898f0fFdF329f50B020CEe5666FfB3602E469b8d`](https://robinhoodchain.blockscout.com/address/0x898f0fFdF329f50B020CEe5666FfB3602E469b8d?tab=contract) | RobinhoodV2PrismNativeRouterV3 | Native-asset entry and exit router through Uniswap v3. | verified |
| `nativePriceHelper` | [`0x24a21CB67D0e6609D26Cc678db7ef13bffFEC142`](https://robinhoodchain.blockscout.com/address/0x24a21CB67D0e6609D26Cc678db7ef13bffFEC142?tab=contract) | RobinhoodV2NativePriceHelper | Read-only Native manager price helper. | verified |
| `nativeQuoter` | [`0x24Dbbc15f3c397DeBE33d64F877B85b2e6BE918a`](https://robinhoodchain.blockscout.com/address/0x24Dbbc15f3c397DeBE33d64F877B85b2e6BE918a?tab=contract) | RobinhoodV2NativeQuoter | Quotes current V2 Native launch and purchase flows. | verified |
| `nativeBuyer` | [`0xBA8f8025461E22164426E5DF84354138099eEacA`](https://robinhoodchain.blockscout.com/address/0xBA8f8025461E22164426E5DF84354138099eEacA?tab=contract) | RobinhoodV2NativeBuyer | Atomic current V2 Native launch and initial purchase helper. | verified |

## Implementations and factories

| Key | Address | Contract | Purpose | Verification |
| --- | --- | --- | --- | --- |
| `nativeManager` | [`0xE46503C508aC75F95e027AC270F60df8407aAa67`](https://robinhoodchain.blockscout.com/address/0xE46503C508aC75F95e027AC270F60df8407aAa67?tab=contract) | RobinhoodNativePairTokenManagerV2 | Implementation used by the current Native manager proxy. | verified |
| `prismManager` | [`0xe8B180832ff356e26edde71EDEe2e9f8D80AB052`](https://robinhoodchain.blockscout.com/address/0xe8B180832ff356e26edde71EDEe2e9f8D80AB052?tab=contract) | RobinhoodPrismTokenManagerV2 | Implementation shared by all current Prism manager proxies. | verified |
| `dividendProcessor` | [`0x353F9f139eD0E775eFeB2c760384Dec7Efd203a7`](https://robinhoodchain.blockscout.com/address/0x353F9f139eD0E775eFeB2c760384Dec7Efd203a7?tab=contract) | RobinhoodDividendProcessor | Implementation selected by the production dividend processor proxy. | verified |
| `mixedHookFactory` | [`0xd5bF02bfc316A5f4Ef000140E8067bAc98Bb24dC`](https://robinhoodchain.blockscout.com/address/0xd5bF02bfc316A5f4Ef000140E8067bAc98Bb24dC?tab=contract) | RobinhoodMixedFeeHookFactory | CREATE2 factory used to deploy the current production mixed-fee hook. | reused-deployment-not-in-production-verification-report |
| `legacyDividendHookFactory` | [`0xdc99879067dF21a1FacB03BB94034E4A30FCB2a1`](https://robinhoodchain.blockscout.com/address/0xdc99879067dF21a1FacB03BB94034E4A30FCB2a1?tab=contract) | RobinhoodDividendFeeHookFactory | Earlier V2 dividend-hook CREATE2 factory retained in the shared manifest; not the factory of the current mixed-fee hook. | verified |

## Current managers

Call each manager proxy with the applicable V2 manager ABI. All Prism proxies
share `RobinhoodPrismTokenManagerV2`; the Native proxy uses
`RobinhoodNativePairTokenManagerV2`.

| Pair | Type | Pair/quote token | Manager proxy | Price helper | Status |
| --- | --- | --- | --- | --- | --- |
| NATIVE | native | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | [`0x45537848Cb5bC7DC30cA3188E5E9a6dD1dD8e8A5`](https://robinhoodchain.blockscout.com/address/0x45537848Cb5bC7DC30cA3188E5E9a6dD1dD8e8A5?tab=contract) | `0x24a21CB67D0e6609D26Cc678db7ef13bffFEC142` | active |
| NVDA | prism | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | [`0x2AF1D4240F9c5Bdd8142a73F55E0E74B39E79A36`](https://robinhoodchain.blockscout.com/address/0x2AF1D4240F9c5Bdd8142a73F55E0E74B39E79A36?tab=contract) | `0x490e7D4D30c9a5501B1fbf1A848fa7BB0DDaA606` | active |
| SPCX | prism | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` | [`0x7685Ff498685247bB3419d2982281EB002FF4dB6`](https://robinhoodchain.blockscout.com/address/0x7685Ff498685247bB3419d2982281EB002FF4dB6?tab=contract) | `0x6367B02ea0EDfe618191E61E10E483A5182d6bE0` | active |
| AAPL | prism | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | [`0x39CAb5AeB881ED8349DBe175393a85A3f38DAAA2`](https://robinhoodchain.blockscout.com/address/0x39CAb5AeB881ED8349DBe175393a85A3f38DAAA2?tab=contract) | `0xe4AcEd9c5e86FfF0705a261ca3D454AC8f400beA` | active |
| META | prism | `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35` | [`0x86991083946269c51Fe258b2Fd80b01b5685333E`](https://robinhoodchain.blockscout.com/address/0x86991083946269c51Fe258b2Fd80b01b5685333E?tab=contract) | `0xa5e155E39c60d6841A924C989F250daDc5600cD3` | active |
| TSLA | prism | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | [`0x2eaDc658bA72a7857EA179550B157D95a1dB2577`](https://robinhoodchain.blockscout.com/address/0x2eaDc658bA72a7857EA179550B157D95a1dB2577?tab=contract) | `0xb24b67C9B258723B694F13436062b8C8f94f5D8c` | active |
| GOOGL | prism | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` | [`0xA4481587FD0BF5BA1c0948A65e49A6558109E5AE`](https://robinhoodchain.blockscout.com/address/0xA4481587FD0BF5BA1c0948A65e49A6558109E5AE?tab=contract) | `0x5b429E387e262972B4c13061B6A359b869a894c7` | active |
| ARENA | prism | `0x50832d74a7160E2f7d361F5E678E107D228B9Aa6` | [`0x1ed84696a221D767249A0d26B6FEb02C645de0d5`](https://robinhoodchain.blockscout.com/address/0x1ed84696a221D767249A0d26B6FEb02C645de0d5?tab=contract) | `0x0b0E3668457418167CC612811E4bEFd50E187690` | active |
| PACK | prism | `0x0145AcbcceFbEd6F303C420bEeaaAc72E905430b` | [`0x8a9B8FbC2d621e334af996623269c6C81E24ef8c`](https://robinhoodchain.blockscout.com/address/0x8a9B8FbC2d621e334af996623269c6C81E24ef8c?tab=contract) | `0x76FD5ccBe09Ec8F08893Fb7602097B458463fEcF` | active |
| THROBBIN | prism | `0xe8fB470E0685437d7739BD2AacBA60b228800335` | [`0x07478206AF95faD0dC2F99627C3AbbbCa82A74D5`](https://robinhoodchain.blockscout.com/address/0x07478206AF95faD0dC2F99627C3AbbbCa82A74D5?tab=contract) | `0x8e5A509d3cA2261700A7a9421A2b252CB867b942` | active |
| GME | prism | `0x1b0E319c6A659F002271B69dB8A7df2F911c153E` | [`0xB10A1c88589c4C5bbbbd148fA9c9aC74dB9275e1`](https://robinhoodchain.blockscout.com/address/0xB10A1c88589c4C5bbbbd148fA9c9aC74dB9275e1?tab=contract) | `0x69A6830139bd26b9fbdB652576D67335311c77E3` | active |
| SPY | prism | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` | [`0x7CFF546D83059Dbb5111b06109dA7F2e1bC69748`](https://robinhoodchain.blockscout.com/address/0x7CFF546D83059Dbb5111b06109dA7F2e1bC69748?tab=contract) | `0x81Aa9B2a25087C7930E585499cbdB7F12071De63` | active-rollout |
| AMD | prism | `0x86923f96303D656E4aa86D9d42D1e57ad2023fdC` | [`0x9644221c99c6146741d00865b36854e7b82ADA2D`](https://robinhoodchain.blockscout.com/address/0x9644221c99c6146741d00865b36854e7b82ADA2D?tab=contract) | `0x580f33176aB0A9d634f6d4649a628F9acA06E609` | deferred-paused |
| AMZN | prism | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` | [`0x8B1870829baB552EBA5528E5f38F76260218EA9c`](https://robinhoodchain.blockscout.com/address/0x8B1870829baB552EBA5528E5f38F76260218EA9c?tab=contract) | `0x0c22b545e177be29E0Be5cE2bBDbE812EBd918D6` | active-rollout |
| MSFT | prism | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` | [`0x3f61929D61bA1f905D862E945E11c4C20fFbf5E6`](https://robinhoodchain.blockscout.com/address/0x3f61929D61bA1f905D862E945E11c4C20fFbf5E6?tab=contract) | `0x3eD9c358252Fb15407760936f6c458AB34e4FCD8` | active-rollout |
| MU | prism | `0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD` | [`0x643c95865CA3713fc76D5d810C209C031f747830`](https://robinhoodchain.blockscout.com/address/0x643c95865CA3713fc76D5d810C209C031f747830?tab=contract) | `0x0e339bDE02cf367E25c5199FF3338F8c8c21Fb76` | active-rollout |
| PLTR | prism | `0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A` | [`0xCe761bCDb7b1a8E05c45db9620a100b059ca1F78`](https://robinhoodchain.blockscout.com/address/0xCe761bCDb7b1a8E05c45db9620a100b059ca1F78?tab=contract) | `0x182e3b626C91374C148b18C9EB903De25409e566` | deferred-paused |
| COST | prism | `0x4EA005168D7F09a7A0Ba9D1DEf21a479950E44C2` | [`0x897420b8F4d972d22bb2751A37B69C7683E816b8`](https://robinhoodchain.blockscout.com/address/0x897420b8F4d972d22bb2751A37B69C7683E816b8?tab=contract) | `0xd89e8411E170B6948EB0741504880E304a96Ebd2` | active-rollout |
| QQQ | prism | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` | [`0xD67DaC287F35d74b1aefE2651B3e8eDc9A61592b`](https://robinhoodchain.blockscout.com/address/0xD67DaC287F35d74b1aefE2651B3e8eDc9A61592b?tab=contract) | `0x84F22A660CA140D7572918AEc183160FeEF39264` | active-rollout |
| GLD | prism | `0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e` | [`0xF9E95D009B64c78A4f84E39a85c2FCa1238B0Cf9`](https://robinhoodchain.blockscout.com/address/0xF9E95D009B64c78A4f84E39a85c2FCa1238B0Cf9?tab=contract) | `0x4c664de27f56430977D083a91983BD9e7676F91b` | active-rollout |
| LLY | prism | `0x8005d266423c7ea827372c9c864491e5786600ea` | [`0x3B2993c8A2c3B5Ee0Dbc5c761a263A60ECeDEB0c`](https://robinhoodchain.blockscout.com/address/0x3B2993c8A2c3B5Ee0Dbc5c761a263A60ECeDEB0c?tab=contract) | `0x65954785fdb7f5219CE363f4bBd34622F4036306` | active-rollout |
| TSM | prism | `0x58FfE4a942d3885bAa22D7520691F611EF09e7AA` | [`0xbc0A2a94CD5D8ECD696efD6efb0240EDbAbCf850`](https://robinhoodchain.blockscout.com/address/0xbc0A2a94CD5D8ECD696efD6efb0240EDbAbCf850?tab=contract) | `0x2e480Eb0381169709186df2D3e68E54aAb86Ef58` | active-rollout |
| SKHY | prism | `0x84CAb63bc87912E71ad199ff14A0bA45de68FeF8` | [`0xCd8De3f8D687a857309B8ff79D09e6d99636aBAa`](https://robinhoodchain.blockscout.com/address/0xCd8De3f8D687a857309B8ff79D09e6d99636aBAa?tab=contract) | `0x7B723bAD1DcC0eEb6C6a9c10463fadDEf96d19A9` | deferred-paused |
| USO | prism | `0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344` | [`0x16f9086F4A9C4829c58C5ed7837771005e958644`](https://robinhoodchain.blockscout.com/address/0x16f9086F4A9C4829c58C5ed7837771005e958644?tab=contract) | `0x8418686B47D80348a9d83518B830322EE0c8c01C` | deferred-paused |
| JNJ | prism | `0x03DfbBE0AC4E7bCDaFd08eD41A400326B77D8c80` | [`0x235F704c412E5671304DFeD424dbc6945C21475c`](https://robinhoodchain.blockscout.com/address/0x235F704c412E5671304DFeD424dbc6945C21475c?tab=contract) | `0x93B36685dA417781f84f94D46E827580f5CF6B18` | deferred-paused |
| SLV | prism | `0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f` | [`0x93CD6aA4b04269CDfB749f667020E8b19E0A8AF4`](https://robinhoodchain.blockscout.com/address/0x93CD6aA4b04269CDfB749f667020E8b19E0A8AF4?tab=contract) | `0xd5f5FBc1553785eB880d3B1AA0685EB4a65005cA` | active-rollout |

The active expansion rollout contains SPY, AMZN, MSFT, MU, COST, QQQ, GLD, LLY, TSM, SLV.
The deployed-but-deferred managers are AMD, PLTR, SKHY, USO, JNJ;
they remain represented here so this registry contains every current V2 manager
address without presenting them as open launch pairs.

## Governance and operations

| Role | Address / state |
| --- | --- |
| Production Safe | `0x0c6aCd89b5fFec5D2a5505aA5e7A3aEFC4E1Cff1` |
| Deployment/configuration operator | `0x4D8E431f3d93B57E3CDd3FA9cc4e6D248678933B` |
| Proposed automation operator | `0x3976207A5cb1E55ABC04c4a15048b3d59F0e3CCf` |
| Automation operator currently has keeper role | `false` |
| Keeper setup state | `safe-schedule-required` |
| LP timelock / vault | `0x7d4A72C6EF99E935c1e723b8eD6e38Ac51C8190b` |
| Minimum timelock | `172800` seconds (48 hours) |
| Creation-fee vault | `0x160b4D8fe9D6fe1d10ABd5E18097676948d288A5` |
| Pre-bond protocol-fee recipient | `0x7C85Be2F4043201461EF98124Dd5d273B2f575fF` |
| Post-bond protocol-fee recipient | `0x5Ab2d4181aaE405Cf12DA8E6a0b7596c252F7679` |

The operator private key is intentionally not part of this archive. The keeper
manifest says the role grant still requires Safe scheduling/execution; do not
assume the proposed operator can call vault keeper functions until that state is
updated and verified on-chain.

## Launch policy

V2 uses a fixed supply of `1,000,000,000` tokens (18 decimals), a `75%`
bonding allocation, a `25%` LP allocation, and curve parameters
`a = 65535`, `b = 0`. Prism curves target `$5,000` of pair-token value
at bonding and a `$0.10` creation fee, using the price snapshots recorded in
the deployment manifests. The Native creation fee is
`800000000000000` wei.

## Dynamic launch tokens

There is no single V2 launch-token address. The factory deploys a new
`RobinhoodMixedFeeLaunchToken` for each launch. Its source and ABI are:

- [`RobinhoodMixedFeeLaunchToken.sol`](sources/contractsV2/contracts/robinhood/RobinhoodMixedFeeLaunchToken.sol)
- [`RobinhoodMixedFeeLaunchToken.json`](abis/RobinhoodMixedFeeLaunchToken.json)

Per-launch token addresses, token IDs, pools, and LP NFT IDs are runtime output,
not fixed stack addresses, so they are intentionally excluded from
`addresses.json`.

## External dependencies

These are used by V2 but were not deployed as Arena V2 contracts.

| Key | Address | Purpose |
| --- | --- | --- |
| `weth` | [`0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`](https://robinhoodchain.blockscout.com/address/0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73?tab=contract) | Wrapped native ETH and the Native launch quote token. |
| `uniswapV4PoolManager` | [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://robinhoodchain.blockscout.com/address/0x8366a39CC670B4001A1121B8F6A443A643e40951?tab=contract) | Uniswap v4 core pool singleton. |
| `uniswapV4PositionManager` | [`0x58daec3116aae6D93017bAAea7749052E8a04fA7`](https://robinhoodchain.blockscout.com/address/0x58daec3116aae6D93017bAAea7749052E8a04fA7?tab=contract) | Uniswap v4 LP NFT manager used by the V2 vault. |
| `uniswapV4StateView` | [`0xF3334192D15450CdD385c8B70e03f9A6bD9E673b`](https://robinhoodchain.blockscout.com/address/0xF3334192D15450CdD385c8B70e03f9A6bD9E673b?tab=contract) | Read-only Uniswap v4 pool and position state. |
| `uniswapUniversalRouter` | [`0x8876789976dEcBfCbBbe364623C63652db8C0904`](https://robinhoodchain.blockscout.com/address/0x8876789976dEcBfCbBbe364623C63652db8C0904?tab=contract) | Uniswap swap router used by V2 periphery. |
| `permit2` | [`0x000000000022D473030F116dDEE9F6B43aC78BA3`](https://robinhoodchain.blockscout.com/address/0x000000000022D473030F116dDEE9F6B43aC78BA3?tab=contract) | Allowance and token-transfer layer used by Uniswap routing. |
| `uniswapV3Factory` | [`0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`](https://robinhoodchain.blockscout.com/address/0x1f7d7550B1b028f7571E69A784071F0205FD2EfA?tab=contract) | Uniswap v3 factory used by the V3 Prism native router. |

## Sources, ABIs, and provenance

`sources/` preserves every Arena-local Solidity source unit transitively used
by the archived V2 contracts. Third-party OpenZeppelin and Uniswap package
sources remain package imports and are not vendored. ABI files are raw JSON
arrays suitable for ethers, viem, and web3 clients.

`manifests/` is an exact copy of the authoritative source manifests used to
generate this snapshot. Run `node sync-from-arena-fork-v2.js` after changing
the sibling `arenaFork` deployment records. The generator is offline and does
not read secrets or submit transactions.
