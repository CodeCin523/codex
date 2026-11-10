# codex

A tiny Zig library for defining game content in JSON **packs**: declarative, validated, merged
across packs, and frozen into read-only tables you look up by ID.

## Install

```sh
zig fetch --save git+https://github.com/CodeCin523/codex.git
```

Then in `build.zig`:

```zig
const codex = b.dependency("codex", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("codex", codex.module("codex"));
```

## Example

A pack on disk (`packs/core/`):

```jsonc
// pack.json
{ "id": "core", "version": "1.0.0",
  "content": { "materials": ["/materials.json"] } }

// materials.json  — tags are just strings; codex collects them, no tag file to maintain
[ { "name": "iron",  "density": 7.8, "tags": ["metal"] },
  { "name": "water", "density": 1.0, "tags": ["liquid"] } ]
```

Using it:

```zig
const std = @import("std");
const codex = @import("codex");
const f = codex.field;

// A content type is a struct: an `ID`, and a `Raw` whose fields are `codex.field.*` types.
const Material = struct {
    pub const ID = enum(u16) { _ };
    pub const Raw = struct {
        name: []const u8, // the entry key
        density: f.Positive(f32), // a JSON number, checked > 0
        tags: f.Tags, // free-form strings; codex interns them + builds a search index
    };
};

// A catalog is the set of kinds loaded from one `pack.json` section (here, "content").
const Data = codex.Catalog("content", .{ .materials = Material });

pub fn main(init: std.process.Init) !void {
    const gpa, const io = .{ init.gpa, init.io };

    var problems: codex.Problems = .init(gpa);
    defer problems.deinit();

    var packs = try codex.Packs.discover(gpa, io, "packs", &problems);
    defer packs.deinit(io);

    var data = codex.load(Data, gpa, io, &packs, &problems) catch {
        problems.logAll(); // every error in the packs, reported at once
        return;
    };
    defer data.deinit();

    const materials = data.registry(Material);

    // Look an entry up by its full name, then read a resolved field.
    const iron = materials.find("core:iron").?;
    std.debug.print("iron density = {d}\n", .{materials.get(iron).density});

    // Query by tag (codex interned "metal" from the entries).
    const metal = data.tag("metal").?;
    for (materials.withTag(metal)) |id| {
        std.debug.print("metal: {s}\n", .{materials.name(id)});
    }
}
```
