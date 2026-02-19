/// This module is a consumer of the `src` library
/// it is also kind of a mess of dependency cycles
/// nothing inside it leaks to the core engine, but many of these leak into
/// each other
/// which suggests misuse or some design flaw
pub const Triangle = @import("pipelines/Triangle.zig");
pub const BackgroundEffects = @import("pipelines/BackgroundEffects.zig");
pub const Scene3D = @import("pipelines/Scene3D.zig");
pub const Camera = @import("Camera.zig");
