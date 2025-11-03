const std = @import("std");
const root = @import("root.zig");
const AllocatedBuffer = root.vma_usage.AllocatedBuffer;
const m3d = @import("math3d.zig");
const c = @import("clibs.zig");

const Vec2 = m3d.Vec2;
const Vec3 = m3d.Vec3;

pub const VertexInputDescription = struct {
    bindings: []const c.vk.VertexInputBindingDescription,
    attributes: []const c.vk.VertexInputAttributeDescription,

    flags: c.vk.PipelineVertexInputStateCreateFlags = 0,
};

pub const Vertex2D = struct {
    position: Vec2,
    color: Vec3,

    pub const vertex_input_description = VertexInputDescription{
        .bindings = &.{c.vk.VertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(@This()),
            .inputRate = c.vk.VERTEX_INPUT_RATE_VERTEX,
        }},

        // An attribute description struct describes how to extract a vertex attribute from a chunk of vertex data originating from a binding description.
        // We have two attributes, position and color, so we need two attribute description structs.
        .attributes = &.{
            c.vk.VertexInputAttributeDescription{
                .binding = 0,
                .location = 0,
                .format = c.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(@This(), "position"),
            },
            c.vk.VertexInputAttributeDescription{
                .binding = 0,
                .location = 1,
                .format = c.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(@This(), "color"),
            },
        },
    };
};

pub const Mesh2D = struct {
    vertices: []Vertex2D,
    vertex_buffer: AllocatedBuffer = undefined,
};

pub const Vertex3D = struct {
    position: Vec3,
    normal: Vec3,
    color: Vec3,
    uv: Vec2,

    pub const vertex_input_description = VertexInputDescription{
        .bindings = &.{
            std.mem.zeroInit(c.vk.VertexInputBindingDescription, .{
                .binding = 0,
                .stride = @sizeOf(Vertex3D),
                .inputRate = c.vk.VERTEX_INPUT_RATE_VERTEX,
            }),
        },
        .attributes = &.{
            std.mem.zeroInit(c.vk.VertexInputAttributeDescription, .{
                .location = 0,
                .binding = 0,
                .format = c.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex3D, "position"),
            }),
            std.mem.zeroInit(c.vk.VertexInputAttributeDescription, .{
                .location = 1,
                .binding = 0,
                .format = c.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex3D, "normal"),
            }),
            std.mem.zeroInit(c.vk.VertexInputAttributeDescription, .{
                .location = 2,
                .binding = 0,
                .format = c.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex3D, "color"),
            }),
            std.mem.zeroInit(c.vk.VertexInputAttributeDescription, .{
                .location = 3,
                .binding = 0,
                .format = c.vk.FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(Vertex3D, "uv"),
            }),
        },
    };
};

pub const Mesh3D = struct {
    vertices: []Vertex3D,
    vertex_buffer: AllocatedBuffer = undefined,
};

const obj_loader = @import("obj_loader.zig");

pub fn load_from_obj(a: std.mem.Allocator, filepath: []const u8) Mesh3D {
    var obj_mesh = obj_loader.parse_file(a, filepath) catch |err| {
        std.log.err("Failed to load obj file: {s}", .{@errorName(err)});
        unreachable;
    };
    defer obj_mesh.deinit();

    var vertices = std.ArrayList(Vertex3D){};

    for (obj_mesh.objects) |object| {
        var index_count: usize = 0;
        for (object.face_vertices) |face_vx_count| {
            if (face_vx_count < 3) {
                @panic("Face has fewer than 3 vertices. Not a valid polygon.");
            }

            for (0..face_vx_count) |vx_index| {
                const obj_index = object.indices[index_count];
                const pos = obj_mesh.vertices[obj_index.vertex];
                const nml = obj_mesh.normals[obj_index.normal];
                const uvs = obj_mesh.uvs[obj_index.uv];

                const vx = Vertex3D{
                    .position = Vec3.make(pos[0], pos[1], pos[2]),
                    .normal = Vec3.make(nml[0], nml[1], nml[2]),
                    .color = Vec3.make(nml[0], nml[1], nml[2]),
                    .uv = Vec2.make(uvs[0], 1.0 - uvs[1]),
                };

                // Triangulate the polygon
                if (vx_index > 2) {
                    const v0 = vertices.items[vertices.items.len - 3];
                    const v1 = vertices.items[vertices.items.len - 1];
                    vertices.append(a, v0) catch @panic("OOM");
                    vertices.append(a, v1) catch @panic("OOM");
                }

                vertices.append(a, vx) catch @panic("OOM");

                index_count += 1;
            }
        }
    }

    return Mesh3D{
        .vertices = vertices.toOwnedSlice(a) catch @panic("Failed to make owned slice"),
    };
}
