const std = @import("std");
const root = @import("root.zig");
const c = root.clibs;
const vk = c.vk;
const vki = root.vulkan_init;
const checkVk = vki.checkVk;
const Vec3 = root.math.Vec3;
const Mat4 = root.math.Mat4;

pub const GPUData = struct {
    model: Mat4,
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

const DEFAULT_EYE: Vec3 = Vec3.make(2.0, 2.0, 2.0);
const DEFAULT_TARGET: Vec3 = Vec3.make(0.0, 0.0, 1.0);

pub const Mode = enum {
    rotate_around,
    user_input,
};

pub fn control(self: *@This(), engine: root.VulkanEngine, desc: *root.BoundDescriptor) void {
    const State = struct {
        /// for rotation so i decided not to store it in camera
        var start: i128 = 0;
    };
    if (State.start == 0)
        State.start = std.time.nanoTimestamp();

    const zoom_speed = 0.1;
    const min_distance = 0.2;
    const max_distance = 10.0;

    self.distance = std.math.clamp(self.distance - engine.input.scroll * zoom_speed, min_distance, max_distance);

    // this could also be computed with a yaw/pitch if those should be added to camera
    const dir = self.target.sub(self.eye).normalized();
    self.eye = self.target.sub(dir.mul(self.distance));

    const now = std.time.nanoTimestamp();
    const delta_ns = now - State.start;
    const time: f32 = @as(f32, (@floatFromInt(delta_ns))) / @as(f32, (@floatFromInt(std.time.ns_per_s)));

    const aspect =
        @as(f32, @floatFromInt(engine.swapchain.extent.width)) /
        @as(f32, @floatFromInt(engine.swapchain.extent.height));

    var ubo = switch (self.mode) {
        .rotate_around => GPUData{
            .model = Mat4.IDENTITY.rotate(self.target, time * 1.0),
            .view = Mat4.lookAt(self.eye, Vec3.ZERO, Vec3.UP),
            .proj = Mat4.perspective(self.fov, aspect, self.near_plane, self.far_plane),
        },
        .user_input => GPUData{
            .model = Mat4.IDENTITY,
            .view = Mat4.lookAt(self.eye, Vec3.ZERO, Vec3.UP),
            .proj = Mat4.perspective(self.fov, aspect, self.near_plane, self.far_plane),
        },
    };

    ubo.proj.j.y *= -1;

    const aligned_data: *GPUData = @ptrCast(@alignCast(desc.mapped));
    aligned_data.* = ubo;
}

pub fn writeSet(set: vk.DescriptorSet, desc: *root.BoundDescriptor) vk.WriteDescriptorSet {
    // const camera_data_info = ;

    return vk.WriteDescriptorSet{
        .dstBinding = 0,
        .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = set,
        .dstArrayElement = 0,
        .descriptorType = desc.descriptor_type,
        .descriptorCount = 1,
        .pBufferInfo = &vk.DescriptorBufferInfo{
            .buffer = desc.data.buffer,
            .offset = 0,
            .range = @sizeOf(GPUData),
        },
    };
}
