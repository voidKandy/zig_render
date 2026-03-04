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
descriptor_type: vk.DescriptorType,
descriptor_stage: vk.ShaderStageFlags,

updateFn: *const fn (@This(), root.VulkanEngine, *Self) void,
state_ptr: *anyopaque,
deinitStateFn: *const fn (*@This(), std.mem.Allocator) void,

const Self = @This();

pub fn init(
    comptime T: type,
    comptime State: type,
    allocs: *root.VulkanEngine.Allocators,
    typ: vk.DescriptorType,
    stage_flags: vk.ShaderStageFlags,
    buffer_usage: vk.BufferUsageFlags,
    memory_usage: vma.MemoryUsage,
    state: State,
    comptime update: *const fn (*State, root.VulkanEngine, *Self) void,
) Self {
    const buf_size = @sizeOf(T);
    const state_ptr: *State = allocs.std.create(State) catch @panic("OOM");
    state_ptr.* = state;

    var self = Self{
        .descriptor_type = typ,
        .descriptor_stage = stage_flags,
        .updateFn = struct {
            fn u(self: Self, engine: root.VulkanEngine, desc: *Self) void {
                const s: *State = @ptrCast(@alignCast(self.state_ptr));
                update(s, engine, desc);
            }
        }.u,
        .state_ptr = @ptrCast(state_ptr),
        .deinitStateFn = struct {
            fn d(self: *Self, a: std.mem.Allocator) void {
                const s: *State = @ptrCast(@alignCast(self.state_ptr));
                a.destroy(s);
            }
        }.d,
    };
    self.data = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        buf_size,
        buffer_usage,
        memory_usage,
        0,
    );
    checkVk(c.vma.MapMemory(allocs.vma, self.data.allocation, &self.mapped)) catch @panic("failed to map uniform buffer");
    return self;
}

pub fn deinit(
    self: *Self,
    allocs: *root.VulkanEngine.Allocators,
) void {
    self.deinitStateFn(self, allocs.std);
    c.vma.UnmapMemory(allocs.vma, self.data.allocation);
    c.vma.DestroyBuffer(allocs.vma, self.data.buffer, self.data.allocation);
}
