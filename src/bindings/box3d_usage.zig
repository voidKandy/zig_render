const std = @import("std");
const core = @import("../root.zig");
const box3d = core.clibs.box3d;

pub fn fromCoreVec3(v: core.lib.math.Vec3) box3d.Vec3 {
    return .{
        .x = v.x,
        .y = v.y,
        .z = v.z,
    };
}

pub fn toCoreVec3(b3dv3: box3d.Vec3) core.lib.math.Vec3 {
    return .{
        .x = b3dv3.x,
        .y = b3dv3.y,
        .z = b3dv3.z,
    };
}

pub fn unpackHexColor(color: box3d.HexColor) core.lib.math.Vec4 {
    const raw: u32 = @intCast(color);
    const r: f32 = @floatFromInt((raw >> 16) & 0xFF);
    const g: f32 = @floatFromInt((raw >> 8) & 0xFF);
    const b: f32 = @floatFromInt(raw & 0xFF);
    return core.lib.math.Vec4.make(r / 255.0, g / 255.0, b / 255.0, 1.0);
}

pub fn box3DMesh(
    mesh: core.lib.mesh.Mesh3D,
    allocator: std.mem.Allocator,
) !struct {
    def: box3d.MeshDef,
    vertices: []box3d.Vec3,
    indices: []i32,
} {
    const vertices = try allocator.alloc(box3d.Vec3, mesh.vertices.len);
    errdefer allocator.free(vertices);

    for (mesh.vertices, 0..) |vertex, i| {
        vertices[i] = .{
            .x = vertex.position.x,
            .y = vertex.position.y,
            .z = vertex.position.z,
        };
    }

    const indices = try allocator.alloc(i32, mesh.indices.len);
    errdefer allocator.free(indices);

    for (mesh.indices, 0..) |index, i| {
        indices[i] = @intCast(index);
    }

    return .{
        .def = .{
            .vertices = vertices.ptr,
            .vertexCount = @intCast(vertices.len),
            .indices = indices.ptr,
            .triangleCount = @intCast(indices.len / 3),
            .useMedianSplit = true,
            .identifyEdges = true,
            .weldVertices = true,
            .weldTolerance = 0.002,
        },
        .vertices = vertices,
        .indices = indices,
    };
}

test "physics: falling body settles on ground" {
    var world_def = box3d.DefaultWorldDef();
    world_def.gravity = .{ .x = 0.0, .y = 0.0, .z = -9.8 };

    const world = box3d.CreateWorld(&world_def);
    defer box3d.DestroyWorld(world);

    // Ground
    {
        var body_def = box3d.DefaultBodyDef();
        body_def.type = box3d.BODY_TYPE_STATIC;

        const body = box3d.CreateBody(world, &body_def);

        var shape_def = box3d.DefaultShapeDef();
        const box = box3d.MakeBoxHull(20.0, 20.0, 0.5);

        _ = box3d.CreateHullShape(body, &shape_def, &box.base);
    }

    // Falling box
    const body = blk: {
        var body_def = box3d.DefaultBodyDef();
        body_def.type = box3d.BODY_TYPE_DYNAMIC;
        body_def.position = .{
            .x = 0.0,
            .y = 0.0,
            .z = 10.0,
        };

        const body = box3d.CreateBody(world, &body_def);

        var shape_def = box3d.DefaultShapeDef();
        shape_def.density = 1.0;

        const box = box3d.MakeBoxHull(0.5, 0.5, 0.5);
        _ = box3d.CreateHullShape(body, &shape_def, &box.base);

        break :blk body;
    };

    const start_z = box3d.Body_GetPosition(body).z;

    // 10 seconds at 60 Hz.
    for (0..600) |_| {
        box3d.World_Step(world, 1.0 / 60.0, 4);
    }

    const end_z = box3d.Body_GetPosition(body).z;

    std.debug.print(
        "falling body: z {d:.3} -> {d:.3}\n",
        .{ start_z, end_z },
    );

    // It definitely fell.
    try std.testing.expect(end_z < start_z);

    // It should have settled with its 1-unit-tall box
    // sitting on top of the 1-unit-thick ground.
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        end_z,
        0.1,
    );
}
