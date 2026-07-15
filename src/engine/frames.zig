const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../root.zig");
const vki = core.bindings.vulkan_init;
const c = core.clibs;
const vma_usage = core.bindings.vma_usage;
const vk = c.vk;
const log = std.log.scoped(.frames);
const Mat4 = core.lib.math.Mat4;
const Vec4 = core.lib.math.Vec4;
const checkVk = vki.checkVk;

pub fn FramesContainer(MAX_FRAMES_IN_FLIGHT: usize) type {
    return struct {
        all: [MAX_FRAMES_IN_FLIGHT]FrameData = .{FrameData{}} ** MAX_FRAMES_IN_FLIGHT,
        current_idx: u32 = 0,
        frame_count: u64 = 0,

        const Self = @This();

        pub fn incrementFrame(self: *Self) void {
            self.frame_count += 1;
            self.current_idx = (self.current_idx + 1) % @as(u32, @intCast(MAX_FRAMES_IN_FLIGHT));
            std.debug.assert(self.current_idx < @as(u32, @intCast(MAX_FRAMES_IN_FLIGHT)));
        }

        pub fn currentFrame(self: *Self) FrameData {
            return self.all[self.current_idx];
        }

        pub fn deinit(self: *Self, device: vk.Device, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
            // vk.DestroyDescriptorSetLayout(device, self.global_descriptor_set_layout, vk_alloc_cbs);

            for (&self.all) |*frame| {
                frame.deinit(device, vk_alloc_cbs);
            }
        }

        pub fn initSyncObjects(
            self: *Self,
            device: c.vk.Device,
            vk_alloc_cbs: ?*vk.AllocationCallbacks,
        ) void {
            for (&self.all) |*frame| {
                const semaphore_ci = vk.SemaphoreCreateInfo{
                    .sType = vk.STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                };

                const fence_ci = vk.FenceCreateInfo{
                    .sType = vk.STRUCTURE_TYPE_FENCE_CREATE_INFO,
                    .flags = vk.FENCE_CREATE_SIGNALED_BIT,
                };

                checkVk(c.vk.CreateSemaphore(device, &semaphore_ci, vk_alloc_cbs, &frame.render_semaphore)) catch @panic("failed to create semaphore");

                checkVk(c.vk.CreateFence(device, &fence_ci, vk_alloc_cbs, &frame.render_fence)) catch @panic("failed to create render fence");
            }
        }

        pub fn initCommands(
            self: *Self,
            device: vk.Device,
            phys_device: vki.PhysicalDevice,
            vk_alloc_cbs: ?*vk.AllocationCallbacks,
        ) void {
            for (&self.all) |*frame| {
                const command_pool_ci = vk.CommandPoolCreateInfo{
                    .sType = vk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                    .flags = vk.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
                    .queueFamilyIndex = phys_device.graphics_queue_family,
                };

                checkVk(vk.CreateCommandPool(device, &command_pool_ci, vk_alloc_cbs, &frame.command_pool)) catch log.err("Failed to create command pool", .{});
                // Allocate a command buffer from the command pool
                const command_buffer_ai = vk.CommandBufferAllocateInfo{
                    .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                    .commandPool = frame.command_pool,
                    .level = vk.COMMAND_BUFFER_LEVEL_PRIMARY,
                    .commandBufferCount = 1,
                };

                checkVk(vk.AllocateCommandBuffers(device, &command_buffer_ai, &frame.main_command_buffer)) catch @panic("Failed to allocate command buffer");
            }
        }
    };
}

pub const FrameData = struct {
    render_semaphore: c.vk.Semaphore = null,
    render_fence: c.vk.Fence = null,
    command_pool: c.vk.CommandPool = null,
    main_command_buffer: c.vk.CommandBuffer = null,

    const Self = @This();

    pub fn deinit(self: *Self, device: c.vk.Device, vk_alloc_cbs: ?*c.vk.AllocationCallbacks) void {
        vk.DestroySemaphore(device, self.render_semaphore, vk_alloc_cbs);
        vk.DestroyFence(device, self.render_fence, vk_alloc_cbs);
        vk.DestroyCommandPool(device, self.command_pool, vk_alloc_cbs);
    }
};
