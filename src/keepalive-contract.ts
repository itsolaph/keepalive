/**
 * Keepalive contract config — imported from the compiled Foundry artifact.
 * Chain / address config stays in src/keepalive-config.ts so a single file
 * points the same build at testnet or mainnet.
 */
import type { Abi } from 'viem'
import artifact from '../contracts/out/Keepalive.sol/Keepalive.json'

export const KEEPALIVE_ABI = artifact.abi as Abi

export type KeepaliveAbi = typeof KEEPALIVE_ABI
