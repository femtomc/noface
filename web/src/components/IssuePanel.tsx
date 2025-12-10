import { useState } from 'preact/hooks'

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

interface Props {
  issues: Issue[]
  onShowGraph?: () => void
}

type StatusFilter = 'all' | 'open' | 'in_progress' | 'closed'

export function IssuePanel({ issues, onShowGraph }: Props) {
  const [filter, setFilter] = useState<StatusFilter>('all')
  const [expanded, setExpanded] = useState<string | null>(null)

  const filtered = issues.filter(issue => {
    if (filter === 'all') return true
    return issue.status === filter
  })

  // Sort: in_progress first, then by priority, then by updated_at
  const sorted = [...filtered].sort((a, b) => {
    if (a.status === 'in_progress' && b.status !== 'in_progress') return -1
    if (b.status === 'in_progress' && a.status !== 'in_progress') return 1
    if (a.priority !== b.priority) return a.priority - b.priority
    return new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime()
  })

  return (
    <div class="panel">
      <div class="panel-header">
        <span>Issues</span>
        <div style={{ display: 'flex', gap: '1ch', alignItems: 'center' }}>
          <span style={{ fontWeight: 'normal', fontSize: '0.8rem' }}>
            {filtered.length} shown
          </span>
          {onShowGraph && (
            <button class="filter-btn" onClick={onShowGraph}>
              graph →
            </button>
          )}
        </div>
      </div>
      <div class="filter-bar" style={{ padding: '0 1ch' }}>
        {(['all', 'open', 'in_progress', 'closed'] as StatusFilter[]).map(f => (
          <button
            key={f}
            class={`filter-btn ${filter === f ? 'active' : ''}`}
            onClick={() => setFilter(f)}
          >
            {f.replace('_', ' ')}
          </button>
        ))}
      </div>
      <div class="panel-content">
        {sorted.length === 0 ? (
          <div class="empty-state">No issues</div>
        ) : (
          <div class="issue-list">
            {sorted.map(issue => (
              <IssueCard
                key={issue.id}
                issue={issue}
                expanded={expanded === issue.id}
                onToggle={() => setExpanded(expanded === issue.id ? null : issue.id)}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

interface IssueCardProps {
  issue: Issue
  expanded: boolean
  onToggle: () => void
}

function IssueCard({ issue, expanded, onToggle }: IssueCardProps) {
  const priorityLabel = ['P0', 'P1', 'P2', 'P3'][issue.priority] || `P${issue.priority}`

  return (
    <div class="issue" onClick={onToggle}>
      <div class="issue-header">
        <span class="issue-id">{issue.id}</span>
        <span class="issue-title">{issue.title}</span>
      </div>
      <div class="issue-meta">
        <span class={`priority priority-${issue.priority}`}>{priorityLabel}</span>
        <span class={`status status-${issue.status}`}>{issue.status.replace('_', ' ')}</span>
        <span class="issue-type">{issue.issue_type}</span>
        {issue.dependencies && issue.dependencies.length > 0 && (
          <span class="dep-link">
            {issue.dependencies.length} dep{issue.dependencies.length > 1 ? 's' : ''}
          </span>
        )}
      </div>
      {expanded && (
        <div style={{ marginTop: 'var(--line-height)', fontSize: '0.9rem' }}>
          <div style={{ color: 'var(--text-color-alt)', marginBottom: 'calc(var(--line-height) / 2)' }}>
            {issue.description}
          </div>
          {issue.acceptance_criteria && (
            <div style={{ borderTop: '1px solid var(--text-color-dim)', paddingTop: 'calc(var(--line-height) / 2)' }}>
              <strong>Acceptance:</strong>
              <div style={{ color: 'var(--text-color-alt)', whiteSpace: 'pre-wrap' }}>
                {issue.acceptance_criteria}
              </div>
            </div>
          )}
          {issue.dependencies && issue.dependencies.length > 0 && (
            <div style={{ borderTop: '1px solid var(--text-color-dim)', paddingTop: 'calc(var(--line-height) / 2)', marginTop: 'calc(var(--line-height) / 2)' }}>
              <strong>Blocks:</strong>
              <div style={{ color: 'var(--text-color-alt)' }}>
                {issue.dependencies.map(d => d.depends_on_id).join(', ')}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
