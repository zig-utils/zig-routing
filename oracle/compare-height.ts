#!/usr/bin/env bun
// Compares /height between the oracle and zr byte for byte on random requests.
//   bun oracle/compare-height.ts <oracle_url> <zr_url> [count] [seed]
// Points fall inside the dataset's elevation tile(s) given by --box minLat,minLon,maxLat,maxLon.
const [oracle, zr, countArg, seedArg] = process.argv.slice(2)
const boxArg = process.argv.find(a => a.startsWith('--box='))?.slice(6) ?? '47.0,9.0,48.0,10.0'
const [minLat, minLon, maxLat, maxLon] = boxArg.split(',').map(Number)
const count = Number(countArg ?? 500)
let seed = Number(seedArg ?? 1)
const rand = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648)

function point() {
  return { lat: +(minLat + rand() * (maxLat - minLat)).toFixed(6), lon: +(minLon + rand() * (maxLon - minLon)).toFixed(6) }
}

function request(i: number) {
  const n = 1 + Math.floor(rand() * 40)
  const shape = Array.from({ length: n }, point)
  const body: Record<string, unknown> = {}
  const kind = i % 6
  if (kind === 5) body.encoded_polyline = encode(shape, 6)
  else if (kind === 4) { body.encoded_polyline = encode(shape, 5); body.shape_format = 'polyline5' }
  else body.shape = shape
  if (i % 2 === 0) body.range = true
  body.height_precision = i % 3
  if (i % 7 === 0) body.resample_distance = 10 + Math.floor(rand() * 500)
  if (i % 11 === 0) body.id = `req-${i}`
  return body
}

function encode(points: { lat: number, lon: number }[], digits: number) {
  const f = 10 ** digits
  let out = ''
  let lastLat = 0
  let lastLon = 0
  const put = (v: number) => {
    v = v < 0 ? ~(v << 1) : v << 1
    while (v >= 0x20) { out += String.fromCharCode((0x20 | (v & 0x1f)) + 63); v >>= 5 }
    out += String.fromCharCode(v + 63)
  }
  for (const p of points) {
    const lat = Math.round(p.lat * f)
    const lon = Math.round(p.lon * f)
    put(lat - lastLat)
    put(lon - lastLon)
    lastLat = lat
    lastLon = lon
  }
  return out
}

let same = 0
const diffs: string[] = []
for (let i = 0; i < count; i++) {
  const body = JSON.stringify(request(i))
  const [a, b] = await Promise.all([oracle, zr].map(async url => {
    const r = await fetch(`${url}/height`, { method: 'POST', body })
    return `${r.status} ${await r.text()}`
  }))
  if (a === b) same++
  else if (diffs.length < 8) {
    let k = 0
    while (k < a.length && a[k] === b[k]) k++
    const from = Math.max(0, k - 80)
    diffs.push(`request ${body.slice(0, 200)}\n first difference at byte ${k}\n oracle ...${a.slice(from, k + 60)}\n zr     ...${b.slice(from, k + 60)}`)
  }
}
console.log(`${same}/${count} identical`)
for (const d of diffs) console.log(`\n${d}`)
process.exit(same === count ? 0 : 1)
