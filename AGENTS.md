# Keepalive

> Built with Arc Studio - money-powered apps in minutes

This is the **project memory** - what Arc Studio remembers about building this app. It helps future agents (or humans) understand and extend the project.

---

## What This App Does

USDC subscription protocol where a provider only earns for epochs in which a designated heartbeat signer submits a heartbeat. Subscribers pay upfront for N future epochs; settlement per epoch credits the provider (alive) or refunds the subscriber (missed heartbeat). Pull-payments only with reentrancy guard.

## Contract Deployments

| Contract | Version | Chain | Address | Explorer |
|----------|---------|-------|---------|----------|
| Keepalive | v1.1 | Arc Mainnet (5042) | 0xe8F3923191b06c351b2eAdc131AC8BCA81b17DB3 | https://explorer.arc.io/address/0xe8F3923191b06c351b2eAdc131AC8BCA81b17DB3 |
| Keepalive | v1.1 | Arc Testnet (5042002) | 0x6b4068700511fd9a3bf3ce77d9ca4887270a5460 | https://explorer.testnet.arc.io/address/0x6b4068700511fd9a3bf3ce77d9ca4887270a5460 |
| Keepalive | v1.0 | Arc Mainnet (5042) | 0xC4467ad71b8B8514FA42e6A41277751053069d3f | https://explorer.arc.io/address/0xC4467ad71b8B8514FA42e6A41277751053069d3f |
| Keepalive | v1.0 | Arc Testnet (5042002) | 0xd051bde9ef648faf12512d9afd8966de97d38179 | https://explorer.testnet.arc.io/address/0xd051bde9ef648faf12512d9afd8966de97d38179 |

## Tech Stack

- Frontend: React 18, Vite, TypeScript, Tailwind CSS
- Web3: wagmi v2, viem v2, ConnectKit
- Contracts: Solidity 0.8.28 + Foundry. Sources in `contracts/`, unit tests in `contracts/test/*.t.sol`. Build with `bun run contracts:build` (`forge build`), test with `bun run contracts:test` (`forge test`).
- Wallet: injected (MetaMask, etc.)
- Chain: Arc Testnet (Chain ID: 5042002, imported from `viem/chains`)
- Token: USDC (6 decimals) (Address: 0x3600000000000000000000000000000000000000, Chain: Arc Testnet)
- Toasts: Sonner

## Key Files

- `src/App.tsx` - Main application logic
- `src/components/` - UI components
- `src/config.ts` - wagmi config (chains, connectors, transports)

## To Run

```bash
bun install
bun run dev
```
