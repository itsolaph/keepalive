/**
 * Single config file — change KEEPALIVE_CHAIN_ID and KEEPALIVE_ADDRESS to
 * point this build at Arc Testnet (5042002) or Arc Mainnet (5042).
 */

/** Arc Testnet = 5042002 | Arc Mainnet = 5042 */
export const KEEPALIVE_CHAIN_ID = 5042

/** Keepalive v1.1 on Arc Mainnet (source-verified on Sourcify) */
export const KEEPALIVE_ADDRESS = '0xe8F3923191b06c351b2eAdc131AC8BCA81b17DB3' as const

// Testnet alternative (Arc Studio deployment):
// export const KEEPALIVE_CHAIN_ID = 5042002
// export const KEEPALIVE_ADDRESS = '0x6b4068700511fd9a3bf3ce77d9ca4887270a5460' as const
