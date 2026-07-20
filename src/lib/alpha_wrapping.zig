const std = @import("std");
const core = @import("../root.zig");
const math_mod = core.lib.math;
const mesh_mod = core.lib.mesh;
const Vec3 = math_mod.Vec3;

pub const delaunay = struct {
    const Tetrahedron = struct {
        /// we store vertices indices
        vertices: [4]usize,

        pub fn vertex(self: Tetrahedron, mesh: *const Mesh, i: usize) Vec3 {
            return mesh.vertices.items[self.vertices[i]];
        }

        pub fn containsPoint(
            self: Tetrahedron,
            mesh: *const Mesh,
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
    };

    pub const Mesh = struct {
        vertices: std.ArrayList(Vec3),
        tetrahedra: std.ArrayList(Tetrahedron),

        fn deinit(self: *@This(), a: std.mem.Allocator) void {
            self.tetrahedra.deinit(a);
            self.vertices.deinit(a);
        }

        /// creates a single large tetrahedron that fits the
        /// entirety of the aabb
        pub fn init(a: std.mem.Allocator, aabb: Aabb) std.mem.Allocator.Error!@This() {
            var mesh = Mesh{
                .vertices = try std.ArrayList(Vec3).initCapacity(a, 4),
                .tetrahedra = try std.ArrayList(Tetrahedron).initCapacity(a, 1),
            };

            const center = aabb.center();

            // Make the tetrahedron comfortably larger than the box.
            const s = aabb.diagonal() * 4.0;

            try mesh.vertices.appendSlice(a, &.{
                center.add(Vec3.make(s, s, s)),
                center.add(Vec3.make(-s, -s, s)),
                center.add(Vec3.make(-s, s, -s)),
                center.add(Vec3.make(s, -s, -s)),
            });

            try mesh.tetrahedra.append(a, .{
                .vertices = .{ 0, 1, 2, 3 },
            });

            return mesh;
        }
    };
};

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

test "super tetrahedron contains AABB" {
    const a = std.testing.allocator;

    var maze = try core.lib.Maze.init(a, 10, 10);
    defer maze.deinit(a);

    const maze_mesh_options = core.lib.Maze.MeshOptions{
        .cell_size = 2.0,
        .wall_height = 2.0,
        .margin = .{
            .x = 0.5,
            .y = 0.5,
            .z = 0.0,
        },
        .origin = .{
            .x = 4.0,
            .y = 0.0,
            .z = 0.0,
        },
    };

    var maze_mesh = try maze_mesh_options.createMesh(a, maze);
    defer maze_mesh.deinit(a);

    const aabb = Aabb.computeFromMesh(maze_mesh);

    var delaunay_mesh = try delaunay.Mesh.init(a, aabb);
    defer delaunay_mesh.deinit(a);

    const tet = delaunay_mesh.tetrahedra.items[0];

    for (aabb.corners()) |corner| {
        try std.testing.expect(
            tet.containsPoint(&delaunay_mesh, corner),
        );
    }
}
