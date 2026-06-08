const std = @import("std");
const mem = std.mem;
const core = @import("../root.zig");
const imgui = core.clibs.imgui;
const log = std.log.scoped(.MainComputePipeline);
const vki = core.vulkan_init;
const vk = core.clibs.vk;
const vma_usage = core.vma_usage;
const checkVk = vki.checkVk;

const Bindings = struct {
    const OUTPUT_IMAGE = 0;
    const MAZE_STATE = 1;
};

const PushConstants = struct {
    width: u32,
    height: u32,
    _pad0: u32 = 0,
    _pad1: u32 = 0,
};

pub const AllocatedData = struct {
    pub const CreateData = struct {
        maze_width: u32,
        maze_height: u32,
    };

    draw_image: vma_usage.AllocatedImage,
    sampler: vk.Sampler,
    maze_state: vma_usage.MappedBuffer,
    maze_width: u32,
    maze_height: u32,

    pub fn create(
        allocs: core.VulkanEngine.Allocators,
        upload_ctx: *vki.UploadContext,
        logical_device: vki.LogicalDevice,
        physical_device: vki.PhysicalDevice,
        cd: CreateData,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) @This() {
        // output image — STORAGE_BIT for compute write, SAMPLED_BIT for HUD read
        const extent = vk.Extent3D{
            .width = cd.maze_width,
            .height = cd.maze_height,
            .depth = 1,
        };
        var image = vma_usage.AllocatedImage.init(
            allocs.vma,
            vk.FORMAT_R8G8B8A8_UNORM,
            extent,
            vk.IMAGE_USAGE_STORAGE_BIT |
                vk.IMAGE_USAGE_SAMPLED_BIT |
                vk.IMAGE_USAGE_TRANSFER_DST_BIT,
        );
        const view_ci = vki.imageViewCreateInfo(image.format, image.image, vk.IMAGE_ASPECT_COLOR_BIT);
        checkVk(vk.CreateImageView(logical_device.handle, &view_ci, alloc_cbs, &image.view)) catch
            @panic("failed to create maze image view");

        // transition to GENERAL for compute writes
        upload_ctx.immediateSubmit(logical_device, struct {
            img: vk.Image,
            pub fn submit(self: @This(), cmd: vk.CommandBuffer) void {
                core.vulkan_util.transitionImageLayout(
                    cmd,
                    self.img,
                    vk.IMAGE_LAYOUT_UNDEFINED,
                    vk.IMAGE_LAYOUT_GENERAL,
                    0,
                    vk.ACCESS_SHADER_WRITE_BIT,
                    vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                    vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                );
            }
        }{ .img = image.image });

        // nearest sampler for pixel-perfect maze display
        var sampler: vk.Sampler = undefined;
        checkVk(vk.CreateSampler(logical_device.handle, &vk.SamplerCreateInfo{
            .sType = vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = vk.FILTER_NEAREST,
            .minFilter = vk.FILTER_NEAREST,
            .addressModeU = vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        }, alloc_cbs, &sampler)) catch @panic("failed to create maze sampler");

        // persistently mapped maze state buffer — one u32 per cell
        const state_size = cd.maze_width * cd.maze_height * @sizeOf(u32);
        const state_alloc = vma_usage.AllocatedBuffer.create(
            allocs.vma,
            state_size,
            vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
            0,
        );
        var maze_state = vma_usage.MappedBuffer{ .allocation = state_alloc };
        checkVk(core.clibs.vma.MapMemory(
            allocs.vma,
            state_alloc.allocation,
            &maze_state.mapped,
        )) catch @panic("failed to map maze state buffer");
        @memset(@as([*]u8, @ptrCast(maze_state.mapped))[0..state_size], 0);

        _ = physical_device;

        return .{
            .draw_image = image,
            .sampler = sampler,
            .maze_state = maze_state,
            .maze_width = cd.maze_width,
            .maze_height = cd.maze_height,
        };
    }

    /// Direct access to maze cell states — write u32 values then call dispatch.
    pub fn cellStates(self: *@This()) []u32 {
        const count = self.maze_width * self.maze_height;
        return @as([*]u32, @ptrCast(@alignCast(self.maze_state.mapped)))[0..count];
    }

    pub fn deinit(
        self: *@This(),
        allocs: core.VulkanEngine.Allocators,
        device: vk.Device,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) void {
        self.maze_state.deinit(allocs.vma);
        self.draw_image.deinit(allocs.vma, device, alloc_cbs);
        vk.DestroySampler(device, self.sampler, alloc_cbs);
    }
};

pub const SystemsData = struct {
    pub fn deinit(_: *@This()) void {}
};

pub const Description = struct {
    device: vk.Device,
    shader: vk.ShaderModule,
};

pipeline: vk.Pipeline = undefined,
pipeline_layout: vk.PipelineLayout = undefined,
descriptor_pool: vk.DescriptorPool = undefined,
descriptor_set_layout: vk.DescriptorSetLayout = undefined,

const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
    vk.DestroyDescriptorPool(device, self.descriptor_pool, alloc_cbs);
}

pub fn init(pd: Description, alloc_cbs: ?*vk.AllocationCallbacks) Self {
    var self = Self{};
    self.createDescriptorSetLayout(pd.device, alloc_cbs);
    self.createDescriptorPool(pd.device, alloc_cbs);
    self.initPipeline(pd, alloc_cbs);
    return self;
}

fn createDescriptorSetLayout(
    self: *Self,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = Bindings.OUTPUT_IMAGE,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
        },
        .{
            .binding = Bindings.MAZE_STATE,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
        },
    };
    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };
    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.descriptor_set_layout)) catch
        @panic("failed to create main compute descriptor set layout");
}

fn createDescriptorPool(
    self: *Self,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1 },
        .{ .type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 },
    };
    const ci = vk.DescriptorPoolCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1,
        .poolSizeCount = pool_sizes.len,
        .pPoolSizes = &pool_sizes,
    };
    checkVk(vk.CreateDescriptorPool(device, &ci, alloc_cbs, &self.descriptor_pool)) catch
        @panic("failed to create main compute descriptor pool");
}

fn initPipeline(
    self: *Self,
    pd: Description,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const push_constant = vk.PushConstantRange{
        .offset = 0,
        .size = @sizeOf(PushConstants),
        .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
    };
    const layout_ci = vk.PipelineLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &self.descriptor_set_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant,
    };
    checkVk(vk.CreatePipelineLayout(pd.device, &layout_ci, alloc_cbs, &self.pipeline_layout)) catch
        @panic("failed to create main compute pipeline layout");

    const stage = vk.PipelineShaderStageCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = vk.SHADER_STAGE_COMPUTE_BIT,
        .module = pd.shader,
        .pName = "main",
    };
    const ci = vk.ComputePipelineCreateInfo{
        .sType = vk.STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .layout = self.pipeline_layout,
        .stage = stage,
    };
    checkVk(vk.CreateComputePipelines(pd.device, null, 1, &ci, alloc_cbs, &self.pipeline)) catch
        @panic("failed to create main compute pipeline");
}

pub fn allocateDescriptorSet(self: Self, device: vk.Device) vk.DescriptorSet {
    var set: vk.DescriptorSet = undefined;
    const ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.descriptor_set_layout,
    };
    checkVk(vk.AllocateDescriptorSets(device, &ai, &set)) catch
        @panic("failed to allocate main compute descriptor set");
    return set;
}

pub fn updateDescriptorSet(
    device: vk.Device,
    alloc_data: AllocatedData,
    set: vk.DescriptorSet,
) void {
    const image_info = vk.DescriptorImageInfo{
        .imageLayout = vk.IMAGE_LAYOUT_GENERAL,
        .imageView = alloc_data.draw_image.view,
    };
    const buffer_info = vk.DescriptorBufferInfo{
        .buffer = alloc_data.maze_state.allocation.buffer,
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    };
    const writes = [_]vk.WriteDescriptorSet{
        .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = set,
            .dstBinding = Bindings.OUTPUT_IMAGE,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .pImageInfo = &image_info,
        },
        .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = set,
            .dstBinding = Bindings.MAZE_STATE,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &buffer_info,
        },
    };
    vk.UpdateDescriptorSets(device, writes.len, &writes, 0, null);
}

pub fn bind(self: Self, cmd: vk.CommandBuffer) void {
    vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
}

pub fn recordCommands(
    self: Self,
    alloc_data: AllocatedData,
    set: vk.DescriptorSet,
    cmd: vk.CommandBuffer,
) void {
    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_COMPUTE,
        self.pipeline_layout,
        0,
        1,
        &set,
        0,
        null,
    );

    const pc = PushConstants{
        .width = alloc_data.maze_width,
        .height = alloc_data.maze_height,
    };
    vk.CmdPushConstants(
        cmd,
        self.pipeline_layout,
        vk.SHADER_STAGE_COMPUTE_BIT,
        0,
        @sizeOf(PushConstants),
        &pc,
    );

    // transition to GENERAL for compute write
    core.vulkan_util.transitionImageLayout(
        cmd,
        alloc_data.draw_image.image,
        vk.IMAGE_LAYOUT_UNDEFINED,
        vk.IMAGE_LAYOUT_GENERAL,
        0,
        vk.ACCESS_SHADER_WRITE_BIT,
        vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
    );

    const w: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(alloc_data.maze_width)) / 16.0));
    const h: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(alloc_data.maze_height)) / 16.0));
    vk.CmdDispatch(cmd, w, h, 1);

    // transition to SHADER_READ_ONLY so HUD can sample it
    core.vulkan_util.transitionImageLayout(
        cmd,
        alloc_data.draw_image.image,
        vk.IMAGE_LAYOUT_GENERAL,
        vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        vk.ACCESS_SHADER_WRITE_BIT,
        vk.ACCESS_SHADER_READ_BIT,
        vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    );
}
