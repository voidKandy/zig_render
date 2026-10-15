const std = @import("std");
const core = @import("../../root.zig");
const predicates = core.clibs.predicates;
pub const Aabb = core.resources.Meshes3D.Aabb;

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

    pub fn norm(self: @This()) f32 {
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

// inline int to_int(Sign s) { return static_cast<int>(s); }

// orient3d(a,b,c,d):
//   POSITIVE  if d is on the positive side of the oriented plane (a,b,c), i.e.
//             the scalar triple product (b-a) . ((c-a) x (d-a)) > 0, which is
//             +1 for the reference tetrahedron a=(0,0,0) b=(1,0,0) c=(0,1,0)
//             d=(0,0,1). Equivalently, (a,b,c,d) is a positively oriented tet.
//   NEGATIVE  if d is on the negative side.
//   ZERO      if a,b,c,d are coplanar.
// Exact.
// Sign orient3d(const Vec3& a, const Vec3& b, const Vec3& c, const Vec3& d);
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

// // insphere(a,b,c,d,e):
// //   POSITIVE  if e lies strictly inside the sphere through a,b,c,d,
// //   NEGATIVE  if strictly outside,
// //   ZERO      if exactly cospherical.
// // Convention is independent of the orientation of (a,b,c,d): the result is
// // normalized by the orientation sign, so callers may pass the four tet vertices
// // in any order. Exact (returns ZERO on exact cospherical input; symbolic
// // perturbation for Delaunay is layered on top of this in delaunay.cpp).
// Sign insphere(const Vec3& a, const Vec3& b, const Vec3& c, const Vec3& d,
//               const Vec3& e);

// // Non-robust fast variants (used only where an approximate answer is
// // acceptable, e.g. spatial heuristics). Return a raw double sign.
// double orient3d_fast(const Vec3& a, const Vec3& b, const Vec3& c, const Vec3& d);
