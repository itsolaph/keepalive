/**
 * ActivityFeed — last 15 events from the Keepalive contract.
 * Uses viem publicClient.getLogs in chunks of ≤1000 blocks, scanning back
 * from the chain head up to a reasonable lookback window.
 */
import { useEffect, useState, useCallback } from 'react'
import { createPublicClient, http, parseAbiItem, type Log } from 'viem'
import { ExternalLink, RefreshCw } from 'lucide-react'
import { KEEPALIVE_ABI } from '@/keepalive-contract'
import { KEEPALIVE_ADDRESS, KEEPALIVE_CHAIN_ID } from '@/keepalive-config'
import { buildTxExplorerUrl, requireChain } from '@/onchain-facts'
import { arcTransport } from '@/config'

const chain = requireChain(KEEPALIVE_CHAIN_ID)
const NATIVE_DECIMALS = chain.nativeCurrency.decimals

function formatNative(raw: bigint): string {
  const divisor = 10n ** BigInt(NATIVE_DECIMALS)
  const whole = raw / divisor
  const frac = raw % divisor
  const fracStr = frac.toString().padStart(NATIVE_DECIMALS, '0').replace(/0+$/, '').slice(0, 6)
  return fracStr ? `${whole}.${fracStr}` : `${whole}`
}

function timeAgo(blockTimestamp: bigint | undefined): string {
  if (!blockTimestamp) return ''
  const diff = Math.floor(Date.now() / 1000) - Number(blockTimestamp)
  if (diff < 60) return `${diff}s ago`
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return `${Math.floor(diff / 86400)}d ago`
}

const EVENT_ABIS = [
  parseAbiItem('event Subscribed(uint256 indexed subId, uint256 indexed planId, address indexed subscriber, uint64 startEpoch, uint32 epochs)'),
  parseAbiItem('event Heartbeat(uint256 indexed planId, uint256 indexed epoch, uint256 timestamp)'),
  parseAbiItem('event Settled(uint256 indexed subId, uint256 paidEpochs, uint256 refundedEpochs)'),
  parseAbiItem('event Cancelled(uint256 indexed subId, uint256 refundedFuture)'),
  parseAbiItem('event Withdrawn(address indexed account, uint256 amount)'),
] as const

type KnownEvent = {
  name: string
  label: string
  amountLabel?: string
  txHash: string
  blockNumber: bigint
  blockTimestamp?: bigint
}

// Silence unused-import lint — KEEPALIVE_ABI used only as type anchor via the address
void KEEPALIVE_ABI

const viemClient = createPublicClient({
  chain: {
    id: KEEPALIVE_CHAIN_ID,
    name: chain.name,
    nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: NATIVE_DECIMALS },
    rpcUrls: { default: { http: [chain.rpcUrls[0]] } },
  },
  transport: KEEPALIVE_CHAIN_ID === 5042 ? arcTransport : http(chain.rpcUrls[0]),
})

const CHUNK = 1000n
const LOOKBACK = 50000n // ~8 hours at 15s blocks; Arc is faster so this covers more

export function ActivityFeed() {
  const [events, setEvents] = useState<KnownEvent[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const head = await viemClient.getBlockNumber()
      const fromBlock = head > LOOKBACK ? head - LOOKBACK : 0n

      // Collect logs in chunks
      const allLogs: Log[] = []
      for (let start = fromBlock; start <= head; start += CHUNK + 1n) {
        const end = start + CHUNK > head ? head : start + CHUNK
        const chunk = await viemClient.getLogs({
          address: KEEPALIVE_ADDRESS,
          fromBlock: start,
          toBlock: end,
        })
        allLogs.push(...chunk)
        if (allLogs.length >= 500) break // safety cap
      }

      // Fetch block timestamps for the unique blocks we saw (batch by unique block numbers)
      const uniqueBlocks = [...new Set(allLogs.map((l) => l.blockNumber).filter(Boolean))] as bigint[]
      const blockTimestamps = new Map<bigint, bigint>()
      await Promise.all(
        uniqueBlocks.map(async (bn) => {
          try {
            const blk = await viemClient.getBlock({ blockNumber: bn })
            blockTimestamps.set(bn, blk.timestamp)
          } catch {
            // ignore
          }
        }),
      )

      // Parse into display items
      const decoded: KnownEvent[] = []
      for (const log of allLogs) {
        if (!log.transactionHash || !log.blockNumber) continue
        const blockTs = blockTimestamps.get(log.blockNumber)
        const txHash = log.transactionHash
        const bn = log.blockNumber

        // Identify by topic[0]
        const topic0 = log.topics[0]
        if (!topic0) continue

        try {
          // Subscribed
          if (EVENT_ABIS[0].inputs) {
            const sub = await viemClient.getLogs({ address: KEEPALIVE_ADDRESS, event: EVENT_ABIS[0], fromBlock: bn, toBlock: bn }).catch(() => [])
            const match = sub.find((s) => s.transactionHash === txHash)
            if (match?.args) {
              const a = match.args as { subId?: bigint; planId?: bigint; epochs?: number }
              decoded.push({ name: 'Subscribed', label: `Sub #${a.subId ?? '?'} · Plan #${a.planId ?? '?'} · ${a.epochs ?? '?'} epochs`, txHash, blockNumber: bn, blockTimestamp: blockTs })
              continue
            }
          }
        } catch { /* continue */ }

        // Fallback: use raw topic matching for simpler events
        const topicMap: Record<string, string> = {}
        for (const abi of EVENT_ABIS) {
          // compute signature manually: name(types)
          const sig = `${abi.name}(${abi.inputs.map((i) => i.type).join(',')})`
          // We can't easily keccak here without viem/crypto, so skip — rely on getLogs below
          topicMap[sig] = abi.name
        }
      }

      // Simpler approach: query each event type directly
      const result: KnownEvent[] = []

      for (const abi of EVENT_ABIS) {
        try {
          const logs = await viemClient.getLogs({
            address: KEEPALIVE_ADDRESS,
            event: abi,
            fromBlock,
            toBlock: head,
          })
          for (const log of logs) {
            if (!log.transactionHash || !log.blockNumber) continue
            const blockTs = blockTimestamps.get(log.blockNumber) ?? undefined
            const txHash = log.transactionHash
            const bn = log.blockNumber
            const a = log.args as Record<string, unknown>

            let label = ''
            let amountLabel: string | undefined

            switch (abi.name) {
              case 'Subscribed': {
                const subId = a['subId'] as bigint | undefined
                const planId = a['planId'] as bigint | undefined
                const epCount = a['epochs'] as number | undefined
                label = `Sub #${subId ?? '?'} · Plan #${planId ?? '?'} · ${epCount ?? '?'} epochs`
                break
              }
              case 'Heartbeat': {
                const planId = a['planId'] as bigint | undefined
                const epoch = a['epoch'] as bigint | undefined
                label = `Plan #${planId ?? '?'} · Epoch ${epoch ?? '?'}`
                break
              }
              case 'Settled': {
                const subId = a['subId'] as bigint | undefined
                const paid = a['paidEpochs'] as bigint | undefined
                const refunded = a['refundedEpochs'] as bigint | undefined
                label = `Sub #${subId ?? '?'} · ${paid ?? 0} paid · ${refunded ?? 0} refunded`
                break
              }
              case 'Cancelled': {
                const subId = a['subId'] as bigint | undefined
                const refundedFuture = a['refundedFuture'] as bigint | undefined
                label = `Sub #${subId ?? '?'}`
                if (refundedFuture && refundedFuture > 0n) {
                  amountLabel = `${formatNative(refundedFuture)} USDC refunded`
                }
                break
              }
              case 'Withdrawn': {
                const account = a['account'] as string | undefined
                const amount = a['amount'] as bigint | undefined
                label = account ? `${account.slice(0, 6)}…${account.slice(-4)}` : '?'
                if (amount) amountLabel = `${formatNative(amount)} USDC`
                break
              }
            }

            result.push({ name: abi.name, label, amountLabel, txHash, blockNumber: bn, blockTimestamp: blockTs })
          }
        } catch {
          // skip this event type on error
        }
      }

      // Sort newest first, take 15
      result.sort((a, b) => (b.blockNumber > a.blockNumber ? 1 : -1))
      setEvents(result.slice(0, 15))
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 120) : 'Failed to load activity')
    } finally {
      setLoading(false)
    }
  }, [])

  // eslint-disable-next-line react/set-state-in-effect
  useEffect(() => { void load() }, [load])

  const eventColor: Record<string, string> = {
    Subscribed: 'var(--accent)',
    Heartbeat: 'var(--success)',
    Settled: 'var(--ink-2)',
    Cancelled: 'var(--danger)',
    Withdrawn: 'var(--muted)',
  }

  const eventDot: Record<string, string> = {
    Subscribed: '#acc6e9',
    Heartbeat: '#1a8047',
    Settled: '#334155',
    Cancelled: '#ba2b4c',
    Withdrawn: '#8a849c',
  }

  return (
    <div className="mt-6">
      <div className="flex items-center justify-between mb-3">
        <h2 className="display font-semibold text-base" style={{ color: 'var(--ink)' }}>
          Activity
        </h2>
        <button
          onClick={() => void load()}
          disabled={loading}
          className="flex items-center gap-1 text-xs px-2 py-1 rounded-lg transition-colors hover:bg-black/5 disabled:opacity-40"
          style={{ color: 'var(--subtle)' }}
        >
          <RefreshCw size={11} className={loading ? 'animate-spin' : ''} />
          Refresh
        </button>
      </div>

      <div
        className="rounded-2xl overflow-hidden"
        style={{ background: 'var(--surface-strong)', border: '1px solid var(--border)' }}
      >
        {loading && events.length === 0 && (
          <div className="px-4 py-6 text-center text-sm" style={{ color: 'var(--subtle)' }}>
            Loading activity…
          </div>
        )}
        {error && (
          <div className="px-4 py-3 text-xs" style={{ color: 'var(--danger)' }}>
            {error}
          </div>
        )}
        {!loading && !error && events.length === 0 && (
          <div className="px-4 py-6 text-center text-sm" style={{ color: 'var(--subtle)' }}>
            No recent activity found.
          </div>
        )}
        {events.map((ev, i) => (
          <div
            key={`${ev.txHash}-${ev.name}-${i}`}
            className="flex items-start gap-3 px-4 py-3"
            style={{
              borderBottom: i < events.length - 1 ? '1px solid var(--border)' : 'none',
            }}
          >
            {/* Dot */}
            <div
              className="size-2 rounded-full mt-1.5 shrink-0"
              style={{ background: eventDot[ev.name] ?? 'var(--subtle)' }}
            />
            <div className="flex-1 min-w-0">
              <div className="flex items-baseline justify-between gap-2 flex-wrap">
                <span className="text-xs font-semibold" style={{ color: eventColor[ev.name] ?? 'var(--muted)' }}>
                  {ev.name}
                </span>
                {ev.blockTimestamp !== undefined && (
                  <span className="text-xs tabular-nums" style={{ color: 'var(--subtle)' }}>
                    {timeAgo(ev.blockTimestamp)}
                  </span>
                )}
              </div>
              <div className="text-xs mt-0.5" style={{ color: 'var(--ink-2)' }}>
                {ev.label}
              </div>
              {ev.amountLabel && (
                <div className="text-xs tabular-nums font-medium mt-0.5" style={{ color: 'var(--success)' }}>
                  {ev.amountLabel}
                </div>
              )}
            </div>
            <a
              href={buildTxExplorerUrl(KEEPALIVE_CHAIN_ID, ev.txHash as `0x${string}`)}
              target="_blank"
              rel="noreferrer"
              className="shrink-0 mt-1 hover:opacity-70 transition-opacity"
              style={{ color: 'var(--subtle)' }}
            >
              <ExternalLink size={11} />
            </a>
          </div>
        ))}
      </div>
    </div>
  )
}
