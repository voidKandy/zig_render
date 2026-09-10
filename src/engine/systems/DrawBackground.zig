const std = @import("std");
const core = @import("../../root.zig");
const math_mod = core.lib.math;
const log = std.log.scoped(.DrawBackground);
const vk = core.clibs.vk;
const imgui = core.clibs.imgui;
const checkVk = core.bindings.vulkan_init.checkVk;

swapchain_extent: vk.Extent2D,

pipeline: ComputePipeline = undefined,

pub const BACKGROUND_SET_NAME = "background_set";
pub const BACKGROUND_IMAGE_NAME = "background";

pub fn init(swapchain_extent: vk.Extent2D) @This() {
    return .{
        .swapchain_extent = swapchain_extent,
    };
}

pub fn initPipeline(
    self: *@This(),
    device: vk.Device,
    resources: core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.pipeline =
        ComputePipeline.init(device, resources, alloc_cbs);
}

pub fn deinit(self: *@This(), device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    self.pipeline.deinit(device, alloc_cbs);
}

pub fn registerSets(
    a: std.mem.Allocator,
    device: vk.Device,
    resources: *core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) std.mem.Allocator.Error!void {
    try resources.materials.createAndRegisterWritableTextureSetLayout(
        a,
        BACKGROUND_SET_NAME,
        &[_][]const u8{BACKGROUND_IMAGE_NAME},
        device,
        alloc_cbs,
    );
}

pub fn addCreateData(self: @This(), a: std.mem.Allocator, resources: *core.resources.Manager) std.mem.Allocator.Error!void {
    try resources.materials.textures.put(
        a,
        BACKGROUND_IMAGE_NAME,
        .{
            .extent = vk.Extent3D{
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .depth = 1,
            },
            .format = core.engine.Engine.MAIN_RENDER_PASS_IMAGE_FORMAT,
            .usages = vk.IMAGE_USAGE_TRANSFER_SRC_BIT |
                vk.IMAGE_USAGE_TRANSFER_DST_BIT |
                vk.IMAGE_USAGE_STORAGE_BIT | vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.IMAGE_USAGE_SAMPLED_BIT,
            .aspect_flags = vk.IMAGE_ASPECT_COLOR_BIT,
            .initial_transition_function = null,
        },
    );
}

pub fn drawImgui(self: *@This()) void {
    var open = true;
    const shown = imgui.Begin("Draw Background System", &open, 0);
    defer imgui.End();

    if (shown) {
        var selected = self.pipeline.effects.getPtr(self.pipeline.current_effect) orelse @panic("Invalid current effect");

        imgui.Text("Selected effect: ", @tagName(self.pipeline.current_effect).ptr);
        if (imgui.BeginCombo("Background Effects", @tagName(self.pipeline.current_effect).ptr, 0)) {
            defer imgui.EndCombo();
            for (std.meta.tags(ComputePipeline.Effect)) |eff| {
                if (imgui.Selectable(@tagName(eff).ptr))
                    self.pipeline.current_effect = eff;
            }
        }

        _ = imgui.SliderFloat4("data1", &selected.push_constants.data1.x, 0.0, 1.0);
        _ = imgui.SliderFloat4("data2", &selected.push_constants.data2.x, 0.0, 1.0);
        _ = imgui.SliderFloat4("data3", &selected.push_constants.data3.x, 0.0, 1.0);
        _ = imgui.SliderFloat4("data4", &selected.push_constants.data4.x, 0.0, 1.0);
    }
}

pub const ComputePipeline = struct {
    /// TODO
    /// give these fields better names
    const PushConstants = struct {
        data1: math_mod.Vec4 = .ZERO,
        data2: math_mod.Vec4 = .ZERO,
        data3: math_mod.Vec4 = .ZERO,
        data4: math_mod.Vec4 = .ZERO,
    };

    const Effect = enum {
        gradient,
        stars,

        /// in order to load shader modules the variants of this enum
        /// needs to be iterated at comptime
        pub const ALL_VARIANTS: [std.meta.tags(@This()).len]@This() = .{
            .gradient,
            .stars,
        };

        fn defaultPushConstants(self: @This()) PushConstants {
            return switch (self) {
                .gradient => PushConstants{
                    .data1 = math_mod.Vec4.make(1.0, 0.0, 0.0, 1.0),
                    .data2 = math_mod.Vec4.make(0.0, 0.0, 1.0, 1.0),
                },

                .stars => PushConstants{
                    .data1 = math_mod.Vec4.make(0.1, 0.2, 0.4, 0.97),
                },
            };
        }

        /// MUST be deinitialized after calling this
        /// `defer vk.DestroyShaderModule(device, shader, alloc_cbs);`
        inline fn shaderModule(comptime self: @This(), device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) vk.ShaderModule {
            return core.engine.shaders.createShaderModule(
                @tagName(self) ++ ".comp",
                device,
                alloc_cbs,
            ) orelse @panic("failed to create compute shader module");
        }
    };

    const EffectData = struct {
        pipeline: vk.Pipeline = undefined,
        push_constants: PushConstants = .{},
    };

    effects: std.EnumMap(Effect, EffectData) = undefined,
    current_effect: Effect = @enumFromInt(0),

    pipeline_layout: vk.PipelineLayout = undefined,

    pub fn deinit(self: *@This(), device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        var iter = self.effects.iterator();
        while (iter.next()) |eff|
            vk.DestroyPipeline(device, eff.value.pipeline, alloc_cbs);

        vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);
    }

    pub fn init(
        device: vk.Device,
        // resources is only passed here so the function can grab the descriptor sets for this given system
        // there is opportunity for abstraction here
        resources: core.resources.Manager,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) @This() {
        var self = @This(){};

        const push_constant = vk.PushConstantRange{
            .offset = 0,
            .size = @sizeOf(PushConstants),
            .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
        };

        const texture_write_layout = resources.materials.writable_textures_descriptor_set_layouts.get(BACKGROUND_SET_NAME).?.layout;

        const set_layouts = [_]vk.DescriptorSetLayout{
            texture_write_layout,
        };

        const layout_ci = vk.PipelineLayoutCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = set_layouts.len,
            .pSetLayouts = &set_layouts,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_constant,
        };
        checkVk(vk.CreatePipelineLayout(device, &layout_ci, alloc_cbs, &self.pipeline_layout)) catch
            @panic("failed to create main compute pipeline layout");

        self.effects = std.EnumMap(Effect, EffectData).initFull(.{});
        inline for (Effect.ALL_VARIANTS) |eff| {
            const shader = Effect.shaderModule(eff, device, alloc_cbs);
            defer vk.DestroyShaderModule(device, shader, alloc_cbs);

            var entry = self.effects.getPtr(eff).?;

            const stage_info = vk.PipelineShaderStageCreateInfo{
                .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .stage = vk.SHADER_STAGE_COMPUTE_BIT,
                .module = shader,
                .pName = "main",
            };

            var ci = vk.ComputePipelineCreateInfo{
                .sType = vk.STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
                .pNext = null,
                .layout = self.pipeline_layout,
                .stage = stage_info,
            };

            entry.push_constants = eff.defaultPushConstants();
            checkVk(vk.CreateComputePipelines(device, null, 1, &ci, alloc_cbs, &entry.pipeline)) catch @panic("failed to create compute pipeline");
        }

        return self;
    }

    pub fn bind(self: @This(), cmd: vk.CommandBuffer) void {
        const effect =
            self.effects.get(self.current_effect) orelse std.debug.panic(
                \\ tried to bind background pipeline '{s}' but it does not exist??
            , .{@tagName(self.current_effect)});
        vk.CmdBindPipeline(
            cmd,
            vk.PIPELINE_BIND_POINT_COMPUTE,
            effect.pipeline,
        );
    }

    pub fn recordCommands(
        self: @This(),
        alloc_resources: core.resources.Manager.AllocatedData,
        swapchain: core.bindings.vulkan_init.Swapchain,
        framebuffer_index: usize,
        write_texture_set: vk.DescriptorSet,
        cmd: vk.CommandBuffer,
    ) void {
        const draw_image = alloc_resources.materials.textures.get(BACKGROUND_IMAGE_NAME).?;

        core.bindings.vulkan_util.transitionImageLayout(
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

        const effect = self.effects.get(self.current_effect) orelse std.debug.panic(
            \\ Attempted to get effect with name '{s}' but it doesn't exist??
        , .{@tagName(self.current_effect)});

        vk.CmdBindDescriptorSets(
            cmd,
            vk.PIPELINE_BIND_POINT_COMPUTE,
            self.pipeline_layout,
            0,
            1,
            &write_texture_set,
            0,
            null,
        );

        vk.CmdPushConstants(cmd, self.pipeline_layout, vk.SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(PushConstants), &effect.push_constants);

        // execute the compute pipeline dispatch. We are using 16x16 workgroup size so we need to divide by it
        const w: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(draw_image.extent.width)) / 16.0));
        const h: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(draw_image.extent.height)) / 16.0));
        vk.CmdDispatch(cmd, w, h, 1);

        core.bindings.vulkan_util.transitionImageLayout(
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

        core.bindings.vulkan_util.transitionImageLayout(
            cmd,
            swapchain.images[framebuffer_index],
            vk.IMAGE_LAYOUT_UNDEFINED,
            vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            vk.ACCESS_TRANSFER_READ_BIT,
            vk.ACCESS_MEMORY_READ_BIT,
            //BAD!
            vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
            vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
        );

        core.bindings.vulkan_util.copyImageToImage(
            cmd,
            draw_image.image,
            swapchain.images[framebuffer_index],
            vk.Extent2D{
                .height = draw_image.extent.height,
                .width = draw_image.extent.width,
            },
            swapchain.extent,
        );

        core.bindings.vulkan_util.transitionImageLayout(
            cmd,
            swapchain.images[framebuffer_index],
            vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            vk.ACCESS_MEMORY_WRITE_BIT,
            vk.ACCESS_MEMORY_READ_BIT | vk.ACCESS_MEMORY_WRITE_BIT,
            //BAD!
            vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
            vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
        );
    }
};
