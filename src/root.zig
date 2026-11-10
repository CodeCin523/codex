//! codex: define game content in packs — declarative JSON, validated, merged across packs, and
//! frozen into a compact read-only form the game reads by ID. See DESIGN.md.
//!
//! This is the dependency-free foundation, ported from zcovetous's `src/pack`. The Catalog / kind /
//! `field` API is built on top of it.

pub const Problems = @import("Problems.zig");
pub const version = @import("version.zig");
pub const name = @import("name.zig");
pub const json = @import("json.zig");
pub const field = @import("field.zig");
pub const Def = @import("def.zig").Def;
pub const build = @import("def.zig").build;
pub const Registry = @import("registry.zig").Registry;
pub const Catalog = @import("catalog.zig").Catalog;
pub const tags = @import("tags.zig");
pub const Builder = @import("builder.zig").Builder;
pub const load = @import("builder.zig").load;
pub const loadAgainst = @import("builder.zig").loadAgainst;
pub const Packs = @import("packs.zig");

test {
    _ = @import("Problems.zig");
    _ = @import("version.zig");
    _ = @import("name.zig");
    _ = @import("json.zig");
    _ = @import("field.zig");
    _ = @import("def.zig");
    _ = @import("registry.zig");
    _ = @import("catalog.zig");
    _ = @import("builder.zig");
    _ = @import("packs.zig");
}
