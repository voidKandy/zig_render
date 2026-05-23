const std = @import("std");
const core = @import("root.zig");
const c = core.clibs;
const vk = c.vk;
const vki = core.vulkan_init;
const checkVk = vki.checkVk;
const Vec3 = core.math.Vec3;
const Mat4 = core.math.Mat4;

pub const GPUData = struct {
    view: Mat4,
    proj: Mat4,
};

near_plane: f32 = 0.1,
far_plane: f32 = 100.0,
fov: f32 = 45.0,

eye: Vec3 = DEFAULT_EYE,
target: Vec3 = DEFAULT_TARGET,
distance: f32 = DEFAULT_EYE.eucDist(DEFAULT_TARGET),

mode: Mode = .user_input,

const DEFAULT_EYE: Vec3 = Vec3.make(4.0, 4.0, 4.0);
const DEFAULT_TARGET: Vec3 = Vec3.make(0.0, 0.0, 1.0);

pub const Mode = enum {
    rotate_around,
    user_input,
};

pub fn createGPUData(self: @This(), extent: vk.Extent2D) GPUData {
    const aspect =
        @as(f32, @floatFromInt(extent.width)) /
        @as(f32, @floatFromInt(extent.height));

    return core.Camera.GPUData{
        .view = core.math.Mat4.lookAt(
            self.eye,
            self.target,
            // core.math.Vec3.ZERO,
            core.math.Vec3.UP,
        ),
        .proj = core.math.Mat4.perspective(
            self.fov,
            aspect,
            self.near_plane,
            self.far_plane,
        ),
    };
}
