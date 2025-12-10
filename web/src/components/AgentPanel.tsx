import { useState, useEffect, useRef } from 'preact/hooks'

interface SessionEvent {
  type: 'tool' | 'text'
  name?: string
  input?: Record<string, unknown>
  content?: string
}

interface Issue {
  id: string
  title: string
  status: string
}

interface State {
  workers: Array<{ id: number; status: string; current_issue?: string }>
  num_workers: number
  total_iterations: number
  successful_completions: number
  failed_attempts: number
}

type Sessions = Record<string, SessionEvent[]>

interface Props {
  sessions: Sessions
  state: State | null
  issues: Issue[]
}

export function AgentPanel({ sessions, state, issues }: Props) {
  const [selectedSession, setSelectedSession] = useState<string | null>(null)
  const outputRef = useRef<HTMLDivElement>(null)

  // Find in-progress issue for active session
  const activeIssue = issues.find(i => i.status === 'in_progress')

  // Auto-select active session
  useEffect(() => {
    if (activeIssue && sessions[activeIssue.id]) {
      setSelectedSession(activeIssue.id)
    }
  }, [activeIssue, sessions])

  // Auto-scroll
  useEffect(() => {
    if (outputRef.current) {
      outputRef.current.scrollTop = outputRef.current.scrollHeight
    }
  }, [sessions, selectedSession])

  const sessionIds = Object.keys(sessions).sort((a, b) => {
    // Active session first
    if (a === activeIssue?.id) return -1
    if (b === activeIssue?.id) return 1
    return 0
  })

  const currentEvents = selectedSession ? sessions[selectedSession] || [] : []

  return (
    <div class="panel">
      <div class="panel-header">
        <span>Agent Activity</span>
        {state && (
          <div class="stats-bar">
            <span class="stat-item">
              <span>done:</span>
              <span class="stat-value">{state.successful_completions}</span>
            </span>
            <span class="stat-item">
              <span>failed:</span>
              <span class="stat-value">{state.failed_attempts}</span>
            </span>
          </div>
        )}
      </div>

      {/* Workers status */}
      {state && (
        <div style={{ padding: '0.5ch 1ch', borderBottom: '1px solid var(--text-color-dim)', background: 'var(--background-color-alt)' }}>
          <div class="worker-grid" style={{ gridTemplateColumns: `repeat(${state.num_workers}, 1fr)` }}>
            {state.workers.slice(0, state.num_workers).map(worker => (
              <div class="worker" key={worker.id} style={{ padding: '0.25ch 0.5ch' }}>
                <span style={{ color: 'var(--text-color-dim)', marginRight: '0.5ch' }}>W{worker.id}</span>
                <span class={`worker-status ${worker.status}`}>{worker.status}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Session tabs */}
      <div class="tabs" style={{ flexWrap: 'wrap' }}>
        {sessionIds.map(id => (
          <button
            key={id}
            class={`tab ${selectedSession === id ? 'active' : ''}`}
            onClick={() => setSelectedSession(id)}
          >
            {id === activeIssue?.id && <span class="live-indicator" />}
            {id}
          </button>
        ))}
      </div>

      {/* Session output */}
      <div class="panel-content" ref={outputRef}>
        {!selectedSession ? (
          <div class="empty-state">Select a session to view agent activity</div>
        ) : currentEvents.length === 0 ? (
          <div class="empty-state">No activity yet</div>
        ) : (
          <div class="agent-output">
            {currentEvents.map((event, i) => (
              <EventDisplay key={i} event={event} />
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

function EventDisplay({ event }: { event: SessionEvent }) {
  if (event.type === 'tool') {
    const params = formatToolParams(event.name || '', event.input || {})
    return (
      <div class="tool-call">
        <span class="tool-call-name">[{event.name}]</span>
        {params && <span class="tool-call-params"> {params}</span>}
      </div>
    )
  }

  if (event.type === 'text') {
    // Truncate very long text
    const content = event.content || ''
    const truncated = content.length > 500 ? content.slice(0, 500) + '...' : content
    return (
      <pre class="text-delta">{truncated}</pre>
    )
  }

  return null
}

function formatToolParams(name: string, input: Record<string, unknown>): string {
  switch (name) {
    case 'Read':
      return String(input.file_path || '')
    case 'Write':
      return String(input.file_path || '')
    case 'Edit':
      return String(input.file_path || '')
    case 'Bash':
      const cmd = String(input.command || '')
      return cmd.length > 60 ? cmd.slice(0, 60) + '...' : cmd
    case 'Grep':
      return `"${input.pattern}" ${input.path || ''}`
    case 'Glob':
      return `"${input.pattern}"`
    case 'Task':
      return String(input.description || '')
    case 'TodoWrite':
      return ''
    default:
      return ''
  }
}
