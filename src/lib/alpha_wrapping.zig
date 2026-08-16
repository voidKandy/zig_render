const std = @import("std");
const core = @import("../root.zig");
const math_mod = core.lib.math;
const mesh_mod = core.lib.mesh;
const Allocator = std.mem.Allocator;
const Vec2 = math_mod.Vec2;
const Vec3 = math_mod.Vec3;
const Vec4 = math_mod.Vec4;
const Mat3 = math_mod.Mat3;
const delaunay = core.lib.delaunay;

pub const Tag = enum { inside, outside };

const Gate = struct {
    /// the "inside" cell we're testing whether to carve
    tet_idx: usize,
    /// which of tet_idx's faces we're entering through
    face_idx: usize,
    /// the "outside" cell we're carving from
    from_tet_idx: usize,
    radius: f32,
};

/// the gates are processed in order of decreasing circumradii
fn gateOrder(context: void, a: Gate, b: Gate) std.math.Order {
    _ = context;
    // max-heap: largest circumradius processed first
    return std.math.order(b.radius, a.radius);
}

pub const Wrapper = struct {
    tri: *delaunay.Triangulation,
    tags: std.ArrayList(Tag),

    /// initializes wrapper from triangulation
    /// Marks ever tetrahedron as `.inside`
    pub fn init(tri: *delaunay.Triangulation, a: Allocator) !Wrapper {
        var tags: std.ArrayList(Tag) = try .initCapacity(a, tri.tetrahedra.items.len);
        try tags.appendNTimes(a, .inside, tri.tetrahedra.items.len);

        return .{
            .tri = tri,
            .tags = tags,
        };
    }

    pub fn deinit(self: *Wrapper, a: Allocator) void {
        self.tags.deinit(a);
    }

    fn ensureTagsCapacity(self: *Wrapper, a: Allocator) Allocator.Error!void {
        while (self.tags.items.len < self.tri.tetrahedra.items.len) {
            try self.tags.append(a, .inside); // placeholder; real new tets get set explicitly below
        }
    }

    /// For a tetrahedron known to be .inside, pushes a gate for every one
    /// of its faces bordering an .outside neighbor. Used both right after
    /// Steiner-point insertion (new cells finding their outside neighbors)
    fn pushGatesIntoInsideTet(
        self: *Wrapper,
        a: Allocator,
        queue: *std.PriorityQueue(Gate, void, gateOrder),
        tet_idx: usize,
        tet: delaunay.Tetrahedron,
        alpha: f32,
        max_radius: f32, //  the radius of the gate that triggered this insertion
    ) Allocator.Error!void {
        for (tet.faces(), 0..) |face, face_idx| {
            const loc = self.tri.adjacency.neighborLocation(tet_idx, face_idx, tet) orelse continue;
            if (self.tags.items[loc.tet] != .outside) continue;

            const radius = face.circumradius(self.tri) catch continue;
            if (radius <= alpha) continue;
            if (radius >= max_radius) continue;

            try queue.push(a, .{
                .tet_idx = tet_idx,
                .face_idx = face_idx,
                .from_tet_idx = loc.tet,
                .radius = radius,
            });
        }
    }

    /// TEMP?
    /// uses the inside cell's own circumcenter as both endpoints when there's no real outside cell
    /// effectively a zero-length segment, meaning segmentOffsetIntersection will just check whether
    /// that single point crosses the offset threshold. That's a reasonable
    /// approximation for "entering from the true exterior" but isn't exactly what the paper describes
    /// (which relies on the infinite cells having well-defined circumcenters too, a concept we don't have
    /// in this simpler bounded-super-tetrahedron approach).
    /// Worth flagging as an approximation, not a fully faithful translation
    /// if it causes weird behavior at the outer hull specifically, this is the place to revisit.
    const NO_OUTSIDE_CELL = std.math.maxInt(usize);
    /// Shrink-wraps the triangulation: floods from the outer boundary
    /// inward, tagging tetrahedra `.outside` wherever alpha-traversable
    /// and not blocked. Cells are never removed, only tagged — the final
    /// wrapped surface is the boundary between .inside and .outside cells.
    ///
    /// TODO(oracle): currently a stub that never blocks traversal (no
    /// Steiner point insertion, no offset-surface intersection checks).
    /// A future pass replaces the hardcoded "always carve" with real
    /// geometry queries against the input.
    pub fn run(
        self: *Wrapper,
        a: Allocator,
        alpha: f32,
        offset: f32,
        oracle: MeshOracle,
    ) !void {
        if (alpha <= 0.0) @panic("alpha of 0 or less disables the sizing bound entirely, defeating its purpose");
        const min_steiner_separation = alpha * 0.1;

        var queue = std.PriorityQueue(Gate, void, gateOrder).initContext({});
        defer queue.deinit(a);

        // first we need to find the convex hull of the alpha wrapped mesh
        // recall, we set every tet as `.inside`
        var iter = self.tri.tetrahedronIterator();
        while (iter.next()) |entry| {
            for (entry.tet.faces(), 0..) |face, face_idx| {
                // if the tet has no neighbor and it's radius fits into alpha we append it to the gate queue
                if (self.tri.adjacency.neighborLocation(entry.index, face_idx, entry.tet) != null) continue;
                const radius = face.circumradius(self.tri) catch @panic("Degenerate face?");
                if (radius <= alpha) continue;

                try queue.push(a, .{
                    .tet_idx = entry.index,
                    .face_idx = face_idx,
                    .from_tet_idx = NO_OUTSIDE_CELL,
                    .radius = radius,
                });
            }
        }

        while (queue.pop()) |gate| {
            // stale gate
            if (self.tags.items[gate.tet_idx] == .outside) continue;
            // A gate whose entry face is already too small to traverse isn't eligible for refinement either
            if (gate.radius <= alpha) continue;
            // skip if tombstoned since queued
            const tet = self.tri.tetrahedra.items[gate.tet_idx] orelse continue;

            const circumsphere = tet.circumsphere(self.tri) catch {
                self.tags.items[gate.tet_idx] = .outside;
                continue;
            };
            const from_point: Vec3 = blk: {
                // No exterior Voronoi vertex exists in bounded Delaunay.
                // Approximate by testing the hull Voronoi vertex itself.
                if (gate.from_tet_idx == NO_OUTSIDE_CELL)
                    break :blk circumsphere.center;

                const from_tet = self.tri.tetrahedra.items[gate.from_tet_idx] orelse break :blk circumsphere.center;
                const from_sphere = from_tet.circumsphere(self.tri) catch break :blk circumsphere.center;
                break :blk from_sphere.center;
            };
            var new_tets: std.ArrayList(usize) = try .initCapacity(a, 64);
            defer new_tets.deinit(a);

            if (oracle.segmentOffsetIntersection(from_point, circumsphere.center, offset)) |steiner| {

                // Can't usefully refine here; treat as resolved without inserting.
                if (tooCloseToExisting(self.tri, steiner, min_steiner_separation)) continue;

                new_tets.clearRetainingCapacity();

                _ = self.tri.addVertexTracked(a, steiner, &new_tets) catch |err| switch (err) {
                    error.DegenerateCavity, error.PointOutsideTriangulation => continue,
                    else => return err,
                };

                try self.ensureTagsCapacity(a);
                for (new_tets.items) |idx| self.tags.items[idx] = .inside;
                for (new_tets.items) |idx| {
                    const new_tet = self.tri.tetrahedra.items[idx].?;
                    try self.pushGatesIntoInsideTet(a, &queue, idx, new_tet, alpha, gate.radius);
                }
                continue;
            }

            if (oracle.tetIntersectsMesh(self.tri, tet)) {
                const proj = oracle.projectToOffset(circumsphere.center, offset);

                std.debug.print("attempting steiner {any}, existing verts {}\n", .{ proj, self.tri.vertices.items.len });

                if (tooCloseToExisting(self.tri, proj, min_steiner_separation)) continue;
                new_tets.clearRetainingCapacity();
                _ = self.tri.addVertexTracked(a, proj, &new_tets) catch |err| switch (err) {
                    error.DegenerateCavity, error.PointOutsideTriangulation => continue,
                    else => return err,
                };

                try self.ensureTagsCapacity(a);
                for (new_tets.items) |idx| self.tags.items[idx] = .inside;
                for (new_tets.items) |idx| {
                    const new_tet = self.tri.tetrahedra.items[idx].?;
                    try self.pushGatesIntoInsideTet(a, &queue, idx, new_tet, alpha, gate.radius);
                }
                continue;
            }

            self.tags.items[gate.tet_idx] = .outside;

            for (tet.faces(), 0..) |tface, tface_idx| {
                if (tface_idx == gate.face_idx) continue; // don't re-cross the tface we entered through
                const loc = self.tri.adjacency.neighborLocation(gate.tet_idx, tface_idx, tet) orelse continue;
                if (self.tags.items[loc.tet] == .outside) continue;
                const radius = tface.circumradius(self.tri) catch continue;
                if (radius <= alpha) continue;
                try queue.push(a, .{
                    .tet_idx = loc.tet,
                    .face_idx = loc.face,
                    .from_tet_idx = gate.tet_idx,
                    .radius = radius,
                });
            }
        }
    }

    /// Returns the faces separating an .inside cell from an .outside one
    /// (or from the implicit exterior). This is the wrapped output surface.
    pub fn extractBoundaryFaces(self: *const Wrapper, a: Allocator) Allocator.Error![]delaunay.Triangulation.Face {
        var result = try std.ArrayList(delaunay.Triangulation.Face).initCapacity(a, 64);
        errdefer result.deinit(a);

        var iter = self.tri.tetrahedronIterator();
        while (iter.next()) |entry| {
            if (self.tags.items[entry.index] == .outside) continue;

            for (entry.tet.faces(), 0..) |face, face_idx| {
                const loc = self.tri.adjacency.neighborLocation(entry.index, face_idx, entry.tet);
                const neighbor_is_outside = if (loc) |l|
                    self.tags.items[l.tet] == .outside
                else
                    true; // boundary face borders the implicit exterior

                if (neighbor_is_outside) try result.append(a, face);
            }
        }

        return result.toOwnedSlice(a);
    }
};

/// A moderate alpha for tests: small enough that most gates between
/// well-separated points remain traversable, large enough to bound
/// refinement near tightly-packed geometry (e.g. near a test mesh)
/// and avoid near-duplicate Steiner point degeneracies.
const TEST_ALPHA: f32 = 0.5;

test "Wrapper.run with stub oracle carves the entire single-tet triangulation" {
    const a = std.testing.allocator;
    var tri = try delaunay.Triangulation.init(a, .{ .min = Vec3.make(-5, -5, -5), .max = Vec3.make(5, 5, 5) });
    defer tri.deinit(a);

    var wrapper = try Wrapper.init(&tri, a);
    defer wrapper.deinit(a);

    const mesh = try mesh_mod.Mesh3D.init(
        a,
        &.{
            .{
                .position = Vec4.make(0, 0, 0, 1),
                .normal = Vec4.ZERO,
                .uv = Vec2.ZERO,
                .color = Vec4.ZERO,
            },
            .{
                .position = Vec4.make(1, 0, 0, 1),
                .normal = Vec4.ZERO,
                .uv = Vec2.ZERO,
                .color = Vec4.ZERO,
            },
            .{
                .position = Vec4.make(0, 1, 0, 1),
                .normal = Vec4.ZERO,
                .uv = Vec2.ZERO,
                .color = Vec4.ZERO,
            },
        },
        &.{ 0, 1, 2 },
    );
    defer mesh.deinit(a);

    const oracle = MeshOracle{
        .mesh = &mesh,
    };

    try wrapper.run(a, TEST_ALPHA, 1.0, oracle);

    try std.testing.expectEqual(Tag.outside, wrapper.tags.items[0]);
}

test "Steiner point insertion strictly shrinks the triggering facet's circumradius" {
    const a = std.testing.allocator;
    var tri = try delaunay.Triangulation.init(a, .{ .min = Vec3.make(-5, -5, -5), .max = Vec3.make(5, 5, 5) });
    defer tri.deinit(a);

    const tet = tri.tetrahedra.items[0].?;
    const face = tet.faces()[0];
    const radius_before = try face.circumradius(&tri);

    const mesh = try mesh_mod.Mesh3D.init(
        a,
        &.{
            .{ .position = Vec4.make(0, 0, 0, 1), .normal = Vec4.ZERO, .uv = Vec2.ZERO, .color = Vec4.ZERO },
            .{ .position = Vec4.make(1, 0, 0, 1), .normal = Vec4.ZERO, .uv = Vec2.ZERO, .color = Vec4.ZERO },
            .{ .position = Vec4.make(0, 1, 0, 1), .normal = Vec4.ZERO, .uv = Vec2.ZERO, .color = Vec4.ZERO },
        },
        &.{ 0, 1, 2 },
    );
    defer mesh.deinit(a);

    const oracle = MeshOracle{ .mesh = &mesh };
    const offset: f32 = 1.0;

    // A genuine, non-degenerate segment: one endpoint very close to the
    // mesh (distance ~0, well inside the offset surface), the other far
    // away (distance >> offset, well outside it) — guaranteed to cross
    // distance(p) == offset somewhere in between.
    const near_mesh = Vec3.make(0.1, 0.1, 0.0); // close to the triangle
    const far_from_mesh = Vec3.make(4.0, 4.0, 4.0); // far away

    const steiner = oracle.segmentOffsetIntersection(far_from_mesh, near_mesh, offset) orelse {
        return error.SkipZigTest;
    };

    var new_tets: std.ArrayList(usize) = try .initCapacity(a, 16);
    defer new_tets.deinit(a);
    _ = try tri.addVertexTracked(a, steiner, &new_tets);

    try std.testing.expect(new_tets.items.len > 0);

    var smallest_new_radius: f32 = std.math.inf(f32);
    for (new_tets.items) |idx| {
        const new_tet = tri.tetrahedra.items[idx].?;
        for (new_tet.faces()) |f| {
            const r = f.circumradius(&tri) catch continue;
            smallest_new_radius = @min(smallest_new_radius, r);
        }
    }

    try std.testing.expect(smallest_new_radius < radius_before);
}

test "segmentOffsetIntersection finds a narrow feature that used to fall between coarse samples" {
    const from = Vec3.make(-5, 5, 0);
    const to = Vec3.make(5, 5, 0);
    const offset: f32 = 1.0;

    const a = std.testing.allocator;
    const feature_y: f32 = 5.0 - 0.9539;

    const mesh = try mesh_mod.Mesh3D.init(
        a,
        &.{
            .{ .position = Vec4.make(0.55, feature_y, 0, 1), .normal = Vec4.ZERO, .uv = Vec2.ZERO, .color = Vec4.ZERO },
            .{ .position = Vec4.make(0.65, feature_y, 0, 1), .normal = Vec4.ZERO, .uv = Vec2.ZERO, .color = Vec4.ZERO },
            .{ .position = Vec4.make(0.6, feature_y + 0.05, 0.02, 1), .normal = Vec4.ZERO, .uv = Vec2.ZERO, .color = Vec4.ZERO },
        },
        &.{ 0, 1, 2 },
    );
    defer mesh.deinit(a);

    const oracle = MeshOracle{ .mesh = &mesh };

    // Ground truth: confirm a real crossing exists.
    var found_real_crossing = false;
    var i: usize = 0;
    const dense_samples: usize = 500;
    while (i <= dense_samples) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(dense_samples));
        const p = from.add(to.sub(from).mul(t));
        if (oracle.distance(p) < offset) {
            found_real_crossing = true;
            break;
        }
    }
    try std.testing.expect(found_real_crossing);

    // Regression check: with SEGMENT_SAMPLE_COUNT = 32, this narrow
    // feature (which was missed at the old default of 8) should now
    // be found. If this ever starts failing again, SEGMENT_SAMPLE_COUNT
    // may have been lowered, or the feature-size assumptions here no
    // longer hold relative to it.
    const result = oracle.segmentOffsetIntersection(from, to, offset);
    try std.testing.expect(result != null);
}

test "projectToOffset produces near-duplicate points for different circumcenters near the same mesh feature" {
    const a = std.testing.allocator;

    // A single small mesh triangle near the origin.
    const mesh = try mesh_mod.Mesh3D.init(
        a,
        &.{
            .{ .position = Vec4.make(0, 0, 0, 1), .normal = Vec4.ZERO, .uv = Vec2.ZERO, .color = Vec4.ZERO },
            .{ .position = Vec4.make(1, 0, 0, 1), .normal = Vec4.ZERO, .uv = Vec2.ZERO, .color = Vec4.ZERO },
            .{ .position = Vec4.make(0, 1, 0, 1), .normal = Vec4.ZERO, .uv = Vec2.ZERO, .color = Vec4.ZERO },
        },
        &.{ 0, 1, 2 },
    );
    defer mesh.deinit(a);

    const oracle = MeshOracle{ .mesh = &mesh };
    const offset: f32 = 1.0;

    // Two DIFFERENT points that are both closest to the same single
    // vertex of the triangle (the origin), just approached from
    // slightly different directions/distances — a very plausible
    // situation for two different circumcenters near the same feature.
    const p1 = Vec3.make(0.0, 0.0, 5.0);
    const p2 = Vec3.make(0.0, 0.0, 4.0);

    const closest1 = oracle.closestPoint(p1);
    const closest2 = oracle.closestPoint(p2);

    // Confirm the premise: both really do share the same nearest point.
    try std.testing.expect(closest1.point.eucDist(closest2.point) < 1e-4);

    const proj1 = oracle.projectToOffset(p1, offset);
    const proj2 = oracle.projectToOffset(p2, offset);

    // Since both p1 and p2 lie along the same ray from the same
    // closest point, projectToOffset should produce IDENTICAL output
    // for both, despite p1 and p2 being genuinely different input
    // points 1 unit apart. This is the actual bug: two legitimately
    // different cells can be mapped to the same (or near-same) Steiner
    // point, which can't shrink both of their cavities simultaneously,
    // and can produce a degenerate/duplicate insertion.
    std.debug.print("proj1: {any}\nproj2: {any}\ndistance: {d}\n", .{
        proj1,
        proj2,
        proj1.eucDist(proj2),
    });

    try std.testing.expect(proj1.eucDist(proj2) < 1e-3);
}

test "inserting a Steiner point mid-flood correctly tags and gates new tetrahedra" {
    const a = std.testing.allocator;
    var tri = try delaunay.Triangulation.init(a, .{ .min = Vec3.make(-5, -5, -5), .max = Vec3.make(5, 5, 5) });
    defer tri.deinit(a);

    var wrapper = try Wrapper.init(&tri, a);
    defer wrapper.deinit(a);

    var new_tets: std.ArrayList(usize) = try .initCapacity(a, 16);
    defer new_tets.deinit(a);

    const original_count = tri.tetrahedra.items.len; // 1
    _ = try tri.addVertexTracked(a, Vec3.make(0, 0, 0), &new_tets);

    try std.testing.expect(new_tets.items.len == 4); // 1 tet -> 4 boundary faces -> 4 new tets
    try std.testing.expect(tri.tetrahedra.items.len == original_count - 1 + new_tets.items.len);

    try wrapper.ensureTagsCapacity(a);
    for (new_tets.items) |idx| wrapper.tags.items[idx] = .inside;

    for (new_tets.items) |idx| {
        try std.testing.expect(wrapper.tags.items[idx] == .inside);
    }
}

test "Wrapper.run produces a wrap that strictly encloses the input mesh" {
    const a = std.testing.allocator;
    const aabb = delaunay.Aabb{ .min = Vec3.make(-10, -10, -10), .max = Vec3.make(10, 10, 10) };

    var tri = try delaunay.Triangulation.init(a, aabb);
    defer tri.deinit(a);

    const points = [_]Vec3{
        Vec3.make(0.3, 1.7, -2.1),
        Vec3.make(4.2, -0.5, 3.3),
        Vec3.make(-3.1, 2.8, 0.9),
        Vec3.make(1.1, -4.4, -1.2),
        Vec3.make(-2.0, -1.3, 4.7),
        Vec3.make(2.9, 3.1, 1.8),
    };
    for (points) |p| _ = try tri.addVertex(a, p);

    var wrapper = try Wrapper.init(&tri, a);
    defer wrapper.deinit(a);

    const mesh = try mesh_mod.Mesh3D.init(
        a,
        &.{
            .{ .position = Vec4.make(0, 0, 0, 1), .normal = Vec4.ZERO, .uv = Vec2.ZERO, .color = Vec4.ZERO },
            .{ .position = Vec4.make(1, 0, 0, 1), .normal = Vec4.ZERO, .uv = Vec2.ZERO, .color = Vec4.ZERO },
            .{ .position = Vec4.make(0, 1, 0, 1), .normal = Vec4.ZERO, .uv = Vec2.ZERO, .color = Vec4.ZERO },
        },
        &.{ 0, 1, 2 },
    );
    defer mesh.deinit(a);

    const oracle = MeshOracle{ .mesh = &mesh };
    try wrapper.run(a, TEST_ALPHA, 1.0, oracle);

    // Every mesh vertex must land inside a .inside-tagged tetrahedron,
    // i.e. strictly within the wrapped volume, not carved away.
    for (mesh.vertices) |mesh_vertex| {
        const p = mesh_vertex.position.toVec3();
        var found_containing_inside_tet = false;

        var iter = tri.tetrahedronIterator();
        while (iter.next()) |entry| {
            if (!entry.tet.containsPoint(&tri, p))
                continue;

            if (wrapper.tags.items[entry.index] == .outside) {
                std.debug.print(
                    "mesh vertex {any} carved into outside tet {}\n",
                    .{ p, entry.index },
                );
            } else found_containing_inside_tet = true;

            std.debug.print(
                "tet intersects? {}\n",
                .{oracle.tetIntersectsMesh(&tri, entry.tet)},
            );
        }

        try std.testing.expect(found_containing_inside_tet);
    }
}

test "Wrapper.run respects alpha: a large alpha prevents carving through a tight cavity" {
    const a = std.testing.allocator;
    const aabb = delaunay.Aabb{ .min = Vec3.make(-10, -10, -10), .max = Vec3.make(10, 10, 10) };

    var tri = try delaunay.Triangulation.init(a, aabb);
    defer tri.deinit(a);

    const points = [_]Vec3{
        Vec3.make(0.3, 1.7, -2.1),
        Vec3.make(4.2, -0.5, 3.3),
        Vec3.make(-3.1, 2.8, 0.9),
        Vec3.make(1.1, -4.4, -1.2),
        Vec3.make(-2.0, -1.3, 4.7),
        Vec3.make(2.9, 3.1, 1.8),
    };
    for (points) |p| _ = try tri.addVertex(a, p);

    var wrapper = try Wrapper.init(&tri, a);
    defer wrapper.deinit(a);

    const mesh = try mesh_mod.Mesh3D.init(
        a,
        &.{
            .{
                .position = Vec4.make(0, 0, 0, 1),
                .normal = Vec4.ZERO,
                .uv = Vec2.ZERO,
                .color = Vec4.ZERO,
            },
            .{
                .position = Vec4.make(1, 0, 0, 1),
                .normal = Vec4.ZERO,
                .uv = Vec2.ZERO,
                .color = Vec4.ZERO,
            },
            .{
                .position = Vec4.make(0, 1, 0, 1),
                .normal = Vec4.ZERO,
                .uv = Vec2.ZERO,
                .color = Vec4.ZERO,
            },
        },
        &.{ 0, 1, 2 },
    );
    defer mesh.deinit(a);

    const oracle = MeshOracle{
        .mesh = &mesh,
    }; // an enormous alpha should make every gate non-traversable immediately,
    // so nothing beyond the initial seed tags should ever get carved
    try wrapper.run(a, 1000.0, 1.0, oracle);

    var outside_count: usize = 0;
    for (wrapper.tags.items) |tag| {
        if (tag == .outside) outside_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), outside_count);
}

test "Wrapper.init tags every tetrahedron .inside before run()" {
    const a = std.testing.allocator;
    const aabb = delaunay.Aabb{ .min = Vec3.make(-10, -10, -10), .max = Vec3.make(10, 10, 10) };

    var tri = try delaunay.Triangulation.init(a, aabb);
    defer tri.deinit(a);

    const points = [_]Vec3{
        Vec3.make(0.3, 1.7, -2.1),
        Vec3.make(4.2, -0.5, 3.3),
        Vec3.make(-3.1, 2.8, 0.9),
    };
    for (points) |p| _ = try tri.addVertex(a, p);

    var wrapper = try Wrapper.init(&tri, a);
    defer wrapper.deinit(a);

    try std.testing.expectEqual(tri.tetrahedra.items.len, wrapper.tags.items.len);
    for (wrapper.tags.items) |tag| {
        try std.testing.expectEqual(Tag.inside, tag);
    }
}

const Point = struct {
    point: Vec3,
    dist: f32,
};

/// Closest point on triangle (a, b, c) to point p, and the distance to it.
fn closestPointOnTriangle(p: Vec3, a: Vec3, b: Vec3, c: Vec3) Point {
    // Standard closest-point-on-triangle via barycentric region tests.
    const ab = b.sub(a);
    const ac = c.sub(a);
    const ap = p.sub(a);

    const d1 = Vec3.dot(ab, ap);
    const d2 = Vec3.dot(ac, ap);
    if (d1 <= 0 and d2 <= 0) return .{ .point = a, .dist = a.eucDist(p) };

    const bp = p.sub(b);
    const d3 = Vec3.dot(ab, bp);
    const d4 = Vec3.dot(ac, bp);
    if (d3 >= 0 and d4 <= d3) return .{ .point = b, .dist = b.eucDist(p) };

    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 and d1 >= 0 and d3 <= 0) {
        const v = d1 / (d1 - d3);
        const pt = a.add(ab.mul(v));
        return .{ .point = pt, .dist = pt.eucDist(p) };
    }

    const cp = p.sub(c);
    const d5 = Vec3.dot(ab, cp);
    const d6 = Vec3.dot(ac, cp);
    if (d6 >= 0 and d5 <= d6) return .{ .point = c, .dist = c.eucDist(p) };

    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 and d2 >= 0 and d6 <= 0) {
        const w = d2 / (d2 - d6);
        const pt = a.add(ac.mul(w));
        return .{ .point = pt, .dist = pt.eucDist(p) };
    }

    const va = d3 * d6 - d5 * d4;
    if (va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0) {
        const w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        const pt = b.add(c.sub(b).mul(w));
        return .{ .point = pt, .dist = pt.eucDist(p) };
    }

    // p projects inside the triangle
    const denom = 1.0 / (va + vb + vc);
    const v = vb * denom;
    const w = vc * denom;
    const pt = a.add(ab.mul(v)).add(ac.mul(w));
    return .{ .point = pt, .dist = pt.eucDist(p) };
}

/// TODO
/// optimize! O(n)
fn tooCloseToExisting(tri: *const delaunay.Triangulation, p: Vec3, min_dist: f32) bool {
    for (tri.vertices.items) |v| {
        if (v.eucDist(p) < min_dist) return true;
    }
    return false;
}

pub const MeshOracle = struct {
    mesh: *const mesh_mod.Mesh3D,

    /// TODO OPTIMIZE: brute-force O(triangle count) per query. A BVH
    /// would make this practical for large meshes.
    fn triangleCount(self: MeshOracle) usize {
        return self.mesh.indices.len / 3;
    }

    fn triangle(self: MeshOracle, i: usize) [3]Vec3 {
        const zero = self.mesh.indices[i * 3 + 0];
        const one = self.mesh.indices[i * 3 + 1];
        const two = self.mesh.indices[i * 3 + 2];
        return .{
            self.mesh.vertices[zero].position.toVec3(),
            self.mesh.vertices[one].position.toVec3(),
            self.mesh.vertices[two].position.toVec3(),
        };
    }

    /// Unsigned distance from `p` to the mesh surface.
    pub fn distance(self: MeshOracle, p: Vec3) f32 {
        return self.closestPoint(p).dist;
    }

    /// Closest point on the mesh surface to `p`, and its distance.
    pub fn closestPoint(self: MeshOracle, p: Vec3) struct { point: Vec3, dist: f32 } {
        var best_dist: f32 = std.math.inf(f32);
        var best_point: Vec3 = undefined;

        var i: usize = 0;
        while (i < self.triangleCount()) : (i += 1) {
            const tri = self.triangle(i);
            const result = closestPointOnTriangle(p, tri[0], tri[1], tri[2]);
            if (result.dist < best_dist) {
                best_dist = result.dist;
                best_point = result.point;
            }
        }

        return .{ .point = best_point, .dist = best_dist };
    }

    /// Projects `p` onto the offset surface (the level set at distance
    /// `offset` from the mesh), moving away from the nearest surface point.
    pub fn projectToOffset(self: MeshOracle, p: Vec3, offset: f32) Vec3 {
        const closest = self.closestPoint(p);

        const dir = if (closest.dist > 1e-6)
            p.sub(closest.point).mul(1.0 / closest.dist)
        else
            Vec3.make(0, 1, 0); // p sits exactly on the surface; pick an arbitrary normal-ish direction

        return closest.point.add(dir.mul(offset));
    }

    /// Number of samples used to search for a crossing of the offset
    /// surface along a segment, before falling back to bisection to
    /// refine the result. Too few samples can miss narrow features
    /// smaller than segment_length / SEGMENT_SAMPLE_COUNT — see
    /// "segmentOffsetIntersection misses a narrow feature between coarse
    /// samples" test for a demonstrated failure case at low sample counts.
    const SEGMENT_SAMPLE_COUNT: usize = 32;
    /// Finds the first point along segment (from -> to) where the
    /// unsigned-distance-minus-offset field crosses zero, i.e. where
    /// the segment crosses the offset surface. Returns null if no
    /// crossing is found.
    ///
    /// Approximate: samples the segment, finds a sign change in
    /// (distance(p) - offset), then refines via bisection. This is not
    /// exact (a sufficiently thin feature between samples could be
    /// missed) but matches the "inexact by construction" nature of the
    /// original algorithm, which also has no closed-form solution here.
    pub fn segmentOffsetIntersection(self: MeshOracle, from: Vec3, to: Vec3, offset: f32) ?Vec3 {
        const f = struct {
            fn eval(oracle: MeshOracle, off: f32, p: Vec3) f32 {
                return oracle.distance(p) - off;
            }
        }.eval;

        var prev_t: f32 = 0.0;
        var prev_val = f(self, offset, from);

        var i: usize = 1;
        while (i <= SEGMENT_SAMPLE_COUNT) : (i += 1) {
            const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SEGMENT_SAMPLE_COUNT));
            const p = from.add(to.sub(from).mul(t));
            const val = f(self, offset, p);

            if ((prev_val <= 0) != (val <= 0)) {
                // sign change between prev_t and t: bisect to refine
                var lo_t = prev_t;
                var hi_t = t;
                var lo_val = prev_val;

                var iter: usize = 0;
                while (iter < 20) : (iter += 1) {
                    const mid_t = (lo_t + hi_t) * 0.5;
                    const mid_p = from.add(to.sub(from).mul(mid_t));
                    const mid_val = f(self, offset, mid_p);

                    if ((mid_val <= 0) == (lo_val <= 0)) {
                        lo_t = mid_t;
                        lo_val = mid_val;
                    } else {
                        hi_t = mid_t;
                    }
                }

                const result_t = (lo_t + hi_t) * 0.5;
                return from.add(to.sub(from).mul(result_t));
            }

            prev_t = t;
            prev_val = val;
        }

        return null;
    }

    /// Möller–Trumbore intersection algorithm
    /// https://en.wikipedia.org/wiki/M%C3%B6ller%E2%80%93Trumbore_intersection_algorithm#Rust_implementation
    /// With some LLM refinement for zig
    fn segmentTriangleIntersection(start: Vec3, end: Vec3, tri: [3]Vec3) ?Vec3 {
        const direction = end.sub(start);

        const e1 = tri[1].sub(tri[0]);
        const e2 = tri[2].sub(tri[0]);

        const h = direction.cross(e2);
        const det = e1.dot(h);

        if (@abs(det) < delaunay.EPSILON)
            return null;

        const inv_det = 1.0 / det;

        const s = start.sub(tri[0]);

        const u = inv_det * s.dot(h);
        if (u < 0 or u > 1)
            return null;

        const q = s.cross(e1);

        const v = inv_det * direction.dot(q);
        if (v < 0 or u + v > 1)
            return null;

        const t = inv_det * e2.dot(q);

        if (t < delaunay.EPSILON or t > 1.0 - delaunay.EPSILON)
            return null;

        return start.add(direction.mul(t));
    }

    pub fn tetIntersectsMesh(self: MeshOracle, tri: *const delaunay.Triangulation, tet: delaunay.Tetrahedron) bool {
        const tet_faces = tet.faces();

        var i: usize = 0;
        while (i < self.triangleCount()) : (i += 1) {
            const mesh_tri = self.triangle(i);

            // Case 1:
            // Any mesh vertex inside tet
            for (mesh_tri) |v| {
                if (tet.containsPoint(tri, v))
                    return true;
            }

            // Case 2:
            // Any mesh edge crosses tet face
            const edges = [_][2]Vec3{
                .{ mesh_tri[0], mesh_tri[1] },
                .{ mesh_tri[1], mesh_tri[2] },
                .{ mesh_tri[2], mesh_tri[0] },
            };

            for (edges) |edge| {
                for (tet_faces) |face| {
                    const face_tri = .{
                        tri.vertices.items[face.vertices[0]],
                        tri.vertices.items[face.vertices[1]],
                        tri.vertices.items[face.vertices[2]],
                    };

                    if (segmentTriangleIntersection(
                        edge[0],
                        edge[1],
                        face_tri,
                    ) != null) {
                        return true;
                    }
                }
            }
        }

        return false;
    }
};
