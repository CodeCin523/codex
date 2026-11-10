//! Tags: free-form string labels on entries, owned entirely by codex. The app declares no tag kind
//! and packs list no tags — a `field.Tags` field just collects whatever strings entries use. codex
//! interns them per catalog (so `metal` is the same tag in every pack), assigns each a stable id,
//! and builds a reverse search index on each tagged registry.

const std = @import("std");

/// A tag's id within a catalog: an index into the catalog's interned tag table.
pub const Id = enum(u16) { _ };

/// name -> id (the id is the key's insertion index). Lives in the catalog's arena.
pub const Table = std.StringArrayHashMapUnmanaged(void);

/// Interns `name`, returning its stable id (adding it if new). New keys are duped with `a`.
pub fn intern(table: *Table, a: std.mem.Allocator, name: []const u8) !Id {
    const gop = try table.getOrPut(a, name);
    if (!gop.found_existing) gop.key_ptr.* = try a.dupe(u8, name);
    return @enumFromInt(@as(u16, @intCast(gop.index)));
}

/// Entries that have all of `all`, at least one of `any` (if not empty), and none of `none`.
pub const Query = struct {
    all: []const Id = &.{},
    any: []const Id = &.{},
    none: []const Id = &.{},
};
