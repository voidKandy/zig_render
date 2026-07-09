const std = @import("std");
const core = @import("root.zig");
const vma_usage = core.vma_usage;
const AllocatedBuffer = vma_usage.AllocatedBuffer;
const checkVk = core.vulkan_init.checkVk;
const m3d = @import("math3d.zig");
const c = @import("clibs.zig");
const vk = c.vk;
const log = std.log.scoped(.mesh);

const Vec2 = m3d.Vec2;
const Vec3 = m3d.Vec3;
const Vec4 = m3d.Vec4;

pub const Vertex3D = extern struct {
    position: Vec4,
    normal: Vec4,
    color: Vec4,
    uv: Vec2,
    _: Vec2 = .ZERO,
};

/// i dont know where this should live
pub const RangeDesc = struct {
    offset: u32,
    range: u32,
};

pub const Mesh3D = struct {
    vertices: []Vertex3D,
    indices: []u32,

    pub const Buffers = struct {
        vertex: vma_usage.AllocatedBuffer = undefined,
        index: vma_usage.AllocatedBuffer = undefined,
    };

    /// vertex & index buffers are not present until `upload` method is called
    // vertex_buffer: AllocatedBuffer = undefined,
    // index_buffer: AllocatedBuffer = undefined,
    const Self = @This();

    pub fn init(a: std.mem.Allocator, vertices: []const Vertex3D, indices: []const u32) std.mem.Allocator.Error!Self {
        return .{
            .vertices = try a.dupe(Vertex3D, vertices),
            .indices = try a.dupe(u32, indices),
        };
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
    }
    const Vertex3DHash = struct {
        pub fn hash(cx: @This(), vertex: Vertex3D) u64 {
            _ = cx;
            var h: u64 = 0;
            for (std.mem.asBytes(&vertex)) |byte| {
                h = h *% 31 +% byte;
            }
            return h;
        }

        pub fn eql(cx: @This(), a: Vertex3D, b: Vertex3D) bool {
            _ = cx;
            return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
        }
    };

    pub fn fromObjFile(a: std.mem.Allocator, obj_file: core.obj_loader.ObjFile) std.mem.Allocator.Error!Self {
        if (obj_file.objects.len == 0) @panic("tried to turn an empty object into a mesh");
        if (obj_file.objects.len > 1) for (obj_file.objects) |object| {
            log.warn("multiple objects in obj file not implemented!: {s}", .{object.name});
            unreachable;
        };

        var indices = try std.ArrayList(u32).initCapacity(a, obj_file.vertices.len);
        var vertices = try std.ArrayList(Vertex3D).initCapacity(a, obj_file.vertices.len);
        var uniques = std.HashMap(
            Vertex3D,
            u32,
            Vertex3DHash,
            std.hash_map.default_max_load_percentage,
        ).init(a);
        defer uniques.deinit();
        var current_vert_idx: u32 = 0;
        const object = obj_file.objects[0];
        var face_base_idx: usize = 0;
        for (object.face_vertices) |face_vert_count| {
            if (face_vert_count == 2) {
                // line element
                for (0..2) |i| {
                    const idx = object.indices[face_base_idx + i];
                    const pos = obj_file.vertices[idx.vertex];
                    const vertex = Vertex3D{
                        .position = Vec4.make(pos[0], pos[1], pos[2], 0.0),
                        .uv = Vec2.ZERO,
                        .normal = Vec4.ZERO,
                        .color = Vec4.ZERO,
                    };
                    const entry = try uniques.getOrPut(vertex);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = current_vert_idx;
                        try vertices.append(a, vertex);
                        current_vert_idx += 1;
                    }
                    try indices.append(a, entry.value_ptr.*);
                }
            } else {
                // triangle fan
                for (0..face_vert_count - 2) |i| {
                    const tri_indices = [3]usize{
                        face_base_idx,
                        face_base_idx + i + 1,
                        face_base_idx + i + 2,
                    };
                    for (tri_indices) |fi| {
                        const idx = object.indices[fi];
                        var uv = Vec2.fromSizedArray(obj_file.uvs[idx.uv]);
                        uv.y = 1.0 - uv.y;
                        const pos = obj_file.vertices[idx.vertex];
                        const norm = obj_file.normals[idx.normal];
                        const vertex = Vertex3D{
                            .position = Vec4.make(pos[0], pos[1], pos[2], 0.0),
                            .uv = uv,
                            .normal = Vec4.make(norm[0], norm[1], norm[2], 0.0),
                            .color = Vec4.ZERO,
                        };
                        const entry = try uniques.getOrPut(vertex);
                        if (!entry.found_existing) {
                            entry.value_ptr.* = current_vert_idx;
                            try vertices.append(a, vertex);
                            current_vert_idx += 1;
                        }
                        try indices.append(a, entry.value_ptr.*);
                    }
                }
            }
            face_base_idx += face_vert_count;
        }
        return .{
            .vertices = try vertices.toOwnedSlice(a),
            .indices = try indices.toOwnedSlice(a),
        };
    }
};

pub const Vertex2D = extern struct {
    position: Vec2,
    uv: Vec2,
};

pub const Mesh2D = struct {
    vertices: []Vertex2D,
    indices: []u32,

    pub fn init(a: std.mem.Allocator, vertices: []const Vertex2D, indices: []const u32) std.mem.Allocator.Error!@This() {
        return .{
            .vertices = try a.dupe(Vertex2D, vertices),
            .indices = try a.dupe(u32, indices),
        };
    }

    pub fn deinit(self: @This(), a: std.mem.Allocator) void {
        a.free(self.vertices);
        a.free(self.indices);
    }

    /// Is NDC coordinates [-1..1]
    /// it's origin in its leftmost bottom corner
    /// input width/height are percentages of the viewport size
    pub fn ndcQuad(a: std.mem.Allocator, w: f32, h: f32) std.mem.Allocator.Error!@This() {
        const vertices = [_]Vertex2D{
            .{ .position = Vec2.make(0, 0), .uv = Vec2.make(0, 0) },
            .{ .position = Vec2.make(w, 0), .uv = Vec2.make(1, 0) },
            .{ .position = Vec2.make(w, h), .uv = Vec2.make(1, 1) },
            .{ .position = Vec2.make(0, h), .uv = Vec2.make(0, 1) },
        };
        const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
        return init(a, &vertices, &indices);
    }
};

test "meshmaze" {
    const allocator = std.testing.allocator;
    var maze = try core.Maze.init(allocator, 10, 10);
    defer maze.deinit(allocator);
    maze.generate(allocator, 16, 8);

    var mesh = try Mesh3D.fromMaze(
        allocator,
        maze,
        2.0,
        2.0,
    );
    defer mesh.deinit(allocator);
}
