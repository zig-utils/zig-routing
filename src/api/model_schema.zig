//! Comptime checks for native route data against the pinned protocol schemas.
const std = @import("std");
const protobuf = @import("protobuf");

pub fn check(comptime Model: type, comptime numbers: []const u29) void {
    @setEvalBranchQuota(100_000);
    const schema = Model.Schema;
    const names = std.meta.fieldNames(Model);
    const types = std.meta.fieldTypes(Model);
    if (schema.schema.len != names.len or numbers.len != names.len)
        @compileError(@typeName(Model) ++ " has the wrong number of fields");
    for (schema.schema, numbers, names, types) |field, number, name, FieldType| {
        if (field.number != number or !std.mem.eql(u8, field.name, name))
            @compileError(@typeName(Model) ++ "." ++ name ++ " does not match the wire field name and number");
        const matches = if (field.kind == .message)
            messageMatches(FieldType, field)
        else
            FieldType == @FieldType(schema.Values, field.name);
        if (!matches) @compileError(@typeName(Model) ++ "." ++ name ++ " does not match the wire field type and presence");
    }
}

fn messageMatches(comptime FieldType: type, comptime field: protobuf.Field) bool {
    const info = @typeInfo(FieldType);
    const child = switch (field.presence) {
        .required => FieldType,
        .optional => if (info == .optional) info.optional.child else return false,
        .repeated => if (info == .pointer and FieldType == []const info.pointer.child)
            info.pointer.child
        else
            return false,
        .implicit => return false,
    };
    return @typeInfo(child) == .@"struct" and @hasDecl(child, "Schema") and child.Schema == field.message;
}

/// Check every schema message and enum, including ones outside a leg's fields.
/// Enum aliases share the generated enum type and all its numeric tags.
pub fn checkCoverage(comptime Model: type, comptime Schema: type) void {
    @setEvalBranchQuota(100_000);
    for (std.meta.declarations(Schema)) |name| {
        const wire = @field(Schema, name);
        for (std.meta.declarations(Model)) |decl| {
            const native = @field(Model, decl);
            if (@TypeOf(native) != type) continue;
            if (@typeInfo(wire) == .@"enum" and native == wire) break;
            if (@typeInfo(native) == .@"struct" and @hasDecl(native, "Schema") and native.Schema == wire) break;
        } else @compileError("missing native model for " ++ name);
    }
}
