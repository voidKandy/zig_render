const std = @import("std");
const core = @import("../root.zig");

pub const MaterialMesh3D = struct {
    mesh_index: u32,
    material_index: u32,

    pub fn fromNames(
        resources: core.resources.Manager,
        names: struct {
            mesh: []const u8,
            material: []const u8,
        },
    ) @This() {
        return .{
            .material_index = @intCast(resources.materials.material_indices.get(names.material) orelse @panic("NO MATERIAL WITH NAME")),
            .mesh_index = @intCast(resources.meshes3D.mesh_indices.get(names.mesh) orelse @panic("NO MESH WITH NAME")),
        };
    }
};

pub const MaterialMesh2D = struct {
    mesh_index: u32,
    material_index: u32,

    pub fn fromNames(
        resources: core.resources.Manager,
        names: struct {
            mesh: []const u8,
            material: []const u8,
        },
    ) @This() {
        return .{
            .material_index = @intCast(resources.materials.material_indices.get(names.material) orelse @panic("NO MATERIAL WITH NAME")),
            .mesh_index = @intCast(resources.meshes2D.mesh_indices.get(names.mesh) orelse @panic("NO MESH WITH NAME")),
        };
    }
};

pub const WorldTransform = struct {
    matrix: core.lib.math.Mat4 = .IDENTITY,
};

pub const ScreenTransform = struct {
    coords: core.lib.math.Vec2 = .ZERO,
};

pub const RigidBody = struct {
    id: core.clibs.box3d.BodyId,
};

pub const GameWorld =
    core.lib.ecs.EntityStore(.{
        .max_entities = 64,
        .components = struct {
            camera: core.engine.Camera,
            world_transform: WorldTransform,
            screen_transform: ScreenTransform,
            mesh3D: MaterialMesh3D,
            mesh2D: MaterialMesh2D,
            rigid_body: RigidBody,
        },
    });
