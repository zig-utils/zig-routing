// Replay one shortest auto route against the default and pruning-opt-in Utrecht oracles.
const [defaultUrl, unprunedUrl] = Bun.argv.slice(2)
if (!defaultUrl || !unprunedUrl)
  throw new Error('usage: bun oracle/check-pruning.ts DEFAULT_URL UNPRUNED_URL')

const request = {
  locations: [{ lat: 52.135665, lon: 5.036623 }, { lat: 52.135788, lon: 5.140872 }],
  costing: 'auto',
  directions_type: 'none',
  costing_options: { auto: { shortest: true, disable_hierarchy_pruning: true } },
}

interface RouteResponse {
  trip?: {
    summary: { cost: number }
    legs: Array<{ shape: string }>
    warnings?: Array<{ code: number }>
  }
}

async function route(base: string) {
  const response = await fetch(new URL('/route', base), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(request),
    signal: AbortSignal.timeout(10_000),
  })
  if (!response.ok)
    throw new Error(`${base} returned HTTP ${response.status}: ${await response.text()}`)
  const { trip } = await response.json() as RouteResponse
  const shape = trip?.legs[0]?.shape
  const cost = trip?.summary.cost
  if (!shape || typeof cost !== 'number' || !Number.isFinite(cost))
    throw new Error(`${base} did not return a route shape and cost`)
  return { shape, cost, rejected: trip?.warnings?.some(warning => warning.code === 205) ?? false }
}

const [pruned, unpruned] = await Promise.all([route(defaultUrl), route(unprunedUrl)])
if (!pruned.rejected || unpruned.rejected)
  throw new Error('expected only the default oracle to reject the pruning option (warning 205)')
if (pruned.shape === unpruned.shape || unpruned.cost >= pruned.cost)
  throw new Error('expected the pruning opt-in to produce a different route with a lower cost')
console.log(`Utrecht shortest auto route changed shape and improved cost: ${pruned.cost} -> ${unpruned.cost}`)
