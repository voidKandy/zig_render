const std = @import("std");
const core = @import("../root.zig");
const imgui = core.clibs.imgui;
const vk = core.clibs.vk;
const checkVk = core.bindings.vulkan_init.checkVk;

layout: vk.DescriptorSetLayout = undefined,

pub fn deinit(
    self: *@This(),
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    vk.DestroyDescriptorSetLayout(device, self.layout, alloc_cbs);
}

pub fn init(
    device: vk.Device,
    resources: core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) @This() {
    var layout: vk.DescriptorSetLayout = undefined;
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        resources.mapped_buffers.createDescriptorSetLayoutBinding(
            core.engine.systems.Camera.CAMERA_BUFFER_NAME,
            0,
            vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            vk.SHADER_STAGE_VERTEX_BIT | vk.SHADER_STAGE_COMPUTE_BIT,
        ),
    };

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = 0,
        .bindingCount = @as(u32, @intCast(bindings.len)),
        .pBindings = &bindings,
    };
    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &layout)) catch
        @panic("failed to create descriptor set layout");
    return .{ .layout = layout };
}

pub fn allocateSet(
    self: @This(),
    device: vk.Device,
    pool: vk.DescriptorPool,
) vk.DescriptorSet {
    var set: vk.DescriptorSet = undefined;
    const ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.layout,
    };

    checkVk(vk.AllocateDescriptorSets(
        device,
        &ai,
        &set,
    )) catch
        @panic("failed to allocate global data descriptor set");

    return set;
}

pub fn updateSet(
    device: vk.Device,
    set: vk.DescriptorSet,
    alloc_resources: core.resources.Manager.AllocatedData,
) void {
    var buf_info: vk.DescriptorBufferInfo = undefined;
    const cam_write = alloc_resources.mapped_buffers.createDescriptorSetWrite(
        set,
        core.engine.systems.Camera.CAMERA_BUFFER_NAME,
        0,
        0,
        vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        &buf_info,
    );
    const writes = &[_]vk.WriteDescriptorSet{
        cam_write,
    };

    vk.UpdateDescriptorSets(device, writes.len, writes.ptr, 0, null);
}
