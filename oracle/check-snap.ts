#!/usr/bin/env bun
// Compare native check-snap output with Valhalla /locate for every corpus location.
type Location = { lat: number, lon: number, minimum_reachability?: number }
type Request = { costing: string, costing_options?: unknown, locations: Location[] }
type OracleEdge = {
  edge_info: { way_id: number, shape: string },
  edge: { forward: boolean },
  correlated_lat: number,
  correlated_lon: number,
  percent_along: number,
}
type NativeEdge = { way_id: number, shape: string, forward: boolean, lat: number, lon: number, percent_along: number }
type Candidates<Edge> = { edges?: Edge[], filtered_edges?: Edge[] }

const [oracle, corpusPath, nativePath] = process.argv.slice(2)
if (!oracle || !corpusPath || !nativePath) {
  throw new Error('usage: bun oracle/check-snap.ts ORACLE_URL CORPUS_TSV NATIVE_JSONL')
}
const corpus = (await Bun.file(corpusPath).text()).trimEnd().split('\n')
const native = (await Bun.file(nativePath).text()).trimEnd().split('\n').map(
  line => JSON.parse(line) as Candidates<NativeEdge> & { ns: number },
)
const groups = new Map<string, { request: Request, indexes: number[] }>()
let size = 0
for (const line of corpus) {
  const tab = line.indexOf('\t')
  if (tab < 0) throw new Error('missing corpus tab delimiter')
  const parsed: Request = JSON.parse(line.slice(tab + 1))
  const key = JSON.stringify([parsed.costing, parsed.costing_options])
  if (!groups.has(key)) {
    groups.set(key, {
      request: { costing: parsed.costing, costing_options: parsed.costing_options, locations: [] },
      indexes: [],
    })
  }
  const group = groups.get(key)!
  for (const location of parsed.locations) {
    group.request.locations.push({ ...location, minimum_reachability: 0 })
    group.indexes.push(size++)
  }
}
if (size === 0 || size !== native.length) throw new Error(`expected ${size} native locations, got ${native.length}`)

function first<Edge>(location: Candidates<Edge>): Edge | undefined {
  return location.edges?.[0] ?? location.filtered_edges?.[0]
}

let matches = 0
let empty = 0
const mismatches: number[] = []
for (const { request, indexes } of groups.values()) {
  for (let start = 0; start < indexes.length; start += 32) {
    const locations = request.locations.slice(start, start + 32)
    const response = await fetch(`${oracle}/locate`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ...request, locations, verbose: true }),
    })
    if (!response.ok) throw new Error(`oracle HTTP ${response.status} ${await response.text()}`)
    const results: Candidates<OracleEdge>[] = await response.json()
    if (results.length !== locations.length) throw new Error('oracle returned an unexpected location count')
    for (const [i, result] of results.entries()) {
      const index = indexes[start + i]
      const a = first(native[index])
      const b = first(result)
      if (!a && !b) empty++
      if ((!a && !b) ||
          (a && b && a.way_id === b.edge_info.way_id && a.shape === b.edge_info.shape && a.forward === b.edge.forward &&
           Math.hypot(a.lat - b.correlated_lat, a.lon - b.correlated_lon) <= 0.000002 &&
           Math.abs(a.percent_along - b.percent_along) < 0.001)) {
        matches++
      } else {
        mismatches.push(index)
      }
    }
  }
}
const timings = native.map(location => location.ns).sort((a, b) => a - b)
function percentile(fraction: number) {
  return timings[Math.ceil(timings.length * fraction) - 1]
}
console.log(JSON.stringify({
  locations: size,
  top_candidate_matches: matches,
  both_empty: empty,
  agreement: matches / size,
  median_ns: percentile(0.5),
  p95_ns: percentile(0.95),
  p99_ns: percentile(0.99),
  mismatches: mismatches.sort((a, b) => a - b),
}))
if (matches / size < 0.99) process.exitCode = 1
