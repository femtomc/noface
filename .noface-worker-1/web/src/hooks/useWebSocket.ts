import { useState, useEffect, useRef, useCallback } from 'preact/hooks'

interface Issue {
  id: string
  title: string
  description: string
  acceptance_criteria?: string
  status: 'open' | 'in_progress' | 'closed'
  priority: number
  issue_type: string
  created_at: string
  updated_at: string
  closed_at?: string
  dependencies?: Array<{
    issue_id: string
    depends_on_id: string
    type: string
  }>
}

interface State {
  state_version: number
  project_name: string
  last_saved: number
  total_iterations: number
  successful_completions: number
  failed_attempts: number
  num_workers: number
  next_batch_id: number
  workers: Array<{ id: number; status: string; current_issue?: string }>
  issues: Record<string, unknown>
  locks: Record<string, unknown>
}

interface SessionEvent {
  type: 'tool' | 'text'
  name?: string
  input?: Record<string, unknown>
  content?: string
}

type Sessions = Record<string, SessionEvent[]>

export function useWebSocket() {
  const [issues, setIssues] = useState<Issue[]>([])
  const [state, setState] = useState<State | null>(null)
  const [sessions, setSessions] = useState<Sessions>({})
  const [connected, setConnected] = useState(false)
  const wsRef = useRef<WebSocket | null>(null)
  const reconnectTimeoutRef = useRef<number | null>(null)

  const connect = useCallback(() => {
    // Use relative URL in production, localhost in dev
    const wsUrl = import.meta.env.DEV
      ? 'ws://localhost:3001/ws'
      : `ws://${window.location.host}/ws`

    const ws = new WebSocket(wsUrl)
    wsRef.current = ws

    ws.onopen = () => {
      console.log('[ws] connected')
      setConnected(true)
    }

    ws.onclose = () => {
      console.log('[ws] disconnected, reconnecting...')
      setConnected(false)
      reconnectTimeoutRef.current = window.setTimeout(connect, 2000)
    }

    ws.onerror = (e) => {
      console.error('[ws] error:', e)
    }

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data)

        switch (msg.type) {
          case 'init':
            if (msg.data.issues) setIssues(msg.data.issues)
            if (msg.data.state) setState(msg.data.state)
            // Also fetch sessions via REST
            fetch('/api/sessions')
              .then(r => r.json())
              .then(setSessions)
              .catch(console.error)
            break
          case 'issues':
            setIssues(msg.data)
            break
          case 'state':
            setState(msg.data)
            break
          case 'session':
            setSessions(prev => ({
              ...prev,
              [msg.data.issueId]: msg.data.events
            }))
            break
        }
      } catch (e) {
        console.error('[ws] parse error:', e)
      }
    }
  }, [])

  useEffect(() => {
    connect()

    return () => {
      if (wsRef.current) {
        wsRef.current.close()
      }
      if (reconnectTimeoutRef.current) {
        clearTimeout(reconnectTimeoutRef.current)
      }
    }
  }, [connect])

  return { issues, state, sessions, connected }
}
