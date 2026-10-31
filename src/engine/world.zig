const std = @import("std");
const core = @import("../root.zig");
const Vec2 = core.lib.math.Vec2;
const Vec3 = core.lib.math.Vec3;
const Vec4 = core.lib.math.Vec4;
const Mat4 = core.lib.math.Mat4;

pub const MaterialMesh3D = struct {
    mesh_index: u32,
    material_index: u32,

    pub fn fromNames(
        resources: *const core.resources.Manager,
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
        resources: *const core.resources.Manager,
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
    position: Vec3 = .ZERO,
    rotation: Vec4 = .IDENTITY,
    scale: Vec3 = .ONE,

    pub fn inverseModelMatrix(self: *const @This()) Mat4 {
        const inverse_scale = Vec3.make(
            1.0 / self.scale.x,
            1.0 / self.scale.y,
            1.0 / self.scale.z,
        );

        const inverse_rotation = Vec4.make(
            -self.rotation.x,
            -self.rotation.y,
            -self.rotation.z,
            self.rotation.w,
        );

        const inverse_translation = self.position.mulScalar(-1.0);

        return Mat4.scaleMatrix(inverse_scale)
            .mul(Mat4.rotationMatrix(inverse_rotation))
            .mul(Mat4.translationMatrix(inverse_translation));
    }
};

pub const ScreenTransform = struct {
    coords: Vec2 = .ZERO,
};

pub const RigidBody = struct {
    id: core.clibs.box3d.BodyId,
};

pub const GameWorld =
    core.lib.ecs.EntityStore(.{
        .max_entities = 64,
        .components = struct {
            camera: core.engine.systems.Camera.Controller,
            world_transform: WorldTransform,
            screen_transform: ScreenTransform,
            mesh3D: MaterialMesh3D,
            mesh2D: MaterialMesh2D,
            rigid_body: RigidBody,
        },
    });
