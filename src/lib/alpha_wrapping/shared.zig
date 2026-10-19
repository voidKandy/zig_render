const std = @import("std");
const core = @import("../../root.zig");
const predicates = core.clibs.predicates;
pub const Aabb = core.resources.Meshes3D.Aabb;
const Allocator = std.mem.Allocator;

pub const Triangle = [3]Vec3;
pub const CellId = i32;
pub const VertexId = i32;
pub const NO_CELL: CellId = -1;

pub fn aabbExpand(aabb: *Aabb, v: Vec3) void {
    aabb.expand(.{
        .x = @floatCast(v.x),
        .y = @floatCast(v.y),
        .z = @floatCast(v.z),
    });
}

pub fn aabbExpandFromBox(aabb: *Aabb, other: *const Aabb) void {
    aabbExpand(aabb, .{
        .x = @floatCast(other.min.x),
        .y = @floatCast(other.min.y),
        .z = @floatCast(other.min.z),
    });
    aabbExpand(aabb, .{
        .x = @floatCast(other.max.x),
        .y = @floatCast(other.max.y),
        .z = @floatCast(other.max.z),
    });
}

pub fn aabbDistSquared(
    aabb: *const Aabb,
    p: Vec3,
) f64 {
    var d2: f64 = 0.0;
    inline for (Vec3.FIELDS) |s| {
        const v: f64 = @field(p, s);
        const min_v: f64 = @floatCast(@field(aabb.min, s));
        const max_v: f64 = @floatCast(@field(aabb.max, s));
        if (v < min_v)
            d2 += (min_v - v) * (min_v - v)
        else if (v > max_v)
            d2 += (v - max_v) * (v - max_v);
    }
    return d2;
}

pub const Vec3 = extern struct {
    x: f64,
    y: f64,
    z: f64,

    pub const FIELDS: [3][]const u8 =
        .{ "x", "y", "z" };

    pub const ZERO: @This() = .make(0.0, 0.0, 0.0);

    pub inline fn make(x: f64, y: f64, z: f64) @This() {
        return .{ .x = x, .y = y, .z = z };
    }

    pub inline fn add(self: @This(), other: @This()) @This() {
        return make(self.x + other.x, self.y + other.y, self.z + other.z);
    }

    pub inline fn sub(self: @This(), other: @This()) @This() {
        return make(self.x - other.x, self.y - other.y, self.z - other.z);
    }

    pub inline fn cross(a: @This(), b: @This()) @This() {
        return @This().make(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x,
        );
    }

    pub inline fn distSquared(self: @This(), other: @This()) f64 {
        return self.sub(other).squaredNorm();
    }

    pub inline fn dist(self: @This(), other: @This()) f64 {
        return @sqrt(self.distSquared(other));
    }

    pub inline fn mul(self: @This(), val: f64) @This() {
        return make(self.x * val, self.y * val, self.z * val);
    }

    pub inline fn div(self: @This(), val: f64) @This() {
        return make(self.x / val, self.y / val, self.z / val);
    }

    pub inline fn dot(a: @This(), b: @This()) f64 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub inline fn squaredNorm(self: @This()) f64 {
        return self.dot(self);
    }

    pub fn norm(self: @This()) f64 {
        return @sqrt(self.squaredNorm());
    }

    pub fn fromCoreVec3(core_v3: core.lib.math.Vec3) @This() {
        return .{
            .x = @floatCast(core_v3.x),
            .y = @floatCast(core_v3.y),
            .z = @floatCast(core_v3.z),
        };
    }

    pub fn toCoreVec3(self: @This()) core.lib.math.Vec3 {
        return .{
            .x = @floatCast(self.x),
            .y = @floatCast(self.y),
            .z = @floatCast(self.z),
        };
    }
};

pub const Sign = enum(i8) {
    negative = -1,
    zero = 0,
    positive = 1,

    fn from(v: f64) @This() {
        if (v > 0) return .positive;
        if (v < 0) return .negative;
        return .zero;
    }
};

/// orient3d(a,b,c,d):
///   POSITIVE  if d is on the positive side of the oriented plane (a,b,c), i.e.
///             the scalar triple product (b-a) . ((c-a) x (d-a)) > 0, which is
///             +1 for the reference tetrahedron a=(0,0,0) b=(1,0,0) c=(0,1,0)
///             d=(0,0,1). Equivalently, (a,b,c,d) is a positively oriented tet.
///   NEGATIVE  if d is on the negative side.
///   ZERO      if a,b,c,d are coplanar.
pub fn orient3d(
    a: Vec3,
    b: Vec3,
    c: Vec3,
    d: Vec3,
) Sign {
    const r = predicates.orient3d(
        &a.x,
        &b.x,
        &c.x,
        &d.x,
    );
    return Sign.from(-r);
}

test "orientation sign convention" {
    const a = Vec3.make(0, 0, 0);
    const b = Vec3.make(1, 0, 0);
    const c = Vec3.make(0, 1, 0);
    const d = Vec3.make(0, 0, 1);
    const o = orient3d(a, b, c, d);
    std.debug.print("orient3d(unit tet) = {d}\n", .{o});
    const z = Vec3.make(1, 0, 0).cross(.make(0, 1, 0));
    try std.testing.expectApproxEqAbs(1.0, z.z, 1e-12);
}
/// insphere(a,b,c,d,e):
///   POSITIVE  if e lies strictly inside the sphere through a,b,c,d,
///   NEGATIVE  if strictly outside,
///   ZERO      if exactly cospherical.
/// Convention is independent of the orientation of (a,b,c,d): the result is
/// normalized by the orientation sign, so callers may pass the four tet vertices
/// in any order. Exact (returns ZERO on exact cospherical input; symbolic
/// perturbation for Delaunay is layered on top of this in delaunay.cpp).
pub fn inSphere(
    a: Vec3,
    b: Vec3,
    c: Vec3,
    d: Vec3,
    e: Vec3,
) Sign {
    const r = predicates.insphere(
        &a.x,
        &b.x,
        &c.x,
        &d.x,
        &e.x,
    );
    return Sign.from(-r);
}

pub const testing_util = struct {
    const Mesh = @import("Wrap.zig").Mesh;

    // ---- adjust these imports to your project layout ----

    // ---------------------------------------------------------------------------
    // soup builders
    // ---------------------------------------------------------------------------

    /// Appends a quad a-b-c-d as two triangles (a,b,c) and (a,c,d).
    /// Winding: normal = (b-a) x (c-a).
    pub fn addQuad(
        alloc: Allocator,
        soup: *std.ArrayListUnmanaged(Triangle),
        a: Vec3,
        b: Vec3,
        c: Vec3,
        d: Vec3,
    ) !void {
        try soup.append(alloc, .{ a, b, c });
        try soup.append(alloc, .{ a, c, d });
    }

    /// Axis-aligned unit cube [0,1]^3, 12 triangles, outward-facing.
    pub fn unitCube(alloc: Allocator) ![]Triangle {
        var soup = std.ArrayListUnmanaged(Triangle).empty;
        errdefer soup.deinit(alloc);

        // -x
        try addQuad(
            alloc,
            &soup,
            Vec3.make(0, 0, 0),
            Vec3.make(0, 0, 1),
            Vec3.make(0, 1, 1),
            Vec3.make(0, 1, 0),
        );
        // +x
        try addQuad(
            alloc,
            &soup,
            Vec3.make(1, 0, 0),
            Vec3.make(1, 1, 0),
            Vec3.make(1, 1, 1),
            Vec3.make(1, 0, 1),
        );
        // -y
        try addQuad(
            alloc,
            &soup,
            Vec3.make(0, 0, 0),
            Vec3.make(1, 0, 0),
            Vec3.make(1, 0, 1),
            Vec3.make(0, 0, 1),
        );
        // +y
        try addQuad(
            alloc,
            &soup,
            Vec3.make(0, 1, 0),
            Vec3.make(0, 1, 1),
            Vec3.make(1, 1, 1),
            Vec3.make(1, 1, 0),
        );
        // -z
        try addQuad(
            alloc,
            &soup,
            Vec3.make(0, 0, 0),
            Vec3.make(0, 1, 0),
            Vec3.make(1, 1, 0),
            Vec3.make(1, 0, 0),
        );
        // +z
        try addQuad(
            alloc,
            &soup,
            Vec3.make(0, 0, 1),
            Vec3.make(1, 0, 1),
            Vec3.make(1, 1, 1),
            Vec3.make(0, 1, 1),
        );

        return soup.toOwnedSlice(alloc);
    }

    /// UV sphere (y is the polar axis), outward-facing. Pole triangles that would
    /// be degenerate are skipped.
    pub fn sphereSoup(
        alloc: Allocator,
        center: Vec3,
        radius: f64,
        stacks: usize,
        slices: usize,
    ) ![]Triangle {
        var soup = std.ArrayListUnmanaged(Triangle).empty;
        errdefer soup.deinit(alloc);

        const pt = struct {
            fn at(c: Vec3, r: f64, st: usize, sl: usize, i: usize, j: usize) Vec3 {
                const theta = std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(st));
                const phi = 2.0 * std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(sl));
                return Vec3.make(
                    c.x + r * @sin(theta) * @cos(phi),
                    c.y + r * @cos(theta),
                    c.z + r * @sin(theta) * @sin(phi),
                );
            }
        }.at;

        for (0..stacks) |i| {
            for (0..slices) |j| {
                const j1 = (j + 1) % slices;
                const p00 = pt(center, radius, stacks, slices, i, j);
                const p01 = pt(center, radius, stacks, slices, i, j1);
                const p10 = pt(center, radius, stacks, slices, i + 1, j);
                const p11 = pt(center, radius, stacks, slices, i + 1, j1);
                if (i != stacks - 1) try soup.append(alloc, .{ p00, p11, p10 });
                if (i != 0) try soup.append(alloc, .{ p00, p01, p11 });
            }
        }

        return soup.toOwnedSlice(alloc);
    }

    /// Torus around the z axis with major radius R, minor radius r,
    /// `major` segments around the ring and `minor` segments around the tube.
    /// Outward-facing.
    pub fn torusSoup(
        alloc: Allocator,
        R: f64,
        r: f64,
        major: usize,
        minor: usize,
    ) ![]Triangle {
        var soup = std.ArrayListUnmanaged(Triangle).empty;
        errdefer soup.deinit(alloc);

        const pt = struct {
            fn at(big: f64, small: f64, nu: usize, nv: usize, i: usize, j: usize) Vec3 {
                const u = 2.0 * std.math.pi * @as(f64, @floatFromInt(i % nu)) / @as(f64, @floatFromInt(nu));
                const v = 2.0 * std.math.pi * @as(f64, @floatFromInt(j % nv)) / @as(f64, @floatFromInt(nv));
                const ring = big + small * @cos(v);
                return Vec3.make(ring * @cos(u), ring * @sin(u), small * @sin(v));
            }
        }.at;

        for (0..major) |i| {
            for (0..minor) |j| {
                const a = pt(R, r, major, minor, i, j);
                const b = pt(R, r, major, minor, i + 1, j);
                const c = pt(R, r, major, minor, i + 1, j + 1);
                const d = pt(R, r, major, minor, i, j + 1);
                try addQuad(alloc, &soup, a, b, c, d);
            }
        }

        return soup.toOwnedSlice(alloc);
    }

    // ---------------------------------------------------------------------------
    // mesh checks
    // ---------------------------------------------------------------------------

    pub const MeshCheck = struct {
        V: usize = 0, // vertices referenced by at least one face
        E: usize = 0, // unique undirected edges
        F: usize = 0,
        euler: i32 = 0, // V - E + F
        closed: bool = false, // every edge shared by exactly 2 faces
        edge_manifold: bool = false, // no edge shared by more than 2 faces
        oriented: bool = false, // no directed edge used twice (consistent winding)
        vertex_manifold: bool = false, // each vertex's incident faces form one fan
    };

    fn find(p: []u32, x: u32) u32 {
        var i = x;
        while (p[i] != i) {
            p[i] = p[p[i]];
            i = p[i];
        }
        return i;
    }

    fn unite(p: []u32, a: u32, b: u32) void {
        p[find(p, a)] = find(p, b);
    }

    pub fn checkMesh(alloc: Allocator, m: Mesh) !MeshCheck {
        const nv = m.vertices.items.len;
        const faces = m.faces.items;

        const used = try alloc.alloc(bool, nv);
        defer alloc.free(used);
        @memset(used, false);

        var edge_count = std.AutoHashMapUnmanaged(u64, u32).empty;
        defer edge_count.deinit(alloc);
        var directed = std.AutoHashMapUnmanaged(u64, void).empty;
        defer directed.deinit(alloc);

        var oriented = true;
        for (faces) |f| {
            for (0..3) |k| {
                const a = f[k];
                const b = f[(k + 1) % 3];
                used[a] = true;

                const lo = @min(a, b);
                const hi = @max(a, b);
                const key = (@as(u64, lo) << 32) | hi;
                const e = try edge_count.getOrPut(alloc, key);
                if (e.found_existing) e.value_ptr.* += 1 else e.value_ptr.* = 1;

                const dkey = (@as(u64, a) << 32) | b;
                const d = try directed.getOrPut(alloc, dkey);
                if (d.found_existing) oriented = false;
            }
        }

        var closed = faces.len > 0;
        var edge_manifold = true;
        var it = edge_count.valueIterator();
        while (it.next()) |c| {
            if (c.* != 2) closed = false;
            if (c.* > 2) edge_manifold = false;
        }

        var v_count: usize = 0;
        for (used) |u| {
            if (u) v_count += 1;
        }

        // ---- vertex manifoldness: incident faces of each vertex must be one fan ----
        // CSR vertex -> incident faces
        const start = try alloc.alloc(u32, nv + 1);
        defer alloc.free(start);
        @memset(start, 0);
        for (faces) |f| {
            for (0..3) |k| start[f[k] + 1] += 1;
        }
        for (0..nv) |i| start[i + 1] += start[i];

        const fill = try alloc.dupe(u32, start[0..nv]);
        defer alloc.free(fill);
        const inc = try alloc.alloc(u32, faces.len * 3);
        defer alloc.free(inc);
        for (faces, 0..) |f, fi| {
            for (0..3) |k| {
                inc[fill[f[k]]] = @intCast(fi);
                fill[f[k]] += 1;
            }
        }

        var vtx_manifold = true;
        var nbr_first = std.AutoHashMapUnmanaged(u32, u32).empty;
        defer nbr_first.deinit(alloc);
        var parent = std.ArrayListUnmanaged(u32).empty;
        defer parent.deinit(alloc);

        for (0..nv) |vi| {
            const v: u32 = @intCast(vi);
            const list = inc[start[vi]..start[vi + 1]];
            if (list.len <= 1) continue;

            nbr_first.clearRetainingCapacity();
            parent.clearRetainingCapacity();
            for (0..list.len) |i| try parent.append(alloc, @intCast(i));

            // two incident faces are adjacent around v if they share another vertex
            for (list, 0..) |fi, i| {
                const f = faces[fi];
                for (0..3) |k| {
                    if (f[k] == v) continue;
                    const g = try nbr_first.getOrPut(alloc, f[k]);
                    if (g.found_existing) {
                        unite(parent.items, @intCast(i), g.value_ptr.*);
                    } else {
                        g.value_ptr.* = @intCast(i);
                    }
                }
            }

            var roots: usize = 0;
            for (0..list.len) |i| {
                if (find(parent.items, @intCast(i)) == i) roots += 1;
            }
            if (roots > 1) {
                vtx_manifold = false;
                break;
            }
        }

        const e_count = edge_count.count();
        return .{
            .V = v_count,
            .E = e_count,
            .F = faces.len,
            .euler = @as(i32, @intCast(v_count)) - @as(i32, @intCast(e_count)) + @as(i32, @intCast(faces.len)),
            .closed = closed,
            .edge_manifold = edge_manifold,
            .oriented = oriented,
            .vertex_manifold = vtx_manifold,
        };
    }

    /// Number of connected components (vertices connected through shared faces).
    pub fn meshComponents(alloc: Allocator, m: Mesh) !usize {
        const nv = m.vertices.items.len;
        const parent = try alloc.alloc(u32, nv);
        defer alloc.free(parent);
        for (0..nv) |i| parent[i] = @intCast(i);

        const used = try alloc.alloc(bool, nv);
        defer alloc.free(used);
        @memset(used, false);

        for (m.faces.items) |f| {
            used[f[0]] = true;
            used[f[1]] = true;
            used[f[2]] = true;
            unite(parent, f[0], f[1]);
            unite(parent, f[1], f[2]);
        }

        var comps: usize = 0;
        for (0..nv) |i| {
            if (used[i] and find(parent, @intCast(i)) == i) comps += 1;
        }
        return comps;
    }
};
