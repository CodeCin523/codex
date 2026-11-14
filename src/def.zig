//! The Def-generator: `codex.Def(Raw)` computes a kind's resolved type from its `Raw`, recursively.
//!
//!   - a `codex.field` type (`is_codex_field`)  -> its `Resolved`
//!   - a slice `[]const E`                       -> `[]const` Def-of-E  (`[]const u8` is an error)
//!   - an array `[N]E`                           -> `[N]` Def-of-E
//!   - an optional `?E`                          -> `?` Def-of-E
//!   - a plain struct (a composite)              -> a struct of the same fields, each resolved
//!   - a number / bool / enum                    -> unchanged
//!
//! `codex.Def` is a pure function of its input type, so `codex.Def(RawResistance)` is the exact type
//! used as the element of a parent's `resistances: []const RawResistance` field — name it and write
//! free functions over it. Generated structs hold data only (Zig cannot attach methods), so domain
//! lookups are free functions, not methods.

const std = @import("std");

/// The resolved type for a kind written as `Raw`. The `field.Name` key (kept in the registry's name
/// map, qualified, not in the `Def`) is omitted; every kind must have exactly one. Used by `Registry`.
pub fn KindDef(comptime Raw: type) type {
    _ = nameFieldOf(Raw); // every kind must declare exactly one field.Name key
    return structDef(Raw, true);
}

/// Whether `T` is the `field.Name` key type (a container declaring `is_name`).
pub fn isNameField(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "is_name"),
        else => false,
    };
}

/// The name of the one `field.Name` field in `Raw`. A compile error if there is not exactly one —
/// codex keys every entry by a `field.Name` (see `field.Name`).
pub fn nameFieldOf(comptime Raw: type) [:0]const u8 {
    const info = @typeInfo(Raw).@"struct";
    var found: ?[:0]const u8 = null;
    for (info.field_names, info.field_types) |fname, ftype| {
        if (!isNameField(ftype)) continue;
        if (found != null) @compileError("codex: " ++ @typeName(Raw) ++ " has more than one codex.field.Name field");
        found = fname;
    }
    return found orelse @compileError("codex: " ++ @typeName(Raw) ++ " has no codex.field.Name field (every kind needs one `name: codex.field.Name` key)");
}

/// The resolved type for any `Raw`-shaped type, including nested composites (nothing omitted).
pub fn Def(comptime Raw: type) type {
    return Resolved(Raw);
}

fn Resolved(comptime T: type) type {
    if (isField(T)) return T.Resolved;
    return switch (@typeInfo(T)) {
        .pointer => |p| blk: {
            if (p.size != .slice) @compileError("codex: unsupported pointer field: " ++ @typeName(T));
            if (p.child == u8) @compileError("codex: `[]const u8` is ambiguous — use " ++
                "`codex.field.String` for text or `codex.field.Bytes` for raw bytes");
            break :blk []const Resolved(p.child);
        },
        .array => |arr| [arr.len]Resolved(arr.child),
        .optional => |o| ?Resolved(o.child),
        .@"struct" => structDef(T, false),
        .int, .float, .bool, .@"enum" => T,
        else => @compileError("codex: unsupported field type: " ++ @typeName(T)),
    };
}

/// Whether `T` is a `codex.field` type (a container declaring `is_codex_field`).
fn isField(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "is_codex_field"),
        else => false,
    };
}

fn structDef(comptime T: type, comptime skip_name: bool) type {
    const info = @typeInfo(T).@"struct";
    comptime {
        var names: [info.field_names.len][:0]const u8 = undefined;
        var types: [info.field_names.len]type = undefined;
        var attrs: [info.field_names.len]std.lang.Type.Struct.FieldAttributes = @splat(.{});
        var n: usize = 0;
        for (info.field_names, info.field_types) |fname, ftype| {
            if (skip_name and isNameField(ftype)) continue;
            names[n] = fname;
            types[n] = Resolved(ftype);
            n += 1;
        }
        return @Struct(.auto, null, names[0..n], types[0..n], attrs[0..n]);
    }
}


/// Fills a `KindDef(Raw)` from a parsed kind `Raw`, skipping the `field.Name` key. See `build`.
pub fn buildKind(comptime Raw: type, raw: Raw, r: anytype) !KindDef(Raw) {
    return buildStruct(Raw, raw, r, true);
}

/// Fills a `Def(Raw)` from a parsed `Raw`, auto-mapping field by field: plain values copied,
/// composites/slices/optionals recursed, `codex.field` types resolved through `r` (which validates
/// scalars, resolves `Ref`/`Tags` names to IDs, and dupes strings into catalog memory). `r` is the
/// builder's resolver. The kind's optional relational `resolve(r, *Def)` runs separately, after.
pub fn build(comptime Raw: type, raw: Raw, r: anytype) !Def(Raw) {
    return resolveField(Raw, raw, r);
}

fn resolveField(comptime T: type, value: T, r: anytype) !Resolved(T) {
    if (comptime isField(T)) return value.resolve(r);
    return switch (@typeInfo(T)) {
        .pointer => |p| blk: {
            const out = try r.allocator.alloc(Resolved(p.child), value.len);
            for (value, out) |in, *o| o.* = try resolveField(p.child, in, r);
            break :blk out;
        },
        .array => |arr| blk: {
            var out: [arr.len]Resolved(arr.child) = undefined;
            for (value, &out) |in, *o| o.* = try resolveField(arr.child, in, r);
            break :blk out;
        },
        .optional => |o| if (value) |v| try resolveField(o.child, v, r) else null,
        .@"struct" => try buildStruct(T, value, r, false),
        .int, .float, .bool, .@"enum" => value,
        else => unreachable,
    };
}

fn buildStruct(comptime T: type, value: T, r: anytype, comptime skip_name: bool) !structDef(T, skip_name) {
    var out: structDef(T, skip_name) = undefined;
    inline for (@typeInfo(T).@"struct".field_names) |fname| {
        if (skip_name and comptime isNameField(@FieldType(T, fname))) continue;
        r.field = fname;
        @field(out, fname) = try resolveField(@FieldType(T, fname), @field(value, fname), r);
    }
    return out;
}


// ================================================================================ //
// = TESTS                                                                        = //
// ================================================================================ //

const field = @import("field.zig");
const Problems = @import("Problems.zig");
const tags = @import("tags.zig");
const testing = std.testing;

test "Def mirrors a flat Raw" {
    const f = field;
    const Raw = struct {
        density: f.Positive(f32),
        flow: f.Range(f32, 0, 1),
        hardness: u8,
        label: f.String,
    };
    const D = Def(Raw);
    try testing.expectEqual(f32, @FieldType(D, "density"));
    try testing.expectEqual(f32, @FieldType(D, "flow"));
    try testing.expectEqual(u8, @FieldType(D, "hardness"));
    try testing.expectEqual([]const u8, @FieldType(D, "label"));
}

test "Def recurses into composites and slices; element types line up" {
    const f = field;
    const Trauma = struct {
        pub const ID = enum(u16) { _ };
    };
    const RawResistance = struct {
        trauma: f.Ref(Trauma),
        factor: f.NonNegative(f32),
    };
    const Raw = struct {
        resistances: []const RawResistance,
        tags: f.Tags,
    };
    const D = Def(Raw);

    // The element type is exactly codex.Def(RawResistance) — same comptime call, same type.
    const Resistance = Def(RawResistance);
    try testing.expectEqual([]const Resistance, @FieldType(D, "resistances"));
    try testing.expectEqual(Trauma.ID, @FieldType(Resistance, "trauma"));
    try testing.expectEqual(f32, @FieldType(Resistance, "factor"));
    try testing.expectEqual([]const tags.Id, @FieldType(D, "tags"));
}

/// A stand-in for the real builder resolver, enough to exercise `build`.
const TestResolver = struct {
    allocator: std.mem.Allocator,
    problems: *Problems,
    ids: *const std.StringHashMapUnmanaged(u16),
    subject: []const u8 = "",
    field: []const u8 = "",

    pub fn string(self: *TestResolver, s: []const u8) ![]const u8 {
        return self.allocator.dupe(u8, s);
    }
    pub fn fail(self: *TestResolver, comptime fmt: []const u8, args: anytype) !void {
        const detail = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.problems.add("", self.subject, "{s}: {s}", .{ self.field, detail });
    }
    pub fn ref(self: *TestResolver, comptime Kind: type, nm: []const u8) !Kind.ID {
        if (self.ids.get(nm)) |i| return @enumFromInt(i);
        try self.fail("unknown ref '{s}'", .{nm});
        return @enumFromInt(std.math.maxInt(u16));
    }
};

test "value build: auto-map, validate, resolve refs" {
    const f = field;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var problems: Problems = .init(testing.allocator);
    defer problems.deinit();

    var ids: std.StringHashMapUnmanaged(u16) = .{};
    try ids.put(a, "fire", 7);

    const Trauma = struct {
        pub const ID = enum(u16) { _ };
    };
    const RawResistance = struct {
        trauma: f.Ref(Trauma),
        factor: f.NonNegative(f32),
    };
    const Raw = struct {
        density: f.Positive(f32),
        label: f.String,
        resistances: []const RawResistance,
    };

    var r = TestResolver{ .allocator = a, .problems = &problems, .ids = &ids, .subject = "core:stone" };

    const good = try std.json.parseFromSliceLeaky(Raw, a,
        \\{ "density": 2.0, "label": "stone", "resistances": [ { "trauma": "fire", "factor": 0.5 } ] }
    , .{});
    const d = try build(Raw, good, &r);
    try testing.expectEqual(@as(f32, 2.0), d.density);
    try testing.expectEqualStrings("stone", d.label);
    try testing.expectEqual(@as(usize, 1), d.resistances.len);
    try testing.expectEqual(@as(u16, 7), @intFromEnum(d.resistances[0].trauma));
    try testing.expectEqual(@as(f32, 0.5), d.resistances[0].factor);
    try testing.expectEqual(@as(usize, 0), problems.count());

    // negative density, negative factor, and an unknown trauma ref -> three problems.
    const bad = try std.json.parseFromSliceLeaky(Raw, a,
        \\{ "density": -1.0, "label": "x", "resistances": [ { "trauma": "ghost", "factor": -0.2 } ] }
    , .{});
    _ = try build(Raw, bad, &r);
    try testing.expectEqual(@as(usize, 3), problems.count());
}

test "fixed-size arrays are positional and length-checked" {
    const f = field;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problems: Problems = .init(testing.allocator);
    defer problems.deinit();
    var ids: std.StringHashMapUnmanaged(u16) = .{};
    var r = TestResolver{ .allocator = a, .problems = &problems, .ids = &ids };

    const Raw = struct {
        span: [2]f.Positive(f32), // JSON [a, b]
        color: [3]u8, // JSON [r, g, b]
    };

    // The Def mirrors the fixed sizes.
    try testing.expectEqual([2]f32, @FieldType(Def(Raw), "span"));
    try testing.expectEqual([3]u8, @FieldType(Def(Raw), "color"));

    const raw = try std.json.parseFromSliceLeaky(Raw, a,
        \\{ "span": [1.0, 2.0], "color": [255, 128, 0] }
    , .{});
    const d = try build(Raw, raw, &r);
    try testing.expectEqual(@as(f32, 1.0), d.span[0]);
    try testing.expectEqual(@as(f32, 2.0), d.span[1]);
    try testing.expectEqual(@as(u8, 128), d.color[1]);
    try testing.expectEqual(@as(usize, 0), problems.count());
}
