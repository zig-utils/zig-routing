#!/usr/bin/env bun
// Keeps the `ready` / `blocked` labels true: an open issue is `ready` when every blocker in
// OUTLINE.txt is closed, `blocked` otherwise. Run by .github/workflows/issue-graph.yml whenever an
// issue is closed or reopened, or by hand:
//
//   bun scripts/issues/sync-ready.ts --repo owner/name
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { DIR, gh, loadOutline } from './lib'

const args = process.argv.slice(2)
const repo = (args.includes('--repo') ? args[args.indexOf('--repo') + 1] : undefined) ?? process.env.GITHUB_REPOSITORY
if (!repo) {
  console.error('Pass --repo owner/name')
  process.exit(1)
}

const created: Record<string, number> = JSON.parse(readFileSync(join(DIR, 'created.json'), 'utf8'))
const { issues } = loadOutline()

interface Remote { number: number, state: string, labels: Array<{ name: string }>, pull_request?: unknown }
const remote = new Map<number, Remote>()
for (let page = 1; ; page++) {
  const batch = JSON.parse(gh(['api', `repos/${repo}/issues?state=all&per_page=100&page=${page}`])) as Remote[]
  for (const item of batch) if (!item.pull_request) remote.set(item.number, item)
  if (batch.length < 100) break
}

let changed = 0
for (const issue of issues) {
  const current = remote.get(created[issue.key]!)
  if (!current || current.state !== 'open') continue
  const open = issue.blockers.filter(key => remote.get(created[key]!)?.state !== 'closed')
  const want = open.length ? 'blocked' : 'ready'
  const drop = open.length ? 'ready' : 'blocked'
  const names = new Set(current.labels.map(label => label.name))
  if (names.has(want) && !names.has(drop)) continue
  const edit = ['issue', 'edit', String(current.number), '-R', repo, '--add-label', want]
  if (names.has(drop)) edit.push('--remove-label', drop)
  gh(edit)
  changed++
  console.log(`#${current.number} ${issue.key} -> ${want}`)
}
console.log(`${changed} issue(s) relabelled`)
