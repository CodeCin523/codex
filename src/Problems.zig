//! Problems found while loading packs: where, about what, and what is wrong.
//!
//! Loading records problems and keeps going, so one run reports everything wrong at once rather
//! than only the first problem. The host application reads these and decides what to do (crash,
//! disable the offending pack, prompt the user): codex sets no policy, and a catalog does not
//! freeze while any problem remains.

const std = @import("std");
const Problems = @This();

const log = std.log.scoped(.codex);

gpa: std.mem.Allocator,
/// The messages, and copies of the paths and names they mention.
arena: std.heap.ArenaAllocator,
list: std.ArrayList(Problem) = .empty,

pub const Problem = struct {
    /// The file, or empty if the problem is not in one file.
    path: []const u8,
    /// The entry or pack it is about, or empty.
    subject: []const u8,
    message: []const u8,

    pub fn format(p: Problem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (p.path.len > 0) try w.print("{s}: ", .{p.path});
        if (p.subject.len > 0) try w.print("{s}: ", .{p.subject});
        try w.writeAll(p.message);
    }
};

pub fn init(gpa: std.mem.Allocator) Problems {
    return .{ .gpa = gpa, .arena = .init(gpa) };
}

pub fn deinit(p: *Problems) void {
    p.list.deinit(p.gpa);
    p.arena.deinit();
    p.* = undefined;
}

pub fn add(p: *Problems, path: []const u8, subject: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const a = p.arena.allocator();
    try p.list.append(p.gpa, .{
        .path = try a.dupe(u8, path),
        .subject = try a.dupe(u8, subject),
        .message = try std.fmt.allocPrint(a, fmt, args),
    });
}

pub fn count(p: *const Problems) usize {
    return p.list.items.len;
}

pub fn items(p: *const Problems) []const Problem {
    return p.list.items;
}

/// Logs every problem with `std.log.err`.
pub fn logAll(p: *const Problems) void {
    for (p.list.items) |problem| log.err("{f}", .{problem});
}


// ================================================================================ //
// = TESTS                                                                        = //
// ================================================================================ //

test "records and reports problems" {
    var p: Problems = .init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.count());
    try p.add("packs/core/pack.json", "core:stone", "unknown {s} '{s}'", .{ "material", "core:lava" });
    try p.add("", "", "no packs folder", .{});
    try std.testing.expectEqual(@as(usize, 2), p.count());

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{p.items()[0]});
    try std.testing.expectEqualStrings(
        "packs/core/pack.json: core:stone: unknown material 'core:lava'",
        w.buffered(),
    );
}
