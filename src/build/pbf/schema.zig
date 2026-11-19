//! OSM PBF framing and header fields from OSM-binary at 9f01ad3.

const protobuf = @import("protobuf");

pub const BlobHeader = protobuf.Message(&.{
    .{ .name = "type", .number = 1, .kind = .string, .presence = .required },
    .{ .name = "datasize", .number = 3, .kind = .int32, .presence = .required },
});

pub const Blob = protobuf.Message(&.{
    .{ .name = "raw", .number = 1, .kind = .bytes, .presence = .optional },
    .{ .name = "raw_size", .number = 2, .kind = .int32, .presence = .optional },
    .{ .name = "zlib_data", .number = 3, .kind = .bytes, .presence = .optional },
    .{ .name = "lzma_data", .number = 4, .kind = .bytes, .presence = .optional },
    .{ .name = "bzip2_data", .number = 5, .kind = .bytes, .presence = .optional },
    .{ .name = "lz4_data", .number = 6, .kind = .bytes, .presence = .optional },
    .{ .name = "zstd_data", .number = 7, .kind = .bytes, .presence = .optional },
});

pub const HeaderBBox = protobuf.Message(&.{
    .{ .name = "left", .number = 1, .kind = .sint64, .presence = .required },
    .{ .name = "right", .number = 2, .kind = .sint64, .presence = .required },
    .{ .name = "top", .number = 3, .kind = .sint64, .presence = .required },
    .{ .name = "bottom", .number = 4, .kind = .sint64, .presence = .required },
});

pub const HeaderBlock = protobuf.Message(&.{
    .{ .name = "bbox", .number = 1, .kind = .message, .presence = .optional, .message = HeaderBBox },
    .{ .name = "required_features", .number = 4, .kind = .string, .presence = .repeated },
    .{ .name = "optional_features", .number = 5, .kind = .string, .presence = .repeated },
    .{ .name = "writingprogram", .number = 16, .kind = .string, .presence = .optional },
    .{ .name = "osmosis_replication_timestamp", .number = 32, .kind = .int64, .presence = .optional },
});
