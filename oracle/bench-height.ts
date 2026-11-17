// bun oracle/bench-height.ts <url> <points_per_request> <concurrency> <seconds>
// Height throughput: `concurrency` clients send requests of `points` points for `seconds`.
const [url, pointsArg, concArg, secArg] = process.argv.slice(2)
const points = Number(pointsArg), concurrency = Number(concArg), seconds = Number(secArg)
let seed = 11
const rand = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648)
const bodies = Array.from({ length: 16 }, () => JSON.stringify({ shape: Array.from({ length: points }, () => ({ lat: +(52 + rand()).toFixed(6), lon: +(5 + rand()).toFixed(6) })) }))
for (const b of bodies.slice(0, 2)) await fetch(`${url}/height`, { method: 'POST', body: b }) // warm up
let requests = 0
const lat: number[] = []
const end = performance.now() + seconds * 1000
await Promise.all(Array.from({ length: concurrency }, async (_, w) => {
  let i = w
  while (performance.now() < end) {
    const t = performance.now()
    const r = await fetch(`${url}/height`, { method: 'POST', body: bodies[i++ % bodies.length] })
    await r.arrayBuffer()
    lat.push(performance.now() - t)
    requests++
  }
}))
lat.sort((a, b) => a - b)
const pps = (requests * points) / seconds
console.log(`${url}: ${requests} req, ${(pps / 1e6).toFixed(2)} M points/s, p50 ${lat[Math.floor(lat.length / 2)].toFixed(1)} ms, p99 ${lat[Math.floor(lat.length * 0.99)].toFixed(1)} ms`)
