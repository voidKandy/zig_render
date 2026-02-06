const std = @import("std");
const log = std.log.scoped(.BackgroundEffects);
const root = @import("../root.zig");
const util = @import("../vulkan_util.zig");
const mesh_mod = @import("../mesh.zig");
const c = @import("../clibs.zig");
const PipelineObject = @import("../PipelineObject.zig");
const ResourceManager = @import("../ResourceManager.zig");
const descriptor = @import("../descriptor.zig");
const PipelineBuilder = @import("../PipelineBuilder.zig");
const vki = @import("../vulkan_init.zig");
const vma_usage = @import("../vma_usage.zig");
const vk = c.vk;
const vma = c.vma;
const checkVk = vki.checkVk;
const Allocator = std.mem.Allocator;
const Vec4 = root.math.Vec4;

/// potentially bad that this is managed externally
const ComputePushConstants = struct {
    data1: Vec4 = Vec4.ZERO,
    data2: Vec4 = Vec4.ZERO,
    data3: Vec4 = Vec4.ZERO,
    data4: Vec4 = Vec4.ZERO,
};

const EffectData = struct {
    pipeline: vk.Pipeline = undefined,
    constants: ComputePushConstants = .{},
};

current_effect: []const u8 = undefined,
all_effects: std.StringHashMap(EffectData) = undefined,
draw_image_id: ResourceManager.ResourceID = undefined,
// draw_image: vma_usage.AllocatedImage = undefined,
pipeline_layout: vk.PipelineLayout = undefined,
// descriptor_allocator: descriptor.Allocator = undefined,
descriptor_set_layout: vk.DescriptorSetLayout = undefined,
descriptor_set: vk.DescriptorSet = undefined,

pub fn init(
    self: *@This(),
    allocs: PipelineObject.Allocators,
    init_data: PipelineObject.InitData,
    resources: []const ResourceManager.ResourceID,
    device: vki.LogicalDevice,
    alloc_cbs: ?*vk.AllocationCallbacks,
) anyerror!void {
    if (resources.len != 1) return error.UnexpectedResourcesLength;
    if (resources[0] != .image) return error.UnexpectedResourceType;
    self.draw_image_id = resources[0];
    const draw_image_resource = init_data.resources.query(self.draw_image_id) orelse @panic("No draw image?");

    self.all_effects = .init(allocs.std);
    // self.initDrawImage(allocs.vma, init_data.swapchain_extent, device.handle, alloc_cbs);
    self.initDescriptorSet(allocs, device.handle, draw_image_resource.image.view, alloc_cbs);
    self.initPipeline(device.handle, alloc_cbs);
}

pub fn drawImgui(self: *@This()) void {
    var open = true;
    if (c.imgui.Begin("background", &open, 0)) {
        var selected = self.all_effects.getPtr(self.current_effect) orelse @panic("Invalid current effect");

        c.imgui.Text("Selected effect: ", self.current_effect.ptr);
        if (c.imgui.BeginCombo("Background Effects", self.current_effect.ptr, 0)) {
            defer c.imgui.EndCombo();
            var iter = self.all_effects.keyIterator();
            while (iter.next()) |key| {
                if (c.imgui.Selectable(key.ptr))
                    self.current_effect = key.*;
            }
        }

        _ = c.imgui.SliderFloat4("data1", &selected.constants.data1.x, 0.0, 1.0);
        _ = c.imgui.SliderFloat4("data2", &selected.constants.data2.x, 0.0, 1.0);
        _ = c.imgui.SliderFloat4("data3", &selected.constants.data3.x, 0.0, 1.0);
        _ = c.imgui.SliderFloat4("data4", &selected.constants.data4.x, 0.0, 1.0);
    }
}

pub fn deinit(
    self: *@This(),
    _: PipelineObject.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    // c.vma.DestroyImage(allocs.vma, self.draw_image.image, self.draw_image.allocation);
    // vk.DestroyImageView(device, self.draw_image.view, alloc_cbs);

    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);

    vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);

    var iter = self.all_effects.valueIterator();
    while (iter.next()) |effect|
        vk.DestroyPipeline(device, effect.pipeline, alloc_cbs);

    self.all_effects.deinit();
}

pub fn draw(self: @This(), dd: PipelineObject.DrawData, cmd: vk.CommandBuffer) void {
    const draw_image_resource = dd.resources.query(self.draw_image_id) orelse @panic("No draw image?");
    const draw_image = draw_image_resource.image;

    util.transitionImageLayout(
        cmd,
        draw_image.image,
        vk.IMAGE_LAYOUT_UNDEFINED,
        vk.IMAGE_LAYOUT_GENERAL,
        vk.ACCESS_MEMORY_WRITE_BIT,
        vk.ACCESS_MEMORY_READ_BIT | vk.ACCESS_MEMORY_WRITE_BIT,
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
            &self.descriptor_set,
            0,
            null,
        );

        vk.CmdPushConstants(cmd, self.pipeline_layout, vk.SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(ComputePushConstants), &effect.constants);

        // execute the compute pipeline dispatch. We are using 16x16 workgroup size so we need to divide by it
        const w: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(draw_image.extent.width)) / 16.0));
        const h: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(draw_image.extent.height)) / 16.0));
        vk.CmdDispatch(cmd, w, h, 1);
    }

    util.transitionImageLayout(
        cmd,
        draw_image.image,
        vk.IMAGE_LAYOUT_GENERAL,
        vk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        vk.ACCESS_TRANSFER_WRITE_BIT | vk.ACCESS_TRANSFER_READ_BIT,
    );

    util.transitionImageLayout(
        cmd,
        dd.swapchain.images[dd.image_index],
        vk.IMAGE_LAYOUT_UNDEFINED,
        vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        vk.ACCESS_TRANSFER_READ_BIT,
        vk.ACCESS_MEMORY_READ_BIT,
    );

    util.copyImageToImage(
        cmd,
        draw_image.image,
        dd.swapchain.images[dd.image_index],
        vk.Extent2D{
            .height = draw_image.extent.height,
            .width = draw_image.extent.width,
        },
        dd.swapchain.extent,
    );

    util.transitionImageLayout(
        cmd,
        dd.swapchain.images[dd.image_index],
        vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        vk.ACCESS_MEMORY_WRITE_BIT,
        vk.ACCESS_MEMORY_READ_BIT | vk.ACCESS_MEMORY_WRITE_BIT,
    );
}

const GRADIENT_EFFECT_NAME = "gradient";
const SKY_EFFECT_NAME = "sky";
fn initDescriptorSet(
    self: *@This(),
    allocs: PipelineObject.Allocators,
    device: vk.Device,
    draw_image_view: vk.ImageView,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const sizes = [_]descriptor.PoolSizeRatio{.{ .typ = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE, .ratio = 1.0 }};
    allocs.descriptor.initPool(device, 10, &sizes);
    {
        var builder = descriptor.LayoutBuilder.init(allocs.std);
        defer builder.deinit(allocs.std);
        builder.addBinding(allocs.std, 0, vk.DESCRIPTOR_TYPE_STORAGE_IMAGE);
        self.descriptor_set_layout = builder.build(device, vk.SHADER_STAGE_COMPUTE_BIT, null, 0, alloc_cbs);
    }
    self.descriptor_set = allocs.descriptor.allocate(device, self.descriptor_set_layout);

    const draw_img_info = vk.DescriptorImageInfo{
        .imageLayout = vk.IMAGE_LAYOUT_GENERAL,
        .imageView = draw_image_view,
    };

    const draw_img_write = vk.WriteDescriptorSet{
        .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,

        .dstBinding = 0,
        .dstSet = self.descriptor_set,
        .descriptorCount = 1,
        .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
        .pImageInfo = &draw_img_info,
    };

    vk.UpdateDescriptorSets(device, 1, &draw_img_write, 0, null);
}

fn initPipeline(
    self: *@This(),
    device: vk.Device,
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

    checkVk(vk.CreatePipelineLayout(device, &compute_layout, alloc_cbs, &self.pipeline_layout)) catch
        @panic("failed to create compute pipeline layout");

    const gradient_shader = root.shaders.createShaderModule("gradient_color.comp", device, alloc_cbs) orelse @panic("failed to create compute shader module");
    defer vk.DestroyShaderModule(device, gradient_shader, alloc_cbs);
    const sky_shader = root.shaders.createShaderModule("sky.comp", device, alloc_cbs) orelse @panic("failed to create compute shader module");
    defer vk.DestroyShaderModule(device, sky_shader, alloc_cbs);

    const stage_info = vk.PipelineShaderStageCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .stage = vk.SHADER_STAGE_COMPUTE_BIT,
        .module = gradient_shader,
        .pName = "main",
    };

    var ci = vk.ComputePipelineCreateInfo{
        .sType = vk.STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .pNext = null,
        .layout = self.pipeline_layout,
        .stage = stage_info,
    };

    var effects_info = [_]struct { []const u8, EffectData, vk.ShaderModule }{
        .{
            GRADIENT_EFFECT_NAME,
            .{ .constants = .{
                .data1 = Vec4.make(1.0, 0.0, 0.0, 1.0),
                .data2 = Vec4.make(0.0, 0.0, 1.0, 1.0),
            } },
            gradient_shader,
        },
        .{
            SKY_EFFECT_NAME,
            .{ .constants = .{
                .data1 = Vec4.make(0.1, 0.2, 0.4, 0.97),
            } },
            sky_shader,
        },
    };

    for (0..effects_info.len) |i| {
        var info = &effects_info[i];
        if (i == 0) self.current_effect = info.@"0";
        ci.stage.module = info.@"2";
        checkVk(vk.CreateComputePipelines(device, null, 1, &ci, alloc_cbs, &info.@"1".pipeline)) catch @panic("failed to create compute pipeline");
        self.all_effects.put(info.@"0", info.@"1") catch @panic("OOM");
    }
}
