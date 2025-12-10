# monowiki Agent Guide

This vault ships with a CLI that is designed to be agent-friendly. Key commands:

- `monowiki build`: render the site to `docs/` and emit `index.json`, `graph.json`, `previews.json`, and a cached site index at `docs/.site_index.json`.
- `monowiki dev`: serve the site locally with live rebuilds **and** JSON endpoints:
  - `/api/search?q=term&limit=10`
  - `/api/note/<slug>`
  - `/api/graph/<slug>?depth=2&direction=both`
  - `/api/graph/path?from=a&to=b&max_depth=5`
- `monowiki search "<query>" --json --limit 5 --types essay,thought --tags rust,notes --with-links` for machine-readable results.
- `monowiki note <slug> --format json --with-links` to fetch a single note (frontmatter, rendered HTML, raw body, links).
- `monowiki graph neighbors --slug <slug> --depth 2 --direction outgoing --json` to fan out.
- `monowiki graph path --from a --to b --max-depth 4 --json` to find shortest paths.
- `monowiki export sections --format jsonl --with-links` to stream embedding-ready chunks.
- `monowiki watch` streams JSON change events from `vault/` (one line per event).

JSON schemas

- CLI `--json` and dev server `/api/*` responses are wrapped in:

```json
{
  "schema_version": "2024-11-llm-v1",
  "kind": "search.results | note.full | graph.neighbors | graph.path",
  "data": { ... }
}
```

- Search results include `id`, `slug`, `url`, `title`, `section_title`, `snippet`, `tags`, `type`, `score`, `outgoing`, `backlinks`.
- Notes include frontmatter, HTML, raw markdown, toc, outgoing, backlinks, and dates.
- Graph neighbors include nodes with `slug/title/url/tags/type` and edges; graph path returns the path array.

Performance tips

- `monowiki build`/`dev` write `docs/.site_index.json`. The `note`, `graph`, and `export` commands reuse this cache to avoid rebuilding when only reading data. Delete it if you need a fresh rebuild.

Conventions:
- Slugs come from frontmatter `slug`, otherwise the filename slugified.
- Drafts are excluded from exports/search when `type: draft` or `draft: true`.
- Backlinks are computed from `[[WikiLinks]]` in markdown and exposed via `graph.json` and the CLI/API.
- Section-level search slices HTML headings into chunks; IDs match rendered anchors.

Tips for agents:
- Use `monowiki export sections` to build retrieval datasets without scraping.
- Use `monowiki note <slug> --format json` to fetch full context (toc, html, raw markdown) before editing.
- Prefer the dev server APIs during interactive sessions; they reflect live rebuilds.

Happy hacking!
