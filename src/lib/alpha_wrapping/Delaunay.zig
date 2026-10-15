const std = @import("std");
const core = @import("../../root.zig");
const predicates = core.clibs.predicates;
const shared = @import("shared.zig");
const math_mod = core.lib.math;
const mesh_mod = core.lib.mesh;
const Allocator = std.mem.Allocator;
const Vec3 = shared.Vec3;
const Aabb = shared.Aabb;
const Sign = shared.Sign;

pub const VertexId = i32;
pub const CellId = i32;
const NO_CELL: CellId = -1;

inline fn edgeKey(a: VertexId, b: VertexId) u64 {
    const lo: u64 = @intCast(@min(a, b));
    const hi: u64 = @intCast(@max(a, b));
    return (hi << 32) | lo;
}

const Cell = struct {
    vertices: [4]VertexId = .{-1} ** 4,
    cells: [4]CellId = .{NO_CELL} ** 4,
    alive: bool = false,
};

/// More or less direct Port
/// https://github.com/alecjacobson/alpha-wrap/blob/main/src/delaunay.hpp
/// https://github.com/alecjacobson/alpha-wrap/blob/main/src/delaunay.cpp
const Delaunay = @This();

points: std.ArrayListUnmanaged(Vec3) = .empty,
cells: std.ArrayListUnmanaged(Cell) = .empty,
free_cells: std.ArrayListUnmanaged(CellId) = .empty,
live_cell_count: usize = 0,
last_cell: CellId = NO_CELL, // walk hint cache
mark: std.ArrayListUnmanaged(u32) = .empty, // per-cell BFS stamp (conflict-zone)
mark_ctr: usize = 0,

const FACET: [4]Vec3 = .{
    .make(1, 2, 3), .make(0, 3, 2), .make(0, 1, 3), .make(0, 2, 1),
};

fn newCell(self: *@This(), a: Allocator) Allocator.Error!CellId {
    var id: CellId = 0;
    if (self.free_cells.items.len > 0) {
        id = self.free_cells.pop().?;
        // self.free_cells.pop_back();
    } else {
        id = @intCast(self.cells.items.len);
        try self.cells.append(a, .{});
    }
    self.cells.items[@intCast(id)].alive = true;
    self.cells.items[@intCast(id)].cells = .{ NO_CELL, NO_CELL, NO_CELL, NO_CELL };
    self.live_cell_count += 1;
    return id;
}

fn killCell(self: *@This(), a: Allocator, cell_id: CellId) Allocator.Error!void {
    self.cells.items[@intCast(cell_id)].alive = false;
    try self.free_cells.append(a, cell_id);
    self.live_cell_count -= 1;
}

// // True iff p is strictly inside cell c's circumsphere (SoS-free; ZERO -> false).
// bool in_conflict(Cid c, const Vec3& p) const;
inline fn inConflict(self: *const @This(), c: CellId, p: Vec3) bool {
    const cc = self.cells.items[@intCast(c)];
    // Strictly inside the circumsphere. Cospherical (ZERO) treated as not-in-
    // conflict for now (general-position path; SoS layered separately).
    return predicates.inSphere(
        &self.points.items[@intCast(cc.vertices[0])].x,
        &self.points.items[@intCast(cc.vertices[1])].x,
        &self.points.items[@intCast(cc.vertices[2])].x,
        &self.points.items[@intCast(cc.vertices[3])].x,
        &p.x,
    ) == @intFromEnum(Sign.positive);
}

inline fn facetIndexOfNeighbor(self: *const @This(), c: CellId, neighbor: CellId) i32 {
    const cc = self.cells.items[@intCast(c)];
    for (0..4) |i|
        if (cc.cells[i] == neighbor) return @intCast(i);
    return -1;
}

// // Build the enclosing super-tetrahedron. `domain` must contain every point
// // that will ever be inserted; the super-tet is placed `margin` box-diagonals
// // away so real points stay strictly interior.
// void init(const Box& domain, double margin = 1000.0);
fn init(
    a: Allocator,
    domain: core.resources.Meshes3D.Aabb,
    margin: f32,
) Allocator.Error!@This() {
    var self = @This(){};

    const c: Vec3 = blk: {
        if (domain.isEmpty()) break :blk .ZERO;
        const cent = domain.center();
        break :blk .make(
            @floatCast(cent.x),
            @floatCast(cent.y),
            @floatCast(cent.z),
        );
    };
    // Vec3 c = domain.empty() ? Vec3{0, 0, 0} : domain.center();
    var diag: f32 = if (domain.isEmpty()) 1.0 else domain.diagonal();
    if (diag <= 0) diag = 1.0;
    const s = margin * diag;

    // Regular tetrahedron directions (even-parity cube corners).
    const dirs: [4]Vec3 = .{
        .make(1, 1, 1),
        .make(1, -1, -1),
        .make(-1, 1, -1),
        .make(-1, -1, 1),
    };
    for (0..4) |i| try self.points.append(a, c.add(dirs[i]).mul(s));

    // // Ensure the initial cell (0,1,2,3) is positively oriented; swap if not.
    var v = [4]VertexId{ 0, 1, 2, 3 };
    if (shared.orient3d(
        self.points.items[0],
        self.points.items[1],
        self.points.items[2],
        self.points.items[3],
    ) != .positive) {
        // std::swap(v[0], v[1]);
        const temp = v[0];
        v[0] = v[1];
        v[1] = temp;
    }
    const c0: CellId = try self.newCell(a);
    self.cells.items[@intCast(c0)].vertices = v;
    self.cells.items[@intCast(c0)].cells = .{NO_CELL} ** 4;
    self.last_cell = c0;

    return self;
}

/// Insert a real point (must be strictly inside the super-tet). Returns its
/// vertex id. Duplicate points (coincident with an existing vertex) are
/// detected and return the existing id without modifying the triangulation.
/// If `new_cells` is non-null it receives the ids of cells created by this
/// insertion (empty on a duplicate).
fn insert(
    self: *@This(),
    a: Allocator,
    p: Vec3,
    out_new_cells: *std.ArrayListUnmanaged(CellId),
) Allocator.Error!VertexId {
    if (out_new_cells.items.len > 0) out_new_cells.clearRetainingCapacity();
    const c0 = self.locate(p, self.last_cell);
    // // Duplicate detection against the located cell's vertices.
    for (0..4) |i| {
        const vi = self.cells.items[@intCast(c0)].vertices[i];
        const q = self.points.items[@intCast(vi)];
        if (q.x == p.x and q.y == p.y and q.z == p.z) return vi;
    }

    const vp: VertexId = @intCast(self.points.items.len);
    try self.points.append(a, p);

    // // ---- gather conflict zone (BFS from c0) using stamps ----
    if (self.mark.items.len < self.cells.items.len) try self.mark.resize(a, self.cells.items.len + 1);
    const stamp_checked: u32 = @intCast(self.mark_ctr);
    self.mark_ctr += 1;
    const stamp_conflict: u32 = @intCast(self.mark_ctr);
    self.mark_ctr += 1;

    var conflict: std.ArrayListUnmanaged(CellId) = .empty;
    var stack: std.ArrayListUnmanaged(CellId) = .empty;

    defer {
        for (conflict.items) |c| self.killCell(a, c) catch @panic("OOM");
        conflict.deinit(a);
        stack.deinit(a);
    }
    self.mark.items[@intCast(c0)] = stamp_conflict;
    try conflict.append(a, c0);
    try stack.append(a, c0);
    while (stack.items.len > 0) {
        const c = stack.pop().?;
        //   stack.pop_back();
        for (0..4) |i| {
            const o = self.cells.items[@intCast(c)].cells[i];
            if (o == NO_CELL) continue;
            if (self.mark.items[@intCast(o)] == stamp_conflict or self.mark.items[@intCast(o)] == stamp_checked) continue;
            if (self.inConflict(o, p)) {
                self.mark.items[@intCast(o)] = stamp_conflict;
                try conflict.append(a, o);
                try stack.append(a, o);
            } else {
                self.mark.items[@intCast(o)] = stamp_checked;
            }
        }
    }

    // // ---- stellate: create new cells from boundary facets to vp ----
    var edge_map: std.AutoHashMapUnmanaged(u64, struct { CellId, usize }) = .empty;
    try edge_map.ensureTotalCapacity(a, @intCast(conflict.items.len * 3));
    var new_cells = try std.ArrayListUnmanaged(CellId).initCapacity(a, conflict.items.len * 2);

    for (conflict.items) |c| {
        for (0..4) |fi| {
            const o = self.cells.items[@intCast(c)].cells[fi];
            const boundary = (o == NO_CELL) or (self.mark.items[@intCast(o)] != stamp_conflict);
            if (!boundary) continue;

            const t0: VertexId = self.cells.items[@intCast(c)].vertices[@trunc(FACET[fi].x)];
            const t1: VertexId = self.cells.items[@intCast(c)].vertices[@trunc(FACET[fi].y)];
            const t2: VertexId = self.cells.items[@intCast(c)].vertices[@trunc(FACET[fi].z)];
            // New cell (t0,t2,t1,vp) is positively oriented (see delaunay.hpp).
            const w = try self.newCell(a);
            try new_cells.append(a, w);
            self.cells.items[@intCast(w)].vertices = .{ t0, t2, t1, vp };
            self.cells.items[@intCast(w)].cells[3] = o;
            if (o != NO_CELL) {
                const back = self.facetIndexOfNeighbor(o, c);
                self.cells.items[@intCast(o)].cells[@intCast(back)] = w;
            }
            // facet 0 opp t0 -> edge {t1,t2}; facet 1 opp t2 -> {t0,t1};
            // facet 2 opp t1 -> {t0,t2}.
            const ek: [3]u64 = .{
                edgeKey(t1, t2),
                edgeKey(t0, t1),
                edgeKey(t0, t2),
            };
            for (0..3) |lf| {
                if (edge_map.get(ek[lf])) |it| {
                    const w2: CellId = it.@"0";
                    const lf2 = it.@"1";
                    self.cells.items[@intCast(w)].cells[lf] = w2;
                    self.cells.items[@intCast(w2)].cells[lf2] = w;
                } else try edge_map.put(a, ek[lf], .{ w, lf });
            }
        }
    }

    self.last_cell = if (new_cells.items.len == 0) c0 else new_cells.getLast();
    if (out_new_cells.items.len > 0) out_new_cells.* = new_cells;
    return vp;
}

// // ---- accessors ----
// int num_vertices() const { return static_cast<int>(points_.size()); }
// int num_cells() const { return static_cast<int>(cells_.size()); }  // includes dead
// int num_live_cells() const { return live_cell_count_; }
// const Vec3& point(Vid v) const { return points_[v]; }
// const Cell& cell(Cid c) const { return cells_[c]; }
// bool cell_alive(Cid c) const { return cells_[c].alive; }

// // The 4 super-tet vertices are ids 0..3.
// bool is_super_vertex(Vid v) const { return v < 4; }
// bool cell_is_outer(Cid c) const {
//   const auto& cc = cells_[c];
//   return cc.v[0] < 4 || cc.v[1] < 4 || cc.v[2] < 4 || cc.v[3] < 4;
// }
// bool is_finite_vertex(Vid v) const { return v >= 4; }

fn det3(u: Vec3, v: Vec3, w: Vec3) f64 {
    return u.x * (v.y * w.z - v.z * w.y) - u.y * (v.x * w.z - v.z * w.x) +
        u.z * (v.x * w.y - v.y * w.x);
}
// // Cell circumcenter (inexact construction). Undefined for degenerate cells.
// Vec3 circumcenter(Cid c) const;
fn circumcenter(self: *const @This(), c: CellId) Vec3 {
    const cc = self.cells.items[@intCast(c)];
    const a = self.points.items[@intCast(cc.vertices[0])];
    const b = self.points.items[@intCast(cc.vertices[1])];
    const d = self.points.items[@intCast(cc.vertices[2])];
    const e = self.points.items[@intCast(cc.vertices[3])];
    // Solve M x' = rhs where rows of M are (b-a),(d-a),(e-a) and
    // rhs = 0.5*(|b-a|^2, |d-a|^2, |e-a|^2); circumcenter = a + x'.
    // Vec3 r0 = b - a, r1 = d - a, r2 = e - a;
    const r0, const r1, const r2 = .{
        b.sub(a),
        d.sub(a),
        e.sub(a),
    };

    const rhs = Vec3.make(
        0.5 * r0.squaredNorm(),
        0.5 * r1.squaredNorm(),
        0.5 * r2.squaredNorm(),
    );
    const det = det3(r0, r1, r2);
    if (det == 0.0) return a; // degenerate
    const invdet = 1.0 / det;
    // Cramer: replace column k of M with rhs. Column entries: col0=(r0.x,r1.x,r2.x) etc.
    const dx = det3(
        .make(rhs.x, r0.y, r0.z),
        .make(rhs.y, r1.y, r1.z),
        .make(rhs.z, r2.y, r2.z),
    );
    const dy = det3(
        .make(r0.x, rhs.x, r0.z),
        .make(r1.x, rhs.y, r1.z),
        .make(r2.x, rhs.z, r2.z),
    );
    const dz = det3(
        .make(r0.x, r0.y, rhs.x),
        .make(r1.x, r1.y, rhs.y),
        .make(r2.x, r2.y, rhs.z),
    );
    return a.add(Vec3.make(dx * invdet, dy * invdet, dz * invdet));
}
// Squared circumradius of a cell (inexact).
fn squaredCircumradius(self: *const @This(), c: CellId) f64 {
    const cc = self.circumcenter(c);
    return cc.distSquared(self.points.items[@intCast(self.cells.items[@intCast(c)].vertices[0])]);
}

// Locate the cell containing p by walking from an optional hint. Returns a
// live cell that contains p (in closure). p must be inside the super-tet.
fn locate(self: *@This(), p: Vec3, hint: CellId) CellId {
    var c = hint;
    if (c == NO_CELL or !self.cells.items[@intCast(c)].alive) c = self.last_cell;
    if (c == NO_CELL or !self.cells.items[@intCast(c)].alive) {
        for (0..self.cells.items.len) |i| {
            if (self.cells.items[@intCast(i)].alive) {
                c = @intCast(i);
                break;
            }
        }
    }
    const max_steps = 2 * self.cells.items.len + 16;
    var prev = NO_CELL;
    for (0..max_steps) |_| {
        const cc = self.cells.items[@intCast(c)];
        var next = NO_CELL;
        for (0..4) |i| {
            if (cc.cells[i] == prev) continue; // don't walk straight back
            const a = self.points.items[@intCast(cc.vertices[@trunc(FACET[i].x)])];
            const b = self.points.items[@intCast(cc.vertices[@trunc(FACET[i].y)])];
            const d = self.points.items[@intCast(cc.vertices[@trunc(FACET[i].z)])];
            // Outward triple (a,b,d): p is beyond facet i iff on its positive side.
            if (shared.orient3d(
                a,
                b,
                d,
                p,
            ) == .positive) {
                if (cc.cells[i] == NO_CELL) continue; // p outside domain across a hull face
                next = cc.cells[i];
                break;
            }
        }
        if (next == NO_CELL) {
            self.last_cell = c;
            return c; // p is inside (closure of) c
        }
        prev = c;
        c = next;
    }
    self.last_cell = c;
    return c;
}

/// panics on an OOM error
fn fail(
    a: Allocator,
    err: *std.ArrayListUnmanaged(u8),
    comptime fmt: []const u8,
    args: anytype,
) bool {
    const str =
        if (@TypeOf(args) == @TypeOf(.{}))
            fmt
        else
            std.fmt.allocPrint(a, fmt, args) catch @panic("OOM");

    err.appendSlice(a, str) catch @panic("OOM");
    return false;
}
// ---- validation (used by tests) ----
// Neighbor symmetry + each internal facet shared by two cells with matching
// vertex sets, and every live cell positively oriented.
// bool verify_topology(std::string* err = nullptr) const;
fn verifyTopology(self: *const @This(), a: Allocator, err: *std.ArrayListUnmanaged(u8)) Allocator.Error!bool {
    for (0..self.cells.items.len) |c| {
        const cc = self.cells.items[@intCast(c)];
        if (!cc.alive) continue;
        if (predicates.orient3d(
            &self.points.items[@intCast(cc.vertices[0])].x,
            &self.points.items[@intCast(cc.vertices[1])].x,
            &self.points.items[@intCast(cc.vertices[2])].x,
            &self.points.items[@intCast(cc.vertices[3])].x,
        ) != @intFromEnum(Sign.positive)) {
            return fail(a, err,
                \\ cell not positively oriented: {d}
            , .{c});
        }
        for (0..4) |i| {
            const o = cc.cells[i];
            if (o == NO_CELL) continue;
            if (!self.cells.items[@intCast(o)].alive) return fail(a, err, "neighbor dead", .{});
            const oi = self.facetIndexOfNeighbor(o, @intCast(c));
            if (oi < 0) return fail(a, err, "neighbor not symmetric", .{});
            const f: [3]VertexId = .{
                cc.vertices[@intFromFloat(FACET[i].x)],
                cc.vertices[@intFromFloat(FACET[i].y)],
                cc.vertices[@intFromFloat(FACET[i].z)],
            };
            const g: [3]VertexId = .{
                self.cells.items[@intCast(o)].vertices[@intFromFloat(FACET[@intCast(oi)].x)],
                self.cells.items[@intCast(o)].vertices[@intFromFloat(FACET[@intCast(oi)].y)],
                self.cells.items[@intCast(o)].vertices[@intFromFloat(FACET[@intCast(oi)].z)],
            };
            for (f) |fv| {
                var found = false;
                for (g) |gv| found |= (fv == gv);
                if (!found)
                    return fail(a, err,
                        \\ shared facet vertex mismatch at cell {d}
                    , .{c});
            }
        }
    }
    return true;
}
// Empty-sphere (Delaunay) property over all cells whose 4 vertices are finite.
// bool verify_delaunay(std::string* err = nullptr) const;
fn verifyDelaunay(self: *const @This(), a: Allocator, err: *std.ArrayListUnmanaged(u8)) Allocator.Error!bool {
    const nv = self.cells.items.len;
    for (0..nv) |c| {
        if (!self.cells.items[@intCast(c)].alive) continue;
        const cc = self.cells.items[@intCast(c)];
        if (cc.vertices[0] < 4 or cc.vertices[1] < 4 or cc.vertices[2] < 4 or cc.vertices[3] < 4) continue;
        for (4..nv) |q| {
            if (q == cc.vertices[0] or q == cc.vertices[1] or q == cc.vertices[2] or q == cc.vertices[3]) continue;
            if (predicates.inSphere(
                &self.points.items[@intCast(cc.vertices[0])].x,
                &self.points.items[@intCast(cc.vertices[1])].x,
                &self.points.items[@intCast(cc.vertices[2])].x,
                &self.points.items[@intCast(cc.vertices[3])].x,
                &self.points.items[@intCast(q)].x,
            ) == @intFromEnum(Sign.positive))
                return fail(a, err,
                    \\ empty-sphere violated: cell {d}
                    \\ contains vertex {d} 
                , .{ c, q });
        }
    }
    return true;
}

//   ---TESTING---
const testing = std.testing;

fn bboxOf(points: []const Vec3) Aabb {
    var b: Aabb = .empty();
    for (points) |p| shared.aabbExpand(&b, p);
    return b;
}

fn testCellContains(t: *const Delaunay, c: CellId, q: Vec3) bool {
    const cc = t.cells.items[@intCast(c)];
    for (0..4) |i| {
        const a = t.points.items[@intCast(cc.vertices[@trunc(FACET[i].x)])];
        const b = t.points.items[@intCast(cc.vertices[@trunc(FACET[i].y)])];
        const d = t.points.items[@intCast(cc.vertices[@trunc(FACET[i].z)])];

        if (shared.orient3d(
            a,
            b,
            d,
            q,
        ) == .positive)
            return false;
    }
    return true;
}

fn testInsert(
    t: *Delaunay,
    a: Allocator,
    p: Vec3,
    new_cells: *std.ArrayListUnmanaged(CellId),
) !VertexId {
    return try t.insert(a, p, new_cells);
}

fn testVerify(t: *const Delaunay, a: Allocator) !void {
    var err: std.ArrayListUnmanaged(u8) = .empty;
    const topology_ok = try t.verifyTopology(a, &err);
    if (!topology_ok) {
        std.debug.print("Topology error: {s}\n", .{err.items});
        return error.TopologyVerificationFailed;
    }

    err.clearRetainingCapacity();
    const delaunay_ok = try t.verifyDelaunay(a, &err);
    if (!delaunay_ok) {
        std.debug.print("Delaunay error: {s}\n", .{err.items});
        return error.DelaunayVerificationFailed;
    }
}

fn testRandomSigned(random: std.Random) f64 {
    return random.float(f64) * 2.0 - 1.0;
}

test "delaunay.single_point" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dom: Aabb = .empty();

    dom.expand(.make(-1, -1, -1));
    dom.expand(.make(1, 1, 1));

    var t = try Delaunay.init(a, dom, 1000.0);
    var new_cells: std.ArrayListUnmanaged(CellId) = .empty;

    try testing.expectEqual(@as(usize, 1), t.live_cell_count);

    _ = try testInsert(&t, a, .make(0.1, 0.2, -0.1), &new_cells);

    try testing.expectEqual(@as(usize, 4), t.live_cell_count);
    try testVerify(&t, a);
}

test "delaunay.five_points_tetra_plus_center" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pts = [_]Vec3{
        .make(0, 0, 0),
        .make(1, 0, 0),
        .make(0, 1, 0),
        .make(0, 0, 1),
        .make(0.25, 0.25, 0.25),
    };

    var t = try Delaunay.init(a, bboxOf(&pts), 1000.0);
    var new_cells: std.ArrayListUnmanaged(CellId) = .empty;

    for (pts) |p| {
        _ = try testInsert(&t, a, p, &new_cells);
    }

    try testVerify(&t, a);
}

test "delaunay.random_cloud_invariants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var pts: std.ArrayListUnmanaged(Vec3) = .empty;
    for (0..300) |_| {
        try pts.append(a, .make(
            testRandomSigned(random),
            testRandomSigned(random),
            testRandomSigned(random),
        ));
    }

    var t = try Delaunay.init(a, bboxOf(pts.items), 1000.0);
    var new_cells: std.ArrayListUnmanaged(CellId) = .empty;

    for (pts.items) |p| {
        _ = try testInsert(&t, a, p, &new_cells);
    }

    try testVerify(&t, a);

    var miss: usize = 0;
    for (0..500) |_| {
        const q = Vec3.make(
            testRandomSigned(random) * 0.9,
            testRandomSigned(random) * 0.9,
            testRandomSigned(random) * 0.9,
        );

        const c = t.locate(q, t.last_cell);
        if (c == NO_CELL or !t.testCellContains(c, q))
            miss += 1;
    }

    try testing.expectEqual(@as(usize, 0), miss);
    @panic("FAIL");
}

test "delaunay.duplicate_insertion_is_idempotent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pts = [_]Vec3{
        .make(0, 0, 0),
        .make(1, 0, 0),
        .make(0, 1, 0),
        .make(0, 0, 1),
    };

    var t = try Delaunay.init(a, bboxOf(&pts), 1000.0);
    var new_cells: std.ArrayListUnmanaged(CellId) = .empty;

    const p = Vec3.make(0.2, 0.2, 0.2);
    const first = try testInsert(&t, a, p, &new_cells);
    const cells_after_first = t.live_cell_count;

    const second = try testInsert(&t, a, p, &new_cells);

    try testing.expectEqual(first, second);
    try testing.expectEqual(cells_after_first, t.live_cell_count);
}

test "delaunay.circumcenter_of_known_tet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pts = [_]Vec3{
        .make(0, 0, 0),
        .make(1, 0, 0),
        .make(0, 1, 0),
        .make(0, 0, 1),
    };

    var t = try Delaunay.init(a, bboxOf(&pts), 1000.0);
    var new_cells: std.ArrayListUnmanaged(CellId) = .empty;

    for (pts) |p| {
        _ = try testInsert(&t, a, p, &new_cells);
    }

    var found = false;
    for (t.cells.items, 0..) |cc, i| {
        if (!cc.alive) continue;

        if (cc.vertices[0] < 4 or
            cc.vertices[1] < 4 or
            cc.vertices[2] < 4 or
            cc.vertices[3] < 4) continue;

        const c: CellId = @intCast(i);
        const cen = t.circumcenter(c);

        try testing.expectApproxEqAbs(@as(f64, 0.5), cen.x, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 0.5), cen.y, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 0.5), cen.z, 1e-9);
        try testing.expectApproxEqAbs(
            @as(f64, 0.75),
            t.squaredCircumradius(c),
            1e-9,
        );

        found = true;
    }

    try testing.expect(found);
}

test "delaunay.degenerate_inputs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_][]const Vec3{
        // Cube corners.
        &.{
            .make(0, 0, 0), .make(0, 0, 1),
            .make(0, 1, 0), .make(0, 1, 1),
            .make(1, 0, 0), .make(1, 0, 1),
            .make(1, 1, 0), .make(1, 1, 1),
        },
        // Coplanar grid with many cospherical subsets.
        &.{
            .make(0, 0, 0), .make(0, 0, 1),
            .make(0, 0, 2), .make(0, 0, 3),
            .make(0, 1, 0), .make(0, 1, 1),
            .make(0, 1, 2), .make(0, 1, 3),
            .make(0, 2, 0), .make(0, 2, 1),
            .make(0, 2, 2), .make(0, 2, 3),
            .make(0, 3, 0), .make(0, 3, 1),
            .make(0, 3, 2), .make(0, 3, 3),
        },
        // Point-on-face configuration.
        &.{
            .make(0, 0, 0), .make(4, 0, 0),
            .make(0, 4, 0), .make(0, 0, 4),
            .make(1, 1, 0), .make(2, 1, 0),
            .make(1, 2, 0),
        },
        // Coplanar square + center, then an apex.
        &.{
            .make(0, 0, 0), .make(2, 0, 0),
            .make(2, 2, 0), .make(0, 2, 0),
            .make(1, 1, 0), .make(1, 1, 3),
        },
    };

    for (cases) |pts| {
        var t = try Delaunay.init(a, bboxOf(pts), 1000.0);
        var new_cells: std.ArrayListUnmanaged(CellId) = .empty;

        for (pts) |p| {
            _ = try testInsert(&t, a, p, &new_cells);
        }

        try testVerify(&t, a);
    }
}

test "delaunay.larger_cloud_stress" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var prng = std.Random.DefaultPrng.init(999);
    const random = prng.random();

    var pts: std.ArrayListUnmanaged(Vec3) = .empty;
    for (0..1500) |_| {
        // Box-Muller transform for normally distributed samples.
        const u_1 = @max(random.float(f64), 1e-15);
        const u_2 = random.float(f64);
        const radius = @sqrt(-2.0 * @log(u_1));
        const angle = 6.283185307179586 * u_2;

        try pts.append(a, .make(
            radius * @cos(angle),
            radius * @sin(angle),
            radius * @sqrt(-2.0 * @log(@max(random.float(f64), 1e-15))) *
                @cos(6.283185307179586 * random.float(f64)),
        ));
    }

    var t = try Delaunay.init(a, bboxOf(pts.items), 1000.0);
    var new_cells: std.ArrayListUnmanaged(CellId) = .empty;

    for (pts.items) |p| {
        _ = try testInsert(&t, a, p, &new_cells);
    }

    try testVerify(&t, a);
}
// };
