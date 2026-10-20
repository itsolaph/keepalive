/**
 * wagmi configuration
 * Built with Arc Studio — https://studio.arc.io
 */

import { http, createConfig } from 'wagmi'
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

export const config = createConfig({
  chains: [arcMainnet, arcTestnet, mainnet], // mainnet needed for ENS resolution
  connectors: [injected()],
  transports: {
    [arcMainnet.id]: http('https://rpc.mainnet.arc.io'),
    [arcTestnet.id]: http(),
    [mainnet.id]: http(), // ENS resolution uses mainnet
  },
})
