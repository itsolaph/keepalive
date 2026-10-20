/**
 * wagmi configuration
 * Built with Arc Studio — https://studio.arc.io
 */

import { http, createConfig, fallback } from 'wagmi'
import { custom } from 'viem'
import { mainnet } from 'wagmi/chains'
import { arcTestnet } from 'viem/chains'
import { defineChain } from 'viem'
import { injected } from 'wagmi/connectors'
import { registerChain } from './tracing'

/** Arc Mainnet — defined manually since viem/chains may not export it yet */
export const arcMainnet = defineChain({
  id: 5042,
  name: 'Arc',
  nativeCurrency: {
    name: 'USDC',
    symbol: 'USDC',
    decimals: 18,
  },
  rpcUrls: {
    default: { http: ['https://rpc.mainnet.arc.io'] },
  },
  blockExplorers: {
    default: { name: 'ArcScan', url: 'https://explorer.arc.io' },
  },
})

// Pre-register chain RPC URLs so trace events show correct chain names immediately
registerChain(arcMainnet.id, arcMainnet.rpcUrls.default.http[0])
registerChain(arcTestnet.id, arcTestnet.rpcUrls.default.http[0])

/**
 * Reads go to the public Arc RPC first. Some browsers (Brave Shields, strict
 * privacy extensions) block that cross-site fetch, so fall back to the
 * connected wallet's own RPC when the public endpoint is unreachable.
 */
type Eip1193 = { request: (args: { method: string; params?: unknown }) => Promise<unknown> }
const injectedProvider = (globalThis as { ethereum?: Eip1193 }).ethereum
export const arcTransport = injectedProvider
  ? fallback([http('https://rpc.mainnet.arc.io'), custom(injectedProvider)])
  : http('https://rpc.mainnet.arc.io')

export const config = createConfig({
  chains: [arcMainnet, arcTestnet, mainnet], // mainnet needed for ENS resolution
  connectors: [injected()],
  transports: {
    [arcMainnet.id]: arcTransport,
    [arcTestnet.id]: http(),
    [mainnet.id]: http(), // ENS resolution uses mainnet
  },
})
