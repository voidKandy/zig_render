const std = @import("std");
const mem = std.mem;
const core = @import("../root.zig");
const imgui = core.clibs.imgui;
const log = std.log.scoped(.DescriptorIndexing);
const mesh_mod = core.mesh;
const vki = core.vulkan_init;
const vk = core.clibs.vk;
const checkVk = vki.checkVk;

// pipeline: vk.Pipeline = undefined,

current_effect: []const u8 = undefined,
all_effects: std.StringHashMap(EffectData) = undefined,
pipeline_layout: vk.PipelineLayout = undefined,
descriptor_pool: vk.DescriptorPool = undefined,
descriptor_set_layout: vk.DescriptorSetLayout = undefined,

/// potentially bad that this is managed externally
const ComputePushConstants = struct {
    data1: core.math.Vec4 = core.math.Vec4.ZERO,
    data2: core.math.Vec4 = core.math.Vec4.ZERO,
    data3: core.math.Vec4 = core.math.Vec4.ZERO,
    data4: core.math.Vec4 = core.math.Vec4.ZERO,
};

pub const EffectData = struct {
    pipeline: vk.Pipeline = undefined,
    constants: ComputePushConstants = .{},
};

const GRADIENT_EFFECT_NAME = "gradient";
const SKY_EFFECT_NAME = "sky";

pub const AllocatedData = struct {
    draw_image: core.vma_usage.AllocatedImage,

    pub fn deinit(
        self: @This(),
        vma_a: core.clibs.vma.Allocator,
        device: vk.Device,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) void {
        self.draw_image.deinit(vma_a, device, alloc_cbs);
    }
};

pub const Description = struct {
    device: vk.Device = undefined,
    window_extent: vk.Extent2D,
    num_images: u32,
    effects_info: []const struct { []const u8, EffectData, vk.ShaderModule },
};

const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    defer self.all_effects.deinit();
    var iter = self.all_effects.valueIterator();
    while (iter.next()) |data|
        vk.DestroyPipeline(device, data.pipeline, alloc_cbs);

    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);
    vk.DestroyDescriptorPool(device, self.descriptor_pool, alloc_cbs);
}

pub fn init(a: std.mem.Allocator, description: Description, alloc_cbs: ?*vk.AllocationCallbacks) @This() {
    var self = Self{
        .all_effects = std.StringHashMap(EffectData).init(a),
    };

    self.createDescriptorSetLayout(description, alloc_cbs);
    self.initPipeline(description, alloc_cbs);

    return self;
    // self.all(description, alloc_cbs);
}

fn initPipeline(
    self: *@This(),
    desc: Description,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const push_constant = vk.PushConstantRange{
        .offset = 0,
        .size = @sizeOf(ComputePushConstants),
        .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
    };

    const compute_layout = vk.PipelineLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .pSetLayouts = &self.descriptor_set_layout,
        .setLayoutCount = 1,
        .pPushConstantRanges = &push_constant,
        .pushConstantRangeCount = 1,
    };

    checkVk(vk.CreatePipelineLayout(desc.device, &compute_layout, alloc_cbs, &self.pipeline_layout)) catch
        @panic("failed to create compute pipeline layout");

    const stage_info = vk.PipelineShaderStageCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .stage = vk.SHADER_STAGE_COMPUTE_BIT,
        .module = desc.effects_info[0].@"2",
        .pName = "main",
    };

    var ci = vk.ComputePipelineCreateInfo{
        .sType = vk.STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .pNext = null,
        .layout = self.pipeline_layout,
        .stage = stage_info,
    };

    for (0..desc.effects_info.len) |i| {
        var info = desc.effects_info[i];
        if (i == 0) self.current_effect = info.@"0";
        ci.stage.module = info.@"2";
        checkVk(vk.CreateComputePipelines(desc.device, null, 1, &ci, alloc_cbs, &info.@"1".pipeline)) catch @panic("failed to create compute pipeline");
        self.all_effects.put(info.@"0", info.@"1") catch @panic("OOM");
    }
}

pub fn createDescriptorPool(
    self: *Self,
    device: vk.Device,
    num_images: u32,
    max_sets: u32,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    var sizes = [_]vk.DescriptorPoolSize{.{
        .type = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
        .descriptorCount = num_images,
    }};
    // const sizes = [_]descriptor.PoolSizeRatio{.{ .typ = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE, .ratio = 1.0 }};
    // allocs.global_descriptor.initPool(device, 10, &sizes);

    const ci = vk.DescriptorPoolCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = 0,
        .maxSets = max_sets,
        .poolSizeCount = @as(u32, @intCast(sizes.len)),
        .pPoolSizes = sizes[0..sizes.len].ptr,
    };

    checkVk(vk.CreateDescriptorPool(device, &ci, alloc_cbs, &self.descriptor_pool)) catch
        @panic("failed to create descriptor pool");
}

fn createDescriptorSetLayout(
    self: *Self,
    description: Description,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
        },
    };

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = 0,
        .bindingCount = @as(u32, @intCast(bindings.len)),
        .pBindings = bindings[0..bindings.len].ptr,
    };

    checkVk(vk.CreateDescriptorSetLayout(description.device, &ci, alloc_cbs, &self.descriptor_set_layout)) catch
        @panic("failed to create descriptor set layout");
}

pub fn allocateDescriptorSet(
    self: Self,
    device: vk.Device,
) vk.DescriptorSet {
    var set: vk.DescriptorSet = undefined;

    const ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.descriptor_set_layout,
    };

    checkVk(vk.AllocateDescriptorSets(device, &ai, &set)) catch
        @panic("failed to allocate descriptor sets");

    return set;
}

pub fn updateDescriptorSets(
    device: vk.Device,
    alloc_data: AllocatedData,
    set: vk.DescriptorSet,
) mem.Allocator.Error!void {
    const draw_img_info = vk.DescriptorImageInfo{
        .imageLayout = vk.IMAGE_LAYOUT_GENERAL,
        .imageView = alloc_data.draw_image.view,
    };

    const draw_img_write = vk.WriteDescriptorSet{
        .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,

        .dstBinding = 0,
        .dstSet = set,
        .descriptorCount = 1,
        .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
        .pImageInfo = &draw_img_info,
    };

    vk.UpdateDescriptorSets(device, 1, &draw_img_write, 0, null);
}

pub fn bind(self: Self, cmd: vk.CommandBuffer) void {
    const current_pipeline = self.all_effects.get(self.current_effect).?.pipeline;
    vk.CmdBindPipeline(
        cmd,
        vk.PIPELINE_BIND_POINT_COMPUTE,
        current_pipeline,
    );
}

pub fn recordCommands(
    self: Self,
    alloc_data: AllocatedData,
    swapchain: core.vulkan_init.Swapchain,
    img_idx: usize,
    set: vk.DescriptorSet,
    cmd: vk.CommandBuffer,
) void {
    const draw_image = alloc_data.draw_image;

    core.vulkan_util.transitionImageLayout(
        cmd,
        draw_image.image,
        vk.IMAGE_LAYOUT_UNDEFINED,
        vk.IMAGE_LAYOUT_GENERAL,
        vk.ACCESS_MEMORY_WRITE_BIT,
        vk.ACCESS_MEMORY_READ_BIT | vk.ACCESS_MEMORY_WRITE_BIT,
        //BAD!
        vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
        vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
    );

    {
        const effect = self.all_effects.get(self.current_effect) orelse {
            log.err(
                \\ Attempted to get effect with name '{s}', but no effect was found
            , .{self.current_effect});
            return;
        };

        vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, effect.pipeline);

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

        vk.CmdPushConstants(cmd, self.pipeline_layout, vk.SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(ComputePushConstants), &effect.constants);

        // execute the compute pipeline dispatch. We are using 16x16 workgroup size so we need to divide by it
        const w: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(draw_image.extent.width)) / 16.0));
        const h: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(draw_image.extent.height)) / 16.0));
        vk.CmdDispatch(cmd, w, h, 1);
    }

    core.vulkan_util.transitionImageLayout(
        cmd,
        draw_image.image,
        vk.IMAGE_LAYOUT_GENERAL,
        vk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        vk.ACCESS_TRANSFER_WRITE_BIT | vk.ACCESS_TRANSFER_READ_BIT,
        //BAD!
        vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
        vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
    );

    core.vulkan_util.transitionImageLayout(
        cmd,
        swapchain.images[img_idx],
        vk.IMAGE_LAYOUT_UNDEFINED,
        vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        vk.ACCESS_TRANSFER_READ_BIT,
        vk.ACCESS_MEMORY_READ_BIT,
        //BAD!
        vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
        vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
    );

    core.vulkan_util.copyImageToImage(
        cmd,
        draw_image.image,
        swapchain.images[img_idx],
        vk.Extent2D{
            .height = draw_image.extent.height,
            .width = draw_image.extent.width,
        },
        swapchain.extent,
    );

    core.vulkan_util.transitionImageLayout(
        cmd,
        swapchain.images[img_idx],
        vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        vk.ACCESS_MEMORY_WRITE_BIT,
        vk.ACCESS_MEMORY_READ_BIT | vk.ACCESS_MEMORY_WRITE_BIT,
        //BAD!
        vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
        vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
    );
}

pub fn drawImgui(self: *@This()) void {
    var open = true;
    const shown = imgui.Begin("Background Pipeline", &open, 0);
    defer imgui.End();

    if (shown) {
        var selected = self.all_effects.getPtr(self.current_effect) orelse @panic("Invalid current effect");

        imgui.Text("Selected effect: ", self.current_effect.ptr);
        if (imgui.BeginCombo("Background Effects", self.current_effect.ptr, 0)) {
            defer imgui.EndCombo();
            var iter = self.all_effects.keyIterator();
            while (iter.next()) |key| {
                if (imgui.Selectable(key.ptr))
                    self.current_effect = key.*;
            }
        }

        _ = imgui.SliderFloat4("data1", &selected.constants.data1.x, 0.0, 1.0);
        _ = imgui.SliderFloat4("data2", &selected.constants.data2.x, 0.0, 1.0);
        _ = imgui.SliderFloat4("data3", &selected.constants.data3.x, 0.0, 1.0);
        _ = imgui.SliderFloat4("data4", &selected.constants.data4.x, 0.0, 1.0);
    }
}
