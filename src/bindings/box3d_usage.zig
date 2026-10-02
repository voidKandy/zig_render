const std = @import("std");
const core = @import("../root.zig");
const box3d = core.clibs.box3d;

pub const DebugDrawFunctions = struct {
    pub const DrawShapeFcn = *const fn (?*anyopaque, box3d.WorldTransform, box3d.HexColor, ?*anyopaque) callconv(.c) void;
    pub const DrawSegmentFcn = *const fn (box3d.Pos, box3d.Pos, box3d.HexColor, ?*anyopaque) callconv(.c) void;
    pub const DrawTransformFcn = *const fn (box3d.WorldTransform, ?*anyopaque) callconv(.c) void;
    pub const DrawPointFcn = *const fn (box3d.Pos, f32, box3d.HexColor, ?*anyopaque) callconv(.c) void;
    pub const DrawSphereFcn = *const fn (box3d.Pos, f32, box3d.HexColor, f32, ?*anyopaque) callconv(.c) void;
    pub const DrawCapsuleFcn = *const fn (box3d.Pos, box3d.Pos, f32, box3d.HexColor, f32, ?*anyopaque) callconv(.c) void;
    pub const DrawBoundsFcn = *const fn (box3d.AABB, box3d.HexColor, ?*anyopaque) callconv(.c) void;
    pub const DrawBoxFcn = *const fn (box3d.Vec3, box3d.WorldTransform, box3d.HexColor, ?*anyopaque) callconv(.c) void;
    pub const DrawStringFcn = *const fn (box3d.Pos, [*c]const u8, box3d.HexColor, ?*anyopaque) callconv(.c) void;

    draw_shape: ?DrawShapeFcn = null,
    draw_segment: ?DrawSegmentFcn = null,
    draw_transform: ?DrawTransformFcn = null,
    draw_point: ?DrawPointFcn = null,
    draw_sphere: ?DrawSphereFcn = null,
    draw_capsule: ?DrawCapsuleFcn = null,
    draw_bounds: ?DrawBoundsFcn = null,
    draw_box: ?DrawBoxFcn = null,
    draw_string: ?DrawStringFcn = null,
};

pub const DebugShapeFunctions = struct {
    pub const CreateDebugShape = *const fn (?*const box3d.DebugShape, ?*anyopaque) callconv(.c) ?*anyopaque;
    pub const DestroyDebugShape = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
    create_debug_shape: CreateDebugShape,
    destroy_debug_shape: DestroyDebugShape,
};

pub fn createMesh(
    a: std.mem.Allocator,
    meshes3D: *const core.resources.Meshes3D,
    mesh_idx: usize,
) std.mem.Allocator.Error![*]box3d.MeshData {
    const range = meshes3D.ranges.items[mesh_idx];

    var vec3s = try std.ArrayListUnmanaged(box3d.Vec3).initCapacity(a, 1024);

    for (meshes3D.vertices.items[range.vertex.offset..][0..range.vertex.range]) |vtx| {
        try vec3s.append(a, fromCoreVec3(core.lib.math.Vec3{
            .x = vtx.position.x,
            .y = vtx.position.y,
            .z = vtx.position.z,
        }));
    }

    const vertices = try vec3s.toOwnedSlice(a);

    var def = box3d.MeshDef{};
    def.triangleCount = @divTrunc(@as(c_int, @intCast(range.index.range)), 3);
    def.vertexCount = @intCast(range.vertex.range);

    def.vertices = vertices[0..range.vertex.range].ptr;
    def.indices = @as([*]i32, @ptrCast(meshes3D.indices.items[range.index.offset .. range.index.offset + range.index.range]));

    def.materialIndices = 0;
    def.useMedianSplit = false;
    def.weldTolerance = 0;
    def.weldVertices = false;

    return box3d.CreateMesh(&def, null, 0);
}

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

pub fn fromCoreVec4(v: core.lib.math.Vec4) box3d.Quat {
    return .{
        .s = v.w,
        .v = .{
            .x = v.x,
            .y = v.y,
            .z = v.z,
        },
    };
}

pub fn toCoreVec4(b3dv4: box3d.Quat) core.lib.math.Vec4 {
    return .{
        .w = b3dv4.s,
        .x = b3dv4.v.x,
        .y = b3dv4.v.y,
        .z = b3dv4.v.z,
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
