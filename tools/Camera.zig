const std = @import("std");
const core = @import("core");
const c = core.clibs;
const vk = c.vk;
const vki = core.vulkan_init;
const checkVk = vki.checkVk;
const Vec3 = core.math.Vec3;
const Mat4 = core.math.Mat4;

pub const Data = struct {
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

const Mode = enum {
    rotate_around,
    user_input,
};

pub fn createBoundDescriptor(
    self: @This(),
    allocs: *core.VulkanEngine.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) core.BoundDescriptor {
    var builder = core.descriptor.LayoutBuilder.init(allocs.std);
    defer builder.deinit(allocs.std);
    builder.addBinding(allocs.std, 0, vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER);
    const layout = builder.build(device, vk.SHADER_STAGE_VERTEX_BIT, null, 0, alloc_cbs);
    const set = allocs.global_descriptor.allocate(device, layout, null);

    const bound = core.BoundDescriptor.init(
        Data,
        @This(),
        allocs,
        set,
        layout,
        self,
        controlCamera,
    );

    return bound;
}

fn createDescriptorSet(device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) vk.DescriptorSet {
    var layout: vk.DescriptorSetLayout = undefined;

    const ubo_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptorCount = 1,
        .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        .pImmutableSamplers = null,
    };
    const sampler_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 1,
        .descriptorCount = 1,
        .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = null,
    };

    const bindings = &[_]vk.DescriptorSetLayoutBinding{ ubo_layout_binding, sampler_layout_binding };

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = bindings,
    };

    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &layout)) catch @panic("failed to create descriptor set layout");
}

pub fn controlCamera(self: *@This(), engine: core.VulkanEngine, desc: *core.BoundDescriptor) void {
    const State = struct {
        /// for rotation so i decided not to store it in camera
        var start: i128 = 0;
    };
    if (State.start == 0)
        State.start = std.time.nanoTimestamp();

    const zoom_speed = 0.1;
    const min_distance = 0.2;
    const max_distance = 10.0;

    // var distance = self.eye.eucDist(self.target);
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
        .rotate_around => Data{
            .model = Mat4.IDENTITY.rotate(self.target, time * 1.0),
            .view = Mat4.lookAt(self.eye, Vec3.ZERO, Vec3.UP),
            .proj = Mat4.perspective(self.fov, aspect, self.near_plane, self.far_plane),
        },
        .user_input => Data{
            .model = Mat4.IDENTITY,
            .view = Mat4.lookAt(self.eye, Vec3.ZERO, Vec3.UP),
            .proj = Mat4.perspective(self.fov, aspect, self.near_plane, self.far_plane),
        },
    };

    ubo.proj.j.y *= -1;

    const aligned_data: *Data = @ptrCast(@alignCast(desc.mapped));
    aligned_data.* = ubo;
}
