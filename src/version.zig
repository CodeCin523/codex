//! Pack versions (`1.2.0`, semantic versioning) and the ranges in `requires` (`>=1.0.0 <2.0.0`).
//!
//! A range is a list of conditions separated by spaces, all of which must hold. Each condition is
//! an operator (`>=`, `>`, `<=`, `<`, `=`) followed by a version; a version alone means `=`.

const std = @import("std");

pub const Version = std.SemanticVersion;

pub fn parse(text: []const u8) error{InvalidVersion}!Version {
    return Version.parse(text) catch error.InvalidVersion;
}

const Operator = enum { at_least, above, at_most, below, equal };

const operators = [_]struct { []const u8, Operator }{
    .{ ">=", .at_least },
    .{ "<=", .at_most },
    .{ ">", .above },
    .{ "<", .below },
    .{ "=", .equal },
};

/// Whether `version` is in `range`.
pub fn satisfies(version: Version, range: []const u8) error{InvalidRange}!bool {
    var any = false;
    var it = std.mem.tokenizeScalar(u8, range, ' ');
    while (it.next()) |condition| {
        any = true;
        var op: Operator = .equal;
        var rest = condition;
        for (operators) |entry| if (std.mem.startsWith(u8, condition, entry[0])) {
            op = entry[1];
            rest = condition[entry[0].len..];
            break;
        };
        const bound = Version.parse(rest) catch return error.InvalidRange;
        const order = version.order(bound);
        const ok = switch (op) {
            .at_least => order != .lt,
            .above => order == .gt,
            .at_most => order != .gt,
            .below => order == .lt,
            .equal => order == .eq,
        };
        if (!ok) return false;
    }
    if (!any) return error.InvalidRange;
    return true;
}


// ================================================================================ //
// = TESTS                                                                        = //
// ================================================================================ //

test satisfies {
    const v = try parse("1.2.0");
    try std.testing.expect(try satisfies(v, ">=0.0.0"));
    try std.testing.expect(try satisfies(v, ">=1.0.0 <2.0.0"));
    try std.testing.expect(try satisfies(v, "1.2.0"));
    try std.testing.expect(try satisfies(v, "=1.2.0"));
    try std.testing.expect(!try satisfies(v, ">1.2.0"));
    try std.testing.expect(!try satisfies(v, "<1.2.0"));
    try std.testing.expect(try satisfies(v, "<=1.2.0"));
    try std.testing.expectError(error.InvalidRange, satisfies(v, ""));
    try std.testing.expectError(error.InvalidRange, satisfies(v, ">=one"));
}
