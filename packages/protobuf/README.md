# Protobuf wire codec

Import the `protobuf` Zig module to describe messages as comptime field tables.

```zig
const proto = @import("protobuf");

const Example = proto.Message(&.{
    .{ .number = 1, .name = "id", .kind = .uint32 },
    .{ .number = 2, .name = "note", .kind = .string, .presence = .optional },
    .{ .number = 3, .name = "deltas", .kind = .sint32, .presence = .repeated, .packed_encoding = true },
});

var buffer: [64]u8 = undefined;
const bytes = try Example.encode(&buffer, .{ .id = 3, .deltas = &.{ -5, 7 } }, proto.no_deadline);
const view = try Example.decode(bytes, proto.no_deadline);
const note = try view.get("note", proto.no_deadline);
var deltas = try view.get("deltas", proto.no_deadline);
while (try deltas.next(proto.no_deadline)) |delta| {
    _ = delta;
}
_ = note;
```

`encode` writes into a caller-provided buffer. `encodedSize` reports the required capacity.
`write` streams to any sink implementing `writeAll`. Decode validates the wire records.
The returned view borrows the input bytes. Repeated fields, including packed values, are
read as iterators. Keep the input alive and immutable for the lifetime of the view.

Use an optional field for explicit presence. `get` returns `null` when it is absent.
`getOrDefault` supplies an optional scalar's schema default. A required field must be
present. An implicit scalar defaults to zero, false, or an empty slice. Enum numbers use
`i32`. Unknown fields are skipped, including legacy groups.

You can pass a deadline with an `expired() bool` method in place of `proto.no_deadline`.

The reference fixture uses Protobuf's `protoc` 29.6 encoder. Regenerate it from the
checked-in schema and text input:

```bash
cd packages/protobuf/fixtures
protoc -I . --encode=routing_fixture.Scalars scalars.proto < scalars.textproto > scalars.bin
```
