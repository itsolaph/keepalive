import { useReadContract, useReadContracts } from 'wagmi'
import { useState, useMemo, useRef } from 'react'
import { Activity, Heart, ExternalLink, ShieldCheck } from 'lucide-react'
import { KEEPALIVE_ABI } from '@/keepalive-contract'
import { KEEPALIVE_ADDRESS, KEEPALIVE_CHAIN_ID } from '@/keepalive-config'
import { requireChain } from '@/onchain-facts'
import { SubscribeSheet } from './SubscribeSheet'

const chain = requireChain(KEEPALIVE_CHAIN_ID)
const NATIVE_DECIMALS = chain.nativeCurrency.decimals

function formatNative(raw: bigint): string {
  const divisor = 10n ** BigInt(NATIVE_DECIMALS)
  const whole = raw / divisor
  const frac = raw % divisor
  const fracStr = frac.toString().padStart(NATIVE_DECIMALS, '0').replace(/0+$/, '').slice(0, 6)
  return fracStr ? `${whole}.${fracStr}` : `${whole}`
}

function epochLabel(secs: number): string {
  if (secs < 3600) return `${secs / 60}m`
  if (secs < 86400) return `${secs / 3600}h`
  return `${Math.round(secs / 86400)}d`
}

function short(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

function formatLocalWindow(startSec: number, endSec: number): string {
  const fmt = (ts: number) =>
    new Date(ts * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  const fmtDate = (ts: number) =>
    new Date(ts * 1000).toLocaleDateString([], { month: 'short', day: 'numeric' })
  const sameDay =
    new Date(startSec * 1000).toDateString() === new Date(endSec * 1000).toDateString()
  if (sameDay) return `${fmtDate(startSec)} ${fmt(startSec)}–${fmt(endSec)}`
  return `${fmtDate(startSec)} ${fmt(startSec)} – ${fmtDate(endSec)} ${fmt(endSec)}`
}

// Tooltip wrapper for heartbeat squares
function EpochSquare({
  idx,
  alive,
  isCurrent,
  epochSeconds,
  startTimeSec,
}: {
  idx: number
  alive: boolean | null
  isCurrent: boolean
  epochSeconds: number
  startTimeSec: number
}) {
  const [show, setShow] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  const epochStart = startTimeSec + idx * epochSeconds
  const epochEnd = epochStart + epochSeconds
  const window = formatLocalWindow(epochStart, epochEnd)
  const label = alive === null ? 'Loading…' : alive ? 'Alive' : 'Missed'

  return (
    <div
      ref={ref}
      className="relative"
      onMouseEnter={() => setShow(true)}
      onMouseLeave={() => setShow(false)}
      onTouchStart={() => setShow(true)}
      onTouchEnd={() => setShow(false)}
    >
      <div
        className="rounded-sm transition-colors cursor-default"
        style={{
          width: 10,
          height: 18,
          background:
            alive === null
              ? 'var(--border-strong)'
              : alive
              ? 'var(--success)'
              : 'var(--danger)',
          opacity: isCurrent ? 0.55 : 1,
          flexShrink: 0,
        }}
      />
      {show && (
        <div
          className="absolute bottom-full mb-1.5 left-1/2 -translate-x-1/2 z-50 rounded-xl px-2.5 py-2 text-xs whitespace-nowrap pointer-events-none"
          style={{
            background: 'var(--ink)',
            color: '#fff',
            boxShadow: '0 4px 16px rgba(0,0,0,0.18)',
          }}
        >
          <div className="font-semibold mb-0.5">Epoch {idx}{isCurrent ? ' (current)' : ''}</div>
          <div style={{ color: 'rgba(255,255,255,0.65)', fontSize: 10 }}>{window}</div>
          <div
            className="font-medium mt-0.5"
            style={{ color: alive ? '#8dd89f' : alive === false ? '#e86d7a' : 'rgba(255,255,255,0.5)' }}
          >
            {label}
          </div>
        </div>
      )}
    </div>
  )
}

function HeartbeatStrip({
  planId,
  epochSeconds,
  startTime,
}: {
  planId: bigint
  epochSeconds: number
  startTime: bigint
}) {
  const currentEpochVal = useMemo(() => {
    const nowSec = BigInt(Math.floor(Date.now() / 1000))
    return startTime > 0n ? Number((nowSec - startTime) / BigInt(epochSeconds)) : 0
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [epochSeconds, startTime.toString()])

  // Short epochs (< 1 hour) show up to 30 squares; otherwise 24
  const maxSquares = epochSeconds < 3600 ? 30 : 24
  // Paging: `back` = how many epochs the window's right edge sits behind the current epoch.
  // `?at=<planId>:<epoch>` deep-links a window ending at that epoch (handy for sharing a past outage).
  const [back, setBack] = useState(() => {
    const at = new URLSearchParams(window.location.search).get('at')
    const [p, e] = (at ?? '').split(':')
    if (p === planId.toString() && e && /^\d+$/.test(e)) return Math.max(0, currentEpochVal - Number(e))
    return 0
  })
  const lastIdx = Math.max(0, currentEpochVal - back)
  const count = Math.min(maxSquares, lastIdx + 1)
  const startIdx = lastIdx - count + 1
  const startTimeSec = Number(startTime)

  const calls = useMemo(
    () =>
      Array.from({ length: count }, (_, i) => ({
        address: KEEPALIVE_ADDRESS as `0x${string}`,
        abi: KEEPALIVE_ABI,
        functionName: 'isAlive' as const,
        args: [planId, BigInt(startIdx + i)] as readonly [bigint, bigint],
        chainId: KEEPALIVE_CHAIN_ID,
      })),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [count, startIdx, planId.toString()],
  )

  const { data } = useReadContracts({ contracts: calls })

  if (count === 0) {
    return <div className="text-xs" style={{ color: 'var(--subtle)' }}>No epochs yet</div>
  }

  const alive: (boolean | null)[] = data
    ? data.map((r) => (r.status === 'success' ? Boolean(r.result) : null))
    : (Array(count).fill(null) as null[])

  const aliveCount = alive.filter(Boolean).length
  const uptime = count > 0 ? Math.round((aliveCount / count) * 100) : 0

  return (
    <div>
      <div className="flex items-center gap-1 flex-wrap">
        {alive.map((a, i) => {
          const epochIdx = startIdx + i
          return (
            <EpochSquare
              key={epochIdx}
              idx={epochIdx}
              alive={a}
              isCurrent={epochIdx === currentEpochVal}
              epochSeconds={epochSeconds}
              startTimeSec={startTimeSec}
            />
          )
        })}
        <span className="ml-2 text-xs tabular-nums font-semibold" style={{ color: 'var(--muted)' }}>
          {uptime}% up
        </span>
      </div>
      <div className="mt-1 flex gap-3 text-xs" style={{ color: 'var(--subtle)' }}>
        <button
          type="button"
          className="hover:underline disabled:opacity-40"
          disabled={startIdx === 0}
          onClick={() => setBack((b) => Math.min(currentEpochVal, b + maxSquares))}
        >
          ← older
        </button>
        <button
          type="button"
          className="hover:underline disabled:opacity-40"
          disabled={back === 0}
          onClick={() => setBack((b) => Math.max(0, b - maxSquares))}
        >
          newer →
        </button>
        {back > 0 && <span>epochs {startIdx}–{lastIdx}</span>}
      </div>
    </div>
  )
}

function PlanCard({ planId, onSubscribe }: { planId: bigint; onSubscribe: (planId: bigint) => void }) {
  const { data: plan } = useReadContract({
    address: KEEPALIVE_ADDRESS,
    abi: KEEPALIVE_ABI,
    functionName: 'plans',
    args: [planId],
    chainId: KEEPALIVE_CHAIN_ID,
  })

  if (!plan) {
    return (
      <div className="rounded-2xl p-4 animate-pulse" style={{ background: 'var(--surface-muted)', minHeight: 120 }} />
    )
  }

  const provider = (plan as unknown[])[0] as string
  const priceRaw = (plan as unknown[])[1] as bigint
  const epochSecondsRaw = (plan as unknown[])[2] as number
  const startTimeRaw = (plan as unknown[])[3] as bigint
  const heartbeatSigner = (plan as unknown[])[4] as string
  const name = (plan as unknown[])[5] as string

  const epochSeconds = Number(epochSecondsRaw)

  return (
    <div
      className="rounded-2xl p-4"
      style={{
        background: 'var(--surface-strong)',
        backdropFilter: 'blur(20px)',
        border: '1px solid var(--border)',
      }}
    >
      <div className="flex items-start justify-between gap-2 mb-3">
        <div className="min-w-0">
          <h3 className="display font-semibold text-base" style={{ color: 'var(--ink)' }}>
            {name || `Plan #${planId}`}
          </h3>
          <a
            href={`${chain.explorerBase}/address/${provider}`}
            target="_blank"
            rel="noreferrer"
            className="text-xs flex items-center gap-1 mt-0.5"
            style={{ color: 'var(--subtle)' }}
          >
            <span className="mono">{short(provider)}</span>
            <ExternalLink size={10} />
          </a>
        </div>
        <button
          onClick={() => onSubscribe(planId)}
          className="rounded-xl px-3 py-1.5 text-xs font-semibold text-white transition-all hover:scale-[1.02] active:scale-[0.98] whitespace-nowrap shrink-0"
          style={{ background: 'var(--accent)' }}
        >
          Subscribe
        </button>
      </div>

      {/* Price / epoch / signer row */}
      <div className="flex flex-wrap gap-4 mb-3">
        <div>
          <div className="text-xs" style={{ color: 'var(--subtle)' }}>Price / epoch</div>
          <div className="display font-semibold tabular-nums text-sm" style={{ color: 'var(--ink)' }}>
            {formatNative(priceRaw)} USDC
          </div>
        </div>
        <div>
          <div className="text-xs" style={{ color: 'var(--subtle)' }}>Epoch length</div>
          <div className="display font-semibold text-sm" style={{ color: 'var(--ink)' }}>
            {epochLabel(epochSeconds)}
          </div>
        </div>
      </div>

      {/* Attestor (fixed) */}
      <div
        className="rounded-xl px-3 py-2 mb-3 flex items-start gap-2"
        style={{ background: 'var(--surface-muted)' }}
      >
        <ShieldCheck size={13} className="mt-0.5 shrink-0" style={{ color: 'var(--success)' }} />
        <div className="min-w-0">
          <div className="text-xs font-semibold" style={{ color: 'var(--muted)' }}>
            Attestor (fixed)
          </div>
          <a
            href={`${chain.explorerBase}/address/${heartbeatSigner}`}
            target="_blank"
            rel="noreferrer"
            className="mono text-xs flex items-center gap-1 mt-0.5 break-all"
            style={{ color: 'var(--ink-2)' }}
          >
            {heartbeatSigner}
            <ExternalLink size={9} className="shrink-0" />
          </a>
          <div className="text-xs mt-1" style={{ color: 'var(--subtle)' }}>
            Missed heartbeat = automatic refund for that epoch
          </div>
        </div>
      </div>

      <HeartbeatStrip planId={planId} epochSeconds={epochSeconds} startTime={startTimeRaw} />
    </div>
  )
}

export function PlansView() {
  const [subscribeTarget, setSubscribeTarget] = useState<bigint | null>(null)

  const { data: planCount, isLoading } = useReadContract({
    address: KEEPALIVE_ADDRESS,
    abi: KEEPALIVE_ABI,
    functionName: 'planCount',
    chainId: KEEPALIVE_CHAIN_ID,
  })

  const count = planCount ? Number(planCount) : 0

  return (
    <div>
      <div className="flex items-center gap-2 mb-4">
        <div
          className="flex size-8 items-center justify-center rounded-xl"
          style={{ background: 'rgba(26,128,71,0.10)' }}
        >
          <Activity size={16} style={{ color: 'var(--success)' }} />
        </div>
        <div>
          <h2 className="display font-semibold text-lg" style={{ color: 'var(--ink)' }}>
            Service Plans
          </h2>
          <p className="text-xs" style={{ color: 'var(--muted)' }}>
            Provider earns only for epochs with a heartbeat
          </p>
        </div>
      </div>

      {isLoading && (
        <div className="space-y-3">
          {[1, 2].map((i) => (
            <div key={i} className="rounded-2xl animate-pulse" style={{ background: 'var(--surface-muted)', height: 160 }} />
          ))}
        </div>
      )}

      {!isLoading && count === 0 && (
        <div
          className="rounded-2xl p-6 text-center"
          style={{ background: 'var(--surface-muted)', border: '1px dashed var(--border-strong)' }}
        >
          <Heart size={24} className="mx-auto mb-2" style={{ color: 'var(--subtle)' }} />
          <p className="text-sm" style={{ color: 'var(--muted)' }}>
            No plans yet. Create a plan from a service provider wallet.
          </p>
        </div>
      )}

      <div className="space-y-3">
        {Array.from({ length: count }, (_, i) => (
          <PlanCard key={i + 1} planId={BigInt(i + 1)} onSubscribe={setSubscribeTarget} />
        ))}
      </div>

      {subscribeTarget !== null && (
        <SubscribeSheet planId={subscribeTarget} onClose={() => setSubscribeTarget(null)} />
      )}
    </div>
  )
}
