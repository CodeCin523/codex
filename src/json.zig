//! Parsing pack files (JSON) into the `Raw` structs, with readable problems.

const std = @import("std");
const Problems = @import("Problems.zig");

/// Parses `text` as a `T`, allocating with `arena`. On failure, records a problem with the line
/// and column, and returns null.
pub fn parse(comptime T: type, arena: std.mem.Allocator, text: []const u8, path: []const u8, problems: *Problems) !?T {
    var scanner: std.json.Scanner = .initCompleteInput(arena, text);
    defer scanner.deinit();
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);

    return std.json.parseFromTokenSourceLeaky(T, arena, &scanner, .{ .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const line = diagnostics.getLine();
        const column = diagnostics.getColumn();
        try problems.add(path, "", "line {d}, column {d}: {s}\n    {s}", .{ line, column, describe(err), lineAt(text, diagnostics.getByteOffset()) });
        return null;
    };
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownField => "unknown field (a typo, or a field this kind does not have)",
        error.MissingField => "a required field is missing",
        error.DuplicateField => "the same field is written twice",
        error.UnexpectedToken => "unexpected value (wrong type, e.g. a string where a number goes)",
        error.SyntaxError => "not valid JSON",
        error.UnexpectedEndOfInput => "the file ends too early",
        error.InvalidNumber, error.InvalidCharacter => "not a valid number",
        error.Overflow => "the number is too large for this field",
        error.InvalidEnumTag => "not one of the allowed values",
        error.LengthMismatch => "wrong number of elements",
        else => @errorName(err),
    };
}

/// The line of `text` containing byte `offset`, to show where the problem is.
fn lineAt(text: []const u8, offset: u64) []const u8 {
    const at: usize = @min(@as(usize, @intCast(offset)), text.len);
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |i| i + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    return std.mem.trim(u8, text[start..end], " \t\r");
}


// ================================================================================ //
// = TESTS                                                                        = //
// ================================================================================ //

test "parses a struct, reports a bad field" {
    const Thing = struct { name: []const u8, level: u8 = 1 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var problems: Problems = .init(std.testing.allocator);
    defer problems.deinit();

    const ok = try parse(Thing, a, "{ \"name\": \"stone\", \"level\": 4 }", "f.json", &problems);
    try std.testing.expect(ok != null);
    try std.testing.expectEqualStrings("stone", ok.?.name);
    try std.testing.expectEqual(@as(u8, 4), ok.?.level);
    try std.testing.expectEqual(@as(usize, 0), problems.count());

    const bad = try parse(Thing, a, "{ \"name\": 7 }", "f.json", &problems);
    try std.testing.expectEqual(@as(?Thing, null), bad);
    try std.testing.expectEqual(@as(usize, 1), problems.count());
}
