"use strict";

// Opens only the ten production Prism V2 pairs in this rollout. Without
// --broadcast, this is a read-only status check.
//
// node contractsV2/scripts/open-production-prism-expansion-10.js
// node contractsV2/scripts/open-production-prism-expansion-10.js \
//   --broadcast --confirm=OPEN_RH_V2_PRODUCTION_PRISM_EXPANSION_10

const fs = require("fs");
const path = require("path");
const { createRequire } = require("module");

const ROOT = path.resolve(__dirname, "../..");
const CONTRACTS_PACKAGE = path.join(ROOT, "contracts");
const requireFromContracts = createRequire(
  path.join(CONTRACTS_PACKAGE, "package.json"),
);
const { Contract, JsonRpcProvider, Wallet, getAddress } =
  requireFromContracts("ethers");

const CHAIN_ID = 4663n;
const RPC_URL =
  process.env.ROBINHOOD_MAINNET_RPC_URL ||
  "https://rpc.mainnet.chain.robinhood.com";
const BROADCAST = process.argv.includes("--broadcast");
const CONFIRMATION = "OPEN_RH_V2_PRODUCTION_PRISM_EXPANSION_10";
const CONFIRMED = process.argv.includes(`--confirm=${CONFIRMATION}`);

const OPERATOR = "0x4D8E431f3d93B57E3CDd3FA9cc4e6D248678933B";
const CONTROLLER = "0xa8F6Cb031C5f0f923909842D4435687e250559bC";
const REGISTRY = "0xF50316b2174c605F53aC37812D83b031D162AD70";
const FEE_HELPER = "0xB28DD2fC871BA2960a4c84b81a13Facca87051bB";
const POOL_DEPLOYER = "0x4B400e1AcC76729BE6A86C3fC73Ab2b8d80B78EF";
const LP_VAULT = "0x7d4A72C6EF99E935c1e723b8eD6e38Ac51C8190b";
const TOKEN_FACTORY = "0x3d1170c9ea8Bb49A58bAAf3378C7c97E59Bb2800";
const NATIVE_HELPER = "0x898f0fFdF329f50B020CEe5666FfB3602E469b8d";

const PAIRS = [
  ["SPY", "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C", "0x7CFF546D83059Dbb5111b06109dA7F2e1bC69748"],
  ["AMZN", "0x12f190a9F9d7D37a250758b26824B97CE941bF54", "0x8B1870829baB552EBA5528E5f38F76260218EA9c"],
  ["MSFT", "0xe93237C50D904957Cf27E7B1133b510C669c2e74", "0x3f61929D61bA1f905D862E945E11c4C20fFbf5E6"],
  ["MU", "0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD", "0x643c95865CA3713fc76D5d810C209C031f747830"],
  ["COST", "0x4EA005168D7F09a7A0Ba9D1DEf21a479950E44C2", "0x897420b8F4d972d22bb2751A37B69C7683E816b8"],
  ["QQQ", "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68", "0xD67DaC287F35d74b1aefE2651B3e8eDc9A61592b"],
  ["GLD", "0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e", "0xF9E95D009B64c78A4f84E39a85c2FCa1238B0Cf9"],
  ["LLY", "0x8005d266423c7ea827372c9c864491e5786600ea", "0x3B2993c8A2c3B5Ee0Dbc5c761a263A60ECeDEB0c"],
  ["TSM", "0x58FfE4a942d3885bAa22D7520691F611EF09e7AA", "0xbc0A2a94CD5D8ECD696efD6efb0240EDbAbCf850"],
  ["SLV", "0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f", "0x93CD6aA4b04269CDfB749f667020E8b19E0A8AF4"],
].map(([symbol, token, manager]) => ({ symbol, token, manager }));

const DEFERRED_PAIRS = [
  ["AMD", "0x86923f96303D656E4aa86D9d42D1e57ad2023fdC", "0x9644221c99c6146741d00865b36854e7b82ADA2D"],
  ["PLTR", "0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A", "0xCe761bCDb7b1a8E05c45db9620a100b059ca1F78"],
  ["SKHY", "0x84CAb63bc87912E71ad199ff14A0bA45de68FeF8", "0xCd8De3f8D687a857309B8ff79D09e6d99636aBAa"],
  ["USO", "0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344", "0x16f9086F4A9C4829c58C5ed7837771005e958644"],
  ["JNJ", "0x03DfbBE0AC4E7bCDaFd08eD41A400326B77D8c80", "0x235F704c412E5671304DFeD424dbc6945C21475c"],
].map(([symbol, token, manager]) => ({ symbol, token, manager }));

const MANAGER_ABI = [
  "function owner() view returns (address)",
  "function paused() view returns (bool)",
  "function unpause()",
  "function canDeployLp() view returns (bool)",
  "function PAIR_TOKEN() view returns (address)",
  "function NATIVE_HELPER() view returns (address)",
  "function tokenFactory() view returns (address)",
  "function dividendController() view returns (address)",
  "function dividendFeeHelper() view returns (address)",
  "function arenaPoolDeployer() view returns (address)",
  "function LP_TOKEN_VAULT() view returns (address)",
];
const CONTROLLER_ABI = [
  "function owner() view returns (address)",
  "function isRegistrar(address) view returns (bool)",
  "function setRegistrar(address,bool)",
];
const REGISTRY_ABI = [
  "function owner() view returns (address)",
  "function getPair(address) view returns (tuple(address manager,uint8 decimals,bool enabled,string label))",
  "function isApprovedManager(address) view returns (bool)",
  "function setPairEnabled(address,bool)",
];

class RetryJsonRpcProvider extends JsonRpcProvider {
  async _send(payload) {
    const requests = Array.isArray(payload) ? payload : [payload];
    const retryable = requests.every(
      ({ method }) =>
        method !== "eth_sendRawTransaction" && method !== "eth_sendTransaction",
    );
    const attempts = retryable ? 6 : 1;
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        return await super._send(payload);
      } catch (error) {
        if (attempt === attempts) throw error;
        await new Promise((resolve) => setTimeout(resolve, attempt * 1_000));
      }
    }
    throw new Error("RPC retry loop exhausted");
  }
}

function fail(message) {
  throw new Error(message);
}

function requireCondition(condition, message) {
  if (!condition) fail(message);
}

function sameAddress(left, right) {
  return getAddress(left) === getAddress(right);
}

function expectAddress(actual, expected, label) {
  requireCondition(sameAddress(actual, expected), `${label} mismatch`);
}

function loadLocalEnv() {
  for (const name of [".env", ".env.local"]) {
    const file = path.join(CONTRACTS_PACKAGE, name);
    if (!fs.existsSync(file)) continue;
    for (const rawLine of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
      const line = rawLine.trim();
      if (!line || line.startsWith("#")) continue;
      const separator = line.indexOf("=");
      if (separator < 1) continue;
      const key = line.slice(0, separator).trim();
      if (process.env[key] !== undefined) continue;
      let value = line.slice(separator + 1).trim();
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1);
      }
      process.env[key] = value;
    }
  }
}

async function readPairState(pair, provider, controller, registry) {
  const manager = new Contract(pair.manager, MANAGER_ABI, provider);
  expectAddress(await manager.owner(), OPERATOR, `${pair.symbol} owner`);
  expectAddress(await manager.PAIR_TOKEN(), pair.token, `${pair.symbol} pair token`);
  expectAddress(await manager.NATIVE_HELPER(), NATIVE_HELPER, `${pair.symbol} native helper`);
  expectAddress(await manager.tokenFactory(), TOKEN_FACTORY, `${pair.symbol} token factory`);
  expectAddress(await manager.dividendController(), CONTROLLER, `${pair.symbol} controller`);
  expectAddress(await manager.dividendFeeHelper(), FEE_HELPER, `${pair.symbol} fee helper`);
  expectAddress(await manager.arenaPoolDeployer(), POOL_DEPLOYER, `${pair.symbol} pool deployer`);
  expectAddress(await manager.LP_TOKEN_VAULT(), LP_VAULT, `${pair.symbol} LP vault`);
  requireCondition(await manager.canDeployLp(), `${pair.symbol} LP deployment is disabled`);

  const registered = await registry.getPair(pair.token);
  expectAddress(registered.manager, pair.manager, `${pair.symbol} registry manager`);
  requireCondition(registered.decimals === 18n, `${pair.symbol} registry decimals mismatch`);
  requireCondition(registered.label === pair.symbol, `${pair.symbol} registry label mismatch`);

  return {
    ...pair,
    contract: manager,
    paused: await manager.paused(),
    registrarEnabled: await controller.isRegistrar(pair.manager),
    registryEnabled: registered.enabled,
    approvedManager: await registry.isApprovedManager(pair.manager),
  };
}

async function requireDeferredClosed(provider, controller, registry) {
  for (const pair of DEFERRED_PAIRS) {
    const manager = new Contract(pair.manager, MANAGER_ABI, provider);
    const registered = await registry.getPair(pair.token);
    expectAddress(await manager.owner(), OPERATOR, `${pair.symbol} owner`);
    expectAddress(await manager.PAIR_TOKEN(), pair.token, `${pair.symbol} pair token`);
    expectAddress(registered.manager, pair.manager, `${pair.symbol} registry manager`);
    requireCondition(await manager.paused(), `${pair.symbol} must remain paused`);
    requireCondition(
      !(await controller.isRegistrar(pair.manager)),
      `${pair.symbol} must remain outside the controller registrar set`,
    );
    requireCondition(!registered.enabled, `${pair.symbol} registry entry must remain disabled`);
  }
}

async function send(label, contract, method, args, configured, signer) {
  if (await configured()) {
    console.log(`${label}: already configured`);
    return;
  }
  const transaction = await contract.connect(signer)[method](...args);
  console.log(`${label}: ${transaction.hash}`);
  const receipt = await transaction.wait(1);
  requireCondition(receipt?.status === 1, `${label} reverted`);
  requireCondition(await configured(), `${label} readback failed`);
}

async function main() {
  if (BROADCAST && !CONFIRMED) {
    fail(`Broadcast requires --confirm=${CONFIRMATION}`);
  }

  const provider = new RetryJsonRpcProvider(
    RPC_URL,
    { chainId: Number(CHAIN_ID), name: "robinhoodMainnet" },
    { staticNetwork: true, batchMaxCount: 1 },
  );
  requireCondition((await provider.getNetwork()).chainId === CHAIN_ID, "Wrong chain");

  const controller = new Contract(CONTROLLER, CONTROLLER_ABI, provider);
  const registry = new Contract(REGISTRY, REGISTRY_ABI, provider);
  expectAddress(await controller.owner(), OPERATOR, "Controller owner");
  expectAddress(await registry.owner(), OPERATOR, "Registry owner");

  const pairs = [];
  for (const pair of PAIRS) {
    pairs.push(await readPairState(pair, provider, controller, registry));
  }
  await requireDeferredClosed(provider, controller, registry);

  console.log(
    JSON.stringify(
      {
        mode: BROADCAST ? "broadcast" : "read-only",
        rollout: pairs.map(({ symbol, paused, registrarEnabled, registryEnabled }) => ({
          symbol,
          paused,
          registrarEnabled,
          registryEnabled,
        })),
        deferred: DEFERRED_PAIRS.map(({ symbol }) => symbol),
      },
      null,
      2,
    ),
  );
  if (!BROADCAST) return;

  loadLocalEnv();
  const privateKey = process.env.DEPLOYER_PRIVATE_KEY_PRODUCTION;
  requireCondition(Boolean(privateKey), "DEPLOYER_PRIVATE_KEY_PRODUCTION is required");
  const signer = new Wallet(privateKey, provider);
  expectAddress(signer.address, OPERATOR, "Production signer");

  for (const pair of pairs) {
    await send(
      `${pair.symbol}:enable-registrar`,
      controller,
      "setRegistrar",
      [pair.manager, true],
      () => controller.isRegistrar(pair.manager),
      signer,
    );
  }
  for (const pair of pairs) {
    await send(
      `${pair.symbol}:enable-registry`,
      registry,
      "setPairEnabled",
      [pair.token, true],
      async () =>
        (await registry.getPair(pair.token)).enabled &&
        (await registry.isApprovedManager(pair.manager)),
      signer,
    );
  }
  for (const pair of pairs) {
    await send(
      `${pair.symbol}:unpause`,
      pair.contract,
      "unpause",
      [],
      async () => !(await pair.contract.paused()),
      signer,
    );
  }

  const finalState = [];
  for (const pair of PAIRS) {
    finalState.push(await readPairState(pair, provider, controller, registry));
  }
  requireCondition(
    finalState.every(
      ({ paused, registrarEnabled, registryEnabled, approvedManager }) =>
        !paused && registrarEnabled && registryEnabled && approvedManager,
    ),
    "Not all ten rollout pairs are open",
  );
  await requireDeferredClosed(provider, controller, registry);
  console.log("All ten production Prism V2 expansion pairs are open.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
