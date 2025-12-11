/**
 * noface-viewer server
 * Watches .beads/issues.jsonl, .noface/state.json, and session logs
 * Serves REST API + WebSocket for real-time updates
 */

import { watch } from "fs"
import { readFile, readdir } from "fs/promises"
import { join, dirname } from "path"

// Find project root (where .beads and .noface directories are)
// From web/server/index.ts, go up 3 levels to reach project root
const PROJECT_ROOT = dirname(dirname(dirname(Bun.main)))
const BEADS_DIR = join(PROJECT_ROOT, ".beads")
const NOFACE_DIR = join(PROJECT_ROOT, ".noface")
const ISSUES_FILE = join(BEADS_DIR, "issues.jsonl")
const STATE_FILE = join(NOFACE_DIR, "state.json")
const SESSION_DIR = "/tmp"

interface Issue {
  id: string
  title: string
  description: string
  acceptance_criteria?: string
  status: "open" | "in_progress" | "closed"
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
  type: string
  event?: unknown
  message?: unknown
  session_id?: string
  [key: string]: unknown
}

// In-memory state
let issues: Issue[] = []
let state: State | null = null
let sessions: Map<string, SessionEvent[]> = new Map()
const wsClients: Set<WebSocket> = new Set()

// Parse JSONL file
async function loadIssues(): Promise<Issue[]> {
  try {
    const content = await readFile(ISSUES_FILE, "utf-8")
    return content
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line))
  } catch (e) {
    console.error("Failed to load issues:", e)
    return []
  }
}

// Load orchestrator state
async function loadState(): Promise<State | null> {
  try {
    const content = await readFile(STATE_FILE, "utf-8")
    return JSON.parse(content)
  } catch (e) {
    console.error("Failed to load state:", e)
    return null
  }
}

// Find and load session files
async function loadSessions(): Promise<Map<string, SessionEvent[]>> {
  const result = new Map<string, SessionEvent[]>()
  try {
    const files = await readdir(SESSION_DIR)
    const sessionFiles = files.filter(
      (f) => f.startsWith("noface-session-") && f.endsWith(".json")
    )

    for (const file of sessionFiles.slice(-10)) {
      // Last 10 sessions
      const issueId = file.replace("noface-session-", "").replace(".json", "")
      try {
        const content = await readFile(join(SESSION_DIR, file), "utf-8")
        const events = content
          .trim()
          .split("\n")
          .filter(Boolean)
          .map((line) => {
            try {
              return JSON.parse(line)
            } catch {
              return null
            }
          })
          .filter(Boolean)
        result.set(issueId, events)
      } catch {
        // Skip unreadable files
      }
    }
  } catch (e) {
    console.error("Failed to load sessions:", e)
  }
  return result
}

// Extract displayable events from session
function summarizeSession(events: SessionEvent[]): object[] {
  const summary: object[] = []

  for (const event of events) {
    if (event.type === "assistant" && event.message) {
      const msg = event.message as { content?: Array<{ type: string; name?: string; input?: unknown }> }
      if (msg.content) {
        for (const block of msg.content) {
          if (block.type === "tool_use") {
            summary.push({
              type: "tool",
              name: block.name,
              input: block.input,
            })
          }
        }
      }
    } else if (event.type === "stream_event") {
      const streamEvent = event.event as { type?: string; delta?: { type?: string; text?: string } }
      if (streamEvent?.type === "content_block_delta") {
        if (streamEvent.delta?.type === "text_delta" && streamEvent.delta?.text) {
          summary.push({
            type: "text",
            content: streamEvent.delta.text,
          })
        }
      }
    }
  }

  // Collapse consecutive text deltas
  const collapsed: object[] = []
  let currentText = ""
  for (const item of summary) {
    const typedItem = item as { type: string; content?: string }
    if (typedItem.type === "text") {
      currentText += typedItem.content || ""
    } else {
      if (currentText) {
        collapsed.push({ type: "text", content: currentText })
        currentText = ""
      }
      collapsed.push(item)
    }
  }
  if (currentText) {
    collapsed.push({ type: "text", content: currentText })
  }

  return collapsed.slice(-100) // Last 100 events
}

// Broadcast to WebSocket clients
function broadcast(type: string, data: unknown) {
  const message = JSON.stringify({ type, data, timestamp: Date.now() })
  for (const client of wsClients) {
    try {
      client.send(message)
    } catch {
      wsClients.delete(client)
    }
  }
}

// Watch for file changes
function setupWatchers() {
  // Watch issues
  try {
    watch(ISSUES_FILE, async () => {
      issues = await loadIssues()
      broadcast("issues", issues)
    })
  } catch (e) {
    console.error("Could not watch issues file:", e)
  }

  // Watch state
  try {
    watch(STATE_FILE, async () => {
      state = await loadState()
      broadcast("state", state)
    })
  } catch (e) {
    console.error("Could not watch state file:", e)
  }

  // Watch session directory for new files
  try {
    watch(SESSION_DIR, async (event, filename) => {
      if (filename?.startsWith("noface-session-") && filename?.endsWith(".json")) {
        sessions = await loadSessions()
        const issueId = filename.replace("noface-session-", "").replace(".json", "")
        const sessionEvents = sessions.get(issueId)
        if (sessionEvents) {
          broadcast("session", {
            issueId,
            events: summarizeSession(sessionEvents),
          })
        }
      }
    })
  } catch (e) {
    console.error("Could not watch session directory:", e)
  }
}

// Initial load
async function init() {
  console.log(`[noface-viewer] Loading from ${PROJECT_ROOT}`)
  issues = await loadIssues()
  state = await loadState()
  sessions = await loadSessions()
  setupWatchers()
  console.log(`[noface-viewer] Loaded ${issues.length} issues, ${sessions.size} sessions`)
}

// HTTP server
const server = Bun.serve({
  port: 3001,
  async fetch(req, server) {
    const url = new URL(req.url)

    // WebSocket upgrade
    if (url.pathname === "/ws") {
      if (server.upgrade(req)) {
        return
      }
      return new Response("WebSocket upgrade failed", { status: 500 })
    }

    // CORS headers
    const headers = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, OPTIONS",
      "Content-Type": "application/json",
    }

    if (req.method === "OPTIONS") {
      return new Response(null, { headers })
    }

    // REST endpoints
    if (url.pathname === "/api/issues") {
      return Response.json(issues, { headers })
    }

    if (url.pathname === "/api/state") {
      return Response.json(state, { headers })
    }

    if (url.pathname === "/api/sessions") {
      const result: Record<string, object[]> = {}
      for (const [id, events] of sessions) {
        result[id] = summarizeSession(events)
      }
      return Response.json(result, { headers })
    }

    if (url.pathname.startsWith("/api/sessions/")) {
      const issueId = url.pathname.replace("/api/sessions/", "")
      const sessionEvents = sessions.get(issueId)
      if (sessionEvents) {
        return Response.json(summarizeSession(sessionEvents), { headers })
      }
      return Response.json([], { headers })
    }

    return new Response("Not found", { status: 404 })
  },
  websocket: {
    open(ws) {
      wsClients.add(ws)
      // Send initial state
      ws.send(JSON.stringify({ type: "init", data: { issues, state } }))
    },
    close(ws) {
      wsClients.delete(ws)
    },
    message(ws, message) {
      // Handle ping/pong
      if (message === "ping") {
        ws.send("pong")
      }
    },
  },
})

await init()
console.log(`[noface-viewer] Server running at http://localhost:${server.port}`)
