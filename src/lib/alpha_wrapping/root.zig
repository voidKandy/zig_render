const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.alpha_wrapping);
const lib = core.lib;

const shared = @import("shared.zig");
/// https://doc.cgal.org/latest/Alpha_wrap_3/index.html
/// started as port of this guy's implementation
/// https://github.com/alecjacobson/alpha-wrap/tree/main/src
const Self = @This();
/// Incremental 3D Delaunay tetrahedralization (Bowyer-Watson).
///
/// The triangulation starts as a single super-tetrahedron (vertex ids 0..3) that
/// encloses the whole domain, so every inserted point is strictly interior and
/// the hull never needs special handling. Cells store four vertex ids and four
/// neighbor ids, where neighbor `i` lies across the facet opposite vertex `i`
/// (see `FACET`). Live cells are always positively oriented. Dead cell slots
/// are recycled through a free list, so a `CellId` is only stable while its
/// cell is alive.
///
/// `insert` locates the containing cell with a walk (seeded by `last_cell`),
/// floods the conflict zone (cells whose circumsphere contains the point) using
/// per-cell stamps, kills those cells, and stellates the cavity boundary to the
/// new vertex. Duplicate points return the existing vertex id.
///
/// Uses exact `orient3d`/`inSphere` predicates but no symbolic perturbation:
/// cospherical points count as "not in conflict". Circumcenters and radii are
/// inexact floating-point constructions.
pub const Delaunay = @import("Delaunay.zig");

/// 3D alpha wrapping: builds a watertight, orientation-consistent triangle mesh
/// that strictly encloses an input triangle soup, following the CGAL
/// alpha-wrap algorithm.
///
/// A Delaunay triangulation of a loose bounding box (plus scaffolding corner
/// vertices) is labelled cell by cell as inside/outside/manifold. Starting from
/// the exterior, "gates" (outside->inside facets) are processed from largest to
/// smallest squared radius, and only gates whose radius exceeds `alpha^2` are
/// traversable. For each gate, either:
///   - Rule 1: the dual Voronoi edge crosses the `offset` iso-surface of the
///     input, so a Steiner point is inserted there;
///   - Rule 2: the inside cell still intersects the input, so a Steiner point is
///     inserted at the offset projection of its circumcenter; or
///   - otherwise the inside cell is carved (relabelled outside).
/// `alpha` sets the feature/gap size the wrap can enter (smaller = tighter,
/// more detail, more cells); `offset` sets the distance kept from the input.
///
/// With `params.manifold` set, a post-pass reclaims outside cells around
/// non-manifold vertices. The boundary between solid and outside cells is then
/// extracted as the output `Mesh`. Statistics are collected in `WrapStats`.
pub const Wrap = @import("Wrap.zig");

/// Geometric query oracle over a triangle soup, backed by a static AABB
/// bounding-volume hierarchy (median split on the longest axis, leaves of up to
/// 4 triangles).
///
/// Zero-area triangles are discarded at build time, since they carry no
/// distance information and destabilize the offset projection and tet tests.
/// All queries use `f64`.
///
/// Supported queries:
///   - `squaredDistance` / `unsignedDistance` / `closestPoint`: nearest point on
///     the soup, with best-first traversal and bbox pruning;
///   - `doIntersectTet`: whether any triangle intersects a tetrahedron (exact
///     half-space polygon clipping with a small epsilon, early exit);
///   - `firstOffsetCrossing`: the first point along a segment where the
///     distance to the soup drops to `delta`, found by sphere tracing within
///     the delta-inflated bounding box.
///
/// An oracle built from an empty (or fully degenerate) soup answers every query
/// as "nothing there".
pub const Oracle = @import("Oracle.zig");

pub fn wrapMesh3D(a: std.mem.Allocator, mesh3D: lib.mesh.Mesh3D) std.mem.Allocator.Error!lib.mesh.Mesh3D {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const tmp = arena_state.allocator();

    // 1. Mesh3D -> triangle soup, tracking the bounding box
    const tri_count = mesh3D.indices.len / 3;
    const soup = try tmp.alloc(shared.Triangle, tri_count);
    var lo = [3]f64{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var hi = [3]f64{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };

    for (0..tri_count) |t| {
        for (0..3) |c| {
            const p = mesh3D.vertices[mesh3D.indices[t * 3 + c]].position;
            const xyz = [3]f64{ p.x, p.y, p.z }; // adjust if Vec4 is a @Vector
            for (0..3) |k| {
                lo[k] = @min(lo[k], xyz[k]);
                hi[k] = @max(hi[k], xyz[k]);
            }
            soup[t][c] = .make(xyz[0], xyz[1], xyz[2]); // adjust to Vec3 ctor
        }
    }

    // 2. Scale parameters to the model: alpha = diag/50, offset = alpha/30
    const dx = hi[0] - lo[0];
    const dy = hi[1] - lo[1];
    const dz = hi[2] - lo[2];
    const diag = @sqrt(dx * dx + dy * dy + dz * dz);
    const alpha = diag / 50.0;
    const offset = alpha / 30.0;

    var stats: Wrap.WrapStats = .{};
    const wrapped = try Wrap.runWrap(tmp, soup, alpha, offset, true, &stats);
    std.log.info(
        "wrap: {d} tris in -> {d} verts / {d} faces out | steiner={d} rule1={d} rule2={d} carved={d} gates={d} reclaimed={d} (alpha={d:.4} offset={d:.5})",
        .{ tri_count, stats.output_vertices, stats.output_faces, stats.steiner_points, stats.rule1, stats.rule2, stats.carved, stats.gates_popped, stats.manifold_cells_reclaimed, alpha, offset },
    );

    // 3. Mesh -> Mesh3D with flat per-face normals (3 unique verts per face,
    //    so faceting and flipped winding are easy to spot)
    const amt_tris = wrapped.faces.items.len * 3; // TODO: match your Mesh's face storage
    const verts = try a.alloc(lib.mesh.Vertex3D, amt_tris);
    const idx = try a.alloc(u32, amt_tris);
    errdefer a.free(verts);
    errdefer a.free(idx);

    for (wrapped.faces.items, 0..) |f, t| { // TODO: match your Mesh's face type
        const p0 = wrapped.vertices.items[f[0]];
        const p1 = wrapped.vertices.items[f[1]];
        const p2 = wrapped.vertices.items[f[2]];
        const e1 = [3]f64{ p1.x - p0.x, p1.y - p0.y, p1.z - p0.z };
        const e2 = [3]f64{ p2.x - p0.x, p2.y - p0.y, p2.z - p0.z };
        var n = [3]f64{
            e1[1] * e2[2] - e1[2] * e2[1],
            e1[2] * e2[0] - e1[0] * e2[2],
            e1[0] * e2[1] - e1[1] * e2[0],
        };
        const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (len > 0) for (&n) |*v| {
            v.* /= len;
        };

        for ([3]shared.Vec3{ p0, p1, p2 }, 0..) |p, c| {
            const i = t * 3 + c;
            verts[i] = .{
                .position = .make(@floatCast(p.x), @floatCast(p.y), @floatCast(p.z), 1.0),
                .normal = .make(@floatCast(n[0]), @floatCast(n[1]), @floatCast(n[2]), 0.0),
                .uv = .ZERO,
            };
            idx[i] = @intCast(i);
        }
    }

    return .{ .vertices = verts, .indices = idx };
}

pub fn wrapVertex3DSoup(a: std.mem.Allocator, soup: []const lib.mesh.Vertex3D) std.mem.Allocator.Error!lib.mesh.Mesh3D {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const tmp = arena_state.allocator();

    // 1. Vertex soup -> triangle soup, tracking the bounding box
    const tri_count = soup.len / 3;
    const tris = try tmp.alloc(shared.Triangle, tri_count);
    var lo = [3]f64{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var hi = [3]f64{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };

    for (0..tri_count) |t| {
        for (0..3) |c| {
            const p = soup[t * 3 + c].position;
            const xyz = [3]f64{ p.x, p.y, p.z }; // adjust if Vec4 is a @Vector
            for (0..3) |k| {
                lo[k] = @min(lo[k], xyz[k]);
                hi[k] = @max(hi[k], xyz[k]);
            }
            tris[t][c] = .make(xyz[0], xyz[1], xyz[2]); // adjust to Vec3 ctor
        }
    }

    // 2. Scale parameters to the model: alpha = diag/50, offset = alpha/30
    const dx = hi[0] - lo[0];
    const dy = hi[1] - lo[1];
    const dz = hi[2] - lo[2];
    const diag = @sqrt(dx * dx + dy * dy + dz * dz);
    // BAD this alpha is super low!!
    const alpha = diag / 1.0;
    const offset = alpha / 30.0;

    var stats: Wrap.WrapStats = .{};
    const wrapped = try Wrap.runWrap(tmp, tris, alpha, offset, true, &stats);
    std.log.info(
        "wrap: {d} tris in -> {d} verts / {d} faces out | steiner={d} rule1={d} rule2={d} carved={d} gates={d} reclaimed={d} (alpha={d:.4} offset={d:.5})",
        .{ tri_count, stats.output_vertices, stats.output_faces, stats.steiner_points, stats.rule1, stats.rule2, stats.carved, stats.gates_popped, stats.manifold_cells_reclaimed, alpha, offset },
    );

    // 3. Mesh -> Mesh3D with flat per-face normals (3 unique verts per face,
    //    so faceting and flipped winding are easy to spot)
    const amt_tris = wrapped.faces.items.len * 3;
    const verts = try a.alloc(lib.mesh.Vertex3D, amt_tris);
    errdefer a.free(verts);
    const idx = try a.alloc(u32, amt_tris);
    errdefer a.free(idx);

    for (wrapped.faces.items, 0..) |f, t| {
        const p0 = wrapped.vertices.items[f[0]];
        const p1 = wrapped.vertices.items[f[1]];
        const p2 = wrapped.vertices.items[f[2]];
        const e1 = [3]f64{ p1.x - p0.x, p1.y - p0.y, p1.z - p0.z };
        const e2 = [3]f64{ p2.x - p0.x, p2.y - p0.y, p2.z - p0.z };
        var n = [3]f64{
            e1[1] * e2[2] - e1[2] * e2[1],
            e1[2] * e2[0] - e1[0] * e2[2],
            e1[0] * e2[1] - e1[1] * e2[0],
        };
        const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (len > 0) for (&n) |*v| {
            v.* /= len;
        };

        for ([3]shared.Vec3{ p0, p1, p2 }, 0..) |p, c| {
            const i = t * 3 + c;
            verts[i] = .{
                .position = .make(@floatCast(p.x), @floatCast(p.y), @floatCast(p.z), 1.0),
                .normal = .make(@floatCast(n[0]), @floatCast(n[1]), @floatCast(n[2]), 0.0),
                .uv = .ZERO,
            };
            idx[i] = @intCast(i);
        }
    }

    return .{ .vertices = verts, .indices = idx };
}

test {
    std.testing.refAllDecls(@This());
}
