# Valhalla Protobuf schemas

The schema tables mirror the 14 descriptors in Valhalla 3.9.3 at
`5c7f918e61306521d79cc4496d40c19c5305fa4b`. Nested Zig declarations use an underscore between
each level of the Protobuf name. Each of the release's one-field `oneof` declarations uses
explicit optional presence. The two map fields expose their wire entries in encoded order.

Use the pinned Zig toolchain and a checkout at that Valhalla commit to verify the tables:

```bash
bun tools/proto/valhalla.ts --check "$VALHALLA_CHECKOUT"
```

Use `--write` to regenerate the tables from the same checkout. CI checks field numbers, field
types, enum members, labels and packing against the upstream sources.

The byte-exact test uses a `/route` response captured from the Utrecht development oracle.
Its public road locations are in the request below. Statistic timings in the capture reflect
that individual run.

```bash
oracle/up.sh utrecht
curl -fsS -H 'Content-Type: application/json' \
  --data '{"locations":[{"lat":52.0911,"lon":5.1165},{"lat":52.0879,"lon":5.125}],"costing":"auto","directions_type":"maneuvers","format":"pbf"}' \
  http://127.0.0.1:8102/route -o utrecht-route.pbf
```
