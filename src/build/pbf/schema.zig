//! OSM PBF file and primitive fields from OSM-binary at 9f01ad3.

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

pub const StringTable = protobuf.Message(&.{
    .{ .name = "s", .number = 1, .kind = .bytes, .presence = .repeated },
});
pub const Info = protobuf.Message(&.{
    .{ .name = "version", .number = 1, .kind = .int32, .presence = .optional },
    .{ .name = "changeset", .number = 3, .kind = .int64, .presence = .optional },
});
const entity_fields = [_]protobuf.Field{
    .{ .name = "keys", .number = 2, .kind = .uint32, .presence = .repeated, .packed_encoding = true },
    .{ .name = "vals", .number = 3, .kind = .uint32, .presence = .repeated, .packed_encoding = true },
    .{ .name = "info", .number = 4, .kind = .message, .presence = .optional, .message = Info },
};
pub const Node = protobuf.Message(&([_]protobuf.Field{
    .{ .name = "id", .number = 1, .kind = .sint64, .presence = .required },
} ++ entity_fields ++ [_]protobuf.Field{
    .{ .name = "lat", .number = 8, .kind = .sint64, .presence = .required },
    .{ .name = "lon", .number = 9, .kind = .sint64, .presence = .required },
}));
pub const Way = protobuf.Message(&([_]protobuf.Field{
    .{ .name = "id", .number = 1, .kind = .int64, .presence = .required },
} ++ entity_fields ++ [_]protobuf.Field{
    .{ .name = "refs", .number = 8, .kind = .sint64, .presence = .repeated, .packed_encoding = true },
}));
pub const Relation = protobuf.Message(&([_]protobuf.Field{
    .{ .name = "id", .number = 1, .kind = .int64, .presence = .required },
} ++ entity_fields ++ [_]protobuf.Field{
    .{ .name = "roles_sid", .number = 8, .kind = .int32, .presence = .repeated, .packed_encoding = true },
    .{ .name = "memids", .number = 9, .kind = .sint64, .presence = .repeated, .packed_encoding = true },
    .{ .name = "types", .number = 10, .kind = .enumeration, .presence = .repeated, .packed_encoding = true },
}));
pub const DenseNodes = protobuf.Message(&.{
    .{ .name = "id", .number = 1, .kind = .sint64, .presence = .repeated, .packed_encoding = true },
    .{ .name = "lat", .number = 8, .kind = .sint64, .presence = .repeated, .packed_encoding = true },
    .{ .name = "lon", .number = 9, .kind = .sint64, .presence = .repeated, .packed_encoding = true },
    .{ .name = "keys_vals", .number = 10, .kind = .int32, .presence = .repeated, .packed_encoding = true },
});
pub const PrimitiveGroup = protobuf.Message(&.{
    .{ .name = "nodes", .number = 1, .kind = .message, .presence = .repeated, .message = Node },
    .{ .name = "dense", .number = 2, .kind = .message, .presence = .optional, .message = DenseNodes },
    .{ .name = "ways", .number = 3, .kind = .message, .presence = .repeated, .message = Way },
    .{ .name = "relations", .number = 4, .kind = .message, .presence = .repeated, .message = Relation },
});
pub const PrimitiveBlock = protobuf.Message(&.{
    .{ .name = "stringtable", .number = 1, .kind = .message, .presence = .required, .message = StringTable },
    .{ .name = "primitivegroup", .number = 2, .kind = .message, .presence = .repeated, .message = PrimitiveGroup },
    .{ .name = "granularity", .number = 17, .kind = .int32, .presence = .optional, .default_value = .{ .integer = 100 } },
    .{ .name = "date_granularity", .number = 18, .kind = .int32, .presence = .optional, .default_value = .{ .integer = 1000 } },
    .{ .name = "lat_offset", .number = 19, .kind = .int64, .presence = .optional },
    .{ .name = "lon_offset", .number = 20, .kind = .int64, .presence = .optional },
});
