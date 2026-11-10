//! The packs in a folder: their `pack.json` manifests, checked and put in load order. Adapted from
//! zcovetous's `src/pack/Packs.zig`.
//!
//!     packs/
//!         core/
//!             pack.json
//!             data/01_materials.json
//!         my_mod/
//!             pack.json
//!             ...
//!
//! Discovery is metadata only: it parses each `pack.json` for its id, version, description and
//! `requires`, keeps the parsed manifest, and orders the packs (a pack loads after everything it
//! requires). The content/resource sections are read later, by `Catalog.load`, from the kept
//! manifest value. A manifest has no pack "type": it simply carries named sections (`content`,
//! `resources`, ...) matching the catalogs the app defines.

const std = @import("std");
const version = @import("version.zig");
const name_rules = @import("name.zig");
const Problems = @import("Problems.zig");

const log = std.log.scoped(.codex);

pub const manifest_name = "pack.json";
/// Pack files larger than this are refused.
pub const max_file_size = 64 * 1024 * 1024;

const Packs = @This();

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
/// The folder that holds the packs.
root: std.Io.Dir,
/// That folder's path, for messages.
root_path: []const u8,
/// In load order.
list: []const Pack = &.{},
/// `reach[a * list.len + b]`: pack `a` requires pack `b`, directly or through other packs.
reach: []const bool = &.{},

pub const Pack = struct {
    id: []const u8,
    version: version.Version,
    description: []const u8,
    /// The pack's folder, inside the packs folder.
    folder: []const u8,
    /// The parsed `pack.json` (a JSON object). Sections are read from it at load time.
    manifest: std.json.Value,

    /// The section named `name` (`"content"`), a JSON object of plural -> [files], or null.
    pub fn section(p: *const Pack, name: []const u8) ?std.json.Value {
        const v = p.manifest.object.get(name) orelse return null;
        return switch (v) {
            .object => v,
            else => null,
        };
    }
};

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Reads every `pack.json` in the subfolders of `path`, checks them, and orders the packs.
pub fn discover(gpa: std.mem.Allocator, io: std.Io, path: []const u8, problems: *Problems) !Packs {
    var root = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        try problems.add(path, "", "cannot open the packs folder: {t}", .{err});
        return error.NoPacksFolder;
    };
    errdefer root.close(io);

    var packs: Packs = .{ .gpa = gpa, .arena = .init(gpa), .root = root, .root_path = undefined };
    errdefer packs.arena.deinit();
    const a = packs.arena.allocator();
    packs.root_path = try a.dupe(u8, path);

    var found: std.ArrayList(Pack) = .empty;
    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const folder = try a.dupe(u8, entry.name);
        const manifest_path = try std.fs.path.join(a, &.{ folder, manifest_name });
        const shown = try packs.shownPath(a, folder, manifest_name);
        const text = root.readFileAlloc(io, manifest_path, a, .limited(max_file_size)) catch |err| switch (err) {
            error.FileNotFound => {
                log.debug("{s}: no {s}, not a pack", .{ folder, manifest_name });
                continue;
            },
            else => {
                try problems.add(shown, "", "cannot read: {t}", .{err});
                continue;
            },
        };

        var scanner: std.json.Scanner = .initCompleteInput(a, text);
        defer scanner.deinit();
        var diag: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&diag);
        const value = std.json.parseFromTokenSourceLeaky(std.json.Value, a, &scanner, .{}) catch {
            try problems.add(shown, "", "not valid JSON (line {d}, column {d})", .{ diag.getLine(), diag.getColumn() });
            continue;
        };
        const obj = switch (value) {
            .object => |o| o,
            else => {
                try problems.add(shown, "", "the manifest must be a JSON object", .{});
                continue;
            },
        };

        const id = getString(obj, "id") orelse {
            try problems.add(shown, "", "has no string 'id'", .{});
            continue;
        };
        if (name_rules.checkPackage(id)) |why| {
            try problems.add(shown, "", "the pack id '{s}' {s}", .{ id, why });
            continue;
        }
        const ver_str = getString(obj, "version") orelse {
            try problems.add(shown, id, "has no string 'version'", .{});
            continue;
        };
        const ver = version.parse(ver_str) catch {
            try problems.add(shown, id, "the version '{s}' is not a version like 1.0.0", .{ver_str});
            continue;
        };

        try found.append(a, .{
            .id = id,
            .version = ver,
            .description = getString(obj, "description") orelse "",
            .folder = folder,
            .manifest = value,
        });
    }

    // Sorted by ID, so the order never depends on the file system.
    std.mem.sort(Pack, found.items, {}, struct {
        fn lessThan(_: void, l: Pack, r: Pack) bool {
            return std.mem.order(u8, l.id, r.id) == .lt;
        }
    }.lessThan);
    for (found.items, 0..) |p, i| if (i > 0) {
        const previous = found.items[i - 1];
        if (std.mem.eql(u8, p.id, previous.id)) {
            try problems.add(packs.root_path, p.id, "two packs have this id (folders {s} and {s})", .{ previous.folder, p.folder });
        }
    };

    try packs.order(found.items, problems);
    for (packs.list) |p| log.info("pack {s} {f} ({s})", .{ p.id, p.version, p.folder });
    return packs;
}

pub fn deinit(packs: *Packs, io: std.Io) void {
    packs.root.close(io);
    packs.arena.deinit();
    packs.* = undefined;
}

pub fn find(packs: *const Packs, id: []const u8) ?usize {
    for (packs.list, 0..) |p, i| if (std.mem.eql(u8, p.id, id)) return i;
    return null;
}

/// Whether pack `a` requires pack `b`, directly or through other packs.
pub fn requires(packs: *const Packs, a: []const u8, b: []const u8) bool {
    const i = packs.find(a) orelse return false;
    const j = packs.find(b) orelse return false;
    return packs.reach[i * packs.list.len + j];
}

/// Reads a file of `pack`, given relative to its folder. The caller owns the result.
pub fn readFile(packs: *const Packs, io: std.Io, pack: *const Pack, sub_path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const full = try std.fs.path.join(gpa, &.{ pack.folder, sub_path });
    defer gpa.free(full);
    return packs.root.readFileAlloc(io, full, gpa, .limited(max_file_size));
}

/// How a pack's file is named in messages: `packs/core/pack.json`. The caller owns the result.
pub fn shownPath(packs: *const Packs, allocator: std.mem.Allocator, folder: []const u8, sub_path: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ packs.root_path, folder, sub_path });
}

fn requiresOf(pack: Pack) ?std.json.ObjectMap {
    const v = pack.manifest.object.get("requires") orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

/// Checks `requires`, then puts the packs in load order (a pack after what it requires).
fn order(packs: *Packs, found: []Pack, problems: *Problems) !void {
    const a = packs.arena.allocator();
    const n = found.len;

    // edges[i * n + j]: pack i requires pack j directly.
    const edges = try a.alloc(bool, n * n);
    @memset(edges, false);
    for (found, 0..) |p, i| {
        const shown = try packs.shownPath(a, p.folder, manifest_name);
        const req = requiresOf(p) orelse continue;
        for (req.keys(), req.values()) |id, range_val| {
            const range = switch (range_val) {
                .string => |s| s,
                else => {
                    try problems.add(shown, p.id, "the version range for {s} must be a string", .{id});
                    continue;
                },
            };
            const j = for (found, 0..) |q, j| {
                if (std.mem.eql(u8, q.id, id)) break j;
            } else {
                try problems.add(shown, p.id, "requires pack {s}, which is not there", .{id});
                continue;
            };
            if (i == j) {
                try problems.add(shown, p.id, "requires itself", .{});
                continue;
            }
            const ok = version.satisfies(found[j].version, range) catch {
                try problems.add(shown, p.id, "the version range '{s}' for {s} is not valid (e.g. \">=1.0.0 <2.0.0\")", .{ range, id });
                continue;
            };
            if (!ok) try problems.add(shown, p.id, "requires {s} {s}, but it is version {f}", .{ id, range, found[j].version });
            edges[i * n + j] = true;
        }
    }

    // Repeatedly take the first pack (by ID) whose requirements are all placed.
    const placed = try a.alloc(bool, n);
    @memset(placed, false);
    const position = try a.alloc(usize, n);
    var list: std.ArrayList(Pack) = .empty;
    while (list.items.len < n) {
        const next = for (0..n) |i| {
            if (placed[i]) continue;
            const ready = for (0..n) |j| {
                if (edges[i * n + j] and !placed[j]) break false;
            } else true;
            if (ready) break i;
        } else break;
        placed[next] = true;
        position[next] = list.items.len;
        try list.append(a, found[next]);
    }
    for (found, 0..) |p, i| if (!placed[i]) {
        try problems.add(try packs.shownPath(a, p.folder, manifest_name), p.id, "is part of a circle of packs requiring each other", .{});
    };

    // Indirect requirements, in load order.
    const m = list.items.len;
    const reach = try a.alloc(bool, m * m);
    @memset(reach, false);
    for (0..n) |i| if (placed[i]) for (0..n) |j| if (placed[j] and edges[i * n + j]) {
        reach[position[i] * m + position[j]] = true;
    };
    for (0..m) |i| for (0..i) |j| if (reach[i * m + j]) for (0..j) |k| {
        if (reach[j * m + k]) reach[i * m + k] = true;
    };

    packs.list = list.items;
    packs.reach = reach;
}


// ================================================================================ //
// = TESTS                                                                        = //
// ================================================================================ //

const testing = std.testing;
const t_gpa = std.testing.allocator;
const t_io = std.testing.io;

fn writeTmp(tmp: *std.testing.TmpDir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |dir| try tmp.dir.createDirPath(t_io, dir);
    try tmp.dir.writeFile(t_io, .{ .sub_path = sub_path, .data = data });
}

test "discover: orders packs by requires" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(&tmp,
        \\core/pack.json
    ,
        \\{ "id": "core", "version": "1.2.0", "content": { "materials": ["/materials.json"] } }
    );
    try writeTmp(&tmp,
        \\mod/pack.json
    ,
        \\{ "id": "mod", "version": "0.1.0", "requires": { "core": ">=1.0.0" } }
    );

    const path = try std.fs.path.join(t_gpa, &.{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    defer t_gpa.free(path);

    var problems: Problems = .init(t_gpa);
    defer problems.deinit();
    var packs = try discover(t_gpa, t_io, path, &problems);
    defer packs.deinit(t_io);

    try testing.expectEqual(@as(usize, 0), problems.count());
    try testing.expectEqual(@as(usize, 2), packs.list.len);
    // core loads before mod, because mod requires core.
    try testing.expectEqualStrings("core", packs.list[0].id);
    try testing.expectEqualStrings("mod", packs.list[1].id);
    try testing.expect(packs.requires("mod", "core"));
    try testing.expect(!packs.requires("core", "mod"));

    // the kept manifest exposes sections
    const core = packs.list[0];
    try testing.expect(core.section("content") != null);
    try testing.expect(core.section("resources") == null);
}

test "discover: reports a missing requirement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(&tmp,
        \\mod/pack.json
    ,
        \\{ "id": "mod", "version": "1.0.0", "requires": { "core": ">=1.0.0" } }
    );

    const path = try std.fs.path.join(t_gpa, &.{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    defer t_gpa.free(path);

    var problems: Problems = .init(t_gpa);
    defer problems.deinit();
    var packs = try discover(t_gpa, t_io, path, &problems);
    defer packs.deinit(t_io);

    try testing.expect(problems.count() >= 1);
}
