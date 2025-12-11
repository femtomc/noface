import { useState } from 'preact/hooks'
import { IssuePanel } from './components/IssuePanel'
import { AgentPanel } from './components/AgentPanel'
import { DepGraph, ProgressBar } from './components/DepGraph'
import { useWebSocket } from './hooks/useWebSocket'

type LeftTab = 'issues' | 'graph'

export function App() {
  const { issues, state, sessions, connected } = useWebSocket()
  const [leftTab, setLeftTab] = useState<LeftTab>('issues')

  const stats = {
    total: issues.length,
    open: issues.filter(i => i.status === 'open').length,
    inProgress: issues.filter(i => i.status === 'in_progress').length,
    closed: issues.filter(i => i.status === 'closed').length,
  }

  return (
    <div class="app-container">
      <header class="header">
        <h1>
          {connected && <span class="live-indicator" />}
          noface
        </h1>
        <div class="header-stats">
          <div class="header-stat" style={{ minWidth: '18ch' }}>
            <ProgressBar done={stats.closed} total={stats.total} width={12} />
          </div>
          <div class="header-stat">
            <span>open:</span>
            <span class="header-stat-value">{stats.open}</span>
          </div>
          <div class="header-stat">
            <span style={{ color: 'var(--warning-color)' }}>active:</span>
            <span class="header-stat-value">{stats.inProgress}</span>
          </div>
          {state && (
            <>
              <div class="header-stat">
                <span>iter:</span>
                <span class="header-stat-value">{state.total_iterations}</span>
              </div>
              <div class="header-stat">
                <span>workers:</span>
                <span class="header-stat-value">
                  {state.workers.filter(w => w.status === 'running').length}/{state.num_workers}
                </span>
              </div>
            </>
          )}
        </div>
      </header>

      {/* Left panel - switchable between issues list and dependency graph */}
      {leftTab === 'issues' ? (
        <IssuePanel issues={issues} onShowGraph={() => setLeftTab('graph')} />
      ) : (
        <div class="panel">
          <div class="panel-header">
            <span>Dependency Graph</span>
            <button
              class="filter-btn"
              onClick={() => setLeftTab('issues')}
              style={{ marginLeft: 'auto' }}
            >
              ← issues
            </button>
          </div>
          <div class="panel-content">
            <DepGraph issues={issues} />
          </div>
        </div>
      )}

      <AgentPanel sessions={sessions} state={state} issues={issues} />
    </div>
  )
}
