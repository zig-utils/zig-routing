#!/usr/bin/env bun
// Turns the call graph of a macOS `sample` report into a flamegraph SVG (and, with
// --folded, the folded stacks flamegraph.pl reads). No dependencies.
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
const [input, output] = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1].startsWith('--') && !['--drop-idle', '--folded'].includes(args[i - 1])))
if (!input || !output) {
  console.error('usage: sample-to-svg.ts SAMPLE.txt OUT.svg [--title T] [--thread NAME] [--min FRACTION] [--drop-idle] [--folded]')
  process.exit(2)
}
const title = flag('--title') ?? 'zr'
const threadFilter = flag('--thread')
const minFraction = Number(flag('--min') ?? '0.002')
const dropIdle = args.includes('--drop-idle')
const idle = /^(kevent|__semwait_signal|__psynch_cvwait|__workq_kernreturn|mach_msg2_trap|__ulock_wait2?|nanosleep|epoll_wait)$/

interface Node { name: string, count: number, children: Map<string, Node> }
const root: Node = { name: 'all', count: 0, children: new Map() }

const text = readFileSync(input, 'utf8')
const start = text.indexOf('Call graph:')
const end = text.indexOf('Total number in stack')
const lines = text.slice(start, end > 0 ? end : undefined).split('\n').slice(1)

// Each line: tree drawing characters, a count, a frame. Depth is the column of the count.
const line_re = /^([\s+!:|]*?)(\d+) (.+)$/
const stack: Array<{ depth: number, node: Node }> = []
let keepThread = true
for (const line of lines) {
  const m = line_re.exec(line)
  if (!m) continue
  const depth = m[1].length
  const count = Number(m[2])
  let name = m[3].trim()
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
  let node = parent.children.get(key)
  if (!node) {
    node = { name: isThread ? key : name, count: 0, children: new Map() }
    parent.children.set(key, node)
  }
  node.count += count
  if (parent === root) root.count += count
  stack.push({ depth, node })
}

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

if (args.includes('--folded')) {
  const out: string[] = []
  const walk = (n: Node, path: string[]) => {
    const kids = [...n.children.values()]
    const self = n.count - kids.reduce((s, c) => s + c.count, 0)
    if (self > 0 && path.length) out.push(`${path.join(';')} ${self}`)
    for (const c of kids) walk(c, [...path, c.name])
  }
  walk(root, [])
  writeFileSync(output.replace(/\.svg$/, '.folded'), `${out.join('\n')}\n`)
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
