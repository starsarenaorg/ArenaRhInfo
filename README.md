# Arena Robinhood Chain Contract Archive

This folder is the standalone Robinhood Chain reference for Arena production
contracts.

- `mainnet.md` is the human-readable mainnet address and purpose registry.
- `addresses.json` is the machine-readable address registry.
- `frontend-production-config.json` records the scalar values selected when the
  frontend runs with `NEXT_PUBLIC_APP_ENV=production`.
- `contracts/` contains Arena's Robinhood-specific Solidity source, preserving
  the original paths and relative imports.
- `abis/` contains raw JSON ABI arrays. Start with `abis/index.json`.
- `sync-from-arena-fork.js` refreshes source, ABIs, and `addresses.json` from
  the production manifests and Hardhat artifacts in `../arenaFork/contracts`.
