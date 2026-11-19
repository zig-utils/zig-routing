#!/usr/bin/env bun
// Turns macOS sample or Linux perf stacks into a flamegraph SVG or folded stacks.
//
//   sample <pid> 10 -file prof.txt
//   bun tools/flamegraph/sample-to-svg.ts prof.txt out.svg [--title T] [--thread NAME] [--min 0.002]
//
// Idle frames (kevent, __semwait_signal, the poller's wait) are kept, so the picture shows
// how busy the workers were; --drop-idle removes them to show only the work.

import { readFileSync, writeFileSync } from 'node:fs'

const args = process.argv.slice(2)
const flag = (n: string) => {
  const i = args.indexOf(n)
  return i >= 0 ? args[i + 1] : undefined
}
const switches = new Set(['--drop-idle', '--folded', '--perf'])
const [input, output] = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1].startsWith('--') && !switches.has(args[i - 1])))
if (!input || !output) {
  console.error('usage: sample-to-svg.ts PROFILE.txt OUT.{svg,folded} [--perf] [--title T] [--thread NAME] [--min FRACTION] [--drop-idle] [--folded]')
  process.exit(2)
}
const title = flag('--title') ?? 'zr'
const threadFilter = flag('--thread')
const minFraction = Number(flag('--min') ?? '0.002')
const dropIdle = args.includes('--drop-idle')
const idle = /^(kevent|__semwait_signal|__psynch_cvwait|__workq_kernreturn|mach_msg2_trap|__ulock_wait2?|nanosleep|epoll_wait)$/

interface Node { name: string, count: number, children: Map<string, Node> }
const root: Node = { name: 'all', count: 0, children: new Map() }

function addFrame(parent: Node, name: string, count: number): Node {
  let node = parent.children.get(name)
  if (!node) {
    node = { name, count: 0, children: new Map() }
    parent.children.set(name, node)
  }
  node.count += count
  if (parent === root) root.count += count
  return node
}

function readSample(text: string): void {
  const start = text.indexOf('Call graph:')
  if (start < 0) return
  const end = text.indexOf('Total number in stack', start)
  const lines = text.slice(start, end > 0 ? end : undefined).split('\n').slice(1)
  // Depth is the column of the count, after the tree drawing characters.
  const lineRe = /^([\s+!:|]*?)(\d+) (.+)$/
  const stack: Array<{ depth: number, node: Node }> = []
  let keepThread = true
  for (const line of lines) {
    const match = lineRe.exec(line)
    if (!match) continue
    const depth = match[1].length
    const count = Number(match[2])
    let name = match[3].trim()
    const isThread = /^Thread_\d+/.test(name)
    if (isThread) {
      keepThread = !threadFilter || name.includes(threadFilter)
      name = name.replace(/\s{2,}.*$/, '')
    }
    if (!keepThread) continue
    name = name.replace(/\s+\(in ([^)]+)\).*$/, '').replace(/\s+\+ \d+.*$/, '').replace(/\s+\[0x[0-9a-f]+\]$/, '')
    if (name === '???' || name.startsWith('??? ')) name = '[unknown]'
    while (stack.length && stack[stack.length - 1].depth >= depth) stack.pop()
    const parent = stack.length ? stack[stack.length - 1].node : root
    // Merge threads with the same work into one tower per thread kind.
    const key = isThread ? name.replace(/_\d+$/, '') : name
    stack.push({ depth, node: addFrame(parent, key, count) })
  }
}

function readPerf(text: string): void {
  const headerRe = /^(.+?)\s+\d+(?:\/\d+)?\s+\d+\.\d+:/
  const frameRe = /^\s+(?:0x)?[0-9a-f]+\s+(.+)\s+\(.*\)\s*$/i
  for (const sample of text.trim().split(/\n[ \t]*\n/)) {
    const [header, ...lines] = sample.trim().split('\n')
    const command = headerRe.exec(header)?.[1].trim()
    if (!command || (threadFilter && !command.includes(threadFilter))) continue
    const frames: string[] = []
    for (const line of lines) {
      const match = frameRe.exec(line)
      if (match) frames.push(match[1].trim().replace(/\+0x[0-9a-f]+$/i, ''))
    }
    if (!frames.length) continue
    let parent = addFrame(root, command, 1)
    // perf prints the sampled frame first, followed by its callers.
    for (let i = frames.length - 1; i >= 0; i--) parent = addFrame(parent, frames[i], 1)
  }
}

const text = readFileSync(input, 'utf8')
if (args.includes('--perf')) readPerf(text)
else readSample(text)

function prune(n: Node): number {
  if (dropIdle && idle.test(n.name)) return 0
  // Samples in this frame itself, before any child is dropped.
  const self = Math.max(0, n.count - [...n.children.values()].reduce((s, c) => s + c.count, 0))
  let kept = 0
  for (const [k, c] of n.children) {
    const v = prune(c)
    if (v === 0) n.children.delete(k)
    kept += v
  }
  if (dropIdle) n.count = kept + self
  return n.count
}
prune(root)
root.count = [...root.children.values()].reduce((s, c) => s + c.count, 0)
if (!root.count) throw new Error('profile contains no matching stack samples')

const foldedOnly = output.endsWith('.folded')
if (foldedOnly || args.includes('--folded')) {
  const out: string[] = []
  const walk = (n: Node, path: string[]) => {
    const kids = [...n.children.values()]
    const self = n.count - kids.reduce((s, c) => s + c.count, 0)
    if (self > 0 && path.length) out.push(`${path.join(';')} ${self}`)
    for (const c of kids) walk(c, [...path, c.name.replaceAll(';', ':')])
  }
  walk(root, [])
  writeFileSync(output.replace(/\.svg$/, '.folded'), `${out.join('\n')}\n`)
}
if (foldedOnly) {
  console.log(`${output}: ${root.count} samples`)
  process.exit(0)
}

// Layout: one row per depth, widths proportional to samples, bottom-up.
const width = 1200
const rowH = 17
let maxDepth = 0
const rects: Array<{ x: number, y: number, w: number, n: Node }> = []
const layout = (n: Node, x: number, depth: number) => {
  maxDepth = Math.max(maxDepth, depth)
  let cx = x
  for (const c of [...n.children.values()].sort((a, b) => a.name.localeCompare(b.name))) {
    const w = (c.count / root.count) * width
    if (c.count / root.count >= minFraction) {
      rects.push({ x: cx, y: depth, w, n: c })
      layout(c, cx, depth + 1)
    }
    cx += w
  }
}
layout(root, 0, 0)
const height = (maxDepth + 2) * rowH + 40
const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
const color = (name: string) => {
  if (idle.test(name)) return '#c8c8d0'
  let h = 0
  for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) >>> 0
  const zr = /^(api|elevation|geo|server|infra|cli)\./.test(name)
  return zr ? `hsl(${20 + (h % 30)}, 85%, ${55 + (h % 15)}%)` : `hsl(${200 + (h % 40)}, 45%, ${62 + (h % 12)}%)`
}
let svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" font-family="Menlo,monospace" font-size="11">\n`
svg += `<rect width="100%" height="100%" fill="#fbfbf8"/>\n<text x="8" y="20" font-size="14">${esc(title)} (${root.count} samples)</text>\n`
for (const r of rects) {
  const y = height - 20 - (r.y + 1) * rowH
  const pct = ((r.n.count / root.count) * 100).toFixed(2)
  const label = r.w > 40 ? esc(r.n.name.slice(0, Math.floor(r.w / 6.6))) : ''
  svg += `<g><title>${esc(r.n.name)}: ${r.n.count} samples (${pct}%)</title><rect x="${r.x.toFixed(1)}" y="${y}" width="${Math.max(0.5, r.w - 0.5).toFixed(1)}" height="${rowH - 1}" fill="${color(r.n.name)}"/>`
  if (label) svg += `<text x="${(r.x + 3).toFixed(1)}" y="${y + 12}">${label}</text>`
  svg += `</g>\n`
}
svg += '</svg>\n'
writeFileSync(output, svg)
console.log(`${output}: ${rects.length} frames, ${root.count} samples`)
