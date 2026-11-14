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
{ "name": "core", "version": "1.0.0",
  "content": { "materials": ["/materials.json"] } }

// materials.json: tags are just strings; codex collects them, no tag file to maintain
[ { "name": "iron",  "tags": ["metal"],  "density": 7.8 },
  { "name": "water", "tags": ["liquid"], "density": 1.0 } ]
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
        name: f.Name, // the entry key (every kind needs exactly one f.Name)
        tags: f.Tags, // free-form strings; codex interns them + builds a search index
        density: f.Positive(f32), // a JSON number, checked > 0
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

## Field defaults

A `Raw` field with a Zig default is optional in JSON: omit it in an entry and the default is used.
Write the default on a wrapped field with `.of`.

```zig
pub const Raw = struct {
    name: f.Name,
    density: f.Positive(f32) = .of(1.0),
    label: f.String = .of("unnamed"),
};
```

```jsonc
// both entries are valid; "stone" takes the defaults density=1.0 and label="unnamed"
[ { "name": "iron", "density": 7.8, "label": "Iron" },
  { "name": "stone" } ]
```

## Reserved ids

A kind can reserve ids the game owns, such as a `none` or `air` sentinel, as named members of its
`ID`. codex keeps those slots stable and numbers pack entries after them, so `none` is `0` whatever
packs load.

```zig
const Material = struct {
    pub const ID = enum(u16) { none = 0, air = 1, _ }; // 0, 1 are the game's; pack entries start at 2
    pub const Raw = struct {
        name: f.Name,
        tags: f.Tags,
        density: f.Positive(f32) = .of(1.0),
    };
    // Optional placeholder values, as a plain comptime struct: set only the fields that differ
    // (plain values, codex wraps them), or omit a member for all-defaults.
    pub const reserved = .{
        .none = .{},
        .air = .{ .density = 0.001, .tags = &.{"gas"} },
    };
};
```

```zig
const materials = data.registry(Material);

const air = materials.find("air").?; // find a reserved id by its member name
std.debug.print("{s} = {d}\n", .{ materials.name(air), materials.get(air).density }); // air = 0.001

for (materials.withTag(data.tag("gas").?)) |id| std.debug.print("gas: {s}\n", .{materials.name(id)}); // gas: air

// get(id) never faults, so a sentinel id is safe to read even with no pack loaded:
//   const m = materials.get(voxel.material); // voxel.material may be .none or .air

// count() and at(i) include reserved slots (reserved first). Skip them with isReserved:
for (0..materials.count()) |i| {
    const id = materials.at(i);
    if (materials.isReserved(id)) continue; // drop to pack-loaded entries only
    std.debug.print("{s}\n", .{materials.name(id)});
}
```
