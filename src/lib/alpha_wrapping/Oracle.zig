const std = @import("std");
const shared = @import("shared.zig");
const core = @import("../../root.zig");
const Vec3 = shared.Vec3;
const Aabb = shared.Aabb;
const Allocator = std.mem.Allocator;

const Triangle = [3]Vec3;
const Oracle = @This();

fn closestPointOnTriangle(
    p: Vec3,
    triangle: Triangle,
) Vec3 {
    const a, const b, const c = .{
        triangle[0],
        triangle[1],
        triangle[2],
    };
    const ab, const ac, const ap = .{
        b.sub(a),
        c.sub(a),
        p.sub(a),
    };

    const d1, const d2 = .{ ab.dot(ap), ac.dot(ap) };
    if (d1 <= 0 and d2 <= 0) return a;

    const bp = p.sub(b);
    const d3, const d4 = .{ ab.dot(bp), ac.dot(bp) };
    if (d3 <= 0 and d4 <= 0) return b;

    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 and d1 >= 0 and d3 <= 0) {
        const v = d1 / (d1 - d3);
        return a.add(ab.mul(v));
    }

    const cp = p.sub(c);
    const d5, const d6 = .{ ab.dot(cp), ac.dot(cp) };
    if (d6 >= 0 and d5 <= d6) return c;

    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 and d2 >= 0 and d6 <= 0) {
        const w = d2 / (d2 - d6);
        return a.add(ac.mul(w));
    }

    const va = d3 * d6 - d5 * d4;
    if (va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0) {
        const w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return b.add(c.sub(b).mul(w));
    }

    const denom = 1.0 / (va + vb + vc);
    const v, const w = .{ vb * denom, vc * denom };
    return a.add(ab.mul(v)).add(ac.mul(w));
}

fn clipHalfspace(
    a: Allocator,
    poly: *std.ArrayListUnmanaged(Vec3),
    p0: Vec3,
    n: Vec3,
    keep: f64,
    eps: f64,
) Allocator.Error!void {
    const m = poly.items.len;
    if (m == 0) return;
    var out = try std.ArrayListUnmanaged(Vec3).initCapacity(a, m + 1);
    errdefer out.deinit(a);

    for (0..m) |i| {
        const vi = poly.items[i];
        const vj = poly.items[(i + 1) % m];
        const di = n.dot(vi.sub(p0)) * keep;
        const dj = n.dot(vj.sub(p0)) * keep;
        const in_i = di >= -eps;
        const in_j = dj >= -eps;
        if (in_i) out.appendAssumeCapacity(vi);
        if (in_i != in_j) {
            const t = di / (di - dj); // di,dj straddle 0
            out.appendAssumeCapacity(vi.add((vj.sub(vi).mul(t))));
        }
    }

    std.mem.swap(std.ArrayListUnmanaged(Vec3), poly, &out);
    out.deinit(a);
}

fn triangleIntersectsTet(
    alloc: Allocator,
    t: Triangle,
    a: Vec3,
    b: Vec3,
    c: Vec3,
    d: Vec3,
) Allocator.Error!bool {
    var poly = try std.ArrayListUnmanaged(Vec3).initCapacity(alloc, 8);
    defer poly.deinit(alloc);
    poly.appendSliceAssumeCapacity(&.{ t[0], t[1], t[2] });

    const scale = @sqrt(@max(
        b.sub(a).squaredNorm(),
        c.sub(a).squaredNorm(),
        d.sub(a).squaredNorm(),
        1e-300,
    ));

    const eps = 1e-12 * scale;

    const faces: [4][3]Vec3 = .{
        .{ a, b, c },
        .{ a, b, d },
        .{ a, c, d },
        .{ b, c, d },
    };

    const opp: [4]Vec3 = .{
        d, c, b, a,
    };

    for (0..4) |f| {
        const fa = faces[f][0];
        const fb = faces[f][1];
        const fc = faces[f][2];
        const n = fb.sub(fa).cross(fc.sub(fa));
        var keep = n.dot(opp[f].sub(fa));
        // degen face
        if (keep == 0) continue;
        keep = if (keep > 0) 1.0 else -1.0;

        try clipHalfspace(alloc, &poly, fa, n, keep, eps);
        if (poly.items.len == 0) return false;
    }

    return (poly.items.len != 0);
}

const Node = struct {
    aabb: Aabb,
    left: i32 = -1, // child node index, or -1 for leaf
    start: i32 = 0, // leaf: first triangle in order_
    count: i32 = 0,
};

fn triBox(t: *const Triangle) Aabb {
    var b = Aabb.empty();
    for (t) |v|
        shared.aabbExpand(&b, v);
    return b;
}

fn triCentroid(t: *const Triangle) Vec3 {
    return t[0].add(t[1]).add(t[2]).div(3.0);
    // return (t[0] + t[1] + t[2]) / 3.0;
}

fn boxesOverlap(x: *const Aabb, y: *const Aabb) bool {
    inline for (Vec3.FIELDS) |s| {
        const xmx = @field(x.max, s);
        const xmn = @field(x.min, s);
        const ymx = @field(y.max, s);
        const ymn = @field(y.min, s);
        if (xmx < ymn or ymx < xmn) return false;
    }
    return true;
}

triangles: std.ArrayListUnmanaged(Triangle) = .empty,
/// triangle indices, permuted by the tree
order: std.ArrayListUnmanaged(usize) = .empty,
nodes: std.ArrayListUnmanaged(Node) = .empty,
bounding_box: Aabb,

fn deinit(self: *@This(), a: Allocator) void {
    self.triangles.deinit(a);
    self.order.deinit(a);
    self.nodes.deinit(a);
}

fn build(a: Allocator, tris_in: []Triangle) Allocator.Error!@This() {
    // Drop degenerate (near-zero-area) triangles: they carry no distance/
    // intersection information and, left in, make the offset projection and
    // tet-intersection tests misbehave (a source of runaway refinement on
    // defective input). Scale the area threshold to the input size.
    var self = @This(){
        .bounding_box = .empty(),
    };

    for (tris_in) |t| {
        for (t) |v| shared.aabbExpand(&self.bounding_box, v);
    }

    const d = self.bounding_box.diagonal();
    const area_eps = @as(f64, if (d > 0) d * d else 1.0) * 1e-20;

    try self.triangles.ensureTotalCapacity(a, tris_in.len);

    for (tris_in) |t| {
        const a2 = t[1].sub(t[0]).cross(t[2].sub(t[0])).squaredNorm(); // (2*area)^2
        if (a2 > area_eps) self.triangles.appendAssumeCapacity(t);
    }

    try self.order.ensureTotalCapacity(a, tris_in.len);
    for (0..self.triangles.items.len) |i| {
        self.order.items[i] = i;
    }

    if (self.triangles.items.len > 0) _ = try self.buildNode(a, 0, self.triangles.items.len, 0);

    return self;
}

const CentroidSortCtx = struct {
    centroids: []const Vec3,
    axis: u2,

    fn key(self: @This(), i: usize) f64 {
        const centroid = self.centroids[i];
        return switch (self.axis) {
            0 => centroid.x,
            1 => centroid.y,
            2 => centroid.z,
            else => unreachable,
        };
    }

    fn lessThan(self: @This(), u: usize, v: usize) bool {
        return self.key(u) < self.key(v);
    }
};

fn buildNode(self: *@This(), a: Allocator, start: usize, count: usize, depth: usize) Allocator.Error!i32 {
    const idx = self.nodes.items.len;
    var new_node = Node{
        .aabb = .empty(),
    };

    for (start..start + count) |i| {
        shared.aabbExpandFromBox(&new_node.aabb, &triBox(&self.triangles.items[self.order.items[i]]));
    }
    const LEAF = 4;
    if (count <= LEAF or depth > 60) {
        new_node.left = -1;
        new_node.start = @intCast(start);
        new_node.count = @intCast(count);
        try self.nodes.append(a, new_node);
        return @intCast(idx);
    }
    const ext = new_node.aabb.extents();
    const axis: u2 = a: {
        if (ext.y > ext.x) break :a 1;
        if (ext.z > ext.x) break :a 2;
        break :a 0;
    };

    const mid = start + count / 2;

    const ctx = CentroidSortCtx{ .centroids = blk: {
        const cents = try a.alloc(Vec3, self.triangles.items.len);
        for (cents, 0..) |*cent, i| {
            cent.* = triCentroid(&self.triangles.items[i]);
        }
        break :blk cents;
    }, .axis = axis };

    defer a.free(ctx.centroids);

    const slice = self.order.items[start .. start + count];
    std.sort.pdq(usize, slice, ctx, CentroidSortCtx.lessThan);
    const l = try self.buildNode(a, start, mid - start, depth + 1);
    const r = try self.buildNode(a, mid, start + count - mid, depth + 1);

    new_node.left = l;
    // right child index stored in `start` for internal nodes
    new_node.start = r;
    new_node.count = -1;
    try self.nodes.append(a, new_node);
    return @intCast(idx);
}

fn nearestRecursive(
    self: *const @This(),
    node: usize,
    p: Vec3,
    best2: *f64,
    best: *Vec3,
) void {
    const nd = self.nodes.items[node];
    if (shared.aabbDistSquared(&nd.aabb, p) >= best2.*) return;
    if (nd.left < 0) { // leaf
        for (@intCast(nd.start)..@intCast(nd.start + nd.count)) |i| {
            const t = self.triangles.items[self.order.items[i]];
            const cp = closestPointOnTriangle(p, t);
            const d2 = p.distSquared(cp);
            if (d2 < best2.*) {
                best2.* = d2;
                best.* = cp;
            }
        }
        return;
    }
    const lc = nd.left;
    const rc = nd.start;

    const dl = shared.aabbDistSquared(&self.nodes.items[@intCast(lc)].aabb, p);
    const dr = shared.aabbDistSquared(&self.nodes.items[@intCast(rc)].aabb, p);
    if (dl <= dr) {
        self.nearestRecursive(@intCast(lc), p, best2, best);
        self.nearestRecursive(@intCast(rc), p, best2, best);
    } else {
        self.nearestRecursive(@intCast(rc), p, best2, best);
        self.nearestRecursive(@intCast(lc), p, best2, best);
    }
}
//                        Vec3& best) const;
// bool intersect_tet_recursive(int node, const Box& qbox, const Vec3& a,
//                              const Vec3& b, const Vec3& c, const Vec3& d) const;
fn squaredDistance(self: *const @This(), p: Vec3) f64 {
    var best2 = std.math.inf(f64);
    var best = p;
    if (self.nodes.items.len > 0) self.nearestRecursive(0, p, &best2, &best);
    return best2;
}

fn unsignedDistance(self: *const @This(), p: Vec3) f64 {
    return @sqrt(self.squaredDistance(p));
}

fn closestPoint(self: *const @This(), p: Vec3) Vec3 {
    var best2 = std.math.inf(f64);
    var best = p;
    if (self.nodes.items.len > 0) self.nearestRecursive(0, p, &best2, &best);
    return best;
}

fn intersectTetRecursive(
    self: *const @This(),
    alloc: Allocator,
    node: usize,
    aabb: *Aabb,
    a: Vec3,
    b: Vec3,
    c: Vec3,
    d: Vec3,
) Allocator.Error!bool {
    const nd = self.nodes.items[node];
    if (!boxesOverlap(&nd.aabb, aabb)) return false;
    if (nd.left < 0) { // leaf
        for (@intCast(nd.start)..@intCast(nd.start + nd.count)) |i| {
            const t = self.triangles.items[self.order.items[i]];
            if (try triangleIntersectsTet(alloc, t, a, b, c, d)) return true;
        }
        return false;
    }
    // Early exit: stop at the first intersecting triangle found in either child.
    return try self.intersectTetRecursive(alloc, @intCast(nd.left), aabb, a, b, c, d) or
        try self.intersectTetRecursive(alloc, @intCast(nd.start), aabb, a, b, c, d);
}

fn doIntersectTet(
    self: *const @This(),
    alloc: Allocator,
    a: Vec3,
    b: Vec3,
    c: Vec3,
    d: Vec3,
) Allocator.Error!bool {
    if (self.nodes.items.len == 0) return false;
    var aabb = Aabb.empty();
    for ([_]Vec3{ a, b, c, d }) |v|
        shared.aabbExpand(&aabb, v);
    return try self.intersectTetRecursive(alloc, 0, &aabb, a, b, c, d);
}

fn distHelper(self: *const @This(), a: Vec3, b: Vec3, t: f64, delta: f64) f64 {
    const x = a.add(b.sub(a).mul(t));
    return self.unsignedDistance(x) - delta;
}

fn firstOffsetCrossing(
    self: *const @This(),
    a: Vec3,
    b: Vec3,
    delta: f64,
    out: *Vec3,
) bool {
    if (self.nodes.items.len == 0) return false;
    //   auto f = [&](double t) {
    //     Vec3 x = a + (b - a) * t;
    //     return unsigned_distance(x) - delta;
    //   };
    const seg_len = a.dist(b);
    if (seg_len == 0) return false;
    // Any point farther than `delta` outside the input bbox has distance > delta,
    // so a crossing can only occur where the segment is within the bbox inflated
    // by delta. Clip the marched interval [tlo,thi] to that region (huge speedup
    // for long outer-cell rays). Slab method.
    const dir = b.sub(a);
    var tlo: f64 = 0.0;
    var thi: f64 = 1.0;
    inline for (Vec3.FIELDS) |s| {
        const lo: f64 = @field(self.bounding_box.min, s) - delta;
        const hi: f64 = @field(self.bounding_box.max, s) + delta;
        const d: f64 = @field(dir, s);
        const afld: f64 = @field(a, s);

        if (@abs(d) < 1e-300) {
            if (afld < lo or afld > hi) return false; // segment never enters slab
        } else {
            var t1 = (lo - afld) / d;
            var t2 = (hi - afld) / d;
            if (t1 > t2) std.mem.swap(f64, &t1, &t2);
            tlo = @max(tlo, t1);
            thi = @min(thi, t2);
        }
    }
    if (tlo > thi) return false; // segment misses the inflated bbox entirely
    // Sphere tracing: f(t) = dist(x(t), input) - delta is 1-Lipschitz in arclength,
    // so |f(t)| is a lower bound on the distance from x(t) to the delta-iso along
    // the ray. Stepping by f(t) never overshoots the first crossing, and converges
    // in O(log) steps regardless of how small delta is (vs O(L/delta) for a fixed
    // march). We march from the outside end (t=tlo, f>0) toward the inside end.
    const tol = @max(delta * 1e-4, seg_len * 1e-9);
    var t = tlo;
    var ft = self.distHelper(a, b, t, delta);

    // already inside at entry
    if (ft <= 0) {
        out.* = a.add(dir.mul(t));
        return true;
    }

    const max_iter = 200;
    for (0..max_iter) |_| {
        // Safe forward step (never crosses the iso): advance arclength by ft.
        var dt = ft / seg_len;
        if (dt < tol) dt = tol; // avoid stalling exactly at grazing
        t += dt;
        if (t >= thi) {
            // Check the endpoint in case the crossing is right at thi.
            const fe = self.distHelper(a, b, thi, delta);
            if (fe <= 0) {
                out.* = a.add(dir.mul(thi));
                return true;
            }
            return false;
        }
        ft = self.distHelper(a, b, t, delta);
        if (ft <= tol) { // reached the iso-surface (within tolerance)
            out.* = a.add(dir.mul(t));
            return true;
        }
    }
    // grazing / no clean crossing within the iteration budget
    return false;
}

// ---testing---
const testing = std.testing;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn uniform(rng: std.Random, lo: f64, hi: f64) f64 {
    return lo + (hi - lo) * rng.float(f64);
}

fn bruteDist2(tris: []const Triangle, p: Vec3) f64 {
    var best = std.math.inf(f64);
    for (tris) |t| {
        const cp = Oracle.closestPointOnTriangle(p, t);
        best = @min(best, p.distSquared(cp));
    }
    return best;
}

fn bruteIntersectTet(
    alloc: Allocator,
    tris: []const Triangle,
    a: Vec3,
    b: Vec3,
    c: Vec3,
    d: Vec3,
) bool {
    for (tris) |t| {
        if (Oracle.triangleIntersectsTet(alloc, t, a, b, c, d) catch @panic("OOM")) return true;
    }
    return false;
}

/// Caller owns the returned slice.
fn randomSoup(alloc: Allocator, rng: std.Random, n: usize) ![]Triangle {
    const tris = try alloc.alloc(Triangle, n);
    for (tris) |*t| {
        const base = Vec3.make(uniform(rng, -1, 1), uniform(rng, -1, 1), uniform(rng, -1, 1));
        const e1 = Vec3.make(uniform(rng, -1, 1) * 0.3, uniform(rng, -1, 1) * 0.3, uniform(rng, -1, 1) * 0.3);
        const e2 = Vec3.make(uniform(rng, -1, 1) * 0.3, uniform(rng, -1, 1) * 0.3, uniform(rng, -1, 1) * 0.3);
        t.* = .{ base, base.add(e1), base.add(e2) };
    }
    return tris;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "closest_point_on_triangle.basic" {
    const tri: Triangle = .{ Vec3.make(0, 0, 0), Vec3.make(1, 0, 0), Vec3.make(0, 1, 0) };

    // Above the interior projects straight down.
    var p = Vec3.make(0.25, 0.25, 5);
    var cp = Oracle.closestPointOnTriangle(p, tri);
    try testing.expectApproxEqAbs(0.25, cp.x, 1e-12);
    try testing.expectApproxEqAbs(0.25, cp.y, 1e-12);
    try testing.expectApproxEqAbs(0.0, cp.z, 1e-12);

    // Beyond vertex a clamps to a.
    p = Vec3.make(-1, -1, 0);
    cp = Oracle.closestPointOnTriangle(p, tri);
    try testing.expectApproxEqAbs(0.0, cp.x, 1e-12);
    try testing.expectApproxEqAbs(0.0, cp.y, 1e-12);

    // Beyond edge ab (below y=0) projects onto the edge.
    p = Vec3.make(0.5, -1, 0);
    cp = Oracle.closestPointOnTriangle(p, tri);
    try testing.expectApproxEqAbs(0.5, cp.x, 1e-12);
    try testing.expectApproxEqAbs(0.0, cp.y, 1e-12);
}

test "oracle.distance_matches_brute_force" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();

    const tris = try randomSoup(alloc, rng, 200);
    defer alloc.free(tris);

    var o = try Oracle.build(alloc, tris);
    defer o.deinit(alloc);

    for (0..400) |_| {
        const p = Vec3.make(uniform(rng, -1.5, 1.5), uniform(rng, -1.5, 1.5), uniform(rng, -1.5, 1.5));
        const a = o.squaredDistance(p);
        const b = bruteDist2(tris, p);
        try testing.expectApproxEqAbs(b, a, 1e-9 * (1 + b));

        // Closest point really is on the soup at that distance.
        const cp = o.closestPoint(p);
        try testing.expectApproxEqAbs(b, p.distSquared(cp), 1e-9 * (1 + b));
    }
}

test "oracle.tet_intersection_matches_brute_force" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(11);
    const rng = prng.random();

    const tris = try randomSoup(alloc, rng, 150);
    defer alloc.free(tris);

    var o = try Oracle.build(alloc, tris);
    defer o.deinit(alloc);

    var agree: usize = 0;
    var total: usize = 0;
    for (0..300) |_| {
        const a = Vec3.make(uniform(rng, -1.2, 1.2), uniform(rng, -1.2, 1.2), uniform(rng, -1.2, 1.2));
        const b = a.add(Vec3.make(uniform(rng, 0.1, 0.8), 0, 0));
        const c = a.add(Vec3.make(0, uniform(rng, 0.1, 0.8), 0));
        const d = a.add(Vec3.make(0, 0, uniform(rng, 0.1, 0.8)));

        const via_tree = o.doIntersectTet(alloc, a, b, c, d) catch @panic("OOM");
        const via_brute = bruteIntersectTet(alloc, tris, a, b, c, d);
        total += 1;
        if (via_tree == via_brute) agree += 1;
    }
    try testing.expectEqual(total, agree);
}

test "triangle_intersects_tet.known_cases" {
    const alloc = testing.allocator;

    // Unit tet at origin.
    const a = Vec3.make(0, 0, 0);
    const b = Vec3.make(1, 0, 0);
    const c = Vec3.make(0, 1, 0);
    const d = Vec3.make(0, 0, 1);

    // Triangle straddling the tet interior.
    const t1: Triangle = .{ Vec3.make(0.2, 0.2, -1), Vec3.make(0.2, 0.2, 1), Vec3.make(0.6, 0.1, 0.1) };
    try testing.expect(try Oracle.triangleIntersectsTet(alloc, t1, a, b, c, d));

    // Triangle far away.
    const t2: Triangle = .{ Vec3.make(5, 5, 5), Vec3.make(6, 5, 5), Vec3.make(5, 6, 5) };
    try testing.expect(!try Oracle.triangleIntersectsTet(alloc, t2, a, b, c, d));

    // Triangle enclosing the tet (tet vertices inside triangle's prism) but
    // coplanar far above -> no intersection.
    const t3: Triangle = .{ Vec3.make(-5, -5, 5), Vec3.make(5, -5, 5), Vec3.make(0, 5, 5) };
    try testing.expect(!try Oracle.triangleIntersectsTet(alloc, t3, a, b, c, d));
}

test "oracle.offset_crossing_on_single_triangle" {
    const alloc = testing.allocator;

    // One triangle in the z=0 plane; unsigned distance to a point above it
    // (over the interior) is just its height. Crossing delta should be at
    // height delta.
    var tris = [_]Triangle{.{ Vec3.make(-2, -2, 0), Vec3.make(2, -2, 0), Vec3.make(0, 3, 0) }};
    var o = try Oracle.build(alloc, &tris);
    defer o.deinit(alloc);

    const delta = 0.1;
    var out: Vec3 = undefined;

    // Segment from high above (dist 1) straight down to the plane (dist 0).
    const a1 = Vec3.make(0, 0, 1.0);
    const b1 = Vec3.make(0, 0, 0.0);
    const hit = o.firstOffsetCrossing(a1, b1, delta, &out);
    try testing.expect(hit);
    try testing.expectApproxEqAbs(delta, o.unsignedDistance(out), 1e-6);
    try testing.expectApproxEqAbs(delta, out.z, 1e-4);

    // Segment that never gets within delta: stays at dist ~1.
    var out2: Vec3 = undefined;
    const a2 = Vec3.make(0, 0, 1.0);
    const b2 = Vec3.make(0.5, 0, 1.0);
    const hit2 = o.firstOffsetCrossing(a2, b2, delta, &out2);
    try testing.expect(!hit2);
}
