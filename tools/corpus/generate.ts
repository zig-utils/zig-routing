#!/usr/bin/env bun
// Request corpora for `zr bench` and `zr diff` (issue P0.05).
//
//   bun tools/corpus/generate.ts            write every corpus and bench/corpora/manifest.json
//   bun tools/corpus/generate.ts --check    regenerate in memory and compare with the manifest
//   bun tools/corpus/generate.ts --validate liechtenstein=http://127.0.0.1:8102
//                                            replay generated candidates against an oracle and
//                                            record the ones it rejects
//
// Options: --out DIR (default bench/corpora), --seed N (default 1), --only SUBSTRING.
//
// A corpus is one request per line, `PATH<TAB>BODY`, the format `zr bench --corpus` reads.
// Output is a pure function of the seed, the pinned upstream commit and this file: every
// random choice comes from a seeded generator, one stream per corpus, and coordinates are
// computed with + - * / and sqrt only (no libm), so two machines write the same bytes.
// The .tsv files are not committed; the manifest records their SHA-256 so a regeneration
// can be checked.

import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'
import { type Anchor, anchors, type Region } from './anchors'

const ROOT = resolve(import.meta.dir, '../..')

// Valhalla 3.9.3. The tag is resolved once and every tree it covers is checked by hash.
const UPSTREAM = {
  repo: 'https://github.com/valhalla/valhalla.git',
  tag: '3.9.3',
  commit: '5c7f918e61306521d79cc4496d40c19c5305fa4b',
  trees: {
    test_requests: 'fb725f8db3f547b737002aa0ab98266a0b26e7ba',
    'run_route_scripts/perf_test/url_de_benchmark_routes.txt': '9d0d6901cce852eadbfce0b9717382c95d41f67c',
  },
}

// ---------------------------------------------------------------------------
// Arguments

const argv = process.argv.slice(2)
function flag(name: string): string | undefined {
  const i = argv.indexOf(name)
  return i >= 0 ? argv[i + 1] : undefined
}
const outDir = resolve(ROOT, flag('--out') ?? 'bench/corpora')
const seed = Number(flag('--seed') ?? '1')
const only = flag('--only')
const check = argv.includes('--check')
if (!Number.isInteger(seed) || seed < 0)
  throw new Error('--seed must be a non-negative integer')

// ---------------------------------------------------------------------------
// Deterministic numbers

/** sfc32 seeded through splitmix32 from FNV-1a of `seed:name`, so each corpus has its own stream. */
function rng(name: string): () => number {
  let h = 0x811C9DC5
  for (const c of `${seed}:${name}`) h = Math.imul(h ^ c.charCodeAt(0), 0x01000193) >>> 0
  const split = () => {
    h = (h + 0x9E3779B9) >>> 0
    let z = h
    z = Math.imul(z ^ (z >>> 16), 0x85EBCA6B) >>> 0
    z = Math.imul(z ^ (z >>> 13), 0xC2B2AE35) >>> 0
    return (z ^ (z >>> 16)) >>> 0
  }
  let a = split()
  let b = split()
  let c = split()
  let d = split()
  return () => {
    const t = (((a + b) >>> 0) + d) >>> 0
    d = (d + 1) >>> 0
    a = b ^ (b >>> 9)
    b = (c + (c << 3)) >>> 0
    c = ((c << 21) | (c >>> 11)) >>> 0
    c = (c + t) >>> 0
    return t / 4294967296
  }
}

type Rand = () => number
const uniform = (r: Rand, lo: number, hi: number) => lo + (hi - lo) * r()
const pick = <T>(r: Rand, xs: readonly T[]): T => xs[Math.floor(r() * xs.length)]
function weighted<T>(r: Rand, xs: ReadonlyArray<readonly [number, T]>): T {
  let x = r() * xs.reduce((s, [w]) => s + w, 0)
  for (const [w, v] of xs) {
    x -= w
    if (x < 0)
      return v
  }
  return xs[xs.length - 1][1]
}
/** Log-uniform in [lo, hi]: lo * (hi/lo)^u, the power built from repeated square roots, not libm. */
function logUniform(r: Rand, lo: number, hi: number): number {
  const ratio = hi / lo
  let u = r()
  let result = 1
  let factor = ratio
  for (let i = 0; i < 40; i++) {
    factor = Math.sqrt(factor)
    u *= 2
    if (u >= 1) {
      result *= factor
      u -= 1
    }
  }
  return lo * result
}

// Trigonometry from series, so results do not depend on the platform libm.
const DEG = Math.PI / 180
function sinSeries(x: number): number {
  let term = x
  let sum = x
  for (let n = 1; n < 14; n++) {
    term *= -x * x / ((2 * n) * (2 * n + 1))
    sum += term
  }
  return sum
}
function cosSeries(x: number): number {
  let term = 1
  let sum = 1
  for (let n = 1; n < 14; n++) {
    term *= -x * x / ((2 * n - 1) * (2 * n))
    sum += term
  }
  return sum
}
function asinNewton(x: number): number {
  let y = x
  for (let i = 0; i < 8; i++) y -= (sinSeries(y) - x) / cosSeries(y)
  return y
}

interface LL { lat: number, lon: number }
const EARTH_M = 6371008.8
const M_PER_DEG_LAT = 111320

/** Great-circle distance in metres (haversine, inputs within one continent). */
function distanceM(a: LL, b: LL): number {
  const s1 = sinSeries((b.lat - a.lat) * DEG / 2)
  const s2 = sinSeries((b.lon - a.lon) * DEG / 2)
  const h = s1 * s1 + cosSeries(a.lat * DEG) * cosSeries(b.lat * DEG) * s2 * s2
  return 2 * EARTH_M * asinNewton(Math.sqrt(h))
}

/** A random unit vector (east, north), by rejection in the unit disc. */
function direction(r: Rand): [number, number] {
  for (;;) {
    const x = r() * 2 - 1
    const y = r() * 2 - 1
    const s = x * x + y * y
    if (s > 1e-6 && s <= 1) {
      const n = Math.sqrt(s)
      return [x / n, y / n]
    }
  }
}

/** Move `metres` along unit vector (east, north), on a local plane (fine below ~100 km). */
function offset(p: LL, east: number, north: number, metres: number): LL {
  return {
    lat: p.lat + north * metres / M_PER_DEG_LAT,
    lon: p.lon + east * metres / (M_PER_DEG_LAT * cosSeries(p.lat * DEG)),
  }
}

const round6 = (x: number) => Math.round(x * 1e6) / 1e6
const loc = (p: LL) => ({ lat: round6(p.lat), lon: round6(p.lon) })

/** Google polyline at precision 6, from the rounded coordinates. */
function polyline6(points: LL[]): string {
  let out = ''
  let plat = 0
  let plon = 0
  const put = (v: number) => {
    let x = v < 0 ? ~(v * 2) : v * 2
    while (x >= 0x20) {
      out += String.fromCharCode((0x20 | (x & 0x1F)) + 63)
      x = Math.floor(x / 32)
    }
    out += String.fromCharCode(x + 63)
  }
  for (const p of points) {
    const lat = Math.round(p.lat * 1e6)
    const lon = Math.round(p.lon * 1e6)
    put(lat - plat)
    put(lon - plon)
    plat = lat
    plon = lon
  }
  return out
}

// ---------------------------------------------------------------------------
// Datasets

interface BBox { minLat: number, maxLat: number, minLon: number, maxLon: number }
interface Dataset {
  name: string
  /** Where requests may be placed: a box (test extracts) or anchors (regional builds). */
  bbox?: BBox
  regions?: Region[]
  /** Longest straight-line route and shape for this extent, in km. */
  maxKm: number
  oracle: string
}

const datasets: Dataset[] = [
  {
    name: 'liechtenstein',
    // Header bbox of upstream test/data/liechtenstein-latest.osm.pbf at 3.9.3.
    bbox: { minLat: 47.04774, maxLat: 47.27128, minLon: 9.471078, maxLon: 9.636217 },
    maxKm: 20,
    oracle: 'oracle/up.sh liechtenstein',
  },
  {
    name: 'utrecht',
    // Header bbox of upstream test/data/utrecht_netherlands.osm.pbf at 3.9.3.
    bbox: { minLat: 52.047, maxLat: 52.1411, minLon: 5.0163, maxLon: 5.1622 },
    maxKm: 12,
    oracle: 'oracle/up.sh utrecht',
  },
  {
    name: 'us-dach',
    regions: ['us', 'dach'],
    maxKm: 80,
    oracle: 'production config, not reproduced locally yet (P0.03)',
  },
]

const inBox = (p: LL, b: BBox) => p.lat >= b.minLat && p.lat <= b.maxLat && p.lon >= b.minLon && p.lon <= b.maxLon

function anchorPool(ds: Dataset): Anchor[] {
  return anchors.filter(a => ds.regions!.includes(a.region))
}

/** A start point: uniform in the box, or within `spreadM` of an anchor. */
function startPoint(r: Rand, ds: Dataset, spreadM: number): LL {
  if (ds.bbox) {
    const b = ds.bbox
    return { lat: uniform(r, b.minLat, b.maxLat), lon: uniform(r, b.minLon, b.maxLon) }
  }
  const a = pick(r, anchorPool(ds))
  const [e, n] = direction(r)
  return offset(a, e, n, Math.sqrt(r()) * spreadM)
}

/** A point `metres` from `from` that stays inside the dataset box, or undefined after retries. */
function stepFrom(r: Rand, ds: Dataset, from: LL, metres: number): LL | undefined {
  for (let i = 0; i < 64; i++) {
    const [e, n] = direction(r)
    const to = offset(from, e, n, metres)
    if (!ds.bbox || inBox(to, ds.bbox))
      return to
  }
  return undefined
}

/** Waypoints whose straight-line legs add up to `totalM`. */
function waypoints(r: Rand, ds: Dataset, count: number, totalM: number): LL[] {
  for (;;) {
    const pts = [startPoint(r, ds, 15000)]
    const leg = totalM / (count - 1)
    for (let i = 1; i < count; i++) {
      const next = stepFrom(r, ds, pts[i - 1], leg)
      if (!next)
        break
      pts.push(next)
    }
    if (pts.length === count)
      return pts
  }
}

// ---------------------------------------------------------------------------
// Request shapes taken from the two production clients (see docs/PLAN.md). Key order
// matches what they send, so request bytes look like real traffic.

const TRAIL_APP_FOOT = { walkway_factor: 0.6, sidewalk_factor: 1, use_tracks: 0.8, max_hiking_difficulty: 3 }
const TRAINING_FOOT = {
  coast: { walkway_factor: 0.6, sidewalk_factor: 1, use_tracks: 0.8, use_living_streets: 0.8, max_hiking_difficulty: 3, step_penalty: 30 },
  trails: { walkway_factor: 0.5, sidewalk_factor: 1, use_tracks: 1, use_living_streets: 0.6, max_hiking_difficulty: 3, step_penalty: 30 },
  direct: { step_penalty: 30 },
}
const TRAINING_BIKE = {
  coast: { use_roads: 0.2, use_hills: 0.4 },
  trails: { use_roads: 0.1 },
}

type Line = [path: string, body: Record<string, unknown>]

function footBikeRequest(r: Rand, ds: Dataset): Line {
  const km = logUniform(r, 1, ds.maxKm)
  const client = weighted(r, [[35, 'trail'], [65, 'training']] as const)
  if (client === 'trail') {
    const pts = waypoints(r, ds, 2, km * 1000)
    return ['/route', { locations: pts.map(loc), costing: 'pedestrian', costing_options: { pedestrian: TRAIL_APP_FOOT }, directions_type: 'none' }]
  }
  const count = weighted(r, [[70, 2], [12, 3], [10, 4], [8, 5]] as const)
  const pts = waypoints(r, ds, count, km * 1000)
  const bike = r() < 0.4
  const options = bike
    ? weighted(r, [[40, TRAINING_BIKE.coast], [40, TRAINING_BIKE.trails], [20, undefined]] as const)
    : weighted(r, [[40, TRAINING_FOOT.coast], [40, TRAINING_FOOT.trails], [20, TRAINING_FOOT.direct]] as const)
  const costing = bike ? 'bicycle' : 'pedestrian'
  const body: Record<string, unknown> = { locations: pts.map(loc), costing, directions_type: 'none' }
  if (options)
    body.costing_options = { [costing]: options }
  return ['/route', body]
}

function heightRequest(r: Rand, ds: Dataset): Line {
  // The training client samples a route at 400 points for climb and up to 1200 for its profile.
  const n = r() < 0.3 ? 400 : Math.round(logUniform(r, 2, 1200))
  const totalM = logUniform(r, 0.5, Math.max(1, ds.maxKm)) * 1000
  const step = totalM / (n - 1)
  let p = startPoint(r, ds, 15000)
  let [e, nn] = direction(r)
  const pts: LL[] = [p]
  while (pts.length < n) {
    // Meander: nudge the heading, renormalise, bounce off the box edges.
    const [de, dn] = direction(r)
    e += de * 0.25
    nn += dn * 0.25
    const len = Math.sqrt(e * e + nn * nn)
    e /= len
    nn /= len
    let next = offset(p, e, nn, step)
    if (ds.bbox && !inBox(next, ds.bbox)) {
      if (next.lat < ds.bbox.minLat || next.lat > ds.bbox.maxLat)
        nn = -nn
      if (next.lon < ds.bbox.minLon || next.lon > ds.bbox.maxLon)
        e = -e
      next = offset(p, e, nn, step)
      if (!inBox(next, ds.bbox))
        next = p
    }
    pts.push(next)
    p = next
  }
  const range = r() < 0.25
  if (r() < 0.25)
    return ['/height', { encoded_polyline: polyline6(pts.map(loc)), range }]
  return ['/height', { shape: pts.map(loc), range }]
}

function anchorPairs(ds: Dataset, loM: number, hiM: number): Array<[Anchor, Anchor]> {
  const pool = anchorPool(ds)
  const pairs: Array<[Anchor, Anchor]> = []
  for (let i = 0; i < pool.length; i++) {
    for (let j = i + 1; j < pool.length; j++) {
      if (pool[i].region !== pool[j].region)
        continue
      const d = distanceM(pool[i], pool[j])
      if (d >= loM && d <= hiM)
        pairs.push([pool[i], pool[j]])
    }
  }
  return pairs
}

function autoRequest(r: Rand, ds: Dataset, km: number, pairs: Array<[Anchor, Anchor]>): Line {
  let pts: LL[]
  if (km <= 50) {
    pts = waypoints(r, ds, 2, uniform(r, 0.8, 1.2) * km * 1000)
  }
  else {
    const [a, b] = pick(r, pairs)
    const ends = r() < 0.5 ? [a, b] : [b, a]
    pts = ends.map((p) => {
      const [e, n] = direction(r)
      return offset(p, e, n, Math.sqrt(r()) * 5000)
    })
  }
  return ['/route', { locations: pts.map(loc), costing: 'auto', directions_type: 'none' }]
}

// ---------------------------------------------------------------------------
// Upstream requests

const upstreamDir = join(outDir, '.upstream')

function git(args: string[], cwd?: string): string {
  const p = Bun.spawnSync(['git', ...args], { cwd, stdout: 'pipe', stderr: 'pipe' })
  if (p.exitCode !== 0)
    throw new Error(`git ${args.join(' ')}: ${p.stderr.toString()}`)
  return p.stdout.toString().trim()
}

function fetchUpstream(): string {
  if (!existsSync(join(upstreamDir, '.git'))) {
    mkdirSync(outDir, { recursive: true })
    git(['clone', '--quiet', '--depth', '1', '--branch', UPSTREAM.tag, '--filter=blob:none', '--sparse', UPSTREAM.repo, upstreamDir])
    git(['sparse-checkout', 'set', 'test_requests', 'run_route_scripts/perf_test'], upstreamDir)
  }
  const head = git(['rev-parse', 'HEAD'], upstreamDir)
  if (head !== UPSTREAM.commit)
    throw new Error(`upstream ${UPSTREAM.tag} resolved to ${head}, expected ${UPSTREAM.commit}`)
  for (const [path, want] of Object.entries(UPSTREAM.trees)) {
    const got = git(['rev-parse', `HEAD:${path}`], upstreamDir)
    if (got !== want)
      throw new Error(`upstream ${path} is ${got}, expected ${want}`)
  }
  if (git(['status', '--porcelain'], upstreamDir) !== '')
    throw new Error(`${upstreamDir} has local changes; delete it to refetch`)
  return upstreamDir
}

/** Every JSON object following `-j '` in an upstream request file (bodies may span lines). */
function parseRequestFile(text: string): { bodies: Array<Record<string, unknown>>, skipped: number } {
  const bodies: Array<Record<string, unknown>> = []
  let skipped = 0
  let at = 0
  for (;;) {
    const j = text.indexOf('-j \'', at)
    if (j < 0)
      break
    const start = text.indexOf('{', j)
    let depth = 0
    let inString = false
    let end = -1
    for (let i = start; i < text.length; i++) {
      const c = text[i]
      if (inString) {
        if (c === '\\')
          i++
        else if (c === '"')
          inString = false
      }
      else if (c === '"') {
        inString = true
      }
      else if (c === '{') {
        depth++
      }
      else if (c === '}' && --depth === 0) {
        end = i
        break
      }
    }
    if (start < 0 || end < 0)
      break
    try {
      bodies.push(JSON.parse(text.slice(start, end + 1)))
    }
    catch {
      skipped++
    }
    at = end + 1
  }
  return { bodies, skipped }
}

function listFiles(dir: string): string[] {
  const out: string[] = []
  for (const name of readdirSync(dir).sort()) {
    const p = join(dir, name)
    if (statSync(p).isDirectory())
      out.push(...listFiles(p))
    else out.push(p)
  }
  return out
}

interface UpstreamRequest { file: string, body: Record<string, unknown> }

function upstreamRequests(dir: string): { requests: UpstreamRequest[], skipped: Record<string, number> } {
  const requests: UpstreamRequest[] = []
  const skipped: Record<string, number> = {}
  for (const file of listFiles(join(dir, 'test_requests'))) {
    const rel = relative(join(dir, 'test_requests'), file)
    if (!rel.endsWith('.txt')) {
      skipped[rel] = -1
      continue
    }
    const { bodies, skipped: bad } = parseRequestFile(readFileSync(file, 'utf8'))
    if (bodies.length === 0) {
      skipped[rel] = -1
      continue
    }
    if (bad)
      skipped[rel] = bad
    for (const body of bodies) requests.push({ file: rel, body })
  }
  return { requests, skipped }
}

function deBenchmark(dir: string): Array<Record<string, unknown>> {
  const text = readFileSync(join(dir, 'run_route_scripts/perf_test/url_de_benchmark_routes.txt'), 'utf8')
  return text.split('\n').filter(Boolean).map((line) => {
    const json = line.slice(line.indexOf('?json=') + 6)
    return JSON.parse(json.startsWith('{') ? json : decodeURIComponent(json))
  })
}

function locationsOf(body: Record<string, unknown>): LL[] {
  const keys = ['locations', 'sources', 'targets', 'shape']
  return keys.flatMap(k => (Array.isArray(body[k]) ? body[k] as LL[] : []))
}

// ---------------------------------------------------------------------------
// Corpora
//
// A generated corpus draws candidates from its own random stream and keeps the first
// `count` that the oracle accepts. Which candidates the oracle rejected (any status but
// 200: points on a footpath island, a mode the data forbids) is recorded in the manifest
// by `--validate`, so regenerating without an oracle skips the same candidates and writes
// the same bytes. Upstream corpora are taken whole.

interface Corpus {
  file: string
  dataset: string
  source: 'generated' | 'upstream'
  description: string
  /** Requests to keep; undefined takes everything the generator yields. */
  count?: number
  gen: () => Iterable<Line>
}

function* forever(make: () => Line): Generator<Line> {
  for (;;) yield make()
}

const corpora: Corpus[] = []

for (const ds of datasets) {
  corpora.push({
    file: `route-foot-bike.${ds.name}.tsv`,
    dataset: ds.name,
    source: 'generated',
    description: `pedestrian and bicycle /route with the production option sets, directions_type none, 1 to ${ds.maxKm} km`,
    count: ds.bbox ? 1000 : 5000,
    gen: () => {
      const r = rng(`route-foot-bike.${ds.name}`)
      return forever(() => footBikeRequest(r, ds))
    },
  })
  corpora.push({
    file: `height.${ds.name}.tsv`,
    dataset: ds.name,
    source: 'generated',
    description: 'bulk /height: shapes and polyline6 of 2 to 1200 points, range on and off',
    count: ds.bbox ? 300 : 1000,
    gen: () => {
      const r = rng(`height.${ds.name}`)
      return forever(() => heightRequest(r, ds))
    },
  })
  const buckets = ds.bbox ? [10] : [10, 200, 1000, 4000]
  for (const km of buckets) {
    const tolerance = km <= 10 ? 0.2 : km <= 200 ? 0.15 : 0.1
    corpora.push({
      file: `route-auto-${km}km.${ds.name}.tsv`,
      dataset: ds.name,
      source: 'generated',
      description: `auto /route, straight-line distance ${km} km +/- ${tolerance * 100}%, directions_type none`,
      count: ds.bbox ? 300 : 500,
      gen: () => {
        const r = rng(`route-auto-${km}km.${ds.name}`)
        const pairs = km > 50 ? anchorPairs(ds, km * 1000 * (1 - tolerance), km * 1000 * (1 + tolerance)) : []
        if (km > 50 && pairs.length === 0)
          throw new Error(`no anchor pairs ${km} km apart in ${ds.name}`)
        return forever(() => autoRequest(r, ds, km, pairs))
      },
    })
  }
}

let upstreamCache: ReturnType<typeof upstreamRequests> | undefined
const upstream = () => (upstreamCache ??= upstreamRequests(fetchUpstream()))
const asRoute = (body: Record<string, unknown>): Line => ['/route', body]

corpora.push({
  file: 'upstream.all.tsv',
  dataset: 'planet',
  source: 'upstream',
  description: `every JSON request in test_requests/ at Valhalla ${UPSTREAM.tag}, replayed as /route like upstream's run_with_server.py`,
  gen: () => upstream().requests.map(q => asRoute(q.body)),
})
for (const ds of datasets.filter(d => d.bbox)) {
  corpora.push({
    file: `upstream.${ds.name}.tsv`,
    dataset: ds.name,
    source: 'upstream',
    description: `test_requests/ entries whose locations all fall inside the ${ds.name} extract`,
    gen: () => upstream().requests
      .filter((q) => {
        const pts = locationsOf(q.body)
        return pts.length > 0 && pts.every(p => inBox(p, ds.bbox!))
      })
      .map(q => asRoute(q.body)),
  })
}
const US_DACH_FILES = ['city_to_city/United_States_routes.txt', 'city_to_city/Germany_routes.txt', 'city_to_city/Austria_routes.txt', 'city_to_city/Switzerland_routes.txt']
corpora.push({
  file: 'upstream.us-dach.tsv',
  dataset: 'us-dach',
  source: 'upstream',
  description: `test_requests/ city-to-city routes for ${US_DACH_FILES.map(f => f.replace(/^city_to_city\/|_routes\.txt$/g, '')).join(', ')}`,
  gen: () => upstream().requests.filter(q => US_DACH_FILES.includes(q.file)).map(q => asRoute(q.body)),
})
corpora.push({
  file: 'de-benchmark.us-dach.tsv',
  dataset: 'us-dach',
  source: 'upstream',
  description: `run_route_scripts/perf_test/url_de_benchmark_routes.txt at Valhalla ${UPSTREAM.tag}: German city pairs, auto`,
  gen: () => deBenchmark(fetchUpstream()).map(asRoute),
})

// ---------------------------------------------------------------------------
// Validate, write and check

interface Entry {
  file: string
  dataset: string
  source: string
  description: string
  requests: number
  endpoints: Record<string, number>
  costing: Record<string, number>
  bytes: number
  sha256: string
  /** Set by --validate: the oracle it ran against and the candidate indices it rejected. */
  validated?: string
  rejected?: number[]
}

/** The kept requests: candidates in order, minus the rejected indices, up to the count. */
function* kept(c: Corpus, rejected: ReadonlySet<number>): Generator<Line> {
  let index = 0
  let n = 0
  for (const line of c.gen()) {
    if (c.count !== undefined && n >= c.count)
      return
    if (!rejected.has(index++)) {
      n++
      yield line
    }
  }
}

function render(c: Corpus, old?: Entry): { text: string, entry: Entry } {
  const rejected = new Set(old?.rejected ?? [])
  const endpoints: Record<string, number> = {}
  const costing: Record<string, number> = {}
  const parts: string[] = []
  for (const [path, body] of kept(c, rejected)) {
    endpoints[path] = (endpoints[path] ?? 0) + 1
    const k = typeof body.costing === 'string' ? body.costing : '(none)'
    costing[k] = (costing[k] ?? 0) + 1
    parts.push(`${path}\t${JSON.stringify(body)}\n`)
  }
  const text = parts.join('')
  const sorted = (o: Record<string, number>) => Object.fromEntries(Object.entries(o).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
  const entry: Entry = {
    file: c.file,
    dataset: c.dataset,
    source: c.source,
    description: c.description,
    requests: parts.length,
    endpoints: sorted(endpoints),
    costing: sorted(costing),
    bytes: Buffer.byteLength(text),
    sha256: createHash('sha256').update(text).digest('hex'),
  }
  if (old?.validated) {
    entry.validated = old.validated
    entry.rejected = old.rejected
  }
  return { text, entry }
}

/** Replay candidates against an oracle until `count` are accepted; returns the rejected indices. */
async function validate(c: Corpus, url: string): Promise<number[]> {
  const rejected: number[] = []
  const it = c.gen()[Symbol.iterator]()
  let index = 0
  let accepted = 0
  const statuses: Record<number, number> = {}
  while (accepted < c.count!) {
    // Batches of 16 in flight; a batch can overshoot the count, and the extras are simply unused.
    const batch: Array<[number, Line]> = []
    for (let i = 0; i < 16; i++) batch.push([index++, it.next().value as Line])
    const codes = await Promise.all(batch.map(async ([, [path, body]]) => {
      const res = await fetch(`${url}${path}`, { method: 'POST', body: JSON.stringify(body) })
      await res.arrayBuffer()
      return res.status
    }))
    for (let i = 0; i < batch.length && accepted < c.count!; i++) {
      statuses[codes[i]] = (statuses[codes[i]] ?? 0) + 1
      if (codes[i] === 200)
        accepted++
      else rejected.push(batch[i][0])
    }
  }
  console.log(`  ${c.file}: ${index} candidates tried, ${rejected.length} rejected ${JSON.stringify(statuses)}`)
  return rejected
}

/** JSON with arrays of numbers kept on one line, so rejected lists do not take a line each. */
function stringify(value: unknown): string {
  return JSON.stringify(value, null, 2).replace(/\[\s+(-?\d[\d\s,.-]*?)\s+\]/g, (_, nums: string) => `[${nums.split(/,\s*/).join(', ')}]`)
}

const manifestPath = join(outDir, 'manifest.json')
const old = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, 'utf8')) : { corpora: [] }
const oldEntries = new Map((old.corpora as Entry[]).map(e => [e.file, e]))
const selected = corpora.filter(c => !only || c.file.includes(only))

if (check) {
  if (old.seed !== seed)
    throw new Error(`manifest was written with --seed ${old.seed}`)
  let bad = 0
  for (const c of selected) {
    const want = oldEntries.get(c.file)
    const { entry } = render(c, want)
    const ok = want?.sha256 === entry.sha256
    if (!ok)
      bad++
    console.log(`${ok ? 'ok  ' : 'DIFF'} ${c.file} ${entry.requests} requests ${entry.sha256.slice(0, 12)}${ok ? '' : ` (manifest ${want?.sha256.slice(0, 12) ?? 'missing'})`}`)
  }
  process.exit(bad ? 1 : 0)
}

// --validate DATASET=URL (repeatable): refresh the rejected lists of that dataset's generated corpora.
const oracles = new Map<string, string>()
argv.forEach((a, i) => {
  if (a === '--validate') {
    const [name, url] = (argv[i + 1] ?? '').split('=')
    if (!name || !url || !datasets.some(d => d.name === name))
      throw new Error('--validate takes DATASET=URL, e.g. liechtenstein=http://127.0.0.1:8102')
    oracles.set(name, url.replace(/\/$/, ''))
  }
})
if (oracles.size && seed !== old.seed && old.seed !== undefined)
  throw new Error(`manifest was written with --seed ${old.seed}; validate with the same seed`)

mkdirSync(outDir, { recursive: true })
for (const c of selected) {
  const url = oracles.get(c.dataset)
  let prior = oldEntries.get(c.file)
  if (url && c.source === 'generated') {
    const status = await (await fetch(`${url}/status`)).json() as { version?: string }
    const rejected = await validate(c, url)
    const ds = datasets.find(d => d.name === c.dataset)!
    prior = { ...(prior ?? {}), validated: `Valhalla ${status.version} (${ds.oracle})`, rejected } as Entry
  }
  const { text, entry } = render(c, prior)
  writeFileSync(join(outDir, c.file), text)
  oldEntries.set(c.file, entry)
  console.log(`${c.file}: ${entry.requests} requests, ${(entry.bytes / 1e6).toFixed(1)} MB`)
}
const known = new Set(corpora.map(c => c.file))
const manifest = {
  generator: 'tools/corpus/generate.ts',
  seed,
  format: 'one request per line: PATH<TAB>BODY (zr bench --corpus)',
  // Upstream files with no JSON requests (-1) or with bodies that do not parse (count).
  upstream: { ...UPSTREAM, skipped: upstreamCache?.skipped ?? old.upstream?.skipped },
  datasets: Object.fromEntries(datasets.map(d => [d.name, { oracle: d.oracle, bbox: d.bbox, regions: d.regions, maxKm: d.maxKm }])),
  corpora: [...oldEntries.values()].filter(e => known.has(e.file)).sort((a, b) => (a.file < b.file ? -1 : 1)),
}
writeFileSync(manifestPath, `${stringify(manifest)}\n`)
console.log(`wrote ${relative(ROOT, manifestPath)}`)
