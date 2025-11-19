const std = @import("std");
const root = @import("root.zig");
const vki = @import("vulkan_init.zig");
pub const c = @import("clibs.zig");
const vma_usage = @import("vma_usage.zig");
const vk = c.vk;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.frames);
const Mat4 = @import("math3d.zig").Mat4;
const checkVk = vki.checkVk;

pub const GPUCameraData = struct {
    model: Mat4,
    view: Mat4,
    proj: Mat4,
};

pub const BoundDescriptor = struct {
    data: root.vma_usage.AllocatedBuffer = .{ .buffer = null, .allocation = null },
    mapped: ?*anyopaque = undefined,
    descriptor_set: c.vk.DescriptorSet = null,

    const Self = @This();

    fn deinit(self: *Self, vma_a: c.vma.Allocator) void {
        c.vma.UnmapMemory(vma_a, self.data.allocation);
        c.vma.DestroyBuffer(vma_a, self.data.buffer, self.data.allocation);
    }
};

pub const FrameData = struct {
    present_semaphore: c.vk.Semaphore = null,
    render_fence: c.vk.Fence = null,
    command_pool: c.vk.CommandPool = null,
    main_command_buffer: c.vk.CommandBuffer = null,
    camera: BoundDescriptor = .{},

    const Self = @This();

    pub fn deinit(self: *Self, vma_a: c.vma.Allocator, device: c.vk.Device, vk_alloc_cbs: ?*c.vk.AllocationCallbacks) void {
        vk.DestroySemaphore(device, self.present_semaphore, vk_alloc_cbs);
        vk.DestroyFence(device, self.render_fence, vk_alloc_cbs);
        vk.DestroyCommandPool(device, self.command_pool, vk_alloc_cbs);
        self.camera.deinit(vma_a);
    }

    pub fn initSyncObjects(self: *Self, device: c.vk.Device, vk_alloc_cbs: ?*c.vk.AllocationCallbacks) void {
        const semaphore_ci = vk.SemaphoreCreateInfo{
            .sType = vk.STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        const fence_ci = vk.FenceCreateInfo{
            .sType = vk.STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = vk.FENCE_CREATE_SIGNALED_BIT,
        };

        checkVk(c.vk.CreateSemaphore(device, &semaphore_ci, vk_alloc_cbs, &self.present_semaphore)) catch @panic("failed to create semaphore");

        checkVk(c.vk.CreateFence(device, &fence_ci, vk_alloc_cbs, &self.render_fence)) catch @panic("failed to create render fence");
    }

    pub fn initBuffers(self: *Self, vma_a: c.vma.Allocator) void {
        const buf_size = @sizeOf(GPUCameraData);
        self.camera.data = vma_usage.AllocatedBuffer.create(
            vma_a,
            buf_size,
            vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            c.vma.MEMORY_USAGE_CPU_TO_GPU,
        );
        checkVk(c.vma.MapMemory(vma_a, self.camera.data.allocation, &self.camera.mapped)) catch @panic("failed to map uniform buffer");
    }

    pub fn initCommands(self: *Self, device: vk.Device, phys_device: vki.PhysicalDevice, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
        const command_pool_ci = vk.CommandPoolCreateInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = vk.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = phys_device.graphics_queue_family,
        };

        checkVk(vk.CreateCommandPool(device, &command_pool_ci, vk_alloc_cbs, &self.command_pool)) catch log.err("Failed to create command pool", .{});
        // Allocate a command buffer from the command pool
        const command_buffer_ai = vk.CommandBufferAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = vk.COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        checkVk(vk.AllocateCommandBuffers(device, &command_buffer_ai, &self.main_command_buffer)) catch @panic("Failed to allocate command buffer");
    }

    pub fn initDescriptorSets(
        self: *Self,
        device: vk.Device,
        pool: vk.DescriptorPool,
        layout: vk.DescriptorSetLayout,
        texture_image_view: vk.ImageView,
        texture_sampler: vk.Sampler,
    ) void {
        const ai = vk.DescriptorSetAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &layout,
        };
        checkVk(vk.AllocateDescriptorSets(device, &ai, &self.camera.descriptor_set)) catch @panic("failed to allocate descriptor sets");

        const camera_data_info = vk.DescriptorBufferInfo{
            .buffer = self.camera.data.buffer,
            .offset = 0,
            .range = @sizeOf(GPUCameraData),
        };

        const camera_data_write = vk.WriteDescriptorSet{
            .dstBinding = 0,
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = self.camera.descriptor_set,
            .dstArrayElement = 0,
            .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .pBufferInfo = &camera_data_info,
        };

        const img_info = vk.DescriptorImageInfo{
            .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .imageView = texture_image_view,
            .sampler = texture_sampler,
        };

        const img_write = vk.WriteDescriptorSet{
            .dstBinding = 1,
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = self.camera.descriptor_set,
            .dstArrayElement = 0,
            .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .pImageInfo = &img_info,
        };

        const writes = &[_]vk.WriteDescriptorSet{ camera_data_write, img_write };

        vk.UpdateDescriptorSets(device, writes.len, writes, 0, null);
    }
};
