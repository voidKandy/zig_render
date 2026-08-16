const std = @import("std");
const core = @import("../root.zig");
/// TODO REORGANIZE
/// This stuff is for the ECS
pub const Mesh3DComponent = struct {
    handle: core.resources.Meshes3D.MeshHandle,
    // metadatas: []const core.resources.Meshes3D.MetaData,
    scale_factor: f32 = 1.0,
};
// pub const Mesh2DComponent = struct {
//     handle: core.resources.Meshes2D.MeshHandle,
// metadatas: []const core.resources.Meshes2D.MetaData,
// };
pub const GameWorld =
    core.lib.ecs.EntityStore(.{
        .max_entities = 64,
        .components = struct {
            camera: core.engine.Camera,
            mesh3D: Mesh3DComponent,
            // mesh2D: Mesh2DComponent,
        },
    });
