const std = @import("std");
/// BAD CLEAN THE METHODS ON ALL THESE STRUCTS

// FIXME: This is a temporary hack to deal with fabs being renamed abs in 0.12.0.
// Once 0.12 is officially released, we need to remove this
pub inline fn abs(f: anytype) @TypeOf(f) {
    const type_info = @typeInfo(@TypeOf(f));
    if (type_info != .float and type_info != .int) {
        @compileError("Expected integer or floating point type");
    }

    return if (f < 0) -f else f;
}

pub const Vec2 = extern struct {
    x: f32,
    y: f32,

    comptime {
        std.debug.assert(@alignOf(Vec2) == 4);
    }
    pub const ZERO = make(0.0, 0.0);

    pub inline fn fromSizedArray(array: [2]f32) Vec2 {
        return .{ .x = array[0], .y = array[1] };
    }

    pub inline fn make(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub inline fn toVec3(self: Vec2, z: f32) Vec3 {
        return .{ .x = self.x, .y = self.y, .z = z };
    }
};

pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    const Self = @This();

    pub const ZERO = make(0.0, 0.0, 0.0);
    pub const ONE = make(1.0, 1.0, 1.0);
    pub const UP = make(0.0, 0.0, 1.0);
    pub const FORWARD = make(0.0, 1.0, 0.0);
    pub const RIGHT = make(1.0, 0.0, 0.0);

    pub fn format(self: @This(), w: *std.Io.Writer) !void {
        try w.print(
            \\
            \\ x: {},
            \\ y: {},
            \\ z: {},
            \\
        , .{
            self.x,
            self.y,
            self.z,
        });
    }

    pub inline fn fromSizedArray(array: [3]f32) Self {
        return .{ .x = array[0], .y = array[1], .z = array[2] };
    }

    pub inline fn make(x: f32, y: f32, z: f32) Self {
        return .{ .x = x, .y = y, .z = z };
    }

    pub inline fn toVec4(self: Self, w: f32) Vec4 {
        return Vec4.make(self.x, self.y, self.z, w);
    }

    pub inline fn squaredNorm(self: Self) f32 {
        return self.dot(self);
    }

    pub fn norm(self: Self) f32 {
        return @sqrt(self.squaredNorm());
    }

    pub inline fn add(self: Self, other: Self) Self {
        return make(self.x + other.x, self.y + other.y, self.z + other.z);
    }

    pub fn negate(self: Vec3) Vec3 {
        return .{ .x = -self.x, .y = -self.y, .z = -self.z };
    }

    pub inline fn eucDist(self: Self, other: Self) f32 {
        return self.sub(other).norm();
    }

    pub inline fn distSquared(self: Self, other: Self) f64 {
        return self.sub(other).squaredNorm();
    }

    pub inline fn sub(self: Self, other: Self) Self {
        return make(self.x - other.x, self.y - other.y, self.z - other.z);
    }

    pub inline fn mul(self: Self, val: f32) Self {
        return make(self.x * val, self.y * val, self.z * val);
    }

    pub inline fn div(self: Self, other: f32) Self {
        return make(self.x / other, self.y / other, self.z / other);
    }

    pub inline fn normalized(self: Self) Self {
        const len = self.norm();
        return self.div(len);
    }

    pub inline fn dot(a: Self, b: Self) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub inline fn cross(a: Self, b: Self) Self {
        return Self.make(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x,
        );
    }
};

pub const Vec4 = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub const ZERO = make(0.0, 0.0, 0.0, 0.0);

    // Those are not real thing, however, they match my preference for 3d coordinates:
    // - x is right;
    // - y is forward;
    // - z is up.
    // The coordinate system is right-handed.
    // This allows to use x,y coordinates as a 2d vector on the floor plane (so to speak).
    pub const UP = make(0.0, 0.0, 1.0, 0.0);
    pub const FORWARD = make(0.0, 1.0, 0.0, 0.0);
    pub const RIGHT = make(1.0, 0.0, 0.0, 0.0);

    pub const IDENTITY = make(0.0, 0.0, 0.0, 1.0);

    const Self = @This();

    pub inline fn make(x: f32, y: f32, z: f32, w: f32) Self {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    // Whatever "forward" means at identity rotation
    // Z-up, forward along +Y: .{ .x = 0, .y = 1, .z = 0 }
    pub fn forwardVec3(rotation: Self) Vec3 {
        const base_forward = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
        return rotation.rotateVec3(base_forward);
    }

    pub fn upVec3(rotation: Self) Vec3 {
        const base_up = Vec3{ .x = 0.0, .y = 0.0, .z = 1.0 }; // Z-up
        return rotation.rotateVec3(base_up);
    }

    pub fn rotateVec3(self: Vec4, v: Vec3) Vec3 {
        const qv = Vec3{ .x = self.x, .y = self.y, .z = self.z };
        const uv = qv.cross(v);
        const uuv = qv.cross(uv);

        return .{
            .x = v.x + 2.0 * (self.w * uv.x + uuv.x),
            .y = v.y + 2.0 * (self.w * uv.y + uuv.y),
            .z = v.z + 2.0 * (self.w * uv.z + uuv.z),
        };
    }

    pub fn conjugate(self: Vec4) Vec4 {
        return .{
            .x = -self.x,
            .y = -self.y,
            .z = -self.z,
            .w = self.w,
        };
    }

    pub inline fn fromSizedArray(array: [4]f32) Self {
        return .{ .x = array[0], .y = array[1], .z = array[2], .w = array[3] };
    }

    pub fn add(self: Self, other: Self) Self {
        // The result is going to be a point if either of the operands is a point.
        return make(
            self.x + other.x,
            self.y + other.y,
            self.z + other.z,
            if (self.w > 0 or other.w > 0) 1.0 else 0.0,
        );
    }

    pub fn lookAt(position: Vec3, target: Vec3) Vec4 {
        const direction = target.sub(position).normalized();

        const yaw = std.math.atan2(direction.x, direction.y);
        const pitch = std.math.asin(direction.z);

        const yaw_rotation = Vec4.axisAngleQuaternion(
            Vec3.UP,
            -yaw,
        );

        const right = yaw_rotation.rotateVec3(Vec3.RIGHT);

        const pitch_rotation = Vec4.axisAngleQuaternion(
            right,
            pitch,
        );

        return pitch_rotation.mul(yaw_rotation);
    }

    /// Creates unit quaternion
    /// angle is in radians
    pub fn axisAngleQuaternion(axis: Vec3, angle: f32) Self {
        const magnitude = @sqrt(axis.dot(axis));

        if (magnitude == 0.0)
            return .make(1.0, 0.0, 0.0, 0.0);

        const ux, const uy, const uz = .{
            axis.x / magnitude,
            axis.y / magnitude,
            axis.z / magnitude,
        };

        const half_angle = angle / 2.0;

        const qx, const qy, const qz = .{
            ux * @sin(half_angle),
            uy * @sin(half_angle),
            uz * @sin(half_angle),
        };

        return .{
            .w = @cos(half_angle),
            .x = qx,
            .y = qy,
            .z = qz,
        };
    }

    pub inline fn mulScalar(self: Self, val: f32) Self {
        return make(self.x * val, self.y * val, self.z * val, self.w * val);
    }

    pub fn mul(self: Self, other: Self) Self {
        return .{
            .x = self.w * other.x + self.x * other.w + self.y * other.z - self.z * other.y,
            .y = self.w * other.y - self.x * other.z + self.y * other.w + self.z * other.x,
            .z = self.w * other.z + self.x * other.y - self.y * other.x + self.z * other.w,
            .w = self.w * other.w - self.x * other.x - self.y * other.y - self.z * other.z,
        };
    }

    pub fn nomalized(self: Self) Self {
        return self.to_vec3().normalized().toVec3(self.w);
    }

    pub fn toVec3(self: Self) Vec3 {
        return Vec3.make(self.x, self.y, self.z);
    }

    pub fn dot(a: Self, b: Self) callconv(.Inline) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }
};

pub const Mat3 = struct {
    i: Vec3,
    j: Vec3,
    k: Vec3,

    pub const IDENTITY: @This() = make(
        Vec3.make(1.0, 0.0, 0.0),
        Vec3.make(0.0, 1.0, 0.0),
        Vec3.make(0.0, 0.0, 1.0),
    );

    pub inline fn make(i: Vec3, j: Vec3, k: Vec3) @This() {
        return .{ .i = i, .j = j, .k = k };
    }

    pub fn determinant(
        self: @This(),
    ) f32 {
        return self.i.x * (self.j.y * self.k.z - self.j.z * self.k.y) -
            self.i.y * (self.j.x * self.k.z - self.j.z * self.k.x) +
            self.i.z * (self.j.x * self.k.y - self.j.y * self.k.x);
    }
};

pub const Mat4 = extern struct {
    i: Vec4,
    j: Vec4,
    k: Vec4,
    t: Vec4,

    const Self = @This();

    pub const IDENTITY: @This() = make(
        Vec4.make(1.0, 0.0, 0.0, 0.0),
        Vec4.make(0.0, 1.0, 0.0, 0.0),
        Vec4.make(0.0, 0.0, 1.0, 0.0),
        Vec4.make(0.0, 0.0, 0.0, 1.0),
    );

    pub inline fn lookAt(eye: Vec3, target: Vec3) Self {
        const f = target.sub(eye).normalized();
        const r = f.cross(Vec3.UP).normalized();
        const u = r.cross(f);

        return Mat4{
            .i = Vec4.make(r.x, u.x, -f.x, 0),
            .j = Vec4.make(r.y, u.y, -f.y, 0),
            .k = Vec4.make(r.z, u.z, -f.z, 0),
            .t = Vec4.make(-r.dot(eye), -u.dot(eye), f.dot(eye), 1),
        };
    }

    pub inline fn make(i: Vec4, j: Vec4, k: Vec4, t: Vec4) Self {
        return .{ .i = i, .j = j, .k = k, .t = t };
    }

    pub fn transposed(self: Self) Self {
        return make(
            Vec4.make(self.i.x, self.j.x, self.k.x, self.t.x),
            Vec4.make(self.i.y, self.j.y, self.k.y, self.t.y),
            Vec4.make(self.i.z, self.j.z, self.k.z, self.t.z),
            Vec4.make(self.i.w, self.j.w, self.k.w, self.t.w),
        );
    }

    pub fn mul(ma: Self, mb: Self) Self {
        return make(
            Vec4.make(ma.i.x * mb.i.x + ma.j.x * mb.i.y + ma.k.x * mb.i.z + ma.t.x * mb.i.w, ma.i.y * mb.i.x + ma.j.y * mb.i.y + ma.k.y * mb.i.z + ma.t.y * mb.i.w, ma.i.z * mb.i.x + ma.j.z * mb.i.y + ma.k.z * mb.i.z + ma.t.z * mb.i.w, ma.i.w * mb.i.x + ma.j.w * mb.i.y + ma.k.w * mb.i.z + ma.t.w * mb.i.w),
            Vec4.make(ma.i.x * mb.j.x + ma.j.x * mb.j.y + ma.k.x * mb.j.z + ma.t.x * mb.j.w, ma.i.y * mb.j.x + ma.j.y * mb.j.y + ma.k.y * mb.j.z + ma.t.y * mb.j.w, ma.i.z * mb.j.x + ma.j.z * mb.j.y + ma.k.z * mb.j.z + ma.t.z * mb.j.w, ma.i.w * mb.j.x + ma.j.w * mb.j.y + ma.k.w * mb.j.z + ma.t.w * mb.j.w),
            Vec4.make(ma.i.x * mb.k.x + ma.j.x * mb.k.y + ma.k.x * mb.k.z + ma.t.x * mb.k.w, ma.i.y * mb.k.x + ma.j.y * mb.k.y + ma.k.y * mb.k.z + ma.t.y * mb.k.w, ma.i.z * mb.k.x + ma.j.z * mb.k.y + ma.k.z * mb.k.z + ma.t.z * mb.k.w, ma.i.w * mb.k.x + ma.j.w * mb.k.y + ma.k.w * mb.k.z + ma.t.w * mb.k.w),
            Vec4.make(ma.i.x * mb.t.x + ma.j.x * mb.t.y + ma.k.x * mb.t.z + ma.t.x * mb.t.w, ma.i.y * mb.t.x + ma.j.y * mb.t.y + ma.k.y * mb.t.z + ma.t.y * mb.t.w, ma.i.z * mb.t.x + ma.j.z * mb.t.y + ma.k.z * mb.t.z + ma.t.z * mb.t.w, ma.i.w * mb.t.x + ma.j.w * mb.t.y + ma.k.w * mb.t.z + ma.t.w * mb.t.w),
        );
    }

    /// Create a translation matrix
    pub fn translation(v: Vec3) Mat4 {
        return make(
            Vec4.make(1.0, 0.0, 0.0, 0.0),
            Vec4.make(0.0, 1.0, 0.0, 0.0),
            Vec4.make(0.0, 0.0, 1.0, 0.0),
            v.toVec4(1.0),
        );
    }

    /// Returns a new matrix obtained by translating the input one.
    pub fn translate(self: Self, v: Vec3) Self {
        return make(
            self.i,
            self.j,
            self.k,
            self.t.add(v.toVec4(0.0)),
        );
    }

    /// Create a perspective projection matrix
    /// The result matrix is for a right-handed, zero to one, clipping space.
    pub fn perspective(fovy_rad: f32, aspect: f32, near: f32, far: f32) Mat4 {
        std.debug.assert(abs(aspect) > 0.0001);
        const f = 1.0 / @tan(fovy_rad / 2.0);

        return make(
            Vec4.make(f / aspect, 0.0, 0.0, 0.0),
            Vec4.make(0.0, f, 0.0, 0.0),
            Vec4.make(0.0, 0.0, far / (near - far), -1.0),
            Vec4.make(0.0, 0.0, -(far * near) / (far - near), 0.0),
        );
    }

    pub fn scale(v: Vec3) Mat4 {
        return make(
            Vec4.make(v.x, 0.0, 0.0, 0.0),
            Vec4.make(0.0, v.y, 0.0, 0.0),
            Vec4.make(0.0, 0.0, v.z, 0.0),
            Vec4.make(0.0, 0.0, 0.0, 1.0),
        );
    }
};
