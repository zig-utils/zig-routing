#!/usr/bin/env bun
// Creates the whole issue graph on GitHub from OUTLINE.txt and bodies-*.json.
//
//   bun scripts/issues/create.ts --repo owner/name --dry-run [--show P3.27]
//   bun scripts/issues/create.ts --repo owner/name
//
// Issues are created in outline order so numbers ascend in execution order. Progress is written to
// created.json after every issue, so a rerun resumes where it stopped and never duplicates.
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { type Body, DIR, gh, type Issue, loadBodies, loadOutline, type Phase, sleep } from './lib'

const args = process.argv.slice(2)
const flag = (name: string) => args.includes(name)
const value = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined)
const repo = value('--repo')
const dryRun = flag('--dry-run')
const PAUSE_MS = Number(value('--pause') ?? 2500)

const { phases, issues } = loadOutline()
const bodies = loadBodies()
const byKey = new Map(issues.map(issue => [issue.key, issue]))
const missing = issues.filter(issue => !bodies.has(issue.key)).map(issue => issue.key)
const unknown = [...bodies.keys()].filter(key => !byKey.has(key))
if (missing.length || unknown.length) {
  console.error(`Bodies missing for: ${missing.join(' ') || 'none'}\nBodies with no outline key: ${unknown.join(' ') || 'none'}`)
  process.exit(1)
}

const createdPath = join(DIR, 'created.json')
const created: Record<string, number> = existsSync(createdPath) ? JSON.parse(readFileSync(createdPath, 'utf8')) : {}
const save = () => writeFileSync(createdPath, `${JSON.stringify(created, null, 2)}\n`)

const list = (title: string, items: string[] | undefined, render: (item: string) => string = item => `- ${item}`) =>
  items && items.length ? `## ${title}\n\n${items.map(render).join('\n')}\n\n` : ''

function leafBody(issue: Issue, body: Body, phase: Phase): string {
  const blockers = issue.blockers.map((key) => {
    const blocker = byKey.get(key)!
    return `- #${created[key] ?? '?'} \`${key}\` ${blocker.title}`
  })
  return [
    `> **${phase.milestone}** · key \`${issue.key}\` · size ${issue.size}${issue.flags.includes('needs-human') ? ' · needs the maintainer' : ''}\n\n`,
    `## Goal\n\n${body.goal}\n\n`,
    list('Upstream reference (Valhalla 3.9.3)', body.upstream, item => `- \`${item}\``),
    list('Scope', body.scope),
    list('Out of scope', body.out_of_scope),
    list('Design notes', body.notes),
    list('Acceptance criteria', body.accept, item => `- [ ] ${item}`),
    blockers.length ? `## Blocked by\n\n${blockers.join('\n')}\n\n` : '## Blocked by\n\nNothing. This issue can start now.\n\n',
    '---\nRules for working on this repository are in [AGENTS.md](../blob/main/AGENTS.md). The plan is in [docs/PLAN.md](../blob/main/docs/PLAN.md).\n',
  ].join('')
}

function leafLabels(issue: Issue, phase: Phase): string[] {
  const labels = [`phase:${phase.n}`, `area:${issue.area}`, `type:${issue.type}`, `size:${issue.size}`, issue.blockers.length ? 'blocked' : 'ready']
  if (issue.flags.includes('needs-human')) labels.push('needs-human')
  return labels
}

function epicBody(phase: Phase): string {
  const leaves = issues.filter(issue => issue.phase === phase.id)
  const tasks = leaves.map(issue => `- [ ] #${created[issue.key] ?? '?'} \`${issue.key}\` ${issue.title}`)
  return `${phase.goal}\n\nThis is a tracking issue. Work the leaf issues below in order; the last one is the phase gate.\n\n## Issues\n\n${tasks.join('\n')}\n\nSee [docs/PLAN.md](../blob/main/docs/PLAN.md) for the phase description and gates.\n`
}

function startBody(): string {
  const epics = phases.map(phase => `- #${created[`EPIC-${phase.id}`] ?? '?'} ${phase.milestone}`)
  return `zig-routing is a faithful, faster Zig port of the Valhalla routing engine. The whole plan is tracked as issues in this repository, numbered in execution order.

## How to pick work

1. Take the **lowest-numbered open issue labelled \`ready\`**. Skip \`epic\` trackers, and skip \`needs-human\` issues unless the maintainer has supplied what they ask for.
2. Read [AGENTS.md](../blob/main/AGENTS.md) and the issue's design notes. Do what its Scope says; its Acceptance criteria are the definition of done.
3. One issue per pull request, closing the issue.
4. When an issue closes, a workflow relabels its dependents from \`blocked\` to \`ready\`. Never start a \`blocked\` issue.

## Phases

${epics.join('\n')}

## Reference

- [docs/PLAN.md](../blob/main/docs/PLAN.md): scoreboard, architecture, phases, parity gates
- [docs/design/engine-and-format.md](../blob/main/docs/design/engine-and-format.md): engine and graph format design
- [docs/upstream/](../tree/main/docs/upstream): upstream Valhalla architecture and its documented performance problems
`
}

if (dryRun) {
  const per = phases.map(phase => `${phase.id}=${issues.filter(issue => issue.phase === phase.id).length}`).join(' ')
  console.log(`${issues.length} leaf issues, ${phases.length} epics, 1 start-here issue. ${per}`)
  console.log(`ready at creation: ${issues.filter(issue => !issue.blockers.length).map(issue => issue.key).join(' ')}`)
  const show = value('--show')
  if (show) {
    const issue = byKey.get(show)!
    const phase = phases.find(candidate => candidate.id === issue.phase)!
    console.log(`\n[${issue.key}] ${issue.title}\nlabels: ${leafLabels(issue, phase).join(', ')}\n\n${leafBody(issue, bodies.get(show)!, phase)}`)
  }
  process.exit(0)
}

if (!repo) {
  console.error('Pass --repo owner/name')
  process.exit(1)
}

async function withRetry<T>(what: string, run: () => T): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try {
      return run()
    }
    catch (error) {
      if (attempt >= 6) throw error
      const wait = 60_000 * attempt
      console.error(`${what}: ${(error as Error).message}. Waiting ${wait / 1000}s (attempt ${attempt}).`)
      await sleep(wait)
    }
  }
}

// Labels
const AREAS = ['geo', 'graph', 'costing', 'snap', 'search', 'accel', 'match', 'narrative', 'api', 'elevation', 'build', 'server', 'traffic', 'tiles', 'geocode', 'cli', 'infra', 'lib']
const TYPES: Record<string, string> = { port: 'Port of upstream Valhalla code', new: 'New design, no upstream equivalent', perf: 'Performance work with a measured budget', test: 'Tests, goldens, fuzzing', infra: 'Tooling, CI, deployment', experiment: 'De-risking experiment with a pass line', gate: 'Phase gate' }
const labels: Array<[string, string, string]> = [
  ['ready', '0e8a16', 'All blockers closed: can be started'],
  ['blocked', 'b60205', 'Waiting on another issue'],
  ['epic', '5319e7', 'Phase tracking issue'],
  ['needs-human', 'fbca04', 'Needs a decision, access or approval from the maintainer'],
  ...phases.map(phase => [`phase:${phase.n}`, '1d76db', phase.milestone] as [string, string, string]),
  ...AREAS.map(area => [`area:${area}`, 'c5def5', `Code area: ${area}`] as [string, string, string]),
  ...Object.entries(TYPES).map(([type, description]) => [`type:${type}`, 'd4c5f9', description] as [string, string, string]),
  ...['S', 'M', 'L'].map(size => [`size:${size}`, 'ededed', `Size ${size}`] as [string, string, string]),
]
if (!created.__labels) {
  for (const [name, color, description] of labels) {
    await withRetry(`label ${name}`, () => gh(['label', 'create', name, '--color', color, '--description', description, '--force', '-R', repo]))
    await sleep(400)
  }
  created.__labels = 1
  save()
  console.log(`labels: ${labels.length}`)
}

// Milestones
if (!created.__milestones) {
  const existing = new Set((JSON.parse(gh(['api', `repos/${repo}/milestones?state=all&per_page=100`])) as Array<{ title: string }>).map(milestone => milestone.title))
  for (const phase of phases) {
    if (existing.has(phase.milestone)) continue
    await withRetry(`milestone ${phase.id}`, () => gh(['api', `repos/${repo}/milestones`, '-f', `title=${phase.milestone}`, '-f', `description=${phase.goal}`]))
    await sleep(400)
  }
  created.__milestones = 1
  save()
  console.log(`milestones: ${phases.length}`)
}

async function createIssue(key: string, title: string, body: string, issueLabels: string[], milestone?: string): Promise<void> {
  if (created[key]) return
  const cmd = ['issue', 'create', '-R', repo!, '--title', title, '--body-file', '-', '--label', issueLabels.join(',')]
  if (milestone) cmd.push('--milestone', milestone)
  const url = await withRetry(key, () => gh(cmd, body))
  const number = Number(url.trim().split('/').pop())
  if (!Number.isInteger(number)) throw new Error(`Could not read the issue number for ${key} from: ${url}`)
  created[key] = number
  save()
  console.log(`#${number} ${key} ${title}`)
  await sleep(PAUSE_MS)
}

await createIssue('START', 'Start here: how this issue graph works', startBody(), ['epic'])
for (const phase of phases) {
  await createIssue(`EPIC-${phase.id}`, `[${phase.id}] Epic: ${phase.milestone}`, epicBody(phase), ['epic', `phase:${phase.n}`], phase.milestone)
  for (const issue of issues.filter(candidate => candidate.phase === phase.id)) {
    await createIssue(issue.key, `[${issue.key}] ${issue.title}`, leafBody(issue, bodies.get(issue.key)!, phase), leafLabels(issue, phase), phase.milestone)
  }
}

// Now that every number is known: fill the epics' task lists and the start-here index, then pin it.
if (!created.__finalized) {
  const positions = new Map(issues.map((issue, i) => [issue.key, i]))
  for (const [i, issue] of issues.entries()) {
    if (!issue.blockers.some(blocker => positions.get(blocker)! > i)) continue
    const phase = phases.find(candidate => candidate.id === issue.phase)!
    await withRetry(issue.key, () => gh(['issue', 'edit', String(created[issue.key]), '-R', repo, '--body-file', '-'], leafBody(issue, bodies.get(issue.key)!, phase)))
    await sleep(800)
  }
  for (const phase of phases) {
    await withRetry(`epic ${phase.id}`, () => gh(['issue', 'edit', String(created[`EPIC-${phase.id}`]), '-R', repo, '--body-file', '-'], epicBody(phase)))
    await sleep(800)
  }
  await withRetry('start', () => gh(['issue', 'edit', String(created.START), '-R', repo, '--body-file', '-'], startBody()))
  try {
    gh(['issue', 'pin', String(created.START), '-R', repo])
  }
  catch (error) {
    console.error(`pin: ${(error as Error).message}`)
  }
  created.__finalized = 1
  save()
}
console.log(`done: ${issues.length} issues, ${phases.length} epics, start-here #${created.START}`)
