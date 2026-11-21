# Geocoder autocomplete

`geocode.autocomplete.Engine` uses the geocoder bundle and term index.
It matches each completed token exactly, using the shared analyzer's
normalization and aliases. The unfinished token matches the beginning of
a dictionary key. A trailing separator completes the preceding token.

```sh
zr geocode suggest BUNDLE 'Rue de la G' --near 6.13,49.61 --limit 5
zr bench BUNDLE --autocomplete --dataset luxembourg-260101 --threads 8 --duration 8s --out autocomplete.json
```

Opening the engine prepares the union of postings for each one- and
two-scalar prefix in each field. Contextual searches can intersect those
lists directly. For an unqualified short query, the engine can return
the precomputed top results. Short queries with spatial or language
constraints use candidates grouped by geographic cell and sorted by
their base score. For proximity, the cell's distance from the bias point
minus its covering radius gives a conservative bound on the best
remaining distance bonus. The search stops evaluating a cell when its
remaining upper score cannot reach the current top results.

Longer prefixes traverse the dictionary. Completed tokens and the final
prefix intersect in importance order, starting with the smaller posting
unions. Cursors can jump over restart groups using their first record's
importance and ID. Deadline checks run at fixed intervals during
intersections. The engine reuses the forward-search rank and result
formatter. Equal ranks keep their importance and ID ordering across
keystrokes.

## Load test

The local `zr bench --autocomplete` mode creates a seeded workload from
real names and addresses in the bundle. It takes up to 48 records per feature
layer, includes a feature-coordinate bias on every fourth source query,
and replays every UTF-8 scalar boundary. With `--corpus FILE`, it
instead takes one complete query per nonempty UTF-8 line.

Each worker warms its request arena on the entire workload, rewinds it
after each lookup, and counts backing allocator calls during the timed
window. Timing includes matching, ranking and the typed result assembly.
The benchmark reports p50 and p99 over all keystrokes, separate p99s for
one- and two-character inputs, sustained requests per second, and
allocation calls. The regional CI job compares these values with
`bench/budgets/autocomplete.json`.

On the 2026-01-01 Luxembourg extract, 192 source queries produced 3,504
keystrokes. An Apple M3 Pro running eight ReleaseFast workers completed
459,786 lookups in 12.007 seconds, or 38,294 per second. Overall p50 was
0.040 ms and p99 was 2.19 ms. The one- and two-character p99 values were
0.32 ms and 0.65 ms. The backing allocator recorded zero timed calls.
The four-worker run sustained 16,308 requests per second.
