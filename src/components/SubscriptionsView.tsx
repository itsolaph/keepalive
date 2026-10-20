import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
  useSwitchChain,
} from 'wagmi'
import { ConnectKitButton } from 'connectkit'
import { ExternalLink, Loader2, CreditCard, DollarSign, Zap } from 'lucide-react'
import { useMemo, useEffect } from 'react'
import { KEEPALIVE_ABI } from '@/keepalive-contract'
import { KEEPALIVE_ADDRESS, KEEPALIVE_CHAIN_ID } from '@/keepalive-config'
import { buildTxExplorerUrl, requireChain } from '@/onchain-facts'
import { toast } from 'sonner'

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

// Reads a plan for an epoch row — called unconditionally (before any conditional return)
function EpochRow({ epoch, planId, price }: { epoch: bigint; planId: bigint; price: bigint }) {
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const now = useMemo(() => BigInt(Math.floor(Date.now() / 1000)), [epoch.toString()])
  const { data: plan } = useReadContract({
    address: KEEPALIVE_ADDRESS,
    abi: KEEPALIVE_ABI,
    functionName: 'plans',
    args: [planId],
    chainId: KEEPALIVE_CHAIN_ID,
  })

  const epochSeconds: number = plan ? Number((plan as unknown[])[2]) : 60
  const startTime: bigint = plan ? (plan as unknown[])[3] as bigint : 0n

  const epochStart = startTime + epoch * BigInt(epochSeconds)
  const epochEnd = epochStart + BigInt(epochSeconds)
  const ended = now >= epochEnd
  const current = now >= epochStart && now < epochEnd

  const { data: isAliveData } = useReadContract({
    address: KEEPALIVE_ADDRESS,
    abi: KEEPALIVE_ABI,
    functionName: 'isAlive',
    args: [planId, epoch],
    chainId: KEEPALIVE_CHAIN_ID,
  })

  const alive = isAliveData as boolean | undefined

  let badge = (
    <span className="text-xs px-2 py-0.5 rounded-lg" style={{ background: 'var(--surface-muted)', color: 'var(--subtle)' }}>
      Pending
    </span>
  )
  if (current) {
    badge = (
      <span className="text-xs px-2 py-0.5 rounded-lg" style={{ background: 'rgba(26,128,71,0.08)', color: 'var(--success)' }}>
        In progress
      </span>
    )
  } else if (ended && alive) {
    badge = (
      <span className="text-xs px-2 py-0.5 rounded-lg font-medium" style={{ background: 'rgba(26,128,71,0.12)', color: 'var(--success)' }}>
        Paid
      </span>
    )
  } else if (ended && alive === false) {
    badge = (
      <span className="text-xs px-2 py-0.5 rounded-lg font-medium" style={{ background: 'rgba(186,43,76,0.10)', color: 'var(--danger)' }}>
        Refunded
      </span>
    )
  }

  return (
    <div className="flex items-center justify-between py-1.5 text-xs">
      <span className="tabular-nums mono" style={{ color: 'var(--muted)' }}>
        Epoch {epoch.toString()}
      </span>
      <div className="flex items-center gap-2">
        <span className="tabular-nums" style={{ color: 'var(--ink-2)' }}>
          {formatNative(price)} USDC
        </span>
        {badge}
      </div>
    </div>
  )
}

function SubscriptionCard({ subId }: { subId: bigint }) {
  const { chainId } = useAccount()
  const { switchChain } = useSwitchChain()
  const wrongChain = chainId !== KEEPALIVE_CHAIN_ID

  const { data: sub, refetch: refetchSub } = useReadContract({
    address: KEEPALIVE_ADDRESS,
    abi: KEEPALIVE_ABI,
    functionName: 'subscriptions',
    args: [subId],
    chainId: KEEPALIVE_CHAIN_ID,
  })

  const subTuple = sub as [bigint, string, bigint, number, number, boolean] | undefined
  const planId: bigint = subTuple ? subTuple[0] : 0n

  // Always call hooks unconditionally
  const { data: plan } = useReadContract({
    address: KEEPALIVE_ADDRESS,
    abi: KEEPALIVE_ABI,
    functionName: 'plans',
    args: [planId],
    chainId: KEEPALIVE_CHAIN_ID,
    query: { enabled: planId > 0n },
  })

  const { data: stateData, refetch: refetchState } = useReadContract({
    address: KEEPALIVE_ADDRESS,
    abi: KEEPALIVE_ABI,
    functionName: 'subscriptionState',
    args: [subId],
    chainId: KEEPALIVE_CHAIN_ID,
    query: { refetchInterval: 10000 },
  })

  const { writeContract, data: hash, isPending, reset } = useWriteContract()
  const { isSuccess } = useWaitForTransactionReceipt({ hash })

  useEffect(() => {
    if (isSuccess) {
      void refetchSub()
      void refetchState()
      reset()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isSuccess])

  const txUrl = hash ? buildTxExplorerUrl(KEEPALIVE_CHAIN_ID, hash) : null

  if (!sub) {
    return <div className="rounded-2xl animate-pulse" style={{ background: 'var(--surface-muted)', height: 120 }} />
  }

  const [, , startEpoch, epochs, settledCount, cancelled] = subTuple!
  const totalEpochs = Number(epochs)
  const pricePerEpoch: bigint = plan ? (plan as unknown[])[1] as bigint : 0n
  const epochSeconds: number = plan ? Number((plan as unknown[])[2]) : 60
  const planName: string = plan ? (plan as unknown[])[5] as string : ''

  const stateTuple = stateData as [bigint, bigint, bigint] | undefined
  const escrowed: bigint = stateTuple ? stateTuple[0] : 0n
  const pendingToProvider: bigint = stateTuple ? stateTuple[1] : 0n
  const pendingToSubscriber: bigint = stateTuple ? stateTuple[2] : 0n

  function doSettle() {
    if (wrongChain) { switchChain({ chainId: KEEPALIVE_CHAIN_ID }); return }
    writeContract(
      { address: KEEPALIVE_ADDRESS, abi: KEEPALIVE_ABI, functionName: 'settle', args: [subId], chainId: KEEPALIVE_CHAIN_ID },
      {
        onSuccess: () => toast.success('Settled!'),
        onError: (e) => { if (!e.message.includes('user rejected')) toast.error(e.message.slice(0, 80)) },
      },
    )
  }

  function doCancel() {
    if (wrongChain) { switchChain({ chainId: KEEPALIVE_CHAIN_ID }); return }
    writeContract(
      { address: KEEPALIVE_ADDRESS, abi: KEEPALIVE_ABI, functionName: 'cancel', args: [subId], chainId: KEEPALIVE_CHAIN_ID },
      {
        onSuccess: () => toast.success('Cancelled and refund credited'),
        onError: (e) => { if (!e.message.includes('user rejected')) toast.error(e.message.slice(0, 80)) },
      },
    )
  }

  const displayEpochs = Array.from({ length: Math.min(totalEpochs, 8) }, (_, i) => BigInt(Number(startEpoch) + i))

  return (
    <div
      className="rounded-2xl p-4"
      style={{
        background: 'var(--surface-strong)',
        backdropFilter: 'blur(20px)',
        border: '1px solid var(--border)',
      }}
    >
      {/* Header */}
      <div className="flex items-start justify-between mb-3">
        <div>
          <div className="display font-semibold text-sm" style={{ color: 'var(--ink)' }}>
            {planName || `Plan #${planId}`}
          </div>
          <div className="text-xs mt-0.5 flex items-center gap-1.5 flex-wrap" style={{ color: 'var(--subtle)' }}>
            <span>Sub #{subId.toString()}</span>
            <span>·</span>
            <span>{totalEpochs} × {epochLabel(epochSeconds)}</span>
            <span>·</span>
            <span>Settled {settledCount}/{totalEpochs}</span>
            {cancelled && (
              <span className="px-1.5 py-0.5 rounded-md text-xs" style={{ background: 'rgba(186,43,76,0.10)', color: 'var(--danger)' }}>
                Cancelled
              </span>
            )}
          </div>
        </div>
      </div>

      {/* Four-number breakdown */}
      <div className="grid grid-cols-2 gap-2 mb-3">
        <div className="rounded-xl px-3 py-2" style={{ background: 'var(--surface-muted)' }}>
          <div className="text-xs mb-0.5" style={{ color: 'var(--subtle)' }}>Escrowed</div>
          <div className="tabular-nums font-semibold text-sm" style={{ color: 'var(--ink)' }}>
            {formatNative(escrowed)} USDC
          </div>
        </div>
        <div className="rounded-xl px-3 py-2" style={{ background: 'var(--surface-muted)' }}>
          <div className="text-xs mb-0.5" style={{ color: 'var(--subtle)' }}>Earned by provider</div>
          <div className="tabular-nums font-semibold text-sm" style={{ color: pendingToProvider > 0n ? 'var(--ink)' : 'var(--subtle)' }}>
            {formatNative(pendingToProvider)} USDC
          </div>
        </div>
        <div className="rounded-xl px-3 py-2" style={{ background: 'var(--surface-muted)' }}>
          <div className="text-xs mb-0.5" style={{ color: 'var(--subtle)' }}>Refund to you</div>
          <div className="tabular-nums font-semibold text-sm" style={{ color: pendingToSubscriber > 0n ? 'var(--success)' : 'var(--subtle)' }}>
            {formatNative(pendingToSubscriber)} USDC
          </div>
        </div>
        <div className="rounded-xl px-3 py-2" style={{ background: 'var(--surface-muted)' }}>
          <div className="text-xs mb-0.5" style={{ color: 'var(--subtle)' }}>Withdrawable now</div>
          <div className="tabular-nums font-semibold text-sm" style={{ color: 'var(--muted)' }}>
            see credit above
          </div>
        </div>
      </div>

      {/* Epoch rows */}
      <div
        className="rounded-xl px-3 divide-y mb-3"
        style={{ background: 'var(--surface-muted)', ['--tw-divide-opacity' as string]: '1' }}
      >
        {displayEpochs.map((ep) => (
          <EpochRow key={ep.toString()} epoch={ep} planId={planId} price={pricePerEpoch} />
        ))}
        {totalEpochs > 8 && (
          <div className="py-1.5 text-xs text-center" style={{ color: 'var(--subtle)' }}>
            +{totalEpochs - 8} more epochs
          </div>
        )}
      </div>

      {txUrl && (
        <a href={txUrl} target="_blank" rel="noreferrer"
          className="flex items-center gap-1 text-xs mb-2 underline"
          style={{ color: 'var(--accent-hover)' }}>
          View last tx <ExternalLink size={10} />
        </a>
      )}

      {/* Actions */}
      <div className="flex gap-2">
        <button
          onClick={doSettle}
          disabled={isPending}
          className="flex-1 rounded-xl py-2 text-xs font-semibold transition-all hover:scale-[1.01] active:scale-[0.99] disabled:opacity-40 disabled:cursor-not-allowed flex items-center justify-center gap-1.5"
          style={{ background: 'var(--accent)', color: '#fff' }}
        >
          {isPending ? <Loader2 size={12} className="animate-spin" /> : null}
          Settle
        </button>
        {!cancelled && (
          <button
            onClick={doCancel}
            disabled={isPending}
            className="flex-1 rounded-xl py-2 text-xs font-semibold transition-all hover:scale-[1.01] active:scale-[0.99] disabled:opacity-40 disabled:cursor-not-allowed"
            style={{
              background: 'transparent',
              border: '1px solid var(--border-strong)',
              color: 'var(--ink-2)',
            }}
          >
            Cancel
          </button>
        )}
      </div>
    </div>
  )
}

// "Claim all" = settleAndWithdraw with all my sub ids (max 20)
function ClaimAllButton({
  address,
  subIds,
  onSuccess,
}: {
  address: string
  subIds: bigint[]
  onSuccess: () => void
}) {
  const { chainId } = useAccount()
  const { switchChain } = useSwitchChain()
  const wrongChain = chainId !== KEEPALIVE_CHAIN_ID

  const ids20 = subIds.slice(0, 20)

  const { data: creditRaw, refetch: refetchCredit } = useReadContract({
    address: KEEPALIVE_ADDRESS,
    abi: KEEPALIVE_ABI,
    functionName: 'credit',
    args: [address],
    chainId: KEEPALIVE_CHAIN_ID,
    query: { refetchInterval: 8000 },
  })
  const creditAmount = creditRaw as bigint | undefined

  const { writeContract, data: hash, isPending, reset } = useWriteContract()
  const { isSuccess } = useWaitForTransactionReceipt({ hash })

  useEffect(() => {
    if (isSuccess) {
      void refetchCredit()
      reset()
      onSuccess()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isSuccess])

  const txUrl = hash ? buildTxExplorerUrl(KEEPALIVE_CHAIN_ID, hash) : null
  const hasCredit = creditAmount !== undefined && creditAmount > 0n

  function doClaim() {
    if (wrongChain) { switchChain({ chainId: KEEPALIVE_CHAIN_ID }); return }
    writeContract(
      {
        address: KEEPALIVE_ADDRESS,
        abi: KEEPALIVE_ABI,
        functionName: 'settleAndWithdraw',
        args: [ids20],
        chainId: KEEPALIVE_CHAIN_ID,
      },
      {
        onSuccess: () => toast.success('Claimed all!'),
        onError: (e) => {
          if (!e.message.includes('user rejected')) toast.error(e.message.slice(0, 80))
        },
      },
    )
  }

  return (
    <div
      className="rounded-2xl p-4 mb-4"
      style={{
        background: 'var(--surface-strong)',
        border: '1px solid var(--border)',
        backdropFilter: 'blur(20px)',
      }}
    >
      <div className="flex items-center gap-2 mb-2">
        <DollarSign size={14} style={{ color: 'var(--success)' }} />
        <span className="text-xs font-semibold" style={{ color: 'var(--muted)' }}>Available Credit</span>
      </div>
      <div className="flex items-end justify-between gap-3 flex-wrap">
        <div className="display text-3xl font-bold tabular-nums" style={{ color: 'var(--ink)' }}>
          {creditAmount !== undefined ? formatNative(creditAmount) : '—'}
          <span className="text-base font-medium ml-1" style={{ color: 'var(--subtle)' }}>USDC</span>
        </div>
        <button
          onClick={doClaim}
          disabled={isPending || (ids20.length === 0 && !hasCredit)}
          className="rounded-xl px-4 py-2.5 text-sm font-semibold transition-all hover:scale-[1.01] active:scale-[0.99] disabled:opacity-40 disabled:cursor-not-allowed text-white flex items-center gap-2"
          style={{ background: 'var(--accent)' }}
        >
          {isPending ? <Loader2 size={14} className="animate-spin" /> : <Zap size={14} />}
          Claim all
        </button>
      </div>
      <p className="text-xs mt-1.5" style={{ color: 'var(--subtle)' }}>
        Settles all your subscriptions and withdraws your full credit in one transaction.
      </p>
      {txUrl && (
        <a href={txUrl} target="_blank" rel="noreferrer"
          className="flex items-center gap-1 text-xs mt-2 underline"
          style={{ color: 'var(--accent-hover)' }}>
          View tx <ExternalLink size={10} />
        </a>
      )}
    </div>
  )
}

export function SubscriptionsView() {
  const { address } = useAccount()

  const { data: subIds, isLoading, refetch: refetchSubs } = useReadContract({
    address: KEEPALIVE_ADDRESS,
    abi: KEEPALIVE_ABI,
    functionName: 'subscriptionsOf',
    args: [address!],
    chainId: KEEPALIVE_CHAIN_ID,
    query: { enabled: !!address, refetchInterval: 15000 },
  })

  const ids = (subIds as bigint[] | undefined) ?? []

  if (!address) {
    return (
      <div>
        <div className="flex items-center gap-2 mb-4">
          <div className="flex size-8 items-center justify-center rounded-xl" style={{ background: 'rgba(18,45,69,0.08)' }}>
            <CreditCard size={16} style={{ color: 'var(--accent)' }} />
          </div>
          <div>
            <h2 className="display font-semibold text-lg" style={{ color: 'var(--ink)' }}>My Subscriptions</h2>
            <p className="text-xs" style={{ color: 'var(--muted)' }}>Connect to see and manage your subscriptions</p>
          </div>
        </div>
        <div
          className="rounded-2xl p-6 flex flex-col items-center gap-3"
          style={{ background: 'var(--surface-muted)', border: '1px dashed var(--border-strong)' }}
        >
          <p className="text-sm" style={{ color: 'var(--muted)' }}>Connect your wallet to continue</p>
          <ConnectKitButton />
        </div>
      </div>
    )
  }

  return (
    <div>
      <div className="flex items-center gap-2 mb-4">
        <div className="flex size-8 items-center justify-center rounded-xl" style={{ background: 'rgba(18,45,69,0.08)' }}>
          <CreditCard size={16} style={{ color: 'var(--accent)' }} />
        </div>
        <div>
          <h2 className="display font-semibold text-lg" style={{ color: 'var(--ink)' }}>My Subscriptions</h2>
          <p className="text-xs" style={{ color: 'var(--muted)' }}>Settle, cancel, and withdraw on {chain.name}</p>
        </div>
      </div>

      <ClaimAllButton
        address={address}
        subIds={ids}
        onSuccess={() => void refetchSubs()}
      />

      {isLoading && (
        <div className="space-y-3">
          {[1, 2].map((i) => (
            <div key={i} className="rounded-2xl animate-pulse" style={{ background: 'var(--surface-muted)', height: 160 }} />
          ))}
        </div>
      )}

      {!isLoading && ids.length === 0 && (
        <div
          className="rounded-2xl p-6 text-center"
          style={{ background: 'var(--surface-muted)', border: '1px dashed var(--border-strong)' }}
        >
          <p className="text-sm" style={{ color: 'var(--muted)' }}>
            No subscriptions yet. Subscribe to a plan from the Plans tab.
          </p>
        </div>
      )}

      <div className="space-y-3">
        {ids.map((id) => (
          <SubscriptionCard key={id.toString()} subId={id} />
        ))}
      </div>
    </div>
  )
}
