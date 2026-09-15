# Arena Robinhood Contract Archive

The repository root is the current **Arena V2** production reference for
Robinhood Chain. The previous complete V1 snapshot is preserved under
[`v1/`](v1/README.md).

- [`mainnet.md`](mainnet.md): readable V2 address and status registry
- [`addresses.json`](addresses.json): machine-readable V2 registry
- [`frontend-production-config.json`](frontend-production-config.json): V2 launch economics and pair configuration
- [`abis/`](abis/): generated raw ABI arrays and index
- [`sources/`](sources/): Arena-local V2 Solidity source closure
- [`manifests/`](manifests/): authoritative deployment-manifest snapshot
- [`rollouts/`](rollouts/): activation/status evidence not stored as a manifest
- [`v1/`](v1/): untouched prior V1 documentation, sources, ABIs, and configuration

Refresh the V2 snapshot from the sibling repository with:

```sh
node sync-from-arena-fork-v2.js
```

The sync script is offline and never reads an `.env` file or private key.
