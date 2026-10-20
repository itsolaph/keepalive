import { useState } from 'react'
import { ConnectKitButton } from 'connectkit'
import { Activity, CreditCard, ExternalLink } from 'lucide-react'
import { PlansView } from './components/PlansView'
import { SubscriptionsView } from './components/SubscriptionsView'
import { ActivityFeed } from './components/ActivityFeed'
import { KEEPALIVE_ADDRESS, KEEPALIVE_CHAIN_ID } from './keepalive-config'
import { requireChain } from '@/onchain-facts'

const chain = requireChain(KEEPALIVE_CHAIN_ID)

type Tab = 'plans' | 'subscriptions'

export default function App() {
  const [tab, setTab] = useState<Tab>('plans')

  return (
    <div className="min-h-dvh" style={{ background: 'var(--bg-gradient)' }}>
      {/* Header */}
      <header
        className="sticky top-0 z-30 px-4 py-3"
        style={{
          background: 'rgba(255,255,255,0.80)',
          backdropFilter: 'blur(24px)',
          WebkitBackdropFilter: 'blur(24px)',
          borderBottom: '1px solid var(--border)',
        }}
      >
        <div className="max-w-md mx-auto flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div
              className="flex size-8 items-center justify-center rounded-xl"
              style={{ background: 'var(--accent)' }}
            >
              <Activity size={16} color="#fff" />
            </div>
            <div>
              <div className="display font-semibold text-sm" style={{ color: 'var(--ink)', letterSpacing: '-0.02em' }}>
                Keepalive
              </div>
              <div className="text-xs" style={{ color: 'var(--subtle)' }}>
                Pay-per-uptime subscriptions · v1.1
              </div>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <a
              href={`${chain.explorerBase}/address/${KEEPALIVE_ADDRESS}`}
              target="_blank"
              rel="noreferrer"
              className="flex items-center gap-1 text-xs rounded-lg px-2 py-1 transition-colors hover:bg-black/5"
              style={{ color: 'var(--subtle)' }}
            >
              Contract
              <ExternalLink size={10} />
            </a>
            <ConnectKitButton />
          </div>
        </div>
      </header>

      {/* Tab bar */}
      <div className="max-w-md mx-auto px-4 pt-4">
        <div
          className="flex rounded-2xl p-1 mb-5"
          style={{ background: 'var(--surface-muted)' }}
        >
          <button
            onClick={() => setTab('plans')}
            className="flex-1 flex items-center justify-center gap-1.5 rounded-xl py-2 text-sm font-semibold transition-all"
            style={{
              background: tab === 'plans' ? 'var(--surface-strong)' : 'transparent',
              color: tab === 'plans' ? 'var(--ink)' : 'var(--subtle)',
              boxShadow: tab === 'plans' ? '0 1px 4px rgba(18,45,69,0.10)' : 'none',
            }}
          >
            <Activity size={14} />
            Plans
          </button>
          <button
            onClick={() => setTab('subscriptions')}
            className="flex-1 flex items-center justify-center gap-1.5 rounded-xl py-2 text-sm font-semibold transition-all"
            style={{
              background: tab === 'subscriptions' ? 'var(--surface-strong)' : 'transparent',
              color: tab === 'subscriptions' ? 'var(--ink)' : 'var(--subtle)',
              boxShadow: tab === 'subscriptions' ? '0 1px 4px rgba(18,45,69,0.10)' : 'none',
            }}
          >
            <CreditCard size={14} />
            My Subscriptions
          </button>
        </div>

        {/* Views */}
        {tab === 'plans' && <PlansView />}
        {tab === 'subscriptions' && <SubscriptionsView />}

        {/* Activity feed — always visible below the active tab */}
        <ActivityFeed />

        {/* Footer */}
        <div className="mt-8 pb-6 text-center text-xs" style={{ color: 'var(--subtle)' }}>
          <a
            href={`${chain.explorerBase}/address/${KEEPALIVE_ADDRESS}`}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-1 hover:underline mono"
            style={{ color: 'var(--subtle)' }}
          >
            {KEEPALIVE_ADDRESS.slice(0, 10)}…{KEEPALIVE_ADDRESS.slice(-8)}
            <ExternalLink size={10} />
          </a>
          <div className="mt-1">{chain.name} · Keepalive v1.1</div>
        </div>
      </div>
    </div>
  )
}
