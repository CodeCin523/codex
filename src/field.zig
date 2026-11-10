//! field: typed building blocks used *inside* a kind's `Raw` struct. Each one declares how it parses
//! from JSON, the type it resolves to in `Def`, and (for the validating ones) how to check itself.
//!
//! A field type `F` carries:
//!     is_codex_field   marker the Def-generator looks for
//!     Resolved         the type it becomes in `Def`
//!     jsonParse        so std.json reads it like its underlying value
//!     invalid          null if valid, else a human reason (the generator adds the field + value)
//!     get              the resolved value for `Def`
//!
//! Merge is NOT here — overriding is a kind-level concern (see DESIGN.md). These are only meaningful
//! inside a `Raw`; the top-level constructs (Catalog, discover) live elsewhere, so the namespace
//! keeps them visibly apart.

const std = @import("std");
const tags = @import("tags.zig");

/// A scalar `T` that must be strictly greater than zero.
pub fn Positive(comptime T: type) type {
    return Checked(T, struct {
        fn ok(v: T) bool {
            return v > 0;
        }
        const reason = "must be greater than 0";
    });
}

/// A scalar `T` that must be zero or more.
pub fn NonNegative(comptime T: type) type {
    return Checked(T, struct {
        fn ok(v: T) bool {
            return v >= 0;
        }
        const reason = "must be 0 or more";
    });
}

/// A scalar `T` that must lie within `[lo, hi]` (inclusive).
pub fn Range(comptime T: type, comptime lo: T, comptime hi: T) type {
    return Checked(T, struct {
        fn ok(v: T) bool {
            return v >= lo and v <= hi;
        }
        const reason = std.fmt.comptimePrint("must be between {d} and {d}", .{ lo, hi });
    });
}

/// A scalar `T` validated by `Rule.ok`, resolving to a bare `T` in `Def`. `Rule` is a struct with
/// `fn ok(T) bool` and `const reason: []const u8`.
fn Checked(comptime T: type, comptime Rule: type) type {
    return struct {
        const Self = @This();

        pub const is_codex_field = {};
        pub const Resolved = T;

        value: T,

        /// std.json reads this exactly like a bare `T`.
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            return .{ .value = try std.json.innerParse(T, allocator, source, options) };
        }

        /// Null if valid, else a human reason. The generator prefixes the field name and appends the
        /// offending value, so the reason stays short and value-free.
        pub fn invalid(self: Self) ?[]const u8 {
            return if (Rule.ok(self.value)) null else Rule.reason;
        }

        /// The resolved value, for `Def`.
        pub fn get(self: Self) T {
            return self.value;
        }

        /// Validate (reporting through `r` on failure) and return the value. `r` prepends the
        /// current entry and field, so the reason stays short and value-free here.
        pub fn resolve(self: Self, r: anytype) !T {
            if (!Rule.ok(self.value)) try r.fail("{s}, got {d}", .{ Rule.reason, self.value });
            return self.value;
        }
    };
}


/// UTF-8 text. Use this instead of a bare `[]const u8`, which is a compile error inside a `Raw`.
pub const String = struct {
    pub const is_codex_field = {};
    pub const Resolved = []const u8;

    value: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !String {
        return .{ .value = try std.json.innerParse([]const u8, allocator, source, options) };
    }

    pub fn get(self: String) []const u8 {
        return self.value;
    }

    pub fn invalid(self: String) ?[]const u8 {
        _ = self;
        return null;
    }

    pub fn resolve(self: String, r: anytype) ![]const u8 {
        return r.string(self.value);
    }
};

/// Raw bytes, written as a base64 string in JSON.
pub const Bytes = struct {
    pub const is_codex_field = {};
    pub const Resolved = []const u8;

    value: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Bytes {
        const text = try std.json.innerParse([]const u8, allocator, source, options);
        const decoder = std.base64.standard.Decoder;
        const n = decoder.calcSizeForSlice(text) catch return error.UnexpectedToken;
        const out = try allocator.alloc(u8, n);
        decoder.decode(out, text) catch return error.UnexpectedToken;
        return .{ .value = out };
    }

    pub fn get(self: Bytes) []const u8 {
        return self.value;
    }

    pub fn resolve(self: Bytes, r: anytype) ![]const u8 {
        return r.string(self.value);
    }
};

/// A reference to an entry of `Kind`, written as its name and resolved to `Kind.ID`.
pub fn Ref(comptime Kind: type) type {
    return struct {
        pub const is_codex_field = {};
        pub const Resolved = Kind.ID;
        /// The referenced kind, so the resolver knows where to look the name up.
        pub const ref_kind = Kind;

        /// The name as written; turned into an ID at resolve time.
        name: []const u8,

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            return .{ .name = try std.json.innerParse([]const u8, allocator, source, options) };
        }

        pub fn resolve(self: @This(), r: anytype) !Kind.ID {
            return r.ref(Kind, self.name);
        }
    };
}

/// Free-form string tags on an entry. codex interns them per catalog and builds a search index; the
/// app declares no tag kind and packs list no tags. Resolves to `[]const codex.tags.Id`.
pub const Tags = struct {
    pub const is_codex_field = {};
    /// Marker: this field is the kind's tag set (the registry builds its index over it).
    pub const is_tags = {};
    pub const Resolved = []const tags.Id;

    names: []const []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Tags {
        return .{ .names = try std.json.innerParse([]const []const u8, allocator, source, options) };
    }

    pub fn resolve(self: Tags, r: anytype) ![]const tags.Id {
        const out = try r.allocator.alloc(tags.Id, self.names.len);
        for (self.names, out) |nm, *o| o.* = try r.tag(nm);
        return out;
    }
};


/// A sandboxed, pack-relative file path, normalized at resolve time to a path relative to the pack
/// root. `/` is the pack root; `./`/`../` is relative to the file declaring it. Bare paths, `\`,
/// uppercase, and escapes past the root are rejected. (Filesystem existence and symlinks are checked
/// when the asset is opened, against the pack's bounded directory — not here.)
pub const Path = struct {
    pub const is_codex_field = {};
    pub const Resolved = []const u8;

    raw: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Path {
        return .{ .raw = try std.json.innerParse([]const u8, allocator, source, options) };
    }

    pub fn resolve(self: Path, r: anytype) ![]const u8 {
        return r.resolvePath(self.raw);
    }
};


// ================================================================================ //
// = TESTS                                                                        = //
// ================================================================================ //

const testing = std.testing;

fn parse(comptime T: type, a: std.mem.Allocator, text: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, text, .{});
}

test "scalar fields parse from JSON and unwrap" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Raw = struct {
        density: Positive(f32),
        flow: Range(f32, 0, 1),
        offset: NonNegative(i32),
    };

    const raw = try parse(Raw, a, "{ \"density\": 2.5, \"flow\": 0.3, \"offset\": 4 }");
    try testing.expectEqual(@as(f32, 2.5), raw.density.get());
    try testing.expectEqual(@as(f32, 0.3), raw.flow.get());
    try testing.expectEqual(@as(i32, 4), raw.offset.get());
}

test "validators accept and reject" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Raw = struct {
        density: Positive(f32),
        flow: Range(f32, 0, 1),
    };

    const ok = try parse(Raw, a, "{ \"density\": 1.0, \"flow\": 1.0 }");
    try testing.expectEqual(@as(?[]const u8, null), ok.density.invalid());
    try testing.expectEqual(@as(?[]const u8, null), ok.flow.invalid());

    const bad = try parse(Raw, a, "{ \"density\": 0.0, \"flow\": 2.0 }");
    try testing.expectEqualStrings("must be greater than 0", bad.density.invalid().?);
    try testing.expectEqualStrings("must be between 0 and 1", bad.flow.invalid().?);
}

test "Def-generator marker and Resolved type" {
    try testing.expect(@hasDecl(Positive(f32), "is_codex_field"));
    try testing.expectEqual(f32, Positive(f32).Resolved);
    try testing.expectEqual(i32, NonNegative(i32).Resolved);

    const Trauma = struct {
        pub const ID = enum(u16) { _ };
    };
    try testing.expectEqual(Trauma.ID, Ref(Trauma).Resolved);
    try testing.expectEqual([]const tags.Id, Tags.Resolved);
    try testing.expectEqual([]const u8, String.Resolved);
    try testing.expectEqual([]const u8, Bytes.Resolved);
}

test "String, Ref, Tags, Bytes parse from JSON" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Trauma = struct {
        pub const ID = enum(u16) { _ };
    };
    const Raw = struct {
        label: String,
        trauma: Ref(Trauma),
        tags: Tags,
        data: Bytes,
    };
    const r = try parse(Raw, a,
        \\{ "label": "iron", "trauma": "core:burn", "tags": ["a", "b"], "data": "aGk=" }
    );
    try testing.expectEqualStrings("iron", r.label.get());
    try testing.expectEqualStrings("core:burn", r.trauma.name);
    try testing.expectEqual(@as(usize, 2), r.tags.names.len);
    try testing.expectEqualStrings("b", r.tags.names[1]);
    try testing.expectEqualStrings("hi", r.data.get());
}
