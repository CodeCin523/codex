//! `Registry(Kind)`: every entry of one kind in a frozen catalog, with its lookups.
//!
//! Entries live in dense arrays indexed by their ID, so `get` is one array access. Everything is
//! read-only once frozen. The `Def` type is generated from the kind's `Raw` (`codex.Def`). If the
//! kind has a `field.Tags` field, the registry also carries a tag search index.

const std = @import("std");
const def = @import("def.zig");
const tags = @import("tags.zig");

pub fn Registry(comptime K: type) type {
    return struct {
        const Self = @This();

        pub const Kind = K;
        pub const ID = K.ID;
        /// The resolved entry, generated from the kind's `Raw` (the `name` key is not stored here).
        pub const Def = def.KindDef(K.Raw);

        /// The name of this kind's `field.Tags` field, if it has one.
        pub const tag_field = tagFieldOf(K);
        pub const tagged = tag_field != null;
        pub const Query = tags.Query;

        /// Indexed by ID.
        defs: []const Def = &.{},
        /// Full names (`package:thing`) in ID order; also the name lookup.
        names: std.StringArrayHashMapUnmanaged(void) = .empty,
        /// The package that defined each entry (the last one, if overridden).
        packages: []const []const u8 = &.{},
        /// Tag search index (built at freeze for tagged kinds). `by_tag[t]` = entries with tag `t`.
        by_tag: []const []const ID = &.{},
        /// One row of `tag_words` words per entry; bit `t` set if the entry has tag `t`.
        tag_bits: []const usize = &.{},
        tag_words: usize = 0,

        pub fn count(r: *const Self) usize {
            return r.defs.len;
        }

        pub fn get(r: *const Self, id: ID) *const Def {
            return &r.defs[@intFromEnum(id)];
        }

        /// The entry called `full_name` (`package:thing`). Meant for loading and debugging.
        pub fn find(r: *const Self, full_name: []const u8) ?ID {
            const index = r.names.getIndex(full_name) orelse return null;
            return @enumFromInt(@as(u16, @intCast(index)));
        }

        pub fn name(r: *const Self, id: ID) []const u8 {
            return r.names.keys()[@intFromEnum(id)];
        }

        pub fn package(r: *const Self, id: ID) []const u8 {
            return r.packages[@intFromEnum(id)];
        }

        /// The tags of entry `id`, in the order written.
        pub fn tagsOf(r: *const Self, id: ID) []const tags.Id {
            if (!tagged) return &.{};
            return @field(r.get(id).*, tag_field.?);
        }

        pub fn hasTag(r: *const Self, id: ID, t: tags.Id) bool {
            if (!tagged) return false;
            const bit = @intFromEnum(t);
            const word = r.tag_bits[@intFromEnum(id) * r.tag_words + bit / @bitSizeOf(usize)];
            return word & (@as(usize, 1) << @intCast(bit % @bitSizeOf(usize))) != 0;
        }

        /// Every entry with tag `t`, in ID order.
        pub fn withTag(r: *const Self, t: tags.Id) []const ID {
            if (!tagged) return &.{};
            return r.by_tag[@intFromEnum(t)];
        }

        pub fn matches(r: *const Self, id: ID, query: tags.Query) bool {
            for (query.all) |t| if (!r.hasTag(id, t)) return false;
            for (query.none) |t| if (r.hasTag(id, t)) return false;
            if (query.any.len == 0) return true;
            for (query.any) |t| if (r.hasTag(id, t)) return true;
            return false;
        }

        /// Every entry matching `query`, in ID order. The caller owns the result.
        pub fn select(r: *const Self, allocator: std.mem.Allocator, query: tags.Query) ![]ID {
            var result: std.ArrayList(ID) = .empty;
            errdefer result.deinit(allocator);
            if (query.all.len > 0) {
                // Only the entries with the rarest required tag can match.
                var rarest = r.withTag(query.all[0]);
                for (query.all[1..]) |t| {
                    const list = r.withTag(t);
                    if (list.len < rarest.len) rarest = list;
                }
                for (rarest) |id| if (r.matches(id, query)) try result.append(allocator, id);
            } else {
                for (0..r.count()) |i| {
                    const id: ID = @enumFromInt(@as(u16, @intCast(i)));
                    if (r.matches(id, query)) try result.append(allocator, id);
                }
            }
            return result.toOwnedSlice(allocator);
        }
    };
}

fn isTagField(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "is_tags"),
        else => false,
    };
}

fn tagFieldOf(comptime K: type) ?[:0]const u8 {
    const info = @typeInfo(K.Raw).@"struct";
    for (info.field_names, info.field_types) |fname, ftype| {
        if (isTagField(ftype)) return fname;
    }
    return null;
}

/// Builds the tag search index for a tagged registry. `tag_count` is the catalog's total tags.
pub fn buildTagIndex(comptime K: type, reg: *Registry(K), tag_count: usize, a: std.mem.Allocator) !void {
    const Self = Registry(K);
    const n = reg.count();
    const words = std.math.divCeil(usize, tag_count, @bitSizeOf(usize)) catch unreachable;
    const bits = try a.alloc(usize, n * words);
    @memset(bits, 0);
    const counts = try a.alloc(usize, tag_count);
    @memset(counts, 0);
    for (0..n) |i| {
        const id: Self.ID = @enumFromInt(@as(u16, @intCast(i)));
        for (reg.tagsOf(id)) |t| {
            const bit = @intFromEnum(t);
            bits[i * words + bit / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(bit % @bitSizeOf(usize));
            counts[bit] += 1;
        }
    }

    // All lists share one array; each tag's list is a slice of it, filled in ID order.
    var total: usize = 0;
    for (counts) |c| total += c;
    const all = try a.alloc(Self.ID, total);
    const by_tag = try a.alloc([]Self.ID, tag_count);
    var start: usize = 0;
    for (by_tag, counts) |*list, c| {
        list.* = all[start..][0..0];
        start += c;
    }
    for (0..n) |i| {
        const id: Self.ID = @enumFromInt(@as(u16, @intCast(i)));
        for (reg.tagsOf(id)) |t| {
            const slot = &by_tag[@intFromEnum(t)];
            slot.* = slot.ptr[0 .. slot.len + 1];
            slot.*[slot.len - 1] = id;
        }
    }

    reg.tag_bits = bits;
    reg.tag_words = words;
    reg.by_tag = by_tag;
}
