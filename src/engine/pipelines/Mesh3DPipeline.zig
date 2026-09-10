const std = @import("std");
const mem = std.mem;
const core = @import("../../root.zig");
const imgui = core.clibs.imgui;
const log = std.log.scoped(.Mesh3DPipeline);
const mesh_mod = core.lib.mesh;
const vki = core.bindings.vulkan_init;
const vk = core.clibs.vk;
const vma = core.clibs.vma;
const vma_usage = core.bindings.vma_usage;
const checkVk = vki.checkVk;
const Mesh = mesh_mod.Mesh3D;
const Meshes3D = core.resources.Meshes3D;
const Meshes2D = core.resources.Meshes2D;

pub const Description = struct {
    camera_descriptor_set_layout: vk.DescriptorSetLayout,
    samplers_descriptor_set_layout: vk.DescriptorSetLayout,
    texture_set_layout: vk.DescriptorSetLayout,
    meshes_set_layout: vk.DescriptorSetLayout,
    device: vk.Device,
    render_pass: vk.RenderPass,
    window_extent: vk.Extent2D,
    vertex_shader: vk.ShaderModule,
    fragment_shader: vk.ShaderModule,
    depth_compare_op: vk.CompareOp = vk.COMPARE_OP_LESS,
};

pub const PipelineOptions = enum {
    solid,
    line,
};

current_pipeline: PipelineOptions = .solid,
solid_pipeline: vk.Pipeline = undefined,
line_pipeline: vk.Pipeline = undefined,
pipeline_layout: vk.PipelineLayout = undefined,

const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyPipeline(device, self.solid_pipeline, alloc_cbs);
    vk.DestroyPipeline(device, self.line_pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);
}

pub fn init(
    pd: Description,
    alloc_cbs: ?*vk.AllocationCallbacks,
) Self {
    var self = Self{};
    const shader_stage_ci = [_]vk.PipelineShaderStageCreateInfo{ .{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = vk.SHADER_STAGE_VERTEX_BIT,
        .module = pd.vertex_shader,
        .pName = "main",
    }, .{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = vk.SHADER_STAGE_FRAGMENT_BIT,
        .module = pd.fragment_shader,
        .pName = "main",
    } };

    const vertex_input_ci = vk.PipelineVertexInputStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    };

    const input_assembly_ci = vk.PipelineInputAssemblyStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = vk.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = vk.FALSE,
    };

    const viewport = vk.Viewport{
        .x = 0.0,
        .y = 0.0,
        .width = @as(f32, (@floatFromInt(pd.window_extent.width))),
        .height = @as(f32, (@floatFromInt(pd.window_extent.height))),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    const scissor = vk.Rect2D{
        .offset = .{
            .x = 0,
            .y = 0,
        },
        .extent = pd.window_extent,
    };

    const viewport_ci = vk.PipelineViewportStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .pViewports = &viewport,
        .scissorCount = 1,
        .pScissors = &scissor,
    };

    const solid_rasterization_ci = vk.PipelineRasterizationStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = vk.POLYGON_MODE_FILL,
        .cullMode = vk.CULL_MODE_BACK_BIT,
        .frontFace = vk.FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1.0,
    };
    const line_rasterization_ci = vk.PipelineRasterizationStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = vk.POLYGON_MODE_LINE,
        .cullMode = vk.CULL_MODE_BACK_BIT,
        .frontFace = vk.FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1.0,
    };

    const multisample_ci = vk.PipelineMultisampleStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = vk.SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = vk.FALSE,
        .minSampleShading = 1.0,
    };

    const depth_stencil_ci = vk.PipelineDepthStencilStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = vk.TRUE,
        .depthWriteEnable = vk.TRUE,
        .depthCompareOp = pd.depth_compare_op,
        .depthBoundsTestEnable = vk.FALSE,
        .stencilTestEnable = vk.FALSE,
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
        .front = .{},
        .back = .{},
    };

    const blend_attach_state = vk.PipelineColorBlendAttachmentState{
        .blendEnable = vk.FALSE,

        .colorWriteMask = vk.COLOR_COMPONENT_R_BIT |
            vk.COLOR_COMPONENT_G_BIT |
            vk.COLOR_COMPONENT_B_BIT |
            vk.COLOR_COMPONENT_A_BIT,
    };

    const blend_ci = vk.PipelineColorBlendStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = vk.FALSE,
        .logicOp = vk.LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &blend_attach_state,
    };

    const set_layouts = [_]vk.DescriptorSetLayout{
        pd.camera_descriptor_set_layout,
        pd.samplers_descriptor_set_layout,
        pd.texture_set_layout,
        pd.meshes_set_layout,
    };

    const layout_ci = vk.PipelineLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = set_layouts.len,
        .pSetLayouts = &set_layouts,
    };

    checkVk(vk.CreatePipelineLayout(pd.device, &layout_ci, alloc_cbs, &self.pipeline_layout)) catch
        @panic("failed to create triangle pipeline layout");

    const dynamic_states = [_]vk.DynamicState{
        vk.DYNAMIC_STATE_VIEWPORT,
        vk.DYNAMIC_STATE_SCISSOR,
    };

    const dynamic_state_ci = vk.PipelineDynamicStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    const solid_pipeline_ci = vk.GraphicsPipelineCreateInfo{
        .sType = vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .pDynamicState = &dynamic_state_ci,
        .stageCount = shader_stage_ci.len,
        .pStages = &shader_stage_ci,
        .pVertexInputState = &vertex_input_ci,
        .pInputAssemblyState = &input_assembly_ci,
        .pViewportState = &viewport_ci,
        .pRasterizationState = &solid_rasterization_ci,
        .pMultisampleState = &multisample_ci,
        .pDepthStencilState = &depth_stencil_ci,
        .pColorBlendState = &blend_ci,
        .layout = self.pipeline_layout,
        .renderPass = pd.render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    const line_pipeline_ci = vk.GraphicsPipelineCreateInfo{
        .sType = vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .pDynamicState = &dynamic_state_ci,
        .stageCount = shader_stage_ci.len,
        .pStages = &shader_stage_ci,
        .pVertexInputState = &vertex_input_ci,
        .pInputAssemblyState = &input_assembly_ci,
        .pViewportState = &viewport_ci,
        .pRasterizationState = &line_rasterization_ci,
        .pMultisampleState = &multisample_ci,
        .pDepthStencilState = &depth_stencil_ci,
        .pColorBlendState = &blend_ci,
        .layout = self.pipeline_layout,
        .renderPass = pd.render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };
    const cis = &[_]vk.GraphicsPipelineCreateInfo{ solid_pipeline_ci, line_pipeline_ci };

    var pipelines = [2]vk.Pipeline{ undefined, undefined };
    checkVk(vk.CreateGraphicsPipelines(
        pd.device,
        null,
        2,
        cis,
        null,
        &pipelines,
    )) catch @panic("failed to create graphics pipeline");
    self.solid_pipeline = pipelines[0];
    self.line_pipeline = pipelines[1];

    return self;
}

pub fn bind(self: Self, cmd_buf: vk.CommandBuffer) void {
    switch (self.current_pipeline) {
        .solid => vk.CmdBindPipeline(
            cmd_buf,
            vk.PIPELINE_BIND_POINT_GRAPHICS,
            self.solid_pipeline,
        ),
        .line => vk.CmdBindPipeline(
            cmd_buf,
            vk.PIPELINE_BIND_POINT_GRAPHICS,
            self.line_pipeline,
        ),
    }
}

pub fn recordCommands(
    self: Self,
    world: *core.engine.world.GameWorld,
    /// TODO
    /// make descriptor sets type
    camera_descriptor_set: vk.DescriptorSet,
    samplers_descriptor_set: vk.DescriptorSet,
    meshes_set: vk.DescriptorSet,
    tx_set: vk.DescriptorSet,
    cmd: vk.CommandBuffer,
) void {
    // should match order of set_layouts in `init`
    const sets = [_]vk.DescriptorSet{
        camera_descriptor_set, samplers_descriptor_set, tx_set, meshes_set,
    };

    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.pipeline_layout,
        0,
        sets.len,
        &sets,
        0,
        null,
    );

    const query = core.engine.world.GameWorld.Query{ .is = .{ .rule = .at_least, .sig = s: {
        var s = core.engine.world.GameWorld.Signature.initEmpty();
        s.set(@intFromEnum(core.engine.world.GameWorld.Meta.ComponentTag.mesh3D));
        break :s s;
    } } };
    var mesh_entities_iter = world.queryEntities(query);

    var idx: usize = 0;
    while (mesh_entities_iter.next()) |handle| : (idx += 1) {
        var mutable_handle = handle;
        const mesh_component = mutable_handle.accessComponent(.mesh3D) catch unreachable;
        const mesh: core.engine.world.Mesh3DComponent = mesh_component.mesh3D;
        const ranges = mesh.handle.ranges;
        // bind set 0: VB, IB, UBO for this submesh
        vk.CmdDraw(
            cmd,
            @as(u32, @intCast(ranges.index.range)),
            1, // num instances
            @as(u32, @intCast(ranges.index.offset)),
            @as(u32, @intCast(idx)), // first instance
        );
    }
}
