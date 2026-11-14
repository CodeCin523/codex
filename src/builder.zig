//! `Builder(Catalog)`: fills a catalog from pack files, then freezes it. Adapted from zcovetous's
//! `src/pack/builder.zig` to the generated `Def` + `codex.build`.
//!
//! 1. `addContent` once per file, in load order. A file is a JSON array of entries of one kind.
//!    Names without a pack are in the file's pack (`stone` in pack `core` is `core:stone`).
//!    Redefining a name from another pack overrides it, keeping its ID.
//! 2. `freeze` auto-maps each `Raw` to its `Def` (through the resolver) and runs each kind's
//!    optional relational `resolve(r, *Def)`. All names are known by then, so references can point
//!    anywhere, even in circles.
//!
//! `load(Catalog, ...)` drives this over every pack in a folder (see `packs.zig`); `loadAgainst` /
//! `freezeAgainst(.{&upstream})` resolve refs to kinds that live in upstream catalogs.
//!
//! (Deferred: the `.pak` binary cache and per-field override merge.)

const std = @import("std");
const def = @import("def.zig");
const registry = @import("registry.zig");
const json = @import("json.zig");
const name_rules = @import("name.zig");
const Problems = @import("Problems.zig");
const Packs = @import("packs.zig");
const tags = @import("tags.zig");

const log = std.log.scoped(.codex);

/// A type-erased lookup into frozen upstream catalogs, for refs to kinds not in the catalog being
/// built. Matches a kind by `@typeName` and returns the entry's `u16` index (its ID), or null.
const External = struct {
    ctx: *const anyopaque,
    lookup: *const fn (ctx: *const anyopaque, kind_name: []const u8, full: []const u8) ?u16,
};

/// Whether catalog `Cat` registers kind `K`.
fn hasKind(comptime Cat: type, comptime K: type) bool {
    inline for (Cat.plurals) |p| if (Cat.KindOf(p) == K) return true;
    return false;
}

/// The `External.lookup` for an `against` tuple of `*const Catalog` pointers.
fn externalLookup(comptime Against: type) *const fn (*const anyopaque, []const u8, []const u8) ?u16 {
    return struct {
        fn f(ctx: *const anyopaque, kind_name: []const u8, full: []const u8) ?u16 {
            const tup: *const Against = @ptrCast(@alignCast(ctx));
            inline for (tup.*) |cat| {
                const Cat = @TypeOf(cat.*);
                inline for (Cat.plurals) |p| {
                    const K = Cat.KindOf(p);
                    if (std.mem.eql(u8, kind_name, @typeName(K))) {
                        if (cat.registry(K).find(full)) |id| return @intFromEnum(id);
                        return null;
                    }
                }
            }
            return null;
        }
    }.f;
}

pub fn Builder(comptime Catalog: type) type {
    const plurals = Catalog.plurals;

    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        /// Raw entries and their names.
        arena: std.heap.ArenaAllocator,
        problems: *Problems,
        /// For checking overrides against `requires`; null when building without packs (tests).
        packs: ?*const Packs = null,
        /// Pack IDs, in order of first appearance.
        packages: std.ArrayList([]const u8) = .empty,
        /// One map per kind: full name -> raw entry, in order of first definition.
        entries: Entries = .{},

        pub fn Entry(comptime K: type) type {
            return struct { raw: K.Raw, package: []const u8, path: []const u8, source: []const u8 };
        }

        const Entries = blk: {
            var types: [plurals.len]type = undefined;
            var attrs: [plurals.len]std.lang.Type.Struct.FieldAttributes = undefined;
            for (plurals, &types, &attrs) |p, *T, *at| {
                T.* = std.StringArrayHashMapUnmanaged(Entry(Catalog.KindOf(p)));
                const empty: T.* = .empty;
                at.* = .{ .default_value_ptr = @ptrCast(&empty) };
            }
            break :blk @Struct(.auto, null, plurals, &types, &attrs);
        };

        pub fn init(gpa: std.mem.Allocator, problems: *Problems) Self {
            return .{ .gpa = gpa, .arena = .init(gpa), .problems = problems };
        }

        pub fn deinit(b: *Self) void {
            inline for (plurals) |p| @field(b.entries, p).deinit(b.gpa);
            b.packages.deinit(b.gpa);
            b.arena.deinit();
            b.* = undefined;
        }

        pub fn addPackage(b: *Self, package: []const u8) ![]const u8 {
            for (b.packages.items) |p| if (std.mem.eql(u8, p, package)) return p;
            const owned = try b.arena.allocator().dupe(u8, package);
            try b.packages.append(b.gpa, owned);
            return owned;
        }

        /// Adds the entries of one file: `text` is a JSON array of entries of `kind` (a plural key
        /// of the catalog). `path` is only used in messages.
        pub fn addContent(b: *Self, package: []const u8, path: []const u8, source: []const u8, kind: []const u8, text: []const u8) !void {
            inline for (plurals) |p| {
                if (std.mem.eql(u8, kind, p)) return b.addEntries(Catalog.KindOf(p), p, package, path, source, text);
            }
            try b.problems.add(path, "", "unknown kind '{s}' (kinds: {s})", .{ kind, comptime kindList() });
        }

        fn kindList() []const u8 {
            if (plurals.len == 0) return "none";
            var list: []const u8 = "";
            for (plurals, 0..) |p, i| list = list ++ (if (i == 0) "" else ", ") ++ p;
            return list;
        }

        fn addEntries(b: *Self, comptime K: type, comptime plural: [:0]const u8, package: []const u8, path: []const u8, source: []const u8, text: []const u8) !void {
            const arena = b.arena.allocator();
            const owned_package = try b.addPackage(package);
            const owned_path = try arena.dupe(u8, path);
            const owned_source = try arena.dupe(u8, source);
            const raws = try json.parse([]const K.Raw, arena, text, owned_path, b.problems) orelse return;
            const map = &@field(b.entries, plural);
            const name_field = comptime def.nameFieldOf(K.Raw);

            for (raws) |raw| {
                const entry_name = @field(raw, name_field).get();
                const full = try name_rules.qualify(arena, owned_package, entry_name);
                if (name_rules.check(full)) |why| {
                    try b.problems.add(owned_path, "", "the {s} name '{s}' {s}", .{ labelOf(K), entry_name, why });
                    continue;
                }
                const slot = try map.getOrPut(b.gpa, full);
                if (slot.found_existing) {
                    const previous = slot.value_ptr.*;
                    if (std.mem.eql(u8, previous.package, owned_package)) {
                        try b.problems.add(owned_path, full, "is defined twice in pack {s} (also in {s})", .{ owned_package, previous.path });
                        continue;
                    }
                    if (b.packs) |packs| if (!packs.requires(owned_package, previous.package)) {
                        try b.problems.add(owned_path, full, "replaces an entry of pack {s}, so pack {s} must require {s}", .{ previous.package, owned_package, previous.package });
                        continue;
                    };
                    log.debug("{s} {s} from {s} overridden by pack {s}", .{ labelOf(K), full, previous.package, owned_package });
                }
                slot.value_ptr.* = .{ .raw = raw, .package = owned_package, .path = owned_path, .source = owned_source };
            }
        }

        fn labelOf(comptime K: type) []const u8 {
            return if (@hasDecl(K, "label")) K.label else Catalog.pluralOf(K);
        }

        /// Resolves and checks everything, returning the frozen catalog. On `error.InvalidCatalog`,
        /// the problems say what is wrong. The catalog does not depend on the builder afterwards.
        pub fn freeze(b: *Self, gpa: std.mem.Allocator) !Catalog {
            return b.freezeAgainst(gpa, .{});
        }

        /// Like `freeze`, but resolves refs to kinds not in this catalog against the frozen upstream
        /// catalogs in the `against` tuple (e.g. a resource catalog against the data catalog).
        pub fn freezeAgainst(b: *Self, gpa: std.mem.Allocator, against: anytype) !Catalog {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            errdefer arena.deinit();
            const a = arena.allocator();

            var catalog: Catalog = .{ .arena = undefined };
            const packages = try a.alloc([]const u8, b.packages.items.len);
            for (b.packages.items, packages) |p, *out| out.* = try a.dupe(u8, p);
            catalog.packages = packages;

            const against_ptr = &against;
            const ext: ?External = if (@typeInfo(@TypeOf(against)).@"struct".field_names.len == 0)
                null
            else
                .{ .ctx = @ptrCast(against_ptr), .lookup = externalLookup(@TypeOf(against)) };
            var r: Resolver = .{ .allocator = a, .builder = b, .external = ext, .tag_table = &catalog.tags };

            inline for (plurals) |plural| {
                const K = Catalog.KindOf(plural);
                const map = &@field(b.entries, plural);
                const reg = &@field(catalog.regs, plural);
                const n = map.count();
                const max = if (@hasDecl(K, "max_count")) K.max_count else std.math.maxInt(u16);

                if (n > max) {
                    try b.problems.add("", "", "there are {d} {s} entries, more than the {d} allowed", .{ n, plural, max });
                } else {
                    const Def = registry.Registry(K).Def;
                    const defs = try a.alloc(Def, n);
                    const entry_packages = try a.alloc([]const u8, n);
                    try reg.names.ensureTotalCapacity(a, n);

                    for (map.keys(), map.values(), 0..) |full, entry, i| {
                        reg.names.putAssumeCapacityNoClobber(try a.dupe(u8, full), {});
                        entry_packages[i] = packages[indexOf(b.packages.items, entry.package)];
                        r.focus(K, i);
                        var d = try def.buildKind(K.Raw, entry.raw, &r);
                        r.field = "";
                        if (@hasDecl(K, "resolve")) try K.resolve(&r, &d);
                        defs[i] = d;
                    }

                    reg.defs = defs;
                    reg.packages = entry_packages;
                }
            }

            // Any problem at all means no catalog.
            if (b.problems.count() > 0) return error.InvalidCatalog;

            // Tag search indexes: a second pass, now that each tag kind's final count is known.
            inline for (plurals) |plural| {
                const K = Catalog.KindOf(plural);
                if (comptime registry.Registry(K).tagged) {
                    try registry.buildTagIndex(K, &@field(catalog.regs, plural), catalog.tags.count(), a);
                }
            }

            catalog.arena = arena;
            return catalog;
        }

        fn indexOf(list: []const []const u8, item: []const u8) usize {
            for (list, 0..) |p, i| if (p.ptr == item.ptr) return i;
            unreachable;
        }

        /// What a kind's `resolve` (and the field types) get: turns names into IDs, checks values,
        /// and records problems against the entry they come from. Problems do not stop resolving, so
        /// all are found at once.
        pub const Resolver = struct {
            /// The catalog's memory: allocate whatever a `Def` keeps (slices, strings) with it.
            allocator: std.mem.Allocator,
            builder: *Self,
            /// Upstream catalogs for refs to kinds not in this one (null if none given).
            external: ?External = null,
            /// The catalog's interned tag table; `field.Tags` adds to it as entries use tags.
            tag_table: *tags.Table = undefined,
            // The entry being resolved.
            package: []const u8 = "",
            path: []const u8 = "",
            source: []const u8 = "",
            subject: []const u8 = "",
            field: []const u8 = "",
            index: usize = 0,

            /// The ID of the entry called `nm` (in this entry's pack if it names none). An unknown
            /// name is recorded as a problem and a sentinel ID is returned.
            pub fn ref(r: *Resolver, comptime K: type, nm: []const u8) !K.ID {
                const full = try name_rules.qualify(r.builder.arena.allocator(), r.package, nm);
                if (comptime hasKind(Catalog, K)) {
                    const map = &@field(r.builder.entries, Catalog.pluralOf(K));
                    if (map.getIndex(full)) |i| return @enumFromInt(@as(u16, @intCast(i)));
                } else {
                    // A ref to a kind not in this catalog: resolve against the upstream catalogs.
                    const idx = if (r.external) |ext| ext.lookup(ext.ctx, @typeName(K), full) else null;
                    if (idx) |i| return @enumFromInt(i);
                }
                try r.fail("unknown {s} '{s}'", .{ labelOf(K), full });
                return @enumFromInt(std.math.maxInt(u16));
            }

            /// A copy of `s` in the catalog's memory.
            pub fn string(r: *Resolver, s: []const u8) ![]const u8 {
                return r.allocator.dupe(u8, s);
            }

            /// Interns a free-form tag name into the catalog, returning its id.
            pub fn tag(r: *Resolver, nm: []const u8) !tags.Id {
                return tags.intern(r.tag_table, r.allocator, nm);
            }

            /// Validates and normalizes a sandboxed pack path to one relative to the pack root. `/`
            /// is the pack root, `./`/`../` is relative to the file declaring it; bare paths, `\`,
            /// uppercase, and escapes past the root are recorded as problems. On a problem, returns
            /// the raw path unchanged (building continues; the problem blocks the freeze).
            pub fn resolvePath(r: *Resolver, raw: []const u8) ![]const u8 {
                if (std.mem.indexOfScalar(u8, raw, '\\') != null) {
                    try r.fail("path '{s}' must use '/', not '\\'", .{raw});
                    return r.string(raw);
                }
                const joined = if (std.mem.startsWith(u8, raw, "/"))
                    raw[1..]
                else if (std.mem.startsWith(u8, raw, "./") or std.mem.startsWith(u8, raw, "../")) blk: {
                    const base = std.fs.path.dirnamePosix(r.source) orelse "";
                    break :blk try std.fmt.allocPrint(r.builder.arena.allocator(), "{s}/{s}", .{ base, raw });
                } else {
                    try r.fail("path '{s}' must start with '/' (pack root) or './' (this file's folder)", .{raw});
                    return r.string(raw);
                };

                var stack: [64][]const u8 = undefined;
                var n: usize = 0;
                var it = std.mem.splitScalar(u8, joined, '/');
                while (it.next()) |comp| {
                    if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
                    if (std.mem.eql(u8, comp, "..")) {
                        if (n == 0) {
                            try r.fail("path '{s}' escapes the pack root", .{raw});
                            return r.string(raw);
                        }
                        n -= 1;
                        continue;
                    }
                    for (comp) |c| if (c >= 'A' and c <= 'Z') {
                        try r.fail("path '{s}' must be lowercase", .{raw});
                        return r.string(raw);
                    };
                    if (n == stack.len) {
                        try r.fail("path '{s}' is too deep", .{raw});
                        return r.string(raw);
                    }
                    stack[n] = comp;
                    n += 1;
                }

                var total: usize = 0;
                for (stack[0..n]) |c| total += c.len + 1;
                const out = try r.allocator.alloc(u8, if (total == 0) 0 else total - 1);
                var w: usize = 0;
                for (stack[0..n], 0..) |c, i| {
                    if (i != 0) {
                        out[w] = '/';
                        w += 1;
                    }
                    @memcpy(out[w..][0..c.len], c);
                    w += c.len;
                }
                return out;
            }

            /// Records a problem against the current entry, prefixed with the current field.
            pub fn fail(r: *Resolver, comptime fmt: []const u8, args: anytype) !void {
                if (r.field.len > 0) {
                    const detail = try std.fmt.allocPrint(r.allocator, fmt, args);
                    try r.builder.problems.add(r.path, r.subject, "{s} {s}", .{ r.field, detail });
                } else {
                    try r.builder.problems.add(r.path, r.subject, fmt, args);
                }
            }

            /// Records a problem if `ok` is false.
            pub fn check(r: *Resolver, ok: bool, comptime fmt: []const u8, args: anytype) !void {
                if (!ok) try r.fail(fmt, args);
            }

            /// The ID of the entry being resolved.
            pub fn current(r: *const Resolver, comptime K: type) K.ID {
                return @enumFromInt(@as(u16, @intCast(r.index)));
            }

            fn focus(r: *Resolver, comptime K: type, index: usize) void {
                const map = &@field(r.builder.entries, Catalog.pluralOf(K));
                r.package = map.values()[index].package;
                r.path = map.values()[index].path;
                r.source = map.values()[index].source;
                r.subject = map.keys()[index];
                r.index = index;
                r.field = "";
            }
        };
    };
}

/// Loads `Catalog` from the `Catalog.section` of every pack in `packs`, in load order. File paths
/// in the section must start with `/` (relative to the pack root). On `error.InvalidCatalog`,
/// `problems` says what is wrong.
pub fn load(comptime Catalog: type, gpa: std.mem.Allocator, io: std.Io, packs: *const Packs, problems: *Problems) !Catalog {
    return loadAgainst(Catalog, gpa, io, packs, problems, .{});
}

/// Like `load`, but resolves refs to kinds not in `Catalog` against the frozen upstream catalogs in
/// `against` (e.g. loading a resource catalog against the data catalog).
pub fn loadAgainst(comptime Catalog: type, gpa: std.mem.Allocator, io: std.Io, packs: *const Packs, problems: *Problems, against: anytype) !Catalog {
    var b: Builder(Catalog) = .init(gpa, problems);
    b.packs = packs;
    defer b.deinit();

    for (packs.list) |*p| {
        _ = try b.addPackage(p.name);
        const sec = p.section(Catalog.section) orelse continue;
        for (sec.object.keys(), sec.object.values()) |plural, files_val| {
            const files = switch (files_val) {
                .array => |arr| arr,
                else => {
                    const shown = try packs.shownPath(gpa, p.folder, Packs.manifest_name);
                    defer gpa.free(shown);
                    try problems.add(shown, p.name, "'{s}' in section '{s}' must be a list of files", .{ plural, Catalog.section });
                    continue;
                },
            };
            for (files.items) |file_val| {
                const file = switch (file_val) {
                    .string => |s| s,
                    else => continue,
                };
                const shown = try packs.shownPath(gpa, p.folder, file);
                defer gpa.free(shown);
                if (file.len == 0 or file[0] != '/') {
                    try problems.add(shown, "", "the path '{s}' must start with '/' (relative to the pack root)", .{file});
                    continue;
                }
                const text = packs.readFile(io, p, file[1..], gpa) catch |err| {
                    try problems.add(shown, "", "cannot read (listed in {s}): {t}", .{ Packs.manifest_name, err });
                    continue;
                };
                defer gpa.free(text);
                try b.addContent(p.name, shown, file[1..], plural, text);
            }
        }
    }

    return b.freezeAgainst(gpa, against);
}


// ================================================================================ //
// = TESTS                                                                        = //
// ================================================================================ //

const field = @import("field.zig");
const makeCatalog = @import("catalog.zig").Catalog;
const testing = std.testing;

test "load: resolve refs across kinds in a catalog" {
    const f = field;
    const Trauma = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "trauma";
        pub const Raw = struct { name: f.Name, desc: f.String };
    };
    const Material = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "material";
        pub const Raw = struct { name: f.Name, density: f.Positive(f32), resist: f.Ref(Trauma) };
    };
    const Data = makeCatalog("content", .{ .traumas = Trauma, .materials = Material });

    var problems: Problems = .init(testing.allocator);
    defer problems.deinit();

    var b: Builder(Data) = .init(testing.allocator, &problems);
    defer b.deinit();

    try b.addContent("core", "packs/core/traumas.json", "traumas.json", "traumas",
        \\[ { "name": "burn", "desc": "fire damage" } ]
    );
    try b.addContent("core", "packs/core/materials.json", "materials.json", "materials",
        \\[ { "name": "stone", "density": 2.5, "resist": "burn" } ]
    );
    try testing.expectEqual(@as(usize, 0), problems.count());

    var data = try b.freeze(testing.allocator);
    defer data.deinit();

    try testing.expectEqual(@as(usize, 1), data.registry(Material).count());
    try testing.expectEqual(@as(usize, 1), data.registry(Trauma).count());

    const stone = data.registry(Material).find("core:stone").?;
    const m = data.registry(Material).get(stone);
    try testing.expectEqual(@as(f32, 2.5), m.density);
    const burn = data.registry(Trauma).find("core:burn").?;
    try testing.expectEqual(burn, m.resist);
}

test "load: unknown ref is reported, no freeze" {
    const f = field;
    const Trauma = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "trauma";
        pub const Raw = struct { name: f.Name };
    };
    const Material = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "material";
        pub const Raw = struct { name: f.Name, resist: f.Ref(Trauma) };
    };
    const Data = makeCatalog("content", .{ .traumas = Trauma, .materials = Material });

    var problems: Problems = .init(testing.allocator);
    defer problems.deinit();
    var b: Builder(Data) = .init(testing.allocator, &problems);
    defer b.deinit();

    try b.addContent("core", "m.json", "m.json", "materials",
        \\[ { "name": "stone", "resist": "ghost" } ]
    );
    try testing.expectError(error.InvalidCatalog, b.freeze(testing.allocator));
    try testing.expect(problems.count() >= 1);
}

test "load: discovers a packs folder and loads a catalog" {
    const f = field;
    const Trauma = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "trauma";
        pub const Raw = struct { name: f.Name, desc: f.String };
    };
    const Material = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "material";
        pub const Raw = struct { name: f.Name, density: f.Positive(f32), resist: f.Ref(Trauma) };
    };
    const Data = makeCatalog("content", .{ .traumas = Trauma, .materials = Material });

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "core");
    try tmp.dir.writeFile(io, .{ .sub_path = "core/pack.json", .data =
        \\{ "name": "core", "version": "1.0.0", "content": { "traumas": ["/traumas.json"], "materials": ["/materials.json"] } }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "core/traumas.json", .data =
        \\[ { "name": "burn", "desc": "fire damage" } ]
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "core/materials.json", .data =
        \\[ { "name": "stone", "density": 2.5, "resist": "burn" } ]
    });

    const path = try std.fs.path.join(testing.allocator, &.{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    defer testing.allocator.free(path);

    var problems: Problems = .init(testing.allocator);
    defer problems.deinit();
    var packs = try Packs.discover(testing.allocator, io, path, &problems);
    defer packs.deinit(io);

    var data = try load(Data, testing.allocator, io, &packs, &problems);
    defer data.deinit();

    try testing.expectEqual(@as(usize, 1), data.registry(Material).count());
    const stone = data.registry(Material).find("core:stone").?;
    try testing.expectEqual(@as(f32, 2.5), data.registry(Material).get(stone).density);
    const burn = data.registry(Trauma).find("core:burn").?;
    try testing.expectEqual(burn, data.registry(Material).get(stone).resist);
}

test "field.Path: prefix rules, normalization, and escape rejection" {
    const f = field;
    const Look = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "look";
        pub const Raw = struct { name: f.Name, texture: f.Path };
    };
    const Res = makeCatalog("resources", .{ .looks = Look });

    {
        var problems: Problems = .init(testing.allocator);
        defer problems.deinit();
        var b: Builder(Res) = .init(testing.allocator, &problems);
        defer b.deinit();
        // source "res/looks.json" -> its folder is "res", so "./dirt.png" -> "res/dirt.png".
        try b.addContent("core", "packs/core/res/looks.json", "res/looks.json", "looks",
            \\[ { "name": "stone", "texture": "/textures/stone.png" },
            \\  { "name": "dirt",  "texture": "./dirt.png" },
            \\  { "name": "up",    "texture": "../shared/x.png" } ]
        );
        var res = try b.freeze(testing.allocator);
        defer res.deinit();
        try testing.expectEqualStrings("textures/stone.png", res.registry(Look).get(res.registry(Look).find("core:stone").?).texture);
        try testing.expectEqualStrings("res/dirt.png", res.registry(Look).get(res.registry(Look).find("core:dirt").?).texture);
        try testing.expectEqualStrings("shared/x.png", res.registry(Look).get(res.registry(Look).find("core:up").?).texture);
    }
    {
        // bare path and an escaping path are rejected.
        var problems: Problems = .init(testing.allocator);
        defer problems.deinit();
        var b: Builder(Res) = .init(testing.allocator, &problems);
        defer b.deinit();
        try b.addContent("core", "p.json", "p.json", "looks",
            \\[ { "name": "bad1", "texture": "bare.png" }, { "name": "bad2", "texture": "/../escape.png" } ]
        );
        try testing.expectError(error.InvalidCatalog, b.freeze(testing.allocator));
        try testing.expect(problems.count() >= 2);
    }
}

test "override: a later pack that requires the first replaces an entry, keeping its id" {
    const f = field;
    const Material = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "material";
        pub const Raw = struct { name: f.Name, density: f.Positive(f32) };
    };
    const Data = makeCatalog("content", .{ .materials = Material });
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "core");
    try tmp.dir.createDirPath(io, "mod");
    try tmp.dir.writeFile(io, .{ .sub_path = "core/pack.json", .data =
        \\{ "name": "core", "version": "1.0.0", "content": { "materials": ["/m.json"] } }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "core/m.json", .data =
        \\[ { "name": "stone", "density": 1.0 } ]
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "mod/pack.json", .data =
        \\{ "name": "mod", "version": "1.0.0", "requires": { "core": ">=1.0.0" }, "content": { "materials": ["/m.json"] } }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "mod/m.json", .data =
        \\[ { "name": "core:stone", "density": 9.0 } ]
    });

    const path = try std.fs.path.join(testing.allocator, &.{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    defer testing.allocator.free(path);
    var problems: Problems = .init(testing.allocator);
    defer problems.deinit();
    var packs = try Packs.discover(testing.allocator, io, path, &problems);
    defer packs.deinit(io);

    var data = try load(Data, testing.allocator, io, &packs, &problems);
    defer data.deinit();

    try testing.expectEqual(@as(usize, 1), data.registry(Material).count());
    const stone = data.registry(Material).find("core:stone").?;
    try testing.expectEqual(@as(f32, 9.0), data.registry(Material).get(stone).density);
}

test "override: without requiring the overridden pack is a problem" {
    const f = field;
    const Material = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "material";
        pub const Raw = struct { name: f.Name, density: f.Positive(f32) };
    };
    const Data = makeCatalog("content", .{ .materials = Material });
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "core");
    try tmp.dir.createDirPath(io, "mod");
    try tmp.dir.writeFile(io, .{ .sub_path = "core/pack.json", .data =
        \\{ "name": "core", "version": "1.0.0", "content": { "materials": ["/m.json"] } }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "core/m.json", .data =
        \\[ { "name": "stone", "density": 1.0 } ]
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "mod/pack.json", .data =
        \\{ "name": "mod", "version": "1.0.0", "content": { "materials": ["/m.json"] } }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "mod/m.json", .data =
        \\[ { "name": "core:stone", "density": 9.0 } ]
    });

    const path = try std.fs.path.join(testing.allocator, &.{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    defer testing.allocator.free(path);
    var problems: Problems = .init(testing.allocator);
    defer problems.deinit();
    var packs = try Packs.discover(testing.allocator, io, path, &problems);
    defer packs.deinit(io);

    try testing.expectError(error.InvalidCatalog, load(Data, testing.allocator, io, &packs, &problems));
    try testing.expect(problems.count() >= 1);
}

test "tags: codex-managed search index with withTag / hasTag / select" {
    const f = field;
    const Material = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "material";
        pub const Raw = struct { name: f.Name, tags: f.Tags };
    };
    const Data = makeCatalog("content", .{ .materials = Material });

    var problems: Problems = .init(testing.allocator);
    defer problems.deinit();
    var b: Builder(Data) = .init(testing.allocator, &problems);
    defer b.deinit();
    // No tag kind, no tags.json: codex interns whatever strings the entries use.
    try b.addContent("core", "m.json", "m.json", "materials",
        \\[ { "name": "iron", "tags": ["metal", "heavy"] },
        \\  { "name": "mercury", "tags": ["metal", "liquid"] },
        \\  { "name": "water", "tags": ["liquid"] } ]
    );
    var data = try b.freeze(testing.allocator);
    defer data.deinit();

    const M = data.registry(Material);
    const metal = data.tag("metal").?;
    const heavy = data.tag("heavy").?;
    const liquid = data.tag("liquid").?;
    try testing.expectEqual(@as(usize, 3), data.tagCount());

    try testing.expectEqual(@as(usize, 2), M.withTag(metal).len); // iron, mercury
    const iron = M.find("core:iron").?;
    try testing.expect(M.hasTag(iron, metal));
    try testing.expect(!M.hasTag(iron, liquid));

    // metal AND NOT heavy -> mercury only
    const sel = try M.select(testing.allocator, .{ .all = &.{metal}, .none = &.{heavy} });
    defer testing.allocator.free(sel);
    try testing.expectEqual(@as(usize, 1), sel.len);
    try testing.expectEqualStrings("core:mercury", M.name(sel[0]));
}

test "against: a resource catalog resolves refs into a data catalog" {
    const f = field;
    const Material = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "material";
        pub const Raw = struct { name: f.Name, density: f.Positive(f32) };
    };
    const Look = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "look";
        pub const Raw = struct { name: f.Name, material: f.Ref(Material), color: [3]u8 };
    };
    const Data = makeCatalog("content", .{ .materials = Material });
    const Resources = makeCatalog("resources", .{ .looks = Look });

    var problems: Problems = .init(testing.allocator);
    defer problems.deinit();

    var bd: Builder(Data) = .init(testing.allocator, &problems);
    defer bd.deinit();
    try bd.addContent("core", "m.json", "m.json", "materials",
        \\[ { "name": "stone", "density": 2.5 } ]
    );
    var data = try bd.freeze(testing.allocator);
    defer data.deinit();

    var br: Builder(Resources) = .init(testing.allocator, &problems);
    defer br.deinit();
    try br.addContent("core", "l.json", "l.json", "looks",
        \\[ { "name": "stone_look", "material": "stone", "color": [128, 128, 128] } ]
    );
    var res = try br.freezeAgainst(testing.allocator, .{&data});
    defer res.deinit();

    const look = res.registry(Look).find("core:stone_look").?;
    const stone = data.registry(Material).find("core:stone").?;
    try testing.expectEqual(stone, res.registry(Look).get(look).material);
    try testing.expectEqual(@as(u8, 128), res.registry(Look).get(look).color[1]);
}

test "against: a ref with no upstream catalog is reported" {
    const f = field;
    const Material = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "material";
        pub const Raw = struct { name: f.Name };
    };
    const Look = struct {
        pub const ID = enum(u16) { _ };
        pub const label = "look";
        pub const Raw = struct { name: f.Name, material: f.Ref(Material) };
    };
    const Resources = makeCatalog("resources", .{ .looks = Look });

    var problems: Problems = .init(testing.allocator);
    defer problems.deinit();
    var br: Builder(Resources) = .init(testing.allocator, &problems);
    defer br.deinit();
    try br.addContent("core", "l.json", "l.json", "looks",
        \\[ { "name": "x", "material": "stone" } ]
    );
    try testing.expectError(error.InvalidCatalog, br.freeze(testing.allocator));
    try testing.expect(problems.count() >= 1);
}
