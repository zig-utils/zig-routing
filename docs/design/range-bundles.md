# Range-fetched bundles

Export a manifest from a verified native bundle and serve its section files
from one immutable HTTP or HTTPS directory. Distribute the manifest through
the same trusted channel as the bundle configuration. The URL may change
while the manifest continues to identify the exact bytes.

```sh
zr bundle-manifest --output MANIFEST BUNDLE
zr fetch-bundle --timeout 10m ORIGIN_URL MANIFEST CACHE_DIRECTORY
```

`CACHE_DIRECTORY` is an existing local directory. The command prints the
completed bundle path under the SHA-256 of the manifest. HTTPS uses the
system trust store and validates the origin hostname through zig-tls. The
origin must support single-range responses with an exact `Content-Range`
and identity content encoding. [HTTP range semantics](https://www.rfc-editor.org/rfc/rfc9110.html#name-content-range)

The version 1 manifest contains the dataset UUID, then section records in
kind order. Each record contains the full mapped file size, its SHA-256
and the SHA-256 of every consecutive 64 KiB extent. The final extent ends
at the file size. These hashes cover headers, padding and payloads.

Cache files are sparse at creation. Each section has a compact persisted
fill bitmap. Reads return a slice after all covering extents verify. One
worker fetches a missing extent while concurrent waiters observe their
own deadlines. The fetcher verifies and writes the bytes before publishing
presence. After restart, remembered extents are verified on first use,
so an interrupted write or damaged cache entry is fetched again. A
completed fill checks each full file and runs the native bundle verifier.

The cache filler accepts recent ranges and runs them after hot sections,
then fills the remaining sections. Online serving from the sparse cache
requires the route request integration and the bundle cell table.
[Range-fetch issue](https://github.com/zig-utils/zig-routing/issues/105)
