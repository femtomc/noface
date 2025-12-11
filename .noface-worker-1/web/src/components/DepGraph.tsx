/**
 * ASCII-style dependency graph visualization
 */

interface Issue {
  id: string
  title: string
  status: 'open' | 'in_progress' | 'closed'
  priority: number
  dependencies?: Array<{
    issue_id: string
    depends_on_id: string
    type: string
  }>
}

interface Props {
  issues: Issue[]
}

export function DepGraph({ issues }: Props) {
  // Build adjacency: issue -> issues it blocks
  const blocks = new Map<string, string[]>()
  const blockedBy = new Map<string, string[]>()

  for (const issue of issues) {
    if (issue.dependencies) {
      for (const dep of issue.dependencies) {
        // dep.issue_id is blocked by dep.depends_on_id
        const blockers = blockedBy.get(dep.issue_id) || []
        blockers.push(dep.depends_on_id)
        blockedBy.set(dep.issue_id, blockers)

        const blocking = blocks.get(dep.depends_on_id) || []
        blocking.push(dep.issue_id)
        blocks.set(dep.depends_on_id, blocking)
      }
    }
  }

  // Find root issues (not blocked by anything open)
  const roots = issues.filter(i => {
    const deps = blockedBy.get(i.id) || []
    return deps.length === 0 || deps.every(d => {
      const blocker = issues.find(x => x.id === d)
      return blocker?.status === 'closed'
    })
  })

  // Find critical path (longest chain of blocking issues)
  const visited = new Set<string>()

  function getDepth(id: string): number {
    if (visited.has(id)) return 0
    visited.add(id)
    const children = blocks.get(id) || []
    if (children.length === 0) return 1
    return 1 + Math.max(...children.map(getDepth))
  }

  const issueDepths = issues.map(i => ({ issue: i, depth: getDepth(i.id) }))
  visited.clear()

  // Render ASCII tree
  function renderTree(id: string, prefix: string, isLast: boolean): string[] {
    const issue = issues.find(i => i.id === id)
    if (!issue || visited.has(id)) return []
    visited.add(id)

    const statusChar = issue.status === 'closed' ? '✓' : issue.status === 'in_progress' ? '▶' : '○'
    const statusColor = issue.status === 'closed' ? 'var(--success-color)' :
                        issue.status === 'in_progress' ? 'var(--warning-color)' : 'var(--text-color-dim)'

    const connector = isLast ? '└─' : '├─'
    const line = `${prefix}${connector} ${statusChar} ${id}`

    const children = blocks.get(id) || []
    const childPrefix = prefix + (isLast ? '   ' : '│  ')

    const childLines = children.flatMap((childId, i) =>
      renderTree(childId, childPrefix, i === children.length - 1)
    )

    return [line, ...childLines]
  }

  // Find top-level issues to start from
  const topLevel = issues.filter(i => {
    const deps = blockedBy.get(i.id) || []
    return deps.length === 0
  }).sort((a, b) => a.priority - b.priority)

  visited.clear()
  const treeLines = topLevel.flatMap((issue, i) =>
    renderTree(issue.id, '', i === topLevel.length - 1)
  )

  if (treeLines.length === 0) {
    return <div class="empty-state">No dependency relationships</div>
  }

  return (
    <pre style={{
      fontSize: '0.8rem',
      lineHeight: '1.4',
      margin: 0,
      whiteSpace: 'pre',
      fontFamily: 'var(--font-family)'
    }}>
      {treeLines.map((line, i) => {
        const match = line.match(/(.*?)(✓|▶|○)(.*)/)
        if (!match) return <div key={i}>{line}</div>

        const [, prefix, status, rest] = match
        const color = status === '✓' ? 'var(--success-color)' :
                      status === '▶' ? 'var(--warning-color)' : 'var(--text-color-dim)'

        return (
          <div key={i}>
            <span style={{ color: 'var(--text-color-dim)' }}>{prefix}</span>
            <span style={{ color }}>{status}</span>
            <span>{rest}</span>
          </div>
        )
      })}
    </pre>
  )
}

/**
 * ASCII progress bar
 */
export function ProgressBar({ done, total, width = 20 }: { done: number; total: number; width?: number }) {
  if (total === 0) return <span style={{ color: 'var(--text-color-dim)' }}>{'░'.repeat(width)}</span>

  const filled = Math.round((done / total) * width)
  const empty = width - filled

  return (
    <span style={{ fontFamily: 'var(--font-family)' }}>
      <span style={{ color: 'var(--success-color)' }}>{'█'.repeat(filled)}</span>
      <span style={{ color: 'var(--text-color-dim)' }}>{'░'.repeat(empty)}</span>
      <span style={{ color: 'var(--text-color-alt)', marginLeft: '1ch' }}>
        {done}/{total}
      </span>
    </span>
  )
}

/**
 * Mini sparkline for recent activity
 */
export function Sparkline({ values, width = 10 }: { values: number[]; width?: number }) {
  const chars = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█']
  const max = Math.max(...values, 1)
  const normalized = values.slice(-width).map(v => Math.floor((v / max) * (chars.length - 1)))

  return (
    <span style={{ color: 'var(--accent-color)', fontFamily: 'var(--font-family)' }}>
      {normalized.map(i => chars[i]).join('')}
    </span>
  )
}
