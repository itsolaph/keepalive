import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useSwitchChain } from 'wagmi'
import { X, Loader2 } from 'lucide-react'
import { AnimatePresence, motion } from 'framer-motion'
import { KEEPALIVE_ABI } from '@/keepalive-contract'
import { KEEPALIVE_ADDRESS, KEEPALIVE_CHAIN_ID } from '@/keepalive-config'
import { useReadContract } from 'wagmi'
import { requireChain } from '@/onchain-facts'
import { buildTxExplorerUrl } from '@/onchain-facts'
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

interface Props {
  planId: bigint
  onClose: () => void
}

export function SubscribeSheet({ planId, onClose }: Props) {
  const [epochs, setEpochs] = useState('100')
  const { address, chainId } = useAccount()
  const { switchChain } = useSwitchChain()
  const wrongChain = address && chainId !== KEEPALIVE_CHAIN_ID

  const { data: plan } = useReadContract({
    address: KEEPALIVE_ADDRESS,
    abi: KEEPALIVE_ABI,
    functionName: 'plans',
    args: [planId],
    chainId: KEEPALIVE_CHAIN_ID,
  })

  const pricePerEpoch: bigint = plan ? (plan as unknown[])[1] as bigint : 0n
  const epochSeconds: number = plan ? Number((plan as unknown[])[2]) : 60
  const name: string = plan ? (plan as unknown[])[5] as string : ''

  const epochCount = Math.max(1, parseInt(epochs) || 1)
  const total: bigint = pricePerEpoch * BigInt(epochCount)

  const { writeContract, data: hash, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const txUrl = hash ? buildTxExplorerUrl(KEEPALIVE_CHAIN_ID, hash) : null

  function handleSubscribe() {
    if (wrongChain) {
      switchChain({ chainId: KEEPALIVE_CHAIN_ID })
      return
    }
    writeContract(
      {
        address: KEEPALIVE_ADDRESS,
        abi: KEEPALIVE_ABI,
        functionName: 'subscribe',
        args: [planId, epochCount],
        value: total,
        chainId: KEEPALIVE_CHAIN_ID,
      },
      {
        onSuccess(hash) {
          toast.success('Subscribed! Tx: ' + hash.slice(0, 10) + '…')
        },
        onError(err) {
          if (!err.message.includes('user rejected')) {
            toast.error('Subscribe failed: ' + err.message.slice(0, 80))
          }
        },
      },
    )
  }

  const ready = !!address && !isPending && !isConfirming && epochCount > 0

  return (
    <AnimatePresence>
      <motion.div
        className="fixed inset-0 z-50 flex items-end justify-center"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        onClick={onClose}
      >
        <div className="absolute inset-0 bg-black/20 backdrop-blur-sm" />
        <motion.section
          className="relative w-full max-w-md overflow-hidden rounded-t-3xl"
          style={{
            background: 'rgba(255,255,255,0.92)',
            backdropFilter: 'blur(40px) saturate(200%)',
            WebkitBackdropFilter: 'blur(40px) saturate(200%)',
          }}
          initial={{ y: '100%' }}
          animate={{ y: 0 }}
          exit={{ y: '100%' }}
          transition={{ type: 'spring', stiffness: 380, damping: 40 }}
          onClick={(e) => e.stopPropagation()}
        >
          {/* spectral strip */}
          <div
            className="h-1"
            style={{
              background:
                'linear-gradient(90deg,#60a5fa,#818cf8,#a78bfa,#c084fc,#e879f9,#f472b6,#fb7185,#f97316)',
            }}
          />
          {/* drag handle */}
          <div className="flex justify-center pt-3 pb-1">
            <div className="h-1 w-10 rounded-full bg-black/10" />
          </div>

          <div className="px-5 pb-7 pt-2">
            <div className="flex items-center justify-between mb-4">
              <h3 className="display font-semibold text-base" style={{ color: 'var(--ink)' }}>
                Subscribe to {name || `Plan #${planId}`}
              </h3>
              <button
                onClick={onClose}
                className="rounded-xl p-1.5 transition-colors hover:bg-black/5"
              >
                <X size={16} style={{ color: 'var(--muted)' }} />
              </button>
            </div>

            <div className="rounded-2xl p-4 mb-3" style={{ background: 'var(--surface-muted)' }}>
              <label className="text-xs font-semibold mb-2 block" style={{ color: 'var(--muted)' }}>
                Number of epochs ({epochLabel(epochSeconds)} each)
              </label>
              <input
                type="number"
                min={1}
                max={256}
                value={epochs}
                onChange={(e) => setEpochs(e.target.value.replace(/[^0-9]/g, ''))}
                className="display w-full bg-transparent text-3xl font-bold tabular-nums outline-none"
                style={{ color: 'var(--ink)' }}
              />
              <div className="flex items-center justify-between mt-2 text-xs" style={{ color: 'var(--subtle)' }}>
                <span>{formatNative(pricePerEpoch)} USDC / epoch</span>
                <span className="font-semibold" style={{ color: 'var(--muted)' }}>
                  Total: {formatNative(total)} USDC
                </span>
              </div>
            </div>

            <div
              className="rounded-xl p-3 mb-3 text-xs"
              style={{ background: 'rgba(26,128,71,0.08)', color: 'var(--success)' }}
            >
              Coverage starts at the next epoch. Only epochs with a heartbeat pay the provider — missed epochs are refunded to you.
            </div>

            {isSuccess && txUrl && (
              <div className="rounded-xl p-3 mb-3 text-xs flex items-center gap-2" style={{ background: 'rgba(26,128,71,0.08)' }}>
                <span style={{ color: 'var(--success)' }}>Subscribed!</span>
                <a href={txUrl} target="_blank" rel="noreferrer" className="flex items-center gap-1 underline" style={{ color: 'var(--accent-hover)' }}>
                  View on explorer
                </a>
              </div>
            )}

            {error && !error.message.includes('user rejected') && (
              <div className="rounded-xl p-3 mb-3 text-xs" style={{ background: 'rgba(186,43,76,0.08)', color: 'var(--danger)' }}>
                {error.message.slice(0, 120)}
              </div>
            )}

            <button
              disabled={!ready}
              onClick={handleSubscribe}
              className="w-full rounded-2xl py-3.5 text-sm font-semibold text-white transition-all hover:scale-[1.01] active:scale-[0.99] disabled:cursor-not-allowed disabled:opacity-40"
              style={{ background: 'var(--accent)' }}
            >
              {!address
                ? 'Connect Wallet'
                : wrongChain
                ? `Switch to ${chain.name}`
                : isPending
                ? (
                    <span className="flex items-center justify-center gap-2">
                      <Loader2 size={14} className="animate-spin" />
                      Confirm in wallet…
                    </span>
                  )
                : isConfirming
                ? (
                    <span className="flex items-center justify-center gap-2">
                      <Loader2 size={14} className="animate-spin" />
                      Confirming…
                    </span>
                  )
                : `Pay ${formatNative(total)} USDC for ${epochCount} epoch${epochCount > 1 ? 's' : ''}`}
            </button>
          </div>
        </motion.section>
      </motion.div>
    </AnimatePresence>
  )
}
