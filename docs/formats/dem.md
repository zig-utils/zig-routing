# Packed DEM format (`.zdem`), version 1

Lossless storage for SRTM elevation posts, built by `zr dem pack` from `.hgt`, `.hgt.gz` and
`.hgt.lz4` tiles and read by `src/elevation/packed.zig`. Every post decodes to exactly the source
value, so `/height` through a pack is byte-identical to `/height` through the tiles it came from.

## Goals

- **Memory-mappable and seekable.** A sample decodes one 64 x 64 block, not a 25 MB tile, so a
  cold server answers its first request without inflating anything.
- **Small.** About a sixth of raw `.hgt` on the test region (below).
- **Checked.** A hash covers the directory, checked at open; a CRC-32 per block, checked by
  `zr dem verify` and `Pack.decodeChecked`.

## Layout

All integers are little-endian. Records are `extern struct`s with comptime size and offset
assertions in `packed.zig`.

```
offset 0          Header (64 bytes)
offset 64         payload: block payloads, tile after tile, in ascending tile order
slots_offset      u32[64800]       one per 1x1 degree tile: 0 absent, else 1 + TileEntry index
entries_offset    TileEntry[n]     16 bytes each, ascending tile index
blocks_offset     BlockEntry[m]    24 bytes each, 3249 per non-constant tile
end_offset        end of file
```

The directory sits after the payload so `pack` can stream tiles to disk and write the header
last. `slots_offset` is 8-byte aligned.

### Header

| Offset | Field | Type | Notes |
|---|---|---|---|
| 0 | magic | u8[8] | `ZRDEM\0\0\x01` |
| 8 | version | u32 | 1 |
| 12 | tile_dim | u16 | 3601 posts per side (1 arc-second SRTM) |
| 14 | block_dim | u16 | 64 |
| 16 | tile_count | u32 | number of TileEntry records |
| 20 | reserved | u32 | 0 |
| 24 | slots_offset | u64 | |
| 32 | entries_offset | u64 | `slots_offset + 4 * 64800` |
| 40 | blocks_offset | u64 | `entries_offset + 16 * tile_count` |
| 48 | end_offset | u64 | file length |
| 56 | directory_hash | u64 | XxHash3 (seed 0) of bytes `[slots_offset, end_offset)` |

The tile index is `(floor(lat) + 90) * 360 + (floor(lon) + 180)`, the same as skadi's.

### TileEntry (16 bytes)

| Offset | Field | Type | Notes |
|---|---|---|---|
| 0 | tile | u32 | tile index |
| 4 | kind | u8 | 0 constant (every post equals `constant`: sea, voids), 1 blocks |
| 5 | reserved | u8 | |
| 6 | constant | i16 | |
| 8 | first_block | u32 | index of the tile's first BlockEntry |
| 12 | reserved | u32 | |

### BlockEntry (24 bytes)

A tile is 57 x 57 blocks, row-major from the north-west corner. Blocks are 64 x 64 posts, except
the last column and row, which are 17 wide or tall (3601 = 56 * 64 + 17).

| Offset | Field | Type | Notes |
|---|---|---|---|
| 0 | offset | u64 | absolute file offset of the payload |
| 8 | len | u32 | payload bytes |
| 12 | crc | u32 | CRC-32 (IEEE) of the payload |
| 16 | kind | u8 | 0 constant, 1 median predictor, 2 plane predictor |
| 17 | reserved | u8 | |
| 18 | constant | i16 | the value of a constant block |
| 20 | reserved | u32 | |

## Block payload

Posts are visited row-major within the block. Each post `x` has a prediction:

- the first post: 0
- the rest of the first row: the west neighbour `a`
- the first column: the north neighbour `b`
- elsewhere, with `c` the north-west neighbour:
  - kind 1, median edge detector (LOCO-I): `min(a, b)` if `c >= max(a, b)`, `max(a, b)` if
    `c <= min(a, b)`, else `a + b - c`
  - kind 2, plane: `a + b - c`

The encoder writes both and keeps the shorter, because the median predictor is off by one step
on every post of a uniform slope, where the plane predictor is exact.

The residual `x - prediction` is computed in wrapping 16-bit arithmetic and zigzag-coded
(`(r << 1) ^ (r >> 15)`), so any input round-trips, voids (-32768) and extremes included.

Residuals are coded in groups of 16 posts (the last group may be shorter):

1. **Widths:** one 4-bit code per group, two per byte, low nibble first: `ceil(groups / 2)`
   bytes. Codes 0 to 14 are bit widths; 15 means 16 bits.
2. **Bits:** each group's residuals at its width, packed least-significant bit first into a
   little-endian bit stream, with no padding between groups. The stream ends on a byte boundary.

A width of 0 means all 16 residuals are zero (a run that matches the prediction exactly).

A full group takes exactly `2 * width` bytes, so every group starts on a byte boundary. The decoder
relies on this to unpack each group with one vector shuffle instead of a serial bit reader, and
the sampler relies on it to find any group's first byte from the widths alone (below); a format
change that breaks it needs a new decoder.

## Reading

`Pack.open` maps the file, checks the magic, version, offsets and directory hash, and checks
that every slot, entry and block reference stays inside the file, so the sampling path never
bounds-checks again. A sample finds its tile through the slot table, its block through the
tile's entry, and reads posts from a per-thread two-way cache of 256 blocks (2 MiB of posts per
thread). Interpolation is `hgt.interpolateWith`, the same code as the tile reader.

A cached block is decoded lazily, because a trail reads only a few of a block's posts and a post
depends only on the posts above and to the left of it. The first sample checks that the payload
holds every bit its widths call for (exactly the condition under which a whole-block decode
succeeds; a block that fails reads as all no data, as before). Posts are then rebuilt as far
down and across as samples have reached: row 0, then strips of eight rows, and in a 64-wide block
16 columns at a time before the rest of the strip. On the US+DACH /height corpus that decodes
about half of each block's posts.

## Measurements

Test region: the two oracle tiles, N47E009 (Alps, Liechtenstein) and N52E005 (Utrecht).
Apple M3 Pro, ReleaseFast.

| | Raw `.hgt` | `.hgt.gz` | `.zdem` |
|---|---|---|---|
| N47E009 | 25.9 MB | 11.4 MB (44%) | 5.9 MB (22.7%, 3.63 bits a post) |
| N52E005 | 25.9 MB | 2.8 MB (10.9%) | 3.3 MB (12.6%, 2.02 bits a post) |
| Both | 51.9 MB | 14.3 MB (27.5%) | 8.9 MB (17.1%, 2.74 bits a post) |

- Pack time: 0.3 s for both tiles on two threads.
- `zr dem verify`: all 25,934,402 posts identical, 10^6 random samples bit-identical.
- `zr diff` of `/height` through tiles and through the pack: 100% on both height corpora.
- Cold first `/height` request: 122 ms with the gzipped tiles (one 25 MB inflate), 0.4 ms with
  the pack.
- Warm throughput: within 5 to 8% of tiles already inflated in memory, either way, which is
  run-to-run noise.

On flat ground gzip is slightly smaller, because there the fixed cost of the width nibbles and
directory (about 0.3 bits a post) outweighs gzip's long matches. Mountains are where the bytes
are, and there the pack is half the size of gzip.
