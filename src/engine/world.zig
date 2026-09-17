const std = @import("std");
const core = @import("../root.zig");

pub const MaterialMesh3D = struct {
    mesh_index: u32,
    material_index: u32,
};

pub const Mesh2DComponent = struct {
    ranges: core.resources.Meshes2D.MeshRanges,
};

pub const Transform = struct {
    matrix: core.lib.math.Mat4 = .IDENTITY,
};

pub const RigidBody = struct {
    id: core.clibs.box3D.BodyId,
};

pub const GameWorld =
    core.lib.ecs.EntityStore(.{
        .max_entities = 64,
        .components = struct {
            camera: core.engine.Camera,
            transform: Transform,
            mesh3D: MaterialMesh3D,
            mesh2D: Mesh2DComponent,
            rigid_body: RigidBody,
        },
    });
