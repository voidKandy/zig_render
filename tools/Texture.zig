const std = @import("std");
const core = @import("core");
const c = core.clibs;
const vk = c.vk;
const vki = core.vulkan_init;
const checkVk = vki.checkVk;

pub const GPUData = struct {};
pub fn createBoundDescriptor(
    self: @This(),
    allocs: *core.VulkanEngine.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) core.BoundDescriptor {}
