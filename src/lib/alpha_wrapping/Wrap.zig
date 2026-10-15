const std = @import("std");
const shared = @import("shared.zig");
const core = @import("../../root.zig");
const math_mod = core.lib.math;
const mesh_mod = core.lib.mesh;
const Allocator = std.mem.Allocator;
const Delaunay = core.lib.alpha_wrapping.Delaunay;
const Oracle = core.lib.alpha_wrapping.Oracle;
const Vec3 = shared.Vec3;

const Mesh = struct {
    vertices: std.ArrayListUnmanaged(Vec3),
    faces: std.ArrayListUnmanaged([3]u32),
};

const WrapParams = struct {
    alpha: f64 = 0,
    offset: f64 = 0,
    manifold: bool = true,
};

const WrapStats = struct {
    steiner_points: u32 = 0,
    rule1: u32 = 0,
    rule2: u32 = 0,
    carved: u32 = 0,
    gates_popped: u32 = 0,
    manifold_cells_reclaimed: u32 = 0,
    output_vertices: u32 = 0,
    output_faces: u32 = 0,
};

const Label = enum(u8) {
    inside = 0,
    outside = 1,
    manifold = 2,
};

oracle: Oracle,
dt: Delaunay,
label: std.ArrayListUnmanaged(u8),
params: WrapParams,
stats: WrapStats,
alpha2: f64 = 0.0,
first_real_vertex: Delaunay.VertexId = 0, // ids < this are super/bbox scaffolding
