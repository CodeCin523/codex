//! Names of catalog entries: `package:thing`.
//!
//! The only rule is the colon: exactly one, with something on both sides. Case and style are up to
//! each pack. Inside a pack, a name without a colon means "in this package", so `stone` written in
//! package `base` is `base:stone`.

const std = @import("std");

pub const separator = ':';

/// The two halves of a full name.
pub const Parts = struct {
    package: []const u8,
    thing: []const u8,
};

/// Splits a full name. Only valid on names that passed `check`.
pub fn split(full: []const u8) Parts {
    const at = std.mem.indexOfScalar(u8, full, separator).?;
    return .{ .package = full[0..at], .thing = full[at + 1 ..] };
}

/// Why `name` is not a valid full name, or null if it is.
pub fn check(full: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, full, separator) orelse return "has no ':' between package and name";
    if (std.mem.indexOfScalarPos(u8, full, first + 1, separator) != null) return "has more than one ':'";
    if (first == 0) return "has nothing before the ':' (the package)";
    if (first == full.len - 1) return "has nothing after the ':' (the name)";
    return null;
}

/// Why `package` is not a valid package name, or null if it is.
pub fn checkPackage(package: []const u8) ?[]const u8 {
    if (package.len == 0) return "is empty";
    if (std.mem.indexOfScalar(u8, package, separator) != null) return "contains ':'";
    return null;
}

/// `name` as a full name: unchanged if it already names a package, `package:name` otherwise.
/// The result may be `name` itself, or allocated with `allocator`.
pub fn qualify(allocator: std.mem.Allocator, package: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, separator) != null) return name;
    return std.mem.concat(allocator, u8, &.{ package, &.{separator}, name });
}


// ================================================================================ //
// = TESTS                                                                        = //
// ================================================================================ //

test check {
    try std.testing.expectEqual(null, check("base:stone"));
    try std.testing.expectEqual(null, check("my_pack:IronOre"));
    try std.testing.expect(check("stone") != null);
    try std.testing.expect(check(":stone") != null);
    try std.testing.expect(check("base:") != null);
    try std.testing.expect(check("a:b:c") != null);
}

test qualify {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("base:stone", try qualify(a, "base", "stone"));
    try std.testing.expectEqualStrings("other:stone", try qualify(a, "base", "other:stone"));
    const parts = split("base:stone");
    try std.testing.expectEqualStrings("base", parts.package);
    try std.testing.expectEqualStrings("stone", parts.thing);
}
