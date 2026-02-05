const std = @import("std");
const root = @import("root.zig");
const vki = @import("vulkan_init.zig");
const c = @import("clibs.zig");
const descriptor = @import("descriptor.zig");
const vma_usage = @import("vma_usage.zig");
const vk = c.vk;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.frames);
const Mat4 = @import("math3d.zig").Mat4;
const Vec4 = @import("math3d.zig").Vec4;
const checkVk = vki.checkVk;

pub fn FramesContainer(MAX_FRAMES_IN_FLIGHT: usize) type {
    return struct {
        global_descriptor_set_layout: vk.DescriptorSetLayout = undefined,
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

                checkVk(c.vk.CreateSemaphore(device, &semaphore_ci, vk_alloc_cbs, &frame.render_semaphore)) catch @panic("failed to create semaphore");

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
                frame.camera_data.data = vma_usage.AllocatedBuffer.create(
                    vma_a,
                    buf_size,
                    vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                    c.vma.MEMORY_USAGE_CPU_TO_GPU,
                    0,
                );
                checkVk(c.vma.MapMemory(vma_a, frame.camera_data.data.allocation, &frame.camera_data.mapped)) catch @panic("failed to map uniform buffer");
            }
        }

        pub fn initDescriptorSetLayouts(self: *Self, device: vk.Device, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
            // const frame_sizes = &[_]descriptor.Allocator.PoolSizeRatio{
            //     .{ vk.DESCRIPTOR_TYPE_STORAGE_IMAGE, 3 },
            //     .{ vk.DESCRIPTOR_TYPE_STORAGE_BUFFER, 3 },
            //     .{ vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER, 3 },
            //     .{ vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 4 },
            // };
            // for (self.all) |frame| {
            //     frame.descriptors = descriptor.Allocator.init(a, vk_alloc_cbs, device, 1000, frame_sizes);
            // }

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
                checkVk(vk.AllocateDescriptorSets(device, &ai, &frame.camera_data.descriptor_set)) catch @panic("failed to allocate descriptor sets");
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
                    .buffer = frame.camera_data.data.buffer,
                    .offset = 0,
                    .range = @sizeOf(GPUCameraData),
                };

                const camera_data_write = vk.WriteDescriptorSet{
                    .dstBinding = 0,
                    .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstSet = frame.camera_data.descriptor_set,
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
                    .dstSet = frame.camera_data.descriptor_set,
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
    render_semaphore: c.vk.Semaphore = null,
    render_fence: c.vk.Fence = null,
    command_pool: c.vk.CommandPool = null,
    main_command_buffer: c.vk.CommandBuffer = null,
    /// Used to pass camera data to shader so objects can be rendered in 3D
    camera_data: BoundDescriptor = .{},

    const Self = @This();

    pub fn deinit(self: *Self, vma_a: c.vma.Allocator, device: c.vk.Device, vk_alloc_cbs: ?*c.vk.AllocationCallbacks) void {
        vk.DestroySemaphore(device, self.render_semaphore, vk_alloc_cbs);
        vk.DestroyFence(device, self.render_fence, vk_alloc_cbs);
        vk.DestroyCommandPool(device, self.command_pool, vk_alloc_cbs);
        self.camera_data.deinit(vma_a);
    }
};

pub const NewFrameData = struct {
    render_semaphore: c.vk.Semaphore = null,
    render_fence: c.vk.Fence = null,
    command_pool: c.vk.CommandPool = null,
    main_command_buffer: c.vk.CommandBuffer = null,
    /// Used to pass camera data to shader so objects can be rendered in 3D
    // global: BoundDescriptor = .{},
    deletion_queue: std.ArrayList(vma_usage.VulkanDeleter) = undefined,
    descriptors: @import("descriptor.zig").AllocatorGrowable = undefined,

    const Self = @This();

    pub fn deinit(self: *Self, device: c.vk.Device, vk_alloc_cbs: ?*c.vk.AllocationCallbacks) void {
        vk.DestroySemaphore(device, self.render_semaphore, vk_alloc_cbs);
        vk.DestroyFence(device, self.render_fence, vk_alloc_cbs);
        vk.DestroyCommandPool(device, self.command_pool, vk_alloc_cbs);

        self.reset(device);
        self.deletion_queue.deinit(self.allocator);
        self.descriptors.deinit();
    }

    /// flushes deletion queue, calling all deletion functions
    /// then clears pools
    pub fn reset(self: *Self, device: vk.Device) void {
        vma_usage.VulkanDeleter.flushList(self.deletion_queue, device);
        self.descriptors.clearPools(device);
    }
};

pub const GPUSceneData = struct {
    model: Mat4,
    view: Mat4,
    proj: Mat4,
    ambient_color: Vec4,
    sunlight_direction: Vec4,
    sunlight_color: Vec4,
};

pub fn NewFramesContainer(MAX_FRAMES_IN_FLIGHT: usize) type {
    return struct {
        gpu_scene_data_layout: vk.DescriptorSetLayout = undefined,
        all: [MAX_FRAMES_IN_FLIGHT]NewFrameData = .{NewFrameData{}} ** MAX_FRAMES_IN_FLIGHT,
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

                checkVk(c.vk.CreateSemaphore(device, &semaphore_ci, vk_alloc_cbs, &frame.render_semaphore)) catch @panic("failed to create semaphore");

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
                const buf_size = @sizeOf(GPUSceneData);
                frame.global.data = vma_usage.AllocatedBuffer.create(
                    vma_a,
                    buf_size,
                    vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                    c.vma.MEMORY_USAGE_CPU_TO_GPU,
                    0,
                );
                checkVk(c.vma.MapMemory(vma_a, frame.global.data.allocation, &frame.global.mapped)) catch @panic("failed to map uniform buffer");
            }
        }

        pub fn initDescriptors(self: *Self, a: std.mem.Allocator, device: vk.Device, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
            const frame_sizes = &[_]descriptor.AllocatorGrowable.PoolSizeRatio{
                .{ .typ = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE, .ratio = 3.0 },
                .{ .typ = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER, .ratio = 3.0 },
                .{ .typ = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER, .ratio = 3.0 },
                .{ .typ = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .ratio = 4.0 },
            };
            for (self.all) |frame| {
                frame.descriptors = descriptor.AllocatorGrowable.init(a, vk_alloc_cbs, device, 1000, frame_sizes);
            }

            var builder = descriptor.LayoutBuilder.init(a);
            builder.addBinding(a, 0, vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER);
            self.gpu_scene_data_layout = builder.build(
                device,
                vk.SHADER_STAGE_VERTEX_BIT | vk.SHADER_STAGE_FRAGMENT_BIT,
                null,
                0,
                vk_alloc_cbs,
            );
        }

        // pub fn allocateDescriptorSets(
        //     self: *Self,
        //     device: vk.Device,
        //     pool: vk.DescriptorPool,
        // ) void {
        //     for (&self.all) |*frame| {
        //         const ai = vk.DescriptorSetAllocateInfo{
        //             .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        //             .descriptorPool = pool,
        //             .descriptorSetCount = 1,
        //             .pSetLayouts = &self.global_descriptor_set_layout,
        //         };
        //         checkVk(vk.AllocateDescriptorSets(device, &ai, &frame.global.descriptor_set)) catch @panic("failed to allocate descriptor sets");
        //     }
        // }

        // pub fn updateDescriptorSets(
        //     self: *Self,
        //     device: vk.Device,
        //     texture_image_view: vk.ImageView,
        //     texture_sampler: vk.Sampler,
        // ) void {
        //     for (&self.all) |*frame| {
        //         const camera_data_info = vk.DescriptorBufferInfo{
        //             .buffer = frame.global.data.buffer,
        //             .offset = 0,
        //             .range = @sizeOf(GPUCameraData),
        //         };

        //         const camera_data_write = vk.WriteDescriptorSet{
        //             .dstBinding = 0,
        //             .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        //             .dstSet = frame.global.descriptor_set,
        //             .dstArrayElement = 0,
        //             .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        //             .descriptorCount = 1,
        //             .pBufferInfo = &camera_data_info,
        //         };

        //         const img_info = vk.DescriptorImageInfo{
        //             .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        //             .imageView = texture_image_view,
        //             .sampler = texture_sampler,
        //         };

        //         const img_write = vk.WriteDescriptorSet{
        //             .dstBinding = 1,
        //             .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        //             .dstSet = frame.global.descriptor_set,
        //             .dstArrayElement = 0,
        //             .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        //             .descriptorCount = 1,
        //             .pImageInfo = &img_info,
        //         };

        //         const writes = &[_]vk.WriteDescriptorSet{ camera_data_write, img_write };

        //         vk.UpdateDescriptorSets(device, writes.len, writes, 0, null);
        //     }
        // }
    };
}
