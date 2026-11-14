//! Reserved ids: the game-owned id values a kind claims as named members of its `ID` enum.
//!
//!     pub const ID = enum(u16) { none = 0, air = 1, _ };
//!
//! codex skips those integer slots when assigning pack entries, so the value is stable, named, and
//! pack-independent. `Registry.get(reserved)` returns a placeholder `Def` (reads stay total in hot
//! loops like `materials.get(voxel.material)`); `find` never returns a reserved id; `count` and
//! iteration skip them.
//!
//! Placeholder values come from a kind's optional `reserved` declaration — a **plain comptime struct**
//! (no generated type to annotate): one field per reserved member, each a bare struct of only the
//! fields that differ. codex reads it at comptime; a `field.*` wrapper takes its plain underlying
//! value and codex wraps it:
//!
//!     pub const reserved = .{
//!         .none = .{},                   // a pure sentinel — every field takes its default
//!         .air  = .{ .density = 0.001 }, // only the differing field; the rest default
//!     };
//!
//! Omitted fields fall back to the `Raw` field's own default, else a zero/empty stand-in; the `Name`
//! key is set to the member name automatically. A typo (an unknown member, or a field the `Raw` does
//! not have) is a compile error. See DESIGN.md "Reserved ids".

const std = @import("std");

const def = @import("def.zig");

/// How many ids a kind's `ID` enum reserves — its named members (`_` is not one, so a plain
/// `enum(u16) { _ }` reserves nothing and everything below is a no-op).
pub fn count(comptime ID: type) usize {
    return @typeInfo(ID).@"enum".field_names.len;
}

/// The reserved member names of `ID`, indexed by id value (`names[0]` is the member valued `0`). A
/// compile error unless the reserved values are exactly `0..count-1` — the lowest ids, contiguous
/// from 0 — so the registry's arrays stay dense; and, when anything is reserved, the enum must be
/// non-exhaustive (`_`) so pack entries have ids past the reserved slots.
pub fn names(comptime ID: type) [count(ID)][:0]const u8 {
    const info = @typeInfo(ID).@"enum";
    const n = info.field_names.len;
    // A comptime block so the plain `for` (which must touch the comptime_int `field_values`) runs at
    // comptime and its `var` writes persist — the pattern `def.structDef` uses. (`enum` tag values
    // are unique by construction, so a true duplicate id is already a Zig error; we only need to
    // reject gaps / values past the top slot.)
    return comptime blk: {
        var out: [n][:0]const u8 = undefined;
        if (n == 0) break :blk out;
        if (info.mode != .nonexhaustive) @compileError("codex: " ++ @typeName(ID) ++
            " reserves ids but is exhaustive — add `_` so pack entries get ids past the reserved ones");
        var filled: [n]bool = @splat(false);
        for (info.field_names, info.field_values) |mname, v| {
            if (v < 0 or v >= n) @compileError("codex: " ++ @typeName(ID) ++ " reserved id '" ++ mname ++
                "' = " ++ std.fmt.comptimePrint("{d}", .{v}) ++ ", but reserved ids must be the lowest ids, " ++
                "contiguous from 0 (here: 0.." ++ std.fmt.comptimePrint("{d}", .{n - 1}) ++ ")");
            out[@intCast(v)] = mname;
            filled[@intCast(v)] = true;
        }
        for (filled) |f| if (!f) @compileError("codex: " ++ @typeName(ID) ++
            " reserved ids must be the lowest ids, contiguous from 0 with no gaps");
        break :blk out;
    };
}

/// Builds a `K.Raw` for one reserved slot from `vals` — the reserved member literal (a bare comptime
/// struct of the fields that differ), or an empty `.{}` for all-defaults. Each field is taken from
/// `vals` if present (a `field.*` wrapper's plain underlying value is wrapped via its `.of`; a value
/// already of the field type is used as-is), else from the `Raw` field's own default, else a
/// zero/empty stand-in. The `Name` key is set to the member name. Any field in `vals` that is not a
/// (non-Name) `Raw` field is a compile error, to catch typos.
pub fn buildRaw(comptime K: type, comptime member: [:0]const u8, vals: anytype) K.Raw {
    const Raw = K.Raw;
    const Vals = @TypeOf(vals);
    comptime {
        // A comptime block (not `inline for`) so a dead `@compileError` branch folds away correctly.
        for (@typeInfo(Vals).@"struct".field_names) |vn| {
            if (!@hasField(Raw, vn)) @compileError("codex: reserved." ++ member ++ " sets '" ++ vn ++
                "', which is not a field of " ++ @typeName(Raw));
            if (def.isNameField(@FieldType(Raw, vn))) @compileError("codex: reserved." ++ member ++
                " must not set the name key '" ++ vn ++ "' — the slot is named by its ID member");
        }
    }
    var raw: Raw = undefined;
    inline for (@typeInfo(Raw).@"struct".field_names, @typeInfo(Raw).@"struct".field_types, @typeInfo(Raw).@"struct".field_attrs) |fname, ftype, attr| {
        if (comptime def.isNameField(ftype)) {
            @field(raw, fname) = ftype.of(member);
        } else if (@hasField(Vals, fname)) {
            @field(raw, fname) = coerce(ftype, @field(vals, fname));
        } else if (comptime attr.defaultValue(ftype)) |dv| {
            @field(raw, fname) = dv;
        } else {
            @field(raw, fname) = zeroOf(ftype);
        }
    }
    return raw;
}

/// Turns a reserved member's provided value into the `Raw` field type: a value already of that type
/// is used as-is; a `field.*` wrapper takes its plain underlying value through `.of`; a plain
/// (non-`field`) field lets the assignment coerce it. (Wrapped fields nested inside a composite or
/// array must be written with explicit constructors — `f.Positive(f32).of(x)` — since there is no
/// typed target to resolve a bare `.of` against there.)
fn coerce(comptime FieldT: type, provided: anytype) FieldT {
    if (@TypeOf(provided) == FieldT) return provided;
    if (comptime isField(FieldT)) return FieldT.of(provided);
    return provided;
}

fn isField(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "is_codex_field"),
        else => false,
    };
}

/// A zero/empty value of `T`: 0 for numbers, false for bools, the first member of an enum, null for
/// optionals, an empty slice, element-wise for arrays, and field-wise for structs (including the
/// `codex.field` wrappers, whose single storage field is zeroed the same way). Used only as a
/// placeholder default for a reserved field the `Raw` leaves required.
pub fn zeroOf(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) &.{} else @compileError("codex: cannot default pointer field " ++ @typeName(T)),
        .optional => null,
        .array => |arr| @splat(zeroOf(arr.child)),
        .@"struct" => structZero(T),
        .int, .comptime_int, .float, .comptime_float => 0,
        .bool => false,
        .@"enum" => blk: {
            const ei = @typeInfo(T).@"enum";
            break :blk if (ei.field_names.len > 0) @field(T, ei.field_names[0]) else @enumFromInt(0);
        },
        else => @compileError("codex: cannot default field of type " ++ @typeName(T)),
    };
}

fn structZero(comptime T: type) T {
    const info = @typeInfo(T).@"struct";
    var out: T = undefined;
    inline for (info.field_names, info.field_types) |fname, ftype| {
        @field(out, fname) = zeroOf(ftype);
    }
    return out;
}


// ================================================================================ //
// = TESTS                                                                        = //
// ================================================================================ //

const field = @import("field.zig");
const testing = std.testing;

test "count and names: reflect an ID enum's reserved members in value order" {
    const A = enum(u16) { _ };
    const B = enum(u16) { none = 0, air = 1, _ };
    // Declaration order differs from value order; names() sorts by value.
    const C = enum(u16) { air = 1, none = 0, _ };

    try testing.expectEqual(@as(usize, 0), count(A));
    try testing.expectEqual(@as(usize, 2), count(B));

    const nb = names(B);
    try testing.expectEqualStrings("none", nb[0]);
    try testing.expectEqualStrings("air", nb[1]);

    const nc = names(C);
    try testing.expectEqualStrings("none", nc[0]);
    try testing.expectEqualStrings("air", nc[1]);
}

test "buildRaw: member literal over Raw defaults over zeros; plain values are wrapped" {
    const f = field;
    const Material = struct {
        pub const ID = enum(u16) { none = 0, air = 1, _ };
        pub const Raw = struct {
            name: f.Name,
            density: f.Positive(f32) = .of(1.0), // has a Raw default
            label: f.String, // required in Raw -> zeroed when unset
            hp: u16 = 7,
        };
    };

    // Nothing set: Name becomes the member; density takes the Raw default; label zeros; hp default.
    const none = buildRaw(Material, "none", .{});
    try testing.expectEqualStrings("none", none.name.get());
    try testing.expectEqual(@as(f32, 1.0), none.density.get());
    try testing.expectEqualStrings("", none.label.get());
    try testing.expectEqual(@as(u16, 7), none.hp);

    // Only the differing fields, written as plain values; codex wraps them.
    const air = buildRaw(Material, "air", .{ .density = 0.001, .label = "air", .hp = 1 });
    try testing.expectEqualStrings("air", air.name.get());
    try testing.expectEqual(@as(f32, 0.001), air.density.get());
    try testing.expectEqualStrings("air", air.label.get());
    try testing.expectEqual(@as(u16, 1), air.hp);
}
