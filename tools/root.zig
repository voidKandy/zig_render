/// This module is a consumer of the `src` library
/// it is also kind of a mess of dependency cycles
/// nothing inside it leaks to the core engine, but many of these leak into
/// each other
/// which suggests misuse or some design flaw
pub const Camera = @import("Camera.zig");
