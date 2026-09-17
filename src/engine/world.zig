const std = @import("std");
const core = @import("../root.zig");
/// rename to materialmesh
pub const Mesh3DComponent = struct {
    mesh_index: u32,
    material_index: u32,
    // TODO REMOVE
    scale_factor: f32 = 1.0,
};

pub const Mesh2DComponent = struct {
    ranges: core.resources.Meshes2D.MeshRanges,
};

pub const Transform = struct {
    matrix: core.lib.math.Mat4 = .IDENTITY,
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
            transform: Transform,
            mesh3D: Mesh3DComponent,
            mesh2D: Mesh2DComponent,
        },
    });
