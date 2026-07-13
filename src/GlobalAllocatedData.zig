const std = @import("std");
const core = @import("root.zig");
const imgui = core.clibs.imgui;
const vk = core.clibs.vk;
const checkVk = core.vulkan_init.checkVk;

camera: core.Camera,
camera_alloc_data: core.Camera.AllocatedData,

pool: vk.DescriptorPool,
layout: vk.DescriptorSetLayout = undefined,
set: vk.DescriptorSet = undefined,

pub const CreateData = struct {
    swapchain_extent: vk.Extent2D,
    camera: core.Camera,
};

pub fn initAndCreateData(
    allocs: core.VulkanEngine.Allocators,
    cd: CreateData,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) @This() {
    var pool: vk.DescriptorPool = undefined;
    const size = vk.DescriptorPoolSize{
        .type = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
    };

    const ci = vk.DescriptorPoolCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = 0,
        .maxSets = 1,
        .poolSizeCount = 1,
        .pPoolSizes = &size,
    };

    checkVk(vk.CreateDescriptorPool(device, &ci, alloc_cbs, &pool)) catch
        @panic("failed to create descriptor pool");

    return .{
        .pool = pool,
        .camera = cd.camera,
        .camera_alloc_data = core.Camera.AllocatedData.createFromCamera(
            allocs.vma,
            cd.camera,
            cd.swapchain_extent,
        ),
    };
}

pub fn deinit(
    self: *@This(),
    vma_a: core.clibs.vma.Allocator,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.camera_alloc_data.deinit(vma_a);
    vk.DestroyDescriptorSetLayout(device, self.layout, alloc_cbs);
    vk.DestroyDescriptorPool(device, self.pool, alloc_cbs);
}

pub fn createLayout(
    self: *@This(),
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        core.Camera.AllocatedData.descriptorSetLayoutBinding(0),
    };

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = 0,
        .bindingCount = @as(u32, @intCast(bindings.len)),
        .pBindings = &bindings,
    };
    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.layout)) catch
        @panic("failed to create descriptor set layout");
}

pub fn allocateSets(self: *@This(), device: vk.Device) void {
    core.Camera.AllocatedData.allocateDescriptorSet(
        &self.set,
        self.layout,
        self.pool,
        device,
    );
}

pub fn updateSets(self: @This(), device: vk.Device) void {
    // eventually, if more data is added, sets could be concatenated

    const camera_uniform_info = vk.DescriptorBufferInfo{
        .buffer = self.camera_alloc_data.uniform.allocation.buffer,
        .offset = 0,
        .range = @as(u64, @intCast(self.camera_alloc_data.uniform.allocation.size)),
    };
    const camera_write = vk.WriteDescriptorSet{
        .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = self.set,
        .dstBinding = 0,
        .dstArrayElement = 0,
        .descriptorCount = 1,
        .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .pBufferInfo = &camera_uniform_info,
    };
    vk.UpdateDescriptorSets(
        device,
        1,
        &camera_write,
        0,
        null,
    );
}

pub fn drawImgui(self: *@This()) void {
    var open = true;
    const shown = imgui.Begin("Global Data", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    defer imgui.End();

    if (!shown) return;

    const current_mode_name = @tagName(self.camera.mode);
    if (imgui.BeginCombo("Camera Modes", current_mode_name.ptr, 0)) {
        defer imgui.EndCombo();

        for (std.meta.tags(core.Camera.Mode)) |tag| {
            const name = @tagName(tag);
            if (imgui.Selectable(name))
                self.camera.mode = tag;
        }
    }
}
