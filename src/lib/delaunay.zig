const std = @import("std");
const core = @import("../root.zig");
const math_mod = core.lib.math;
const mesh_mod = core.lib.mesh;
const Allocator = std.mem.Allocator;
const Vec3 = math_mod.Vec3;
const Mat3 = math_mod.Mat3;

const DelaunayError = error{
    PointOutsideTriangulation,
    DegenerateTetrahedron,
    DegenerateTriangle,
    DegenerateCavity,
};
const Error = Allocator.Error || DelaunayError;

pub const Aabb = struct {
    min: Vec3,
    max: Vec3,

    pub fn computeFromMesh(mesh: mesh_mod.Mesh3D) @This() {
        std.debug.assert(mesh.vertices.len > 0);

        const first = mesh.vertices[0].position.toVec3();

        var min = first;
        var max = first;

        for (mesh.vertices[1..]) |vertex| {
            const p = vertex.position.toVec3();

            min.x = @min(min.x, p.x);
            min.y = @min(min.y, p.y);
            min.z = @min(min.z, p.z);

            max.x = @max(max.x, p.x);
            max.y = @max(max.y, p.y);
            max.z = @max(max.z, p.z);
        }

        return .{
            .min = min,
            .max = max,
        };
    }

    /// Returns corners in order shown below
    ///     7------6
    ///    /|     /|
    ///   4------5 |
    ///   | |    | |
    ///   | 3----|-2
    ///   |/     |/
    ///   0------1
    ///
    pub fn corners(self: Aabb) [8]Vec3 {
        return .{
            Vec3.make(self.min.x, self.min.y, self.min.z), // 0
            Vec3.make(self.max.x, self.min.y, self.min.z), // 1
            Vec3.make(self.max.x, self.max.y, self.min.z), // 2
            Vec3.make(self.min.x, self.max.y, self.min.z), // 3

            Vec3.make(self.min.x, self.min.y, self.max.z), // 4
            Vec3.make(self.max.x, self.min.y, self.max.z), // 5
            Vec3.make(self.max.x, self.max.y, self.max.z), // 6
            Vec3.make(self.min.x, self.max.y, self.max.z), // 7
        };
    }

    pub fn center(self: Aabb) Vec3 {
        return self.min.add(self.max).mul(0.5);
    }

    pub fn size(self: Aabb) Vec3 {
        return self.max.sub(self.min);
    }

    pub fn diagonal(self: Aabb) f32 {
        return self.max.sub(self.min).norm();
    }

    pub fn expand(self: *Aabb, amount: f32) void {
        const delta = Vec3.make(amount, amount, amount);
        self.min = self.min.sub(delta);
        self.max = self.max.add(delta);
    }
};

pub const Tetrahedron = struct {
    /// we store vertices indices
    vertices: [4]usize,

    pub fn vertex(self: Tetrahedron, mesh: *const Triangulation, i: usize) Vec3 {
        return mesh.vertices.items[self.vertices[i]];
    }

    pub fn containsPoint(
        self: Tetrahedron,
        mesh: *const Triangulation,
        p: Vec3,
    ) bool {
        const a = self.vertex(mesh, 0);
        const b = self.vertex(mesh, 1);
        const c = self.vertex(mesh, 2);
        const d = self.vertex(mesh, 3);

        const eps: f32 = 1e-5;

        const v = signedVolume(a, b, c, d);

        const v0 = signedVolume(p, b, c, d);
        const v1 = signedVolume(a, p, c, d);
        const v2 = signedVolume(a, b, p, d);
        const v3 = signedVolume(a, b, c, p);

        if (v > 0) {
            return v0 >= -eps and
                v1 >= -eps and
                v2 >= -eps and
                v3 >= -eps;
        } else {
            return v0 <= eps and
                v1 <= eps and
                v2 <= eps and
                v3 <= eps;
        }
    }

    fn signedVolume(
        a: Vec3,
        b: Vec3,
        c: Vec3,
        d: Vec3,
    ) f32 {
        return Vec3.dot(
            b.sub(a),
            Vec3.cross(
                c.sub(a),
                d.sub(a),
            ),
        );
    }

    pub fn faces(tet: @This()) [4]Triangulation.Face {
        return .{
            .{ .vertices = .{ tet.vertices[0], tet.vertices[2], tet.vertices[1] } },
            .{ .vertices = .{ tet.vertices[0], tet.vertices[1], tet.vertices[3] } },
            .{ .vertices = .{ tet.vertices[0], tet.vertices[3], tet.vertices[2] } },
            .{ .vertices = .{ tet.vertices[1], tet.vertices[2], tet.vertices[3] } },
        };
    }

    pub fn circumsphere(
        self: @This(),
        triangulation: *const Triangulation,
    ) DelaunayError!Circumsphere {
        const center = try Circumsphere.circumcenter(
            triangulation.vertices.items[self.vertices[0]],
            triangulation.vertices.items[self.vertices[1]],
            triangulation.vertices.items[self.vertices[2]],
            triangulation.vertices.items[self.vertices[3]],
        );

        return .{
            .center = center,
            .radius = center.eucDist(triangulation.vertices.items[self.vertices[0]]),
        };
    }

    pub const Circumsphere = struct {
        center: Vec3,
        radius: f32,

        pub fn containsPoint(
            self: Circumsphere,
            p: Vec3,
        ) bool {
            return self.center.eucDist(p) <= self.radius + 1e-5;
        }

        fn circumcenter(
            a: Vec3,
            b: Vec3,
            c: Vec3,
            d: Vec3,
        ) DelaunayError!Vec3 {
            const row0 = b.sub(a);
            const row1 = c.sub(a);
            const row2 = d.sub(a);

            const matrix = Mat3.make(row0, row1, row2);

            const rhs = Vec3.make(
                (b.squaredNorm() - a.squaredNorm()) * 0.5,
                (c.squaredNorm() - a.squaredNorm()) * 0.5,
                (d.squaredNorm() - a.squaredNorm()) * 0.5,
            );

            const det = matrix.determinant();

            // Degenerate tetrahedron
            if (@abs(det) < 1e-6)
                return error.DegenerateTetrahedron;

            const dx = Mat3.make(
                Vec3.make(rhs.x, row0.y, row0.z),
                Vec3.make(rhs.y, row1.y, row1.z),
                Vec3.make(rhs.z, row2.y, row2.z),
            ).determinant();

            const dy = Mat3.make(
                Vec3.make(row0.x, rhs.x, row0.z),
                Vec3.make(row1.x, rhs.y, row1.z),
                Vec3.make(row2.x, rhs.z, row2.z),
            ).determinant();

            const dz = Mat3.make(
                Vec3.make(row0.x, row0.y, rhs.x),
                Vec3.make(row1.x, row1.y, rhs.y),
                Vec3.make(row2.x, row2.y, rhs.z),
            ).determinant();

            return Vec3.make(
                dx / det,
                dy / det,
                dz / det,
            );
        }
    };
};

pub const Triangulation = struct {
    vertices: std.ArrayList(Vec3),
    free_slots: std.AutoHashMap(usize, void),
    tetrahedra: std.ArrayList(?Tetrahedron),
    adjacency: FaceAdjacency,

    pub const Face = struct {
        /// vertex indices in original winding order (as they appeared on the
        /// tetrahedron), used later to build the new tetrahedron correctly
        vertices: [3]usize,

        /// canonical form for equality checks, independent of winding
        fn key(self: Triangulation.Face) [3]usize {
            var k = self.vertices;
            std.mem.sort(usize, &k, {}, std.sort.asc(usize));
            return k;
        }

        fn eql(a: Triangulation.Face, b: Triangulation.Face) bool {
            return std.mem.eql(usize, &a.key(), &b.key());
        }

        /// Radius of the circle passing through all 3 vertices of this
        /// face. Used to rank gates during alpha-wrapping traversal.
        pub fn circumradius(self: Triangulation.Face, tri: *const Triangulation) DelaunayError!f32 {
            const a = tri.vertices.items[self.vertices[0]];
            const b = tri.vertices.items[self.vertices[1]];
            const c = tri.vertices.items[self.vertices[2]];

            const ab = b.sub(a);
            const ac = c.sub(a);
            const bc = c.sub(b);

            const double_area = Vec3.cross(ab, ac).norm();

            if (double_area < 1e-9)
                return error.DegenerateTriangle;

            return (ab.norm() * ac.norm() * bc.norm()) / (2.0 * double_area);
        }
    };

    pub const FaceAdjacency = struct {
        map: std.AutoHashMapUnmanaged([3]usize, Entry),

        const Location = struct {
            tet: usize,
            face: usize,
        };

        const Entry = struct {
            first: ?Location = null,
            second: ?Location = null,
        };

        pub fn deinit(self: *FaceAdjacency, a: Allocator) void {
            self.map.deinit(a);
        }

        pub fn addTetrahedron(self: *FaceAdjacency, a: Allocator, tet_idx: usize, tet: Tetrahedron) Allocator.Error!void {
            for (tet.faces(), 0..) |face, face_idx| {
                const key = face.key();
                const gop = try self.map.getOrPut(a, key);
                if (!gop.found_existing) gop.value_ptr.* = .{};

                const loc = Location{ .tet = tet_idx, .face = face_idx };
                if (gop.value_ptr.first == null) {
                    gop.value_ptr.first = loc;
                } else if (gop.value_ptr.second == null) {
                    gop.value_ptr.second = loc;
                } else unreachable; // face shared by 3+ tets: corrupted triangulation

            }
        }

        pub fn removeTetrahedron(self: *FaceAdjacency, tet_idx: usize, tet: Tetrahedron) void {
            for (tet.faces()) |face| {
                const key = face.key();
                const entry = self.map.getPtr(key) orelse unreachable;

                if (entry.first != null and entry.first.?.tet == tet_idx) {
                    entry.first = entry.second;
                    entry.second = null;
                } else if (entry.second != null and entry.second.?.tet == tet_idx) {
                    entry.second = null;
                } else unreachable; // tet_idx wasn't registered for this face

                if (entry.first == null and entry.second == null) {
                    _ = self.map.remove(key);
                }
            }
        }

        pub fn neighborLocation(self: FaceAdjacency, tet_idx: usize, face_idx: usize, tet: Tetrahedron) ?Location {
            const key = tet.faces()[face_idx].key();
            const entry = self.map.get(key) orelse return null;

            const first = entry.first orelse return null;
            if (first.tet == tet_idx and first.face == face_idx) return entry.second;

            const second = entry.second orelse return null;
            if (second.tet == tet_idx and second.face == face_idx) return first;

            unreachable;
        }
    };

    pub fn deinit(self: *@This(), a: Allocator) void {
        self.tetrahedra.deinit(a);
        self.vertices.deinit(a);
        self.free_slots.deinit();
        self.adjacency.deinit(a);
    }

    /// creates a single large tetrahedron that fits the
    /// entirety of the aabb
    pub fn init(a: Allocator, aabb: Aabb) Allocator.Error!@This() {
        var tri = @This(){
            .vertices = try std.ArrayList(Vec3).initCapacity(a, 64),
            .free_slots = std.AutoHashMap(usize, void).init(a),
            .tetrahedra = try std.ArrayList(?Tetrahedron).initCapacity(a, 64),
            .adjacency = .{ .map = .{} },
        };

        const center = aabb.center();

        // Make the tetrahedron comfortably larger than the box.
        const s = aabb.diagonal() * 4.0;

        try tri.vertices.appendSlice(a, &.{
            center.add(Vec3.make(s, s, s)),
            center.add(Vec3.make(-s, -s, s)),
            center.add(Vec3.make(-s, s, -s)),
            center.add(Vec3.make(s, -s, -s)),
        });

        _ = try tri.addTetrahedron(a, .{ 0, 1, 2, 3 });

        return tri;
    }

    /// TODO OPTIMIZE
    fn findContainingTetrahedron(self: *const @This(), point: Vec3) ?usize {
        for (self.tetrahedra.items, 0..) |tet, i| {
            // BAD
            if (tet == null) continue;
            if (tet.?.containsPoint(self, point)) return i;
        }
        return null;
    }

    /// TODO OPTIMIZE
    fn findCavity(self: *const @This(), a: Allocator, point: Vec3) Allocator.Error!?[]usize {
        var cavity: std.ArrayList(usize) = try .initCapacity(a, 8);
        errdefer cavity.deinit(a);

        for (self.tetrahedra.items, 0..) |tet, i| {
            // BAD
            if (tet == null) continue;
            const sphere = tet.?.circumsphere(self) catch continue; // skip degenerate tets
            if (sphere.containsPoint(point)) {
                try cavity.append(a, i);
            }
        }

        if (cavity.items.len == 0) return null;

        return try cavity.toOwnedSlice(a);
    }

    /// TODO OPTIMIZE
    fn findBoundaryFaces(
        self: *const @This(),
        a: std.mem.Allocator,
        cavity: []const usize,
    ) Allocator.Error![]Triangulation.Face {
        var all_faces: std.ArrayList(Triangulation.Face) = try .initCapacity(a, cavity.len * 4);
        defer all_faces.deinit(a);

        for (cavity) |tet_index| {
            if (self.tetrahedra.items[tet_index]) |tet| {
                for (tet.faces()) |face| {
                    try all_faces.append(a, face);
                }
            }
        }

        var boundary: std.ArrayList(Triangulation.Face) = try .initCapacity(a, all_faces.items.len);
        errdefer boundary.deinit(a);

        for (all_faces.items) |face| {
            var count: usize = 0;
            for (all_faces.items) |other| {
                if (face.eql(other)) count += 1;
            }
            if (count == 1) {
                try boundary.append(a, face);
            }
        }

        return boundary.toOwnedSlice(a);
    }

    pub fn removeSuperTetrahedron(self: *@This(), a: Allocator) Allocator.Error!void {
        // 1. Drop tetrahedra that still touch a super-vertex, via the same
        //    tombstoning path as normal removal (keeps adjacency consistent).
        var to_remove: std.ArrayList(usize) = .{};
        defer to_remove.deinit(a);

        for (self.tetrahedra.items, 0..) |maybe_tet, i| {
            const tet = maybe_tet orelse continue;
            const touches_super = tet.vertices[0] < 4 or
                tet.vertices[1] < 4 or
                tet.vertices[2] < 4 or
                tet.vertices[3] < 4;
            if (touches_super) try to_remove.append(a, i);
        }

        for (to_remove.items) |idx| {
            const tet = self.tetrahedra.items[idx].?;
            self.adjacency.removeTetrahedron(idx, tet);
            self.tetrahedra.items[idx] = null;
        }
        for (to_remove.items) |i| {
            try self.free_slots.put(i, {});
        }

        // 2. Drop the 4 super-vertices themselves.
        var new_vertices: std.ArrayList(Vec3) = try .initCapacity(a, self.vertices.items.len - 4);
        errdefer new_vertices.deinit(a);
        try new_vertices.appendSlice(a, self.vertices.items[4..]);
        self.vertices.deinit(a);
        self.vertices = new_vertices;

        // 3. Remap every remaining (non-null) tetrahedron's indices down by 4.
        // Note: adjacency's Face keys are derived from these vertex indices,
        // so remapping in place invalidates the existing adjacency map's keys.
        // Rebuild it fresh afterward rather than trying to patch it incrementally.
        for (self.tetrahedra.items) |*maybe_tet| {
            const tet = if (maybe_tet.*) |*t| t else continue;
            for (&tet.vertices) |*vi| vi.* -= 4;
        }

        var new_adjacency = FaceAdjacency{ .map = .{} };
        for (self.tetrahedra.items, 0..) |maybe_tet, i| {
            const tet = maybe_tet orelse continue;
            try new_adjacency.addTetrahedron(a, i, tet);
        }
        self.adjacency.deinit(a);
        self.adjacency = new_adjacency;
    }

    fn removeTetrahedra(self: *@This(), cavity: []const usize) Allocator.Error!void {
        for (cavity) |idx| {
            const tet = self.tetrahedra.items[idx] orelse unreachable;
            self.adjacency.removeTetrahedron(idx, tet);
            self.tetrahedra.items[idx] = null;
        }
        for (cavity) |i| {
            try self.free_slots.put(i, {});
        }
    }

    fn removeNextFreeSlot(self: *@This()) ?usize {
        var keys = self.free_slots.keyIterator();
        const entry = self.free_slots.fetchRemove((keys.next() orelse return null).*);
        return entry.?.key;
    }

    fn addTetrahedron(self: *@This(), a: Allocator, verts: [4]usize) Allocator.Error!usize {
        const tet = Tetrahedron{ .vertices = verts };
        const next_free_slot = self.removeNextFreeSlot();
        const idx = next_free_slot orelse self.tetrahedra.items.len;

        if (next_free_slot == null)
            try self.tetrahedra.append(a, tet)
        else
            self.tetrahedra.items[idx] = tet;

        try self.adjacency.addTetrahedron(a, idx, tet);
        return idx;
    }

    fn fillCavity(
        self: *@This(),
        a: Allocator,
        boundary: []const Triangulation.Face,
        new_vertex: usize,
        new_tets: ?*std.ArrayList(usize),
    ) Error!void {
        for (boundary) |face| {
            var verts = [4]usize{ face.vertices[0], face.vertices[1], face.vertices[2], new_vertex };

            const vol = Tetrahedron.signedVolume(
                self.vertices.items[verts[0]],
                self.vertices.items[verts[1]],
                self.vertices.items[verts[2]],
                self.vertices.items[verts[3]],
            );
            if (vol < 0) std.mem.swap(usize, &verts[0], &verts[1]);

            if (std.debug.runtime_safety) {
                const fixed_vol = Tetrahedron.signedVolume(
                    self.vertices.items[verts[0]],
                    self.vertices.items[verts[1]],
                    self.vertices.items[verts[2]],
                    self.vertices.items[verts[3]],
                );
                std.debug.assert(fixed_vol > 0);
            }

            const tet_idx = try self.addTetrahedron(a, verts);
            if (new_tets) |list| try list.append(a, tet_idx);
        }
    }

    /// Same as addVertex, but appends the index of every newly-created
    /// tetrahedron to `new_tets`. Used by callers (e.g. alpha-wrapping)
    /// that need to know exactly what changed as a result of insertion.
    pub fn addVertexTracked(
        self: *@This(),
        a: Allocator,
        point: Vec3,
        new_tets: *std.ArrayList(usize),
    ) Error!usize {
        const new_vertex_idx = self.vertices.items.len;
        try self.vertices.append(a, point);

        const cavity = (try self.findCavity(a, point)) orelse return error.PointOutsideTriangulation;
        defer a.free(cavity);

        const boundary = try self.findBoundaryFaces(a, cavity);
        defer a.free(boundary);

        try self.removeTetrahedra(cavity);
        if (!isValidCavityBoundary(boundary)) return error.DegenerateCavity;
        try self.fillCavity(a, boundary, @intCast(new_vertex_idx), new_tets);

        return new_vertex_idx;
    }

    pub fn addVertex(self: *@This(), a: Allocator, point: Vec3) Error!usize {
        const new_vertex_idx = self.vertices.items.len;
        try self.vertices.append(a, point);

        const cavity = (try self.findCavity(a, point)) orelse return error.PointOutsideTriangulation;
        defer a.free(cavity);

        const boundary = try self.findBoundaryFaces(a, cavity);
        defer a.free(boundary);

        try self.removeTetrahedra(cavity);

        if (!isValidCavityBoundary(boundary)) return error.DegenerateCavity;
        try self.fillCavity(a, boundary, @intCast(new_vertex_idx), null);

        return new_vertex_idx;
    }

    /// Debug-only integrity check: verifies that `boundary` describes a
    /// well-formed cavity boundary before we attempt to stitch new
    /// tetrahedra onto it. Catches cavity/adjacency corruption at its
    /// source rather than downstream in addTetrahedron's "3+ tets share
    /// a face" crash, which is much harder to trace back to its cause.
    fn isValidCavityBoundary(boundary: []const Triangulation.Face) bool {
        // existing per-face checks (duplicate faces, already-full adjacency)...
        // [keep what you already have here]

        // NEW: edge-manifoldness check
        const Edge = struct {
            a: usize,
            b: usize,

            fn make(x: usize, y: usize) @This() {
                return if (x < y) .{ .a = x, .b = y } else .{ .a = y, .b = x };
            }
        };

        var edge_counts = std.AutoHashMap(Edge, usize).init(std.heap.page_allocator);
        defer edge_counts.deinit();

        for (boundary) |face| {
            const edges = [_]Edge{
                Edge.make(face.vertices[0], face.vertices[1]),
                Edge.make(face.vertices[1], face.vertices[2]),
                Edge.make(face.vertices[2], face.vertices[0]),
            };
            for (edges) |e| {
                const gop = edge_counts.getOrPut(e) catch unreachable;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }

        var it = edge_counts.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != 2) {
                return false;
            }
        }
        return true;
    }
};

test "Triangulation.Face.circumradius matches closed form for equilateral triangle" {
    const a = std.testing.allocator;
    var tri = try Triangulation.init(a, .{ .min = Vec3.make(-10, -10, -10), .max = Vec3.make(10, 10, 10) });
    defer tri.deinit(a);
    tri.tetrahedra.clearRetainingCapacity();

    const base = tri.vertices.items.len;

    // equilateral triangle with side length 2, centered at origin, in the XY plane
    try tri.vertices.appendSlice(a, &.{
        Vec3.make(1, 0, 0),
        Vec3.make(-0.5, std.math.sqrt(3.0) / 2.0, 0),
        Vec3.make(-0.5, -std.math.sqrt(3.0) / 2.0, 0),
    });

    const face = Triangulation.Face{ .vertices = .{ base + 0, base + 1, base + 2 } };
    const r = try face.circumradius(&tri);

    // side length here is sqrt(3) (distance between any two of the above points);
    // expected circumradius = s / sqrt(3) = 1.0
    try std.testing.expect(@abs(r - 1.0) < 0.001);
}

test "Triangulation.Face.circumradius returns error for degenerate (collinear) triangle" {
    const a = std.testing.allocator;
    var tri = try Triangulation.init(a, .{ .min = Vec3.make(-10, -10, -10), .max = Vec3.make(10, 10, 10) });
    defer tri.deinit(a);
    tri.tetrahedra.clearRetainingCapacity();

    const base = tri.vertices.items.len;
    try tri.vertices.appendSlice(a, &.{
        Vec3.make(0, 0, 0),
        Vec3.make(1, 0, 0),
        Vec3.make(2, 0, 0), // collinear with the above two
    });

    const face = Triangulation.Face{ .vertices = .{ base + 0, base + 1, base + 2 } };
    try std.testing.expectError(error.DegenerateTriangle, face.circumradius(&tri));
}
