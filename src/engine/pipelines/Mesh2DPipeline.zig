const std = @import("std");
const mem = std.mem;
const core = @import("../../root.zig");
const imgui = core.clibs.imgui;
const log = std.log.scoped(.Mesh2DPipeline);
const vki = core.bindings.vulkan_init;
const vk = core.clibs.vk;
const vma_usage = core.bindings.vma_usage;
const checkVk = vki.checkVk;

const GraphicsPushConstants = struct {
    inverse_window_resolution: core.lib.math.Vec2,
};

pub const Description = struct {
    global_descriptor_set_layout: vk.DescriptorSetLayout,
    texture_set_layout: vk.DescriptorSetLayout,
    meshes_set_layout: vk.DescriptorSetLayout,
    device: vk.Device,
    render_pass: vk.RenderPass,
    window_extent: vk.Extent2D,
    vert_shader: vk.ShaderModule,
    frag_shader: vk.ShaderModule,
};

graphics_pipeline: vk.Pipeline = undefined,
graphics_pipeline_layout: vk.PipelineLayout = undefined,

const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyPipeline(device, self.graphics_pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.graphics_pipeline_layout, alloc_cbs);
}

pub fn init(
    pd: Description,
    alloc_cbs: ?*vk.AllocationCallbacks,
) Self {
    var self = Self{};
    self.initPipeline(pd, alloc_cbs);
    return self;
}

fn initPipeline(
    self: *Self,
    pd: Description,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.SHADER_STAGE_VERTEX_BIT,
            .module = pd.vert_shader,
            .pName = "main",
        },
        .{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.SHADER_STAGE_FRAGMENT_BIT,
            .module = pd.frag_shader,
            .pName = "main",
        },
    };

    const binding_descs = core.resources.Meshes2D.VERTEX_INPUT_BINDING_DESCRIPTIONS;
    const attr_descs = core.resources.Meshes2D.VERTEX_INPUT_ATTRIBUTE_DESCRIPTIONS;

    const vertex_input_ci = vk.PipelineVertexInputStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = binding_descs.len,
        .pVertexBindingDescriptions = &binding_descs,
        .vertexAttributeDescriptionCount = attr_descs.len,
        .pVertexAttributeDescriptions = &attr_descs,
    };

    const input_assembly_ci = vk.PipelineInputAssemblyStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = vk.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = vk.FALSE,
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(pd.window_extent.width),
        .height = @floatFromInt(pd.window_extent.height),
        .minDepth = 0,
        .maxDepth = 1,
    };

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = pd.window_extent,
    };
    const viewport_ci = vk.PipelineViewportStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .pViewports = &viewport,
        .scissorCount = 1,
        .pScissors = &scissor,
    };

    const raster_ci = vk.PipelineRasterizationStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = vk.POLYGON_MODE_FILL,
        // BAD
        .cullMode = vk.CULL_MODE_NONE,
        .frontFace = vk.FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1.0,
    };

    const multisample_ci = vk.PipelineMultisampleStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = vk.SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = vk.FALSE,
        .minSampleShading = 1.0,
    };

    // no depth test — HUD always renders on top
    const depth_stencil_ci = vk.PipelineDepthStencilStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = vk.FALSE,
        .depthWriteEnable = vk.FALSE,
        .depthCompareOp = vk.COMPARE_OP_ALWAYS,
        .depthBoundsTestEnable = vk.FALSE,
        .stencilTestEnable = vk.FALSE,
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
        .front = .{},
        .back = .{},
    };

    // alpha blending so the HUD can be transparent
    const blend_attach = vk.PipelineColorBlendAttachmentState{
        .blendEnable = vk.TRUE,
        .srcColorBlendFactor = vk.BLEND_FACTOR_SRC_ALPHA,
        .dstColorBlendFactor = vk.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = vk.BLEND_OP_ADD,
        .srcAlphaBlendFactor = vk.BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk.BLEND_FACTOR_ZERO,
        .alphaBlendOp = vk.BLEND_OP_ADD,
        .colorWriteMask = vk.COLOR_COMPONENT_R_BIT | vk.COLOR_COMPONENT_G_BIT |
            vk.COLOR_COMPONENT_B_BIT | vk.COLOR_COMPONENT_A_BIT,
    };
    const blend_ci = vk.PipelineColorBlendStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = vk.FALSE,
        .logicOp = vk.LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &blend_attach,
    };

    const dynamic_states = [_]vk.DynamicState{ vk.DYNAMIC_STATE_VIEWPORT, vk.DYNAMIC_STATE_SCISSOR };
    const dynamic_state_ci = vk.PipelineDynamicStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    const push_constant = vk.PushConstantRange{
        .offset = 0,
        .size = @sizeOf(GraphicsPushConstants),
        .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
    };

    const set_layouts = [_]vk.DescriptorSetLayout{
        pd.global_descriptor_set_layout,
        pd.texture_set_layout,
        pd.meshes_set_layout,
    };

    const layout_ci = vk.PipelineLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = set_layouts.len,
        .pSetLayouts = &set_layouts,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant,
    };
    checkVk(vk.CreatePipelineLayout(pd.device, &layout_ci, alloc_cbs, &self.graphics_pipeline_layout)) catch
        @panic("failed to create hud pipeline layout");

    const pipeline_ci = vk.GraphicsPipelineCreateInfo{
        .sType = vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .stageCount = shader_stages.len,
        .pStages = &shader_stages,
        .pVertexInputState = &vertex_input_ci,
        .pInputAssemblyState = &input_assembly_ci,
        .pViewportState = &viewport_ci,
        .pRasterizationState = &raster_ci,
        .pMultisampleState = &multisample_ci,
        .pDepthStencilState = &depth_stencil_ci,
        .pColorBlendState = &blend_ci,
        .pDynamicState = &dynamic_state_ci,
        .layout = self.graphics_pipeline_layout,
        .renderPass = pd.render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };
    checkVk(vk.CreateGraphicsPipelines(pd.device, null, 1, &pipeline_ci, alloc_cbs, &self.graphics_pipeline)) catch
        @panic("failed to create hud pipeline");
}

pub fn bind(self: Self, cmd: vk.CommandBuffer) void {
    vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);
}

pub fn recordCommands(
    self: Self,
    world: *core.engine.world.GameWorld,
    window_extent: vk.Extent2D,
    alloc_resources: core.resources.Manager.AllocatedData,
    global_descriptor_set: vk.DescriptorSet,
    meshes_set: vk.DescriptorSet,
    tx_set: vk.DescriptorSet,
    cmd: vk.CommandBuffer,
) void {
    const sets = [_]vk.DescriptorSet{
        global_descriptor_set, tx_set, meshes_set,
    };

    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.graphics_pipeline_layout,
        0,
        sets.len,
        &sets,
        0,
        null,
    );

    const pc = GraphicsPushConstants{
        .inverse_window_resolution = core.lib.math.Vec2.make(
            1.0 / @as(f32, @floatFromInt(window_extent.width)),
            1.0 / @as(f32, @floatFromInt(window_extent.height)),
        ),
    };

    vk.CmdPushConstants(
        cmd,
        self.graphics_pipeline_layout,
        vk.SHADER_STAGE_VERTEX_BIT,
        0,
        @sizeOf(GraphicsPushConstants),
        &pc,
    );
    const offsets = [_]vk.DeviceSize{0};
    vk.CmdBindVertexBuffers(cmd, 0, 1, &alloc_resources.meshes2D.vertex_buffer.buffer, &offsets);
    vk.CmdBindIndexBuffer(cmd, alloc_resources.meshes2D.index_buffer.buffer, 0, vk.INDEX_TYPE_UINT32);

    const query = core.engine.world.GameWorld.Query{ .is = .{ .rule = .at_least, .sig = s: {
        var s = core.engine.world.GameWorld.Signature.initEmpty();
        s.set(@intFromEnum(core.engine.world.GameWorld.Meta.ComponentTag.mesh2D));
        break :s s;
    } } };
    var mesh_entities_iter = world.queryEntities(query);

    var idx: usize = 0;
    while (mesh_entities_iter.next()) |handle| : (idx += 1) {
        var mutable_handle = handle;
        const mesh_component = mutable_handle.accessComponent(.mesh2D) catch unreachable;
        const mesh: core.engine.world.Mesh2DComponent = mesh_component.mesh2D;

        vk.CmdDrawIndexed(
            cmd,
            @intCast(mesh.ranges.index.range), // index count
            1, // instance count
            @intCast(mesh.ranges.index.offset), // first index
            0, // vertex offset (already baked in during appendMesh)
            @intCast(idx), // first instance — used to look up MetaData in shader
        );
    }
}
