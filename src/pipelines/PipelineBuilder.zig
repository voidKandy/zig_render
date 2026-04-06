const std = @import("std");
const engine = @import("../root.zig");
const c = engine.clibs;
const vki = engine.vulkan_init;
const vk = c.vk;
const vma = c.vma;
const checkVk = vki.checkVk;

allocator: std.mem.Allocator,
callbacks: ?*vk.AllocationCallbacks,
shader_stages: std.ArrayList(vk.PipelineShaderStageCreateInfo),

vertex_input_info: vk.PipelineVertexInputStateCreateInfo = undefined,
input_assembly: vk.PipelineInputAssemblyStateCreateInfo = undefined,
rasterizer: vk.PipelineRasterizationStateCreateInfo = undefined,

viewport: vk.Viewport = undefined,
scissor: vk.Rect2D = undefined,

color_blend_attachment: vk.PipelineColorBlendAttachmentState = undefined,
multisampling: vk.PipelineMultisampleStateCreateInfo = undefined,
layout: vk.PipelineLayout = undefined,
depth_stencil: vk.PipelineDepthStencilStateCreateInfo = undefined,
render_info: vk.PipelineRenderingCreateInfo = undefined,
// color_attachment_format: vk.Format = undefined,

const Self = @This();
pub fn init(a: std.mem.Allocator, callbacks: ?*vk.AllocationCallbacks) Self {
    var self = Self{
        .allocator = a,
        .shader_stages = std.ArrayList(vk.PipelineShaderStageCreateInfo).initCapacity(a, 2) catch @panic("out of memory"),
        .callbacks = callbacks,
    };
    self.clear();
    return self;
}

pub fn deinit(self: *Self) void {
    self.shader_stages.deinit(self.allocator);
}

pub fn clear(self: *Self) void {
    self.input_assembly = .{ .sType = vk.STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
    self.rasterizer = .{ .sType = vk.STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
    self.color_blend_attachment = .{};
    self.vertex_input_info = .{ .sType = vk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    self.multisampling = .{ .sType = vk.STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
    // self.layout = undefind
    self.viewport = .{};
    self.scissor = .{};
    self.depth_stencil = .{ .sType = vk.STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO };
    // self.render_info = .{ .sType = vk. };
    self.shader_stages.clearRetainingCapacity();
}

// pub fn setShaders(self: *Self, vertex_shader: vk.ShaderModule, fragment_shader: vk.ShaderModule) void {
//     self.shader_stages.clearRetainingCapacity();
//     self.shader_stages.append(self.allocator, vki.pipelineShaderStageCreateInfo(vk.SHADER_STAGE_VERTEX_BIT, vertex_shader, "main")) catch @panic("out of memory");
//     self.shader_stages.append(self.allocator, vki.pipelineShaderStageCreateInfo(vk.SHADER_STAGE_FRAGMENT_BIT, fragment_shader, "main")) catch @panic("out of memory");
// }

pub fn setInputTopology(self: *Self, topology: vk.PrimitiveTopology) void {
    self.input_assembly.topology = topology;
    self.input_assembly.primitiveRestartEnable = vk.FALSE;
}

pub fn setPolygonMode(self: *Self, mode: vk.PolygonMode) void {
    self.rasterizer.polygonMode = mode;
    self.rasterizer.lineWidth = 1.0;
}

pub fn setCullMode(self: *Self, cull_mode: vk.CullModeFlags, front_face: vk.FrontFace) void {
    self.rasterizer.cullMode = cull_mode;
    self.rasterizer.frontFace = front_face;
}

pub fn setMultisamplingNone(
    self: *Self,
) void {
    self.multisampling.sampleShadingEnable = vk.FALSE;
    // multisampling defaulted to no multisampling (1 sample per pixel)
    self.multisampling.rasterizationSamples = vk.SAMPLE_COUNT_1_BIT;
    self.multisampling.minSampleShading = 1.0;
    self.multisampling.pSampleMask = null;
    // no alpha to coverage either
    self.multisampling.alphaToCoverageEnable = vk.FALSE;
    self.multisampling.alphaToOneEnable = vk.FALSE;
}

pub fn disableBlending(self: *Self) void {
    // default write mask
    self.color_blend_attachment.colorWriteMask = vk.COLOR_COMPONENT_R_BIT | vk.COLOR_COMPONENT_G_BIT | vk.COLOR_COMPONENT_B_BIT | vk.COLOR_COMPONENT_A_BIT;
    // no blending
    self.color_blend_attachment.blendEnable = vk.FALSE;
}

pub fn disableDepthtest(self: *Self) void {
    self.depth_stencil.depthTestEnable = vk.FALSE;
    self.depth_stencil.depthWriteEnable = vk.FALSE;
    self.depth_stencil.depthCompareOp = vk.COMPARE_OP_NEVER;
    self.depth_stencil.depthBoundsTestEnable = vk.FALSE;
    self.depth_stencil.stencilTestEnable = vk.FALSE;
    self.depth_stencil.front = .{};
    self.depth_stencil.back = .{};
    self.depth_stencil.minDepthBounds = 0.0;
    self.depth_stencil.maxDepthBounds = 1.0;
}

pub fn build(self: *Self, device: vk.Device, render_pass: vk.RenderPass) vk.Pipeline {

    // make viewport state from our stored viewport and scissor.
    // at the moment we wont support multiple viewports or scissors
    const viewport_state = vk.PipelineViewportStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,

        .viewportCount = 1,
        .scissorCount = 1,
        .pViewports = &self.viewport,
        .pScissors = &self.scissor,
    };

    // setup dummy color blending. We arent using transparent objects yet
    // the blending is just "no blend", but we do write to the color attachment
    const color_blending = vk.PipelineColorBlendStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,

        .logicOpEnable = vk.FALSE,
        .logicOp = vk.LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &self.color_blend_attachment,
    };

    // completely clear VertexInputStateCreateInfo, as we have no need for it
    // const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{ .sType = vk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };

    const states = &[_]vk.DynamicState{ vk.DYNAMIC_STATE_VIEWPORT, vk.DYNAMIC_STATE_SCISSOR };

    const state_ci = vk.PipelineDynamicStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pDynamicStates = states,
        .dynamicStateCount = @intCast(states.len),
    };

    const pipeline_ci = vk.GraphicsPipelineCreateInfo{
        .sType = vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .renderPass = render_pass,
        // .pNext = &self.render_info,
        .stageCount = @intCast(self.shader_stages.items.len),
        .pStages = self.shader_stages.items.ptr,
        .pVertexInputState = &self.vertex_input_info,
        .pInputAssemblyState = &self.input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &self.rasterizer,
        .pMultisampleState = &self.multisampling,
        .pColorBlendState = &color_blending,
        .pDepthStencilState = &self.depth_stencil,
        .subpass = 0,
        .layout = self.layout,
        .pDynamicState = &state_ci,
    };

    var pipeline: vk.Pipeline = undefined;
    checkVk(vk.CreateGraphicsPipelines(device, null, 1, &pipeline_ci, self.callbacks, &pipeline)) catch @panic("failed to create pipeline");
    return pipeline;
}
