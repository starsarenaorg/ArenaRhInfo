"use strict";

// Regenerates the public V2 archive from arenaFork's deployment manifests.
// This script is deliberately offline: it does not load .env files, use RPC,
// construct a wallet, or submit transactions.

const fs = require("fs");
const path = require("path");
const { createRequire } = require("module");

const ARCHIVE = __dirname;
const ARENA_FORK = path.resolve(ARCHIVE, "../arenaFork");
const DEPLOYMENTS = path.join(ARENA_FORK, "contractsV2/deployments");
const CONTRACTS_PACKAGE = path.join(ARENA_FORK, "contracts");
const requireFromContracts = createRequire(
  path.join(CONTRACTS_PACKAGE, "package.json"),
);

const MANIFEST_NAMES = [
  "robinhood.v2.shared.json",
  "robinhood.v2.production.native.json",
  "robinhood.v2.production.native-replacement.json",
  "robinhood.v2.production.hook.json",
  "robinhood.v2.production.prism.json",
  "robinhood.v2.production.prism-core-replacement.json",
  "robinhood.v2.production.prism-expansion.json",
  "robinhood.v2.production.activation.json",
  "robinhood.v2.production.operator-keeper.json",
  "robinhood.v2.production.verification.json",
  // The production processor proxy reuses this implementation deployment.
  "robinhood.v2.staging.processor-proxy.json",
];
const ROLLOUT_FILES = ["contractsV2/scripts/open-production-prism-expansion-10.js"];

const OPEN_EXPANSION = new Set([
  "SPY",
  "AMZN",
  "MSFT",
  "MU",
  "COST",
  "QQQ",
  "GLD",
  "LLY",
  "TSM",
  "SLV",
]);
const DEFERRED_EXPANSION = new Set(["AMD", "PLTR", "SKHY", "USO", "JNJ"]);

const EXPLORER = "https://robinhoodchain.blockscout.com";
const RPC = "https://rpc.mainnet.chain.robinhood.com";
const ABI_DIR = path.join(ARCHIVE, "abis");
const SOURCE_DIR = path.join(ARCHIVE, "sources");
const MANIFEST_DIR = path.join(ARCHIVE, "manifests");
const ROLLOUT_DIR = path.join(ARCHIVE, "rollouts");

function fail(message) {
  throw new Error(message);
}

function load(name) {
  return JSON.parse(fs.readFileSync(path.join(DEPLOYMENTS, name), "utf8"));
}

const manifests = Object.fromEntries(
  MANIFEST_NAMES.map((name) => [name, load(name)]),
);
const shared = manifests["robinhood.v2.shared.json"];
const native = manifests["robinhood.v2.production.native.json"];
const nativeReplacement =
  manifests["robinhood.v2.production.native-replacement.json"];
const hook = manifests["robinhood.v2.production.hook.json"];
const prism = manifests["robinhood.v2.production.prism.json"];
const core = manifests["robinhood.v2.production.prism-core-replacement.json"];
const expansion = manifests["robinhood.v2.production.prism-expansion.json"];
const activation = manifests["robinhood.v2.production.activation.json"];
const keeper = manifests["robinhood.v2.production.operator-keeper.json"];
const verification = manifests["robinhood.v2.production.verification.json"];
const processor = manifests["robinhood.v2.staging.processor-proxy.json"];

const verificationByAddress = new Map(
  verification.contracts.map((record) => [record.address.toLowerCase(), record]),
);

function verified(address) {
  const record = verificationByAddress.get(address.toLowerCase());
  if (!record) return "not-in-production-verification-report";
  return record.status === "already-verified" ? "verified" : record.status;
}

function abiPath(contractName) {
  return `abis/${contractName}.json`;
}

function deployment(record, role, options = {}) {
  const contractName =
    options.contractName || record.contract || path.basename(record.source, ".sol");
  const sourceUnit = options.source || record.source;
  return {
    address: record.address,
    contractName,
    role,
    source: `sources/${sourceUnit}`,
    sourceUnit,
    abi: abiPath(options.abiContract || contractName),
    verification: options.verification || verified(record.address),
    transaction: record.transaction,
    blockNumber: record.blockNumber,
    ...(options.extra || {}),
  };
}

function manifestSource(name) {
  return `contractsV2/deployments/${name}`;
}

function selectedEconomics(economics) {
  if (!economics) return null;
  return {
    curveScaler: economics.curveScaler,
    terminalReserve: economics.terminalReserve,
    targetReserve: economics.targetReserve,
    targetBondUsdE6: economics.terminalValueUsdE6,
    creationFeeAmount: economics.creationFeeAmount,
    referencePriceUsdE6: economics.referencePriceUsdE6,
    multiplierE18: economics.multiplierE18,
    startingPrice: economics.startingPrice,
    invertedStartingPrice: economics.invertedStartingPrice,
    capturedAt: economics.capturedAt,
  };
}

function prismPair(symbol, pair, rollout, operationalStatus, sourceName) {
  const economics =
    rollout === "core" ? core.economics[symbol] : expansion.economics[symbol];
  return {
    kind: "prism",
    rollout,
    operationalStatus,
    statusSource:
      rollout === "core"
        ? manifestSource("robinhood.v2.production.activation.json")
        : "rollouts/open-production-prism-expansion-10.js",
    pairToken: pair.pairToken,
    tokenIdNamespace: pair.namespace,
    managerProxy: pair.manager.address,
    managerProxyContract: "RobinhoodTokenManagerProxy",
    managerProxySource:
      "sources/contracts/contracts/proxy/RobinhoodTokenManagerProxy.sol",
    managerProxyTransaction: pair.manager.transaction,
    managerProxyBlockNumber: pair.manager.blockNumber,
    managerImplementation: shared.contracts.prismManagerImplementation.address,
    managerImplementationSource:
      "sources/contractsV2/contracts/robinhood/RobinhoodPrismTokenManagerV2.sol",
    priceHelper: pair.priceHelper.address,
    priceHelperSource:
      "sources/contractsV2/contracts/robinhood/RobinhoodV2PrismPriceHelper.sol",
    priceHelperTransaction: pair.priceHelper.transaction,
    priceHelperBlockNumber: pair.priceHelper.blockNumber,
    managerAbi: abiPath("RobinhoodPrismTokenManagerV2"),
    proxyAbi: abiPath("RobinhoodTokenManagerProxy"),
    priceHelperAbi: abiPath("RobinhoodV2PrismPriceHelper"),
    verification: {
      managerProxy: verified(pair.manager.address),
      implementation: verified(
        shared.contracts.prismManagerImplementation.address,
      ),
      priceHelper: verified(pair.priceHelper.address),
    },
    economics: selectedEconomics(economics),
    deploymentManifest: manifestSource(sourceName),
  };
}

const managerPairs = {
  NATIVE: {
    kind: "native",
    rollout: "core",
    operationalStatus: "active",
    statusSource: manifestSource("robinhood.v2.production.activation.json"),
    quoteToken: native.reused.weth,
    tokenIdNamespace: {
      start: nativeReplacement.initialTokenId,
      endExclusive: core.pairs.NVDA.namespace.start,
    },
    managerProxy: nativeReplacement.contracts.manager.address,
    managerProxyContract: "RobinhoodTokenManagerProxy",
    managerProxySource:
      "sources/contracts/contracts/proxy/RobinhoodTokenManagerProxy.sol",
    managerProxyTransaction: nativeReplacement.contracts.manager.transaction,
    managerProxyBlockNumber: nativeReplacement.contracts.manager.blockNumber,
    managerImplementation: shared.contracts.managerImplementation.address,
    managerImplementationSource:
      "sources/contractsV2/contracts/robinhood/RobinhoodNativePairTokenManagerV2.sol",
    priceHelper: nativeReplacement.contracts.priceHelper.address,
    priceHelperSource:
      "sources/contractsV2/contracts/robinhood/RobinhoodV2NativePriceHelper.sol",
    quoter: nativeReplacement.contracts.quoter.address,
    buyer: nativeReplacement.contracts.buyer.address,
    managerAbi: abiPath("RobinhoodNativePairTokenManagerV2"),
    proxyAbi: abiPath("RobinhoodTokenManagerProxy"),
    priceHelperAbi: abiPath("RobinhoodV2NativePriceHelper"),
    quoterAbi: abiPath("RobinhoodV2NativeQuoter"),
    buyerAbi: abiPath("RobinhoodV2NativeBuyer"),
    verification: {
      managerProxy: verified(nativeReplacement.contracts.manager.address),
      implementation: verified(shared.contracts.managerImplementation.address),
      priceHelper: verified(nativeReplacement.contracts.priceHelper.address),
      quoter: verified(nativeReplacement.contracts.quoter.address),
      buyer: verified(nativeReplacement.contracts.buyer.address),
    },
    economics: {
      curveScaler: nativeReplacement.curves.production.scaler,
      terminalReserve: nativeReplacement.curves.production.terminalReserve,
      creationFeeAmount: nativeReplacement.productionBaseline.creationFeeAmount,
      startingPrice: nativeReplacement.productionBaseline.pool.startingPrice,
      invertedStartingPrice: nativeReplacement.productionBaseline.invertedStartingPrice,
    },
    deploymentManifest: manifestSource(
      "robinhood.v2.production.native-replacement.json",
    ),
  },
};

for (const [symbol, pair] of Object.entries(core.pairs)) {
  managerPairs[symbol] = prismPair(
    symbol,
    pair,
    "core",
    "active",
    "robinhood.v2.production.prism-core-replacement.json",
  );
}
for (const [symbol, pair] of Object.entries(expansion.pairs)) {
  const operationalStatus = OPEN_EXPANSION.has(symbol)
    ? "active-rollout"
    : "deferred-paused";
  managerPairs[symbol] = prismPair(
    symbol,
    pair,
    "expansion",
    operationalStatus,
    "robinhood.v2.production.prism-expansion.json",
  );
}

const coreContracts = {
  lpVault: deployment(
    native.contracts.lpVault,
    "48-hour timelocked custody and automation vault for Uniswap v4 LP NFTs.",
  ),
  dividendController: deployment(
    native.contracts.controller,
    "Registers launch tokens and coordinates dividend accounting/distribution.",
  ),
  dividendProcessor: deployment(
    native.contracts.processorProxy,
    "Upgradeable processor used for holder dividend distributions.",
    {
      contractName: "RobinhoodDividendProcessor",
      abiContract: "RobinhoodDividendProcessor",
      source: processor.contracts.processorImplementation.source,
      extra: {
        proxyContractName: "RobinhoodTokenManagerProxy",
        proxyAbi: abiPath("RobinhoodTokenManagerProxy"),
        implementation: processor.contracts.processorImplementation.address,
        implementationVerification: verified(
          processor.contracts.processorImplementation.address,
        ),
      },
    },
  ),
  tokenFactory: deployment(
    native.contracts.tokenFactory,
    "Deploys RobinhoodMixedFeeLaunchToken instances for V2 launches.",
  ),
  poolDeployer: deployment(
    native.contracts.poolDeployer,
    "Initializes post-bond pools and deposits LP NFTs into the V2 vault.",
  ),
  dividendFeeHelper: deployment(
    hook.contracts.productionFeeHelper,
    "Splits and routes post-bond protocol, referral, and dividend fees.",
  ),
  mixedFeeHook: deployment(
    hook.contracts.mixedHook,
    "Shared Uniswap v4 hook for protocol fees and token-holder dividends.",
  ),
  referralRegistry: {
    address: native.reused.referralRegistry,
    contractName: "RobinhoodArenaReferralRegistry",
    role: "V1 referral registry reused by the V2 managers and fee helper.",
    source:
      "sources/contracts/contracts/robinhood/RobinhoodArenaReferralRegistry.sol",
    sourceUnit:
      "contracts/contracts/robinhood/RobinhoodArenaReferralRegistry.sol",
    abi: abiPath("RobinhoodArenaReferralRegistry"),
    verification: "verified-reused-v1-deployment",
  },
};

const implementationContracts = {
  nativeManager: deployment(
    shared.contracts.managerImplementation,
    "Implementation used by the current Native manager proxy.",
  ),
  prismManager: deployment(
    shared.contracts.prismManagerImplementation,
    "Implementation shared by all current Prism manager proxies.",
  ),
  dividendProcessor: deployment(
    processor.contracts.processorImplementation,
    "Implementation selected by the production dividend processor proxy.",
  ),
  mixedHookFactory: {
    address: hook.contracts.mixedHook.factory,
    contractName: "RobinhoodMixedFeeHookFactory",
    role: "CREATE2 factory used to deploy the current production mixed-fee hook.",
    source:
      "sources/contractsV2/contracts/robinhood/RobinhoodMixedFeeHookFactory.sol",
    sourceUnit:
      "contractsV2/contracts/robinhood/RobinhoodMixedFeeHookFactory.sol",
    abi: abiPath("RobinhoodMixedFeeHookFactory"),
    verification: "reused-deployment-not-in-production-verification-report",
  },
  legacyDividendHookFactory: deployment(
    shared.contracts.hookFactory,
    "Earlier V2 dividend-hook CREATE2 factory retained in the shared manifest; not the factory of the current mixed-fee hook.",
  ),
};

const peripheryContracts = {
  prismRegistry: deployment(
    prism.contracts.registry,
    "Maps supported Prism pair tokens to their active manager proxies.",
  ),
  prismQuoter: deployment(
    prism.contracts.quoter,
    "Read-only quoting for V2 Prism launch and purchase flows.",
  ),
  prismBuyer: deployment(
    prism.contracts.buyer,
    "Atomic V2 Prism launch and initial purchase helper.",
  ),
  prismNativeRouterV4: deployment(
    prism.contracts.routerV4,
    "Native-asset entry and exit router through Uniswap v4.",
  ),
  prismNativeRouterV3: deployment(
    prism.contracts.routerV3,
    "Native-asset entry and exit router through Uniswap v3.",
  ),
  nativePriceHelper: deployment(
    nativeReplacement.contracts.priceHelper,
    "Read-only Native manager price helper.",
  ),
  nativeQuoter: deployment(
    nativeReplacement.contracts.quoter,
    "Quotes current V2 Native launch and purchase flows.",
  ),
  nativeBuyer: deployment(
    nativeReplacement.contracts.buyer,
    "Atomic current V2 Native launch and initial purchase helper.",
  ),
};

const addresses = {
  schemaVersion: 2,
  stack: "Arena launchpad V2",
  chain: {
    name: "Robinhood Chain",
    chainId: 4663,
    rpc: RPC,
    explorer: EXPLORER,
  },
  snapshot: {
    sourceRepository: "../arenaFork",
    latestManifestUpdate: verification.updatedAt,
    verificationSummary: verification.summary,
    note: "Fixed production infrastructure only. Per-launch token addresses are dynamic protocol output.",
    manifests: MANIFEST_NAMES.map((name) => `manifests/${name}`),
    rolloutEvidence: ROLLOUT_FILES.map(
      (name) => `rollouts/${path.basename(name)}`,
    ),
  },
  governance: {
    productionSafe: native.productionSafe,
    deploymentOperator: native.productionDeployer,
    automationOperator: keeper.operator,
    automationOperatorHasKeeperRole: keeper.operatorIsKeeper,
    automationKeeperStatus: keeper.status,
    minimumTimelockSeconds: keeper.minimumDelay,
    feeRecipients: {
      creationFeeVault:
        nativeReplacement.productionBaseline.creationFeeVault,
      preBondProtocolFee:
        nativeReplacement.productionBaseline.protocolFeeDestination,
      postBondProtocolFee: hook.configuration.protocolFeeRecipient,
    },
  },
  launchPolicy: {
    totalSupplyWei: core.policy.totalSupply,
    totalSupplyTokens: "1000000000",
    salePercentage: core.policy.salePercentage,
    lpPercentage: core.policy.lpPercentage,
    curveA: core.policy.curveA,
    curveB: core.policy.curveB,
    targetBondUsdE6: core.policy.targetBondUsdE6,
    targetCreationFeeUsdE6: core.policy.targetCreationFeeUsdE6,
    postBondProtocolFeePpm: String(hook.configuration.protocolFeePpm),
    referralFeePpm: String(hook.configuration.referralFeePpm),
  },
  implementations: implementationContracts,
  coreContracts,
  peripheryContracts,
  managerPairs,
  externalDependencies: {
    weth: native.reused.weth,
    uniswapV4PoolManager: native.reused.poolManager,
    uniswapV4PositionManager: native.reused.positionManager,
    uniswapV4StateView: "0xF3334192D15450CdD385c8B70e03f9A6bD9E673b",
    uniswapUniversalRouter: native.reused.universalRouter,
    permit2: native.reused.permit2,
    uniswapV3Factory: prism.dependencies.v3Factory,
  },
  rollout: {
    coreActive: ["NATIVE", ...Object.keys(core.pairs)],
    expansionActive: [...OPEN_EXPANSION],
    expansionDeferred: [...DEFERRED_EXPANSION],
    coreActivationCompletedAt: activation.completedAt,
  },
};

function sourceFile(sourceUnit) {
  const local = path.join(ARENA_FORK, sourceUnit);
  if (fs.existsSync(local)) return local;
  const dependency = path.join(CONTRACTS_PACKAGE, "node_modules", sourceUnit);
  if (fs.existsSync(dependency)) return dependency;
  fail(`Missing source unit: ${sourceUnit}`);
}

function importsFrom(source) {
  const imports = [];
  const pattern = /import\s+(?:(?:[^"']*?)\s+from\s+)?["']([^"']+)["']\s*;/g;
  for (let match = pattern.exec(source); match; match = pattern.exec(source)) {
    imports.push(match[1]);
  }
  return imports;
}

function normalizeImport(importer, imported) {
  if (!imported.startsWith(".")) return imported;
  return path.posix.normalize(
    path.posix.join(path.posix.dirname(importer), imported),
  );
}

const archiveSourceUnits = new Set();
function collectSources(entry) {
  const sources = {};
  const pending = [entry];
  while (pending.length > 0) {
    const sourceUnit = pending.pop();
    if (sources[sourceUnit]) continue;
    const content = fs.readFileSync(sourceFile(sourceUnit), "utf8");
    sources[sourceUnit] = { content };
    if (
      sourceUnit.startsWith("contracts/") ||
      sourceUnit.startsWith("contractsV2/")
    ) {
      archiveSourceUnits.add(sourceUnit);
    }
    for (const imported of importsFrom(content)) {
      pending.push(normalizeImport(sourceUnit, imported));
    }
  }
  return sources;
}

const compilerCache = new Map();
function compiler(version) {
  if (compilerCache.has(version)) return compilerCache.get(version);
  const names = {
    "0.8.26": "solc",
    "0.8.28": "solc-0.8.28",
    "0.8.30": "solc-0.8.30",
  };
  if (!names[version]) fail(`Unsupported compiler: ${version}`);
  const instance = requireFromContracts(names[version]);
  compilerCache.set(version, instance);
  return instance;
}

function shortCompiler(recorded) {
  const match = String(recorded).match(/^(0\.8\.(?:26|28|30))/);
  if (!match) fail(`Cannot parse compiler: ${recorded}`);
  return match[1];
}

function compileAbi(spec) {
  const version = shortCompiler(spec.compiler);
  const settings = {
    optimizer: {
      enabled: spec.settings?.optimizer?.enabled !== false,
      runs: Number(spec.settings?.optimizer?.runs || 200),
    },
    viaIR: spec.settings?.viaIR !== false,
    evmVersion: spec.settings?.evmVersion || "cancun",
    outputSelection: { "*": { "*": ["abi"] } },
  };
  const input = {
    language: "Solidity",
    sources: collectSources(spec.source),
    settings,
  };
  const output = JSON.parse(compiler(version).compile(JSON.stringify(input)));
  const errors = (output.errors || []).filter(({ severity }) => severity === "error");
  if (errors.length) {
    fail(errors.map(({ formattedMessage }) => formattedMessage).join("\n"));
  }
  const artifact = output.contracts?.[spec.source]?.[spec.contract];
  if (!artifact) fail(`Missing ABI for ${spec.source}:${spec.contract}`);
  return artifact.abi;
}

function normalizeSpec(record) {
  const pragma = fs
    .readFileSync(sourceFile(record.source), "utf8")
    .match(/pragma\s+solidity\s+[^0-9]*(0\.8\.\d+)/)?.[1];
  const longVersions = {
    "0.8.26": "0.8.26+commit.8a97fa7a.Emscripten.clang",
    "0.8.28": "0.8.28+commit.7893614a.Emscripten.clang",
    "0.8.30": "0.8.30+commit.73712a01.Emscripten.clang",
  };
  return {
    source: record.source,
    contract: record.contract || path.basename(record.source, ".sol"),
    compiler: record.compiler || longVersions[pragma],
    settings: record.settings || {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
      evmVersion: "cancun",
    },
  };
}

function buildAbiSpecs() {
  const specs = verification.contracts.map(normalizeSpec);
  specs.push(
    normalizeSpec({
      source:
        "contractsV2/contracts/robinhood/RobinhoodMixedFeeLaunchToken.sol",
      contract: "RobinhoodMixedFeeLaunchToken",
      compiler: "0.8.28",
    }),
    normalizeSpec({
      source:
        "contractsV2/contracts/robinhood/RobinhoodMixedFeeHookFactory.sol",
      contract: "RobinhoodMixedFeeHookFactory",
      compiler: "0.8.30",
    }),
    normalizeSpec({
      source:
        "contracts/contracts/robinhood/RobinhoodArenaReferralRegistry.sol",
      contract: "RobinhoodArenaReferralRegistry",
      compiler: "0.8.30",
      settings: {
        optimizer: { enabled: true, runs: 200 },
        viaIR: false,
        evmVersion: "cancun",
      },
    }),
  );
  const unique = new Map();
  for (const spec of specs) {
    const key = `${spec.source}:${spec.contract}`;
    if (!unique.has(key)) unique.set(key, spec);
  }
  return [...unique.values()].sort((a, b) =>
    a.contract.localeCompare(b.contract),
  );
}

function resetGeneratedDirectory(directory) {
  fs.rmSync(directory, { recursive: true, force: true });
  fs.mkdirSync(directory, { recursive: true });
}

function writeJson(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function explorerLink(address) {
  return `[\`${address}\`](${EXPLORER}/address/${address}?tab=contract)`;
}

function coreRows(group) {
  return Object.entries(group)
    .map(
      ([key, record]) =>
        `| \`${key}\` | ${explorerLink(record.address)} | ${record.contractName} | ${record.role} | ${record.verification} |`,
    )
    .join("\n");
}

function managerRows() {
  return Object.entries(managerPairs)
    .map(([symbol, record]) => {
      const token = record.pairToken || record.quoteToken;
      const helper = record.priceHelper;
      return `| ${symbol} | ${record.kind} | \`${token}\` | ${explorerLink(record.managerProxy)} | \`${helper}\` | ${record.operationalStatus} |`;
    })
    .join("\n");
}

function externalRows() {
  const roles = {
    weth: "Wrapped native ETH and the Native launch quote token.",
    uniswapV4PoolManager: "Uniswap v4 core pool singleton.",
    uniswapV4PositionManager: "Uniswap v4 LP NFT manager used by the V2 vault.",
    uniswapV4StateView: "Read-only Uniswap v4 pool and position state.",
    uniswapUniversalRouter: "Uniswap swap router used by V2 periphery.",
    permit2: "Allowance and token-transfer layer used by Uniswap routing.",
    uniswapV3Factory: "Uniswap v3 factory used by the V3 Prism native router.",
  };
  return Object.entries(addresses.externalDependencies)
    .map(
      ([key, address]) =>
        `| \`${key}\` | ${explorerLink(address)} | ${roles[key]} |`,
    )
    .join("\n");
}

function makeMainnetMarkdown() {
  return `# Arena V2 Contracts on Robinhood Chain Mainnet

This is the fixed production-infrastructure registry for Arena launchpad V2.
The complete former V1 archive is retained under [\`v1/\`](v1/README.md).

| Network | Value |
| --- | --- |
| Chain | Robinhood Chain mainnet |
| Chain ID | \`4663\` |
| RPC | \`${RPC}\` |
| Explorer | [Robinhood Blockscout](${EXPLORER}) |
| Machine registry | [\`addresses.json\`](addresses.json) |
| ABI index | [\`abis/index.json\`](abis/index.json) |
| Deployment evidence | [\`manifests/\`](manifests/) |

## Verification snapshot

The production verification report was updated at
\`${verification.updatedAt}\` and records **${verification.summary["already-verified"]} exact-match verified deployments**.
That includes the current fixed V2 stack, all current manager proxies and price
helpers, plus the five intentionally deferred expansion managers. Dynamic
launch tokens are separate deployments and are not counted as fixed infrastructure.

## Core contracts

| Key | Address | Contract | Purpose | Verification |
| --- | --- | --- | --- | --- |
${coreRows(coreContracts)}

## Periphery

| Key | Address | Contract | Purpose | Verification |
| --- | --- | --- | --- | --- |
${coreRows(peripheryContracts)}

## Implementations and factories

| Key | Address | Contract | Purpose | Verification |
| --- | --- | --- | --- | --- |
${coreRows(implementationContracts)}

## Current managers

Call each manager proxy with the applicable V2 manager ABI. All Prism proxies
share \`RobinhoodPrismTokenManagerV2\`; the Native proxy uses
\`RobinhoodNativePairTokenManagerV2\`.

| Pair | Type | Pair/quote token | Manager proxy | Price helper | Status |
| --- | --- | --- | --- | --- | --- |
${managerRows()}

The active expansion rollout contains ${[...OPEN_EXPANSION].join(", ")}.
The deployed-but-deferred managers are ${[...DEFERRED_EXPANSION].join(", ")};
they remain represented here so this registry contains every current V2 manager
address without presenting them as open launch pairs.

## Governance and operations

| Role | Address / state |
| --- | --- |
| Production Safe | \`${native.productionSafe}\` |
| Deployment/configuration operator | \`${native.productionDeployer}\` |
| Proposed automation operator | \`${keeper.operator}\` |
| Automation operator currently has keeper role | \`${keeper.operatorIsKeeper}\` |
| Keeper setup state | \`${keeper.status}\` |
| LP timelock / vault | \`${native.contracts.lpVault.address}\` |
| Minimum timelock | \`${keeper.minimumDelay}\` seconds (48 hours) |
| Creation-fee vault | \`${nativeReplacement.productionBaseline.creationFeeVault}\` |
| Pre-bond protocol-fee recipient | \`${nativeReplacement.productionBaseline.protocolFeeDestination}\` |
| Post-bond protocol-fee recipient | \`${hook.configuration.protocolFeeRecipient}\` |

The operator private key is intentionally not part of this archive. The keeper
manifest says the role grant still requires Safe scheduling/execution; do not
assume the proposed operator can call vault keeper functions until that state is
updated and verified on-chain.

## Launch policy

V2 uses a fixed supply of \`1,000,000,000\` tokens (18 decimals), a \`75%\`
bonding allocation, a \`25%\` LP allocation, and curve parameters
\`a = 65535\`, \`b = 0\`. Prism curves target \`$5,000\` of pair-token value
at bonding and a \`$0.10\` creation fee, using the price snapshots recorded in
the deployment manifests. The Native creation fee is
\`${nativeReplacement.productionBaseline.creationFeeAmount}\` wei.

## Dynamic launch tokens

There is no single V2 launch-token address. The factory deploys a new
\`RobinhoodMixedFeeLaunchToken\` for each launch. Its source and ABI are:

- [\`RobinhoodMixedFeeLaunchToken.sol\`](sources/contractsV2/contracts/robinhood/RobinhoodMixedFeeLaunchToken.sol)
- [\`RobinhoodMixedFeeLaunchToken.json\`](abis/RobinhoodMixedFeeLaunchToken.json)

Per-launch token addresses, token IDs, pools, and LP NFT IDs are runtime output,
not fixed stack addresses, so they are intentionally excluded from
\`addresses.json\`.

## External dependencies

These are used by V2 but were not deployed as Arena V2 contracts.

| Key | Address | Purpose |
| --- | --- | --- |
${externalRows()}

## Sources, ABIs, and provenance

\`sources/\` preserves every Arena-local Solidity source unit transitively used
by the archived V2 contracts. Third-party OpenZeppelin and Uniswap package
sources remain package imports and are not vendored. ABI files are raw JSON
arrays suitable for ethers, viem, and web3 clients.

\`manifests/\` is an exact copy of the authoritative source manifests used to
generate this snapshot. Run \`node sync-from-arena-fork-v2.js\` after changing
the sibling \`arenaFork\` deployment records. The generator is offline and does
not read secrets or submit transactions.
`;
}

function makeReadme() {
  return `# Arena Robinhood Contract Archive

The repository root is the current **Arena V2** production reference for
Robinhood Chain. The previous complete V1 snapshot is preserved under
[\`v1/\`](v1/README.md).

- [\`mainnet.md\`](mainnet.md): readable V2 address and status registry
- [\`addresses.json\`](addresses.json): machine-readable V2 registry
- [\`frontend-production-config.json\`](frontend-production-config.json): V2 launch economics and pair configuration
- [\`abis/\`](abis/): generated raw ABI arrays and index
- [\`sources/\`](sources/): Arena-local V2 Solidity source closure
- [\`manifests/\`](manifests/): authoritative deployment-manifest snapshot
- [\`rollouts/\`](rollouts/): activation/status evidence not stored as a manifest
- [\`v1/\`](v1/): untouched prior V1 documentation, sources, ABIs, and configuration

Refresh the V2 snapshot from the sibling repository with:

\`\`\`sh
node sync-from-arena-fork-v2.js
\`\`\`

The sync script is offline and never reads an \`.env\` file or private key.
`;
}

function makeFrontendConfig() {
  const pairs = Object.fromEntries(
    Object.entries(managerPairs).map(([symbol, pair]) => [
      symbol,
      {
        enabled: pair.operationalStatus === "active" ||
          pair.operationalStatus === "active-rollout",
        kind: pair.kind,
        manager: pair.managerProxy,
        pairToken: pair.pairToken || pair.quoteToken,
        priceHelper: pair.priceHelper,
        tokenIdNamespace: pair.tokenIdNamespace,
        economics: pair.economics,
      },
    ]),
  );
  return {
    source: [
      manifestSource("robinhood.v2.production.native-replacement.json"),
      manifestSource("robinhood.v2.production.prism-core-replacement.json"),
      manifestSource("robinhood.v2.production.prism-expansion.json"),
      manifestSource("robinhood.v2.production.activation.json"),
    ],
    chainId: 4663,
    launchEconomics: addresses.launchPolicy,
    pairs,
  };
}

function main() {
  for (const required of [ARENA_FORK, CONTRACTS_PACKAGE, DEPLOYMENTS]) {
    if (!fs.existsSync(required)) fail(`Missing required path: ${required}`);
  }

  resetGeneratedDirectory(ABI_DIR);
  resetGeneratedDirectory(SOURCE_DIR);
  resetGeneratedDirectory(MANIFEST_DIR);
  resetGeneratedDirectory(ROLLOUT_DIR);

  const abiIndex = {};
  for (const spec of buildAbiSpecs()) {
    const abi = compileAbi(spec);
    const file = `${spec.contract}.json`;
    writeJson(path.join(ABI_DIR, file), abi);
    abiIndex[spec.contract] = {
      file: `abis/${file}`,
      source: `sources/${spec.source}`,
    };
  }

  const positionManagerAbi = path.join(
    ARCHIVE,
    "v1/abis/UniswapV4PositionManager.json",
  );
  if (fs.existsSync(positionManagerAbi)) {
    fs.copyFileSync(
      positionManagerAbi,
      path.join(ABI_DIR, "UniswapV4PositionManager.json"),
    );
    abiIndex.UniswapV4PositionManager = {
      file: "abis/UniswapV4PositionManager.json",
      source: "external-uniswap-v4",
    };
  }
  writeJson(path.join(ABI_DIR, "index.json"), abiIndex);

  for (const sourceUnit of [...archiveSourceUnits].sort()) {
    const destination = path.join(SOURCE_DIR, sourceUnit);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(sourceFile(sourceUnit), destination);
  }
  for (const name of MANIFEST_NAMES) {
    fs.copyFileSync(path.join(DEPLOYMENTS, name), path.join(MANIFEST_DIR, name));
  }
  for (const source of ROLLOUT_FILES) {
    fs.copyFileSync(
      path.join(ARENA_FORK, source),
      path.join(ROLLOUT_DIR, path.basename(source)),
    );
  }

  writeJson(path.join(ARCHIVE, "addresses.json"), addresses);
  writeJson(
    path.join(ARCHIVE, "frontend-production-config.json"),
    makeFrontendConfig(),
  );
  fs.writeFileSync(path.join(ARCHIVE, "mainnet.md"), makeMainnetMarkdown());
  fs.writeFileSync(path.join(ARCHIVE, "README.md"), makeReadme());

  console.log(
    `Wrote ${Object.keys(managerPairs).length} managers, ` +
      `${Object.keys(abiIndex).length} ABIs, ` +
      `${archiveSourceUnits.size} Arena-local sources, and ` +
      `${MANIFEST_NAMES.length} manifests.`,
  );
}

main();
