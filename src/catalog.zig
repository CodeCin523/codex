//! `Catalog(section, .{ .plural = Kind, ... })`: generates the catalog type for one `pack.json`
//! section. The field names of the registration are the content keys (plural) and the on-disk
//! section; the values are the kinds. codex has no built-in "data"/"resources" — the app names its
//! catalogs.
//!
//! The generated type stores one `Registry(Kind)` per kind (in `regs`) plus the owning `arena` and
//! the `packages` it was loaded from. It carries decls the loader needs (`section`, the kind list)
//! and a `registry(K)` accessor. Loading lives in `builder.zig`.

const std = @import("std");
const registry = @import("registry.zig");
const Registry = registry.Registry;
const tags = @import("tags.zig");

pub fn Catalog(comptime section_name: []const u8, comptime reg: anytype) type {
    const info = @typeInfo(@TypeOf(reg)).@"struct";

    // One `Registry(Kind)` field per plural key, each defaulting to empty.
    const Registries = blk: {
        var names: [info.field_names.len][:0]const u8 = undefined;
        var types: [info.field_names.len]type = undefined;
        var attrs: [info.field_names.len]std.lang.Type.Struct.FieldAttributes = undefined;
        for (info.field_names, &names, &types, &attrs) |fname, *n, *ty, *at| {
            const Kind = @field(reg, fname);
            n.* = fname;
            ty.* = Registry(Kind);
            const empty: Registry(Kind) = .{};
            at.* = .{ .default_value_ptr = @ptrCast(&empty) };
        }
        break :blk @Struct(.auto, null, &names, &types, &attrs);
    };

    return struct {
        const Self = @This();

        /// The `pack.json` section this catalog is loaded from.
        pub const section = section_name;
        /// The content keys (plural), in declaration order.
        pub const plurals = info.field_names;

        regs: Registries = .{},
        packages: []const []const u8 = &.{},
        /// All distinct tag strings used across this catalog's entries; a tag's id is its index.
        tags: tags.Table = .empty,
        arena: std.heap.ArenaAllocator,

        /// The kind registered under `plural`.
        pub fn KindOf(comptime plural: [:0]const u8) type {
            return @field(reg, plural);
        }

        /// The plural key that kind `K` is registered under.
        pub fn pluralOf(comptime K: type) [:0]const u8 {
            inline for (info.field_names) |fname| {
                if (@field(reg, fname) == K) return fname;
            }
            @compileError("catalog has no kind " ++ @typeName(K));
        }

        /// The registry of kind `K` (`data.registry(Material)`).
        pub fn registry(self: *const Self, comptime K: type) *const Registry(K) {
            return &@field(self.regs, pluralOf(K));
        }

        /// The id of tag `name`, or null if no entry in this catalog uses it.
        pub fn tag(self: *const Self, name: []const u8) ?tags.Id {
            const i = self.tags.getIndex(name) orelse return null;
            return @enumFromInt(@as(u16, @intCast(i)));
        }

        pub fn tagName(self: *const Self, id: tags.Id) []const u8 {
            return self.tags.keys()[@intFromEnum(id)];
        }

        pub fn tagCount(self: *const Self) usize {
            return self.tags.count();
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}


// ================================================================================ //
// = TESTS                                                                        = //
// ================================================================================ //

const field = @import("field.zig");
const testing = std.testing;

test "Catalog generates registries, exposes section, and the Def is generated" {
    const Trauma = struct {
        pub const ID = enum(u16) { _ };
        pub const Raw = struct { desc: field.String };
    };
    const Material = struct {
        pub const ID = enum(u16) { _ };
        pub const Raw = struct {
            density: field.Positive(f32),
            trauma: field.Ref(Trauma),
        };
    };
    const Data = Catalog("content", .{ .traumas = Trauma, .materials = Material });

    try testing.expectEqualStrings("content", Data.section);
    try testing.expectEqual(@as(usize, 2), Data.plurals.len);

    var d: Data = .{ .arena = .init(testing.allocator) };
    defer d.deinit();
    try testing.expectEqual(@as(usize, 0), d.registry(Material).count());
    try testing.expectEqual(@as(usize, 0), d.registry(Trauma).count());

    // The registry's Def is generated from Raw.
    const Def = Registry(Material).Def;
    try testing.expectEqual(f32, @FieldType(Def, "density"));
    try testing.expectEqual(Trauma.ID, @FieldType(Def, "trauma"));
}
