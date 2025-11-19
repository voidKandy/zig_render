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

pub fn FramesContainer(MAX_FRAMES_IN_FLIGHT: usize) type {
    return struct {
        global_descriptor_set_layout: vk.DescriptorSetLayout = undefined,
        all: [MAX_FRAMES_IN_FLIGHT]FrameData = .{FrameData{}} ** MAX_FRAMES_IN_FLIGHT,
        current: u32 = 0,

        const Self = @This();

        pub fn incrementFrame(self: *Self) void {
            self.current = (self.current + 1) % @as(u32, @intCast(MAX_FRAMES_IN_FLIGHT));
            std.debug.assert(self.current < @as(u32, @intCast(MAX_FRAMES_IN_FLIGHT)));
        }

        pub fn currentFrame(self: *Self) FrameData {
            return self.all[self.current];
        }

        pub fn deinit(self: *Self, device: vk.Device, vma_a: c.vma.Allocator, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
            vk.DestroyDescriptorSetLayout(device, self.global_descriptor_set_layout, vk_alloc_cbs);

            for (&self.all) |*frame| {
                frame.deinit(vma_a, device, vk_alloc_cbs);
            }
        }

        pub fn initSyncObjects(self: *Self, device: c.vk.Device, vk_alloc_cbs: ?*c.vk.AllocationCallbacks) void {
            for (&self.all) |*frame| {
                const semaphore_ci = vk.SemaphoreCreateInfo{
                    .sType = vk.STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                };

                const fence_ci = vk.FenceCreateInfo{
                    .sType = vk.STRUCTURE_TYPE_FENCE_CREATE_INFO,
                    .flags = vk.FENCE_CREATE_SIGNALED_BIT,
                };

                checkVk(c.vk.CreateSemaphore(device, &semaphore_ci, vk_alloc_cbs, &frame.present_semaphore)) catch @panic("failed to create semaphore");

                checkVk(c.vk.CreateFence(device, &fence_ci, vk_alloc_cbs, &frame.render_fence)) catch @panic("failed to create render fence");
            }
        }

        pub fn initCommands(self: *Self, device: vk.Device, phys_device: vki.PhysicalDevice, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
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

        pub fn initBuffers(self: *Self, vma_a: c.vma.Allocator) void {
            for (&self.all) |*frame| {
                const buf_size = @sizeOf(GPUCameraData);
                frame.global.data = vma_usage.AllocatedBuffer.create(
                    vma_a,
                    buf_size,
                    vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                    c.vma.MEMORY_USAGE_CPU_TO_GPU,
                );
                checkVk(c.vma.MapMemory(vma_a, frame.global.data.allocation, &frame.global.mapped)) catch @panic("failed to map uniform buffer");
            }
        }

        pub fn initDescriptorSetLayouts(self: *Self, device: vk.Device, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
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

            checkVk(vk.CreateDescriptorSetLayout(device, &ci, vk_alloc_cbs, &self.global_descriptor_set_layout)) catch @panic("failed to create descriptor set layout");
        }

        pub fn allocateDescriptorSets(
            self: *Self,
            device: vk.Device,
            pool: vk.DescriptorPool,
        ) void {
            for (&self.all) |*frame| {
                const ai = vk.DescriptorSetAllocateInfo{
                    .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                    .descriptorPool = pool,
                    .descriptorSetCount = 1,
                    .pSetLayouts = &self.global_descriptor_set_layout,
                };
                checkVk(vk.AllocateDescriptorSets(device, &ai, &frame.global.descriptor_set)) catch @panic("failed to allocate descriptor sets");
            }
        }

        pub fn updateDescriptorSets(
            self: *Self,
            device: vk.Device,
            texture_image_view: vk.ImageView,
            texture_sampler: vk.Sampler,
        ) void {
            for (&self.all) |*frame| {
                const camera_data_info = vk.DescriptorBufferInfo{
                    .buffer = frame.global.data.buffer,
                    .offset = 0,
                    .range = @sizeOf(GPUCameraData),
                };

                const camera_data_write = vk.WriteDescriptorSet{
                    .dstBinding = 0,
                    .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstSet = frame.global.descriptor_set,
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
                    .dstSet = frame.global.descriptor_set,
                    .dstArrayElement = 0,
                    .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                    .descriptorCount = 1,
                    .pImageInfo = &img_info,
                };

                const writes = &[_]vk.WriteDescriptorSet{ camera_data_write, img_write };

                vk.UpdateDescriptorSets(device, writes.len, writes, 0, null);
            }
        }
    };
}

pub const GPUCameraData = struct {
    model: Mat4,
    view: Mat4,
    proj: Mat4,
};

/// Each bound descriptor is associated with a descriptor set and an updateDescriptorSet function
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
    /// Used to pass camera data to shader so objects can be rendered in 3D
    global: BoundDescriptor = .{},

    const Self = @This();

    pub fn deinit(self: *Self, vma_a: c.vma.Allocator, device: c.vk.Device, vk_alloc_cbs: ?*c.vk.AllocationCallbacks) void {
        vk.DestroySemaphore(device, self.present_semaphore, vk_alloc_cbs);
        vk.DestroyFence(device, self.render_fence, vk_alloc_cbs);
        vk.DestroyCommandPool(device, self.command_pool, vk_alloc_cbs);
        self.global.deinit(vma_a);
    }
};
