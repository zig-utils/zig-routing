// Shared parsing for the issue graph: OUTLINE.txt (keys, titles, labels, dependencies)
// plus bodies-*.json (goal, scope, acceptance criteria).
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

export const DIR = import.meta.dir

export interface Phase { id: string, n: number, milestone: string, goal: string }
export interface Issue {
  key: string
  phase: string
  title: string
  area: string
  type: string
  size: string
  blockers: string[]
  flags: string[]
}
export interface Body {
  key: string
  goal: string
  upstream?: string[]
  scope?: string[]
  out_of_scope?: string[]
  notes?: string[]
  accept?: string[]
}

export function loadOutline(): { phases: Phase[], issues: Issue[] } {
  return parseOutline(readFileSync(join(DIR, 'OUTLINE.txt'), 'utf8'))
}

export function parseOutline(source: string): { phases: Phase[], issues: Issue[] } {
  const phases: Phase[] = []
  const issues: Issue[] = []
  const seen = new Set<string>()
  for (const raw of source.split('\n')) {
    const line = raw.trim()
    if (!line) continue
    if (line.startsWith('## ')) {
      const [id, milestone, goal] = line.slice(3).split('|').map(part => part.trim())
      phases.push({ id: id!, n: Number(id!.slice(1)), milestone: milestone!, goal: goal ?? '' })
      continue
    }
    if (line.startsWith('#')) continue
    const parts = line.split('|').map(part => part.trim())
    const [key, title, area, type, size, blocked, flags] = parts
    if (!key || !title || !area || !type || !size) throw new Error(`Bad outline line: ${line}`)
    if (seen.has(key)) throw new Error(`Duplicate key ${key}`)
    const blockers = !blocked || blocked === '-' ? [] : blocked.split(/\s+/)
    seen.add(key)
    issues.push({ key, phase: key.split('.')[0]!, title, area, type, size, blockers, flags: flags ? flags.split(/\s+/) : [] })
  }
  validateDependencies(issues)
  return { phases, issues }
}

function validateDependencies(issues: Issue[]): void {
  const byKey = new Map(issues.map(issue => [issue.key, issue]))
  const checked = new Set<string>()
  const path: string[] = []
  const visiting = new Set<string>()
  function visit(issue: Issue): void {
    if (checked.has(issue.key)) return
    if (visiting.has(issue.key)) {
      const cycle = [...path.slice(path.indexOf(issue.key)), issue.key].join(' -> ')
      throw new Error(`Dependency cycle: ${cycle}`)
    }
    path.push(issue.key)
    visiting.add(issue.key)
    for (const key of issue.blockers) {
      const blocker = byKey.get(key)
      if (!blocker) throw new Error(`${issue.key} is blocked by unknown issue ${key}`)
      visit(blocker)
    }
    path.pop()
    visiting.delete(issue.key)
    checked.add(issue.key)
  }
  for (const issue of issues) visit(issue)
}

export function loadBodies(): Map<string, Body> {
  const bodies = new Map<string, Body>()
  for (const file of readdirSync(DIR).filter(name => /^bodies-.*\.json$/.test(name)).sort()) {
    for (const body of JSON.parse(readFileSync(join(DIR, file), 'utf8')) as Body[]) {
      if (bodies.has(body.key)) throw new Error(`Duplicate body for ${body.key} (${file})`)
      bodies.set(body.key, body)
    }
  }
  return bodies
}

export function gh(args: string[], input?: string): string {
  const result = Bun.spawnSync(['gh', ...args], { stdin: input === undefined ? undefined : new TextEncoder().encode(input) })
  const out = result.stdout.toString()
  if (result.exitCode !== 0) throw new Error(`gh ${args.slice(0, 3).join(' ')} failed: ${result.stderr.toString().trim()}`)
  return out
}

export const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))
