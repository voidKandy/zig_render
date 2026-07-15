const std = @import("std");
const core = @import("../root.zig");
const Mesh3D = core.lib.mesh.Mesh3D;
const Vertex3D = core.lib.mesh.Vertex3D;
const Vec4 = core.lib.math.Vec4;
const Vec2 = core.lib.math.Vec2;

fn sampleHeight(px: [*c]u8, iw: u32, ih: u32, u: f32, v: f32) f32 {
    const x: u32 = @intFromFloat(
        @min(
            u * @as(f32, @floatFromInt(iw)),
            @as(f32, @floatFromInt(iw - 1)),
        ),
    );
    const y: u32 = @intFromFloat(
        @min(
            v * @as(f32, @floatFromInt(ih)),
            @as(f32, @floatFromInt(ih - 1)),
        ),
    );
    const byte = px[y * iw + x];
    return @as(f32, @floatFromInt(byte)) / 255.0;
}

pub fn fromHeightmap(
    a: std.mem.Allocator,
    image_path: []const u8,
    width_verts: u32, // number of vertices along X
    depth_verts: u32, // number of vertices along Z
    height_scale: f32, // max height in world units
    world_size: f32, // total size of terrain in world units
) std.mem.Allocator.Error!Mesh3D {
    // load the heightmap
    var width: c_int = undefined;
    var height: c_int = undefined;
    var channels: c_int = undefined;

    var path_buf: [512]u8 = undefined;
    const pathz = std.fmt.bufPrintZ(&path_buf, "{s}", .{image_path}) catch @panic("Failed to buf print");

    const pixels = core.clibs.stbi.load(pathz.ptr, &width, &height, &channels, 1) // force grayscale
        orelse @panic("failed to load heightmap");
    defer core.clibs.stbi.image_free(pixels);

    const img_w: u32 = @intCast(width);
    const img_h: u32 = @intCast(height);

    // sample heightmap at normalized UV

    var vertices = try std.ArrayList(Vertex3D).initCapacity(a, width_verts * depth_verts);
    var indices = try std.ArrayList(u32).initCapacity(a, (width_verts - 1) * (depth_verts - 1) * 6);

    // generate vertices
    for (0..depth_verts) |zi| {
        for (0..width_verts) |xi| {
            const u = @as(f32, @floatFromInt(xi)) / @as(f32, @floatFromInt(width_verts - 1));
            const v = @as(f32, @floatFromInt(zi)) / @as(f32, @floatFromInt(depth_verts - 1));

            const x = (u - 0.5) * world_size;
            const z = (v - 0.5) * world_size;
            const y = sampleHeight(pixels, img_w, img_h, u, v) * height_scale;

            try vertices.append(a, Vertex3D{
                .position = Vec4.make(x, y, z, 0.0),
                .normal = Vec4.make(0, 1, 0, 0), // flat normal for now
                .color = Vec4.ZERO,
                .uv = Vec2.make(u, v),
            });
        }
    }

    // generate indices (two triangles per quad)
    for (0..depth_verts - 1) |zi| {
        for (0..width_verts - 1) |xi| {
            const tl: u32 = @intCast(zi * width_verts + xi);
            const tr: u32 = tl + 1;
            const bl: u32 = @intCast((zi + 1) * width_verts + xi);
            const br: u32 = bl + 1;

            // triangle 1
            try indices.append(a, tl);
            try indices.append(a, bl);
            try indices.append(a, tr);

            // triangle 2
            try indices.append(a, tr);
            try indices.append(a, bl);
            try indices.append(a, br);
        }
    }

    return Mesh3D{
        .vertices = try vertices.toOwnedSlice(a),
        .indices = try indices.toOwnedSlice(a),
    };
}
