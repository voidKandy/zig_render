const std = @import("std");
const root = @import("root.zig");
const vki = @import("vulkan_init.zig");
const c = @import("clibs.zig");
const descriptor = @import("descriptor.zig");
const vma_usage = @import("vma_usage.zig");
const vk = c.vk;
const vma = c.vma;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.frames);
const Mat4 = @import("math3d.zig").Mat4;
const Vec4 = @import("math3d.zig").Vec4;
const checkVk = vki.checkVk;

data: root.vma_usage.AllocatedBuffer = .{ .buffer = null, .allocation = null },
mapped: ?*anyopaque = undefined,
descriptor_set: c.vk.DescriptorSet,
descriptor_set_layout: c.vk.DescriptorSetLayout,
updateFn: *const fn (root.VulkanEngine, *Self) void,

const Self = @This();

pub fn init(
    comptime T: type,
    vma_a: vma.Allocator,
    set: vk.DescriptorSet,
    layout: vk.DescriptorSetLayout,
    update: *const fn (root.VulkanEngine, *Self) void,
) Self {
    const buf_size = @sizeOf(T);
    var self = Self{
        .descriptor_set = set,
        .descriptor_set_layout = layout,
        .updateFn = update,
    };
    self.data = vma_usage.AllocatedBuffer.create(
        vma_a,
        buf_size,
        // these should maybe be params
        vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        vma.MEMORY_USAGE_CPU_TO_GPU,
        0,
    );
    checkVk(c.vma.MapMemory(vma_a, self.data.allocation, &self.mapped)) catch @panic("failed to map uniform buffer");
    return self;
}

pub fn deinit(
    self: *Self,
    vma_a: c.vma.Allocator,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    c.vma.UnmapMemory(vma_a, self.data.allocation);
    c.vma.DestroyBuffer(vma_a, self.data.buffer, self.data.allocation);
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
}
