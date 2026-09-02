const std = @import("std");
const mem = std.mem;
const core = @import("../../root.zig");
const imgui = core.clibs.imgui;
const log = std.log.scoped(.Mesh2DPipeline);
const vki = core.bindings.vulkan_init;
const vk = core.clibs.vk;
const vma_usage = core.bindings.vma_usage;
const checkVk = vki.checkVk;

const Bindings = struct {
    /// Set 0
    const OUTPUT_IMAGE = 0;
    const MAZE_STATE = 1;
    /// Set 1
    const TEXTURE2D = 0;
    const METADATA = 1;
};

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

// this stuff should be moved to a system or something
compute_pipeline: vk.Pipeline = undefined,
compute_pipeline_layout: vk.PipelineLayout = undefined,
mapped_buffer_descriptor_set_layout: vk.DescriptorSetLayout = undefined,
texture_write_descriptor_set_layout: vk.DescriptorSetLayout = undefined,

const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyPipeline(device, self.graphics_pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.graphics_pipeline_layout, alloc_cbs);
    vk.DestroyPipeline(device, self.compute_pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.compute_pipeline_layout, alloc_cbs);
    vk.DestroyDescriptorSetLayout(device, self.mapped_buffer_descriptor_set_layout, alloc_cbs);
    vk.DestroyDescriptorSetLayout(device, self.texture_write_descriptor_set_layout, alloc_cbs);
}

const TEXTURE_WRITE_NAMES =
    [_][]const u8{"maze"};

pub fn init(
    pd: Description,
    resources: core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) Self {
    var self = Self{};
    self.createDescriptorSetLayout(pd.device, resources, alloc_cbs);
    self.texture_write_descriptor_set_layout = resources.materials.createWritableTextureSetLayout(
        &TEXTURE_WRITE_NAMES,
        pd.device,
        alloc_cbs,
    );
    self.initComputePipeline(pd, alloc_cbs);
    self.initGraphicsPipeline(pd, alloc_cbs);
    return self;
}

fn createDescriptorSetLayout(
    self: *Self,
    device: vk.Device,
    resources: core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const maze_buffer_binding = resources.mapped_buffers.createDescriptorSetLayoutBinding(
        "maze",
        0,
        vk.SHADER_STAGE_COMPUTE_BIT,
    );
    const compute_bindings = &[_]vk.DescriptorSetLayoutBinding{
        // .{
        //     .binding = Bindings.OUTPUT_IMAGE,
        //     .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
        //     .descriptorCount = 1,
        //     .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
        // },
        // .{
        //     .binding = Bindings.MAZE_STATE,
        //     .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
        //     .descriptorCount = 1,
        //     .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
        // },
        maze_buffer_binding,
    };
    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = @as(u32, @intCast(compute_bindings.len)),
        .pBindings = compute_bindings.ptr,
    };

    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.mapped_buffer_descriptor_set_layout)) catch
        @panic("failed to create main compute descriptor set layout");
}

/// instead of the user passing a shader module, this
/// pipeline manages its own compute shaders internally
fn initComputePipeline(
    self: *Self,
    pd: Description,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const maze_shader = core.engine.shaders.createShaderModule(
        "maze.comp",
        pd.device,
        alloc_cbs,
    ) orelse @panic("failed to create maze compute shader module");
    defer vk.DestroyShaderModule(pd.device, maze_shader, alloc_cbs);
    const push_constant = vk.PushConstantRange{
        .offset = 0,
        .size = @sizeOf(core.engine.systems.Maze.PushConstants),
        .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
    };

    const set_layouts = [_]vk.DescriptorSetLayout{
        pd.global_descriptor_set_layout,
        self.texture_write_descriptor_set_layout,
        self.mapped_buffer_descriptor_set_layout,
    };

    const layout_ci = vk.PipelineLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = set_layouts.len,
        .pSetLayouts = &set_layouts,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant,
    };
    checkVk(vk.CreatePipelineLayout(pd.device, &layout_ci, alloc_cbs, &self.compute_pipeline_layout)) catch
        @panic("failed to create main compute pipeline layout");

    const stage = vk.PipelineShaderStageCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = vk.SHADER_STAGE_COMPUTE_BIT,
        .module = maze_shader,
        .pName = "main",
    };
    const ci = vk.ComputePipelineCreateInfo{
        .sType = vk.STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .layout = self.compute_pipeline_layout,
        .stage = stage,
    };
    checkVk(vk.CreateComputePipelines(pd.device, null, 1, &ci, alloc_cbs, &self.compute_pipeline)) catch
        @panic("failed to create main compute pipeline");
}

fn initGraphicsPipeline(
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

pub const DescriptorSets = struct {
    mapped_buffer: vk.DescriptorSet,
    write_texture: vk.DescriptorSet,
    // graphics: vk.DescriptorSet,
    ui: vk.DescriptorSet,
};

pub fn allocateDescriptorSets(
    self: Self,
    pool: vk.DescriptorPool,
    device: vk.Device,
    alloc_resources: core.resources.Manager.AllocatedData,
) DescriptorSets {
    var mapped_buffer_set: vk.DescriptorSet = undefined;
    const mp_bf_ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.mapped_buffer_descriptor_set_layout,
    };

    checkVk(vk.AllocateDescriptorSets(
        device,
        &mp_bf_ai,
        &mapped_buffer_set,
    )) catch
        @panic("failed to allocate mapped buffer descriptor set");

    var write_texture_set: vk.DescriptorSet = undefined;
    const wr_tx_ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.texture_write_descriptor_set_layout,
    };

    checkVk(vk.AllocateDescriptorSets(
        device,
        &wr_tx_ai,
        &write_texture_set,
    )) catch |e|
        std.debug.panic("failed to allocate writable-texture descriptor set: {s}", .{@errorName(e)});

    // TODO
    // some kind of system that adds all textures to the ui set
    const maze_tex = alloc_resources.materials.textures.get("maze").?;
    const ui_set = imgui.impl_vulkan.AddTexture(maze_tex.sampler, maze_tex.image_alloc.view, vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

    return .{
        .mapped_buffer = mapped_buffer_set,
        .write_texture = write_texture_set,
        .ui = ui_set,
    };
}

/// does nothing with graphics set?
pub fn updateDescriptorSets(
    device: vk.Device,
    alloc_resources: core.resources.Manager.AllocatedData,
    sets: DescriptorSets,
) void {
    alloc_resources.materials.updateWritableTextureSet(
        device,
        sets.write_texture,
        &TEXTURE_WRITE_NAMES,
    );

    var maze_buf_info: vk.DescriptorBufferInfo = undefined;
    const writes = [_]vk.WriteDescriptorSet{
        alloc_resources.mapped_buffers.createDescriptorSetWrite(
            sets.mapped_buffer,
            "maze",
            0,
            vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            0,
            &maze_buf_info,
        ),
    };

    vk.UpdateDescriptorSets(device, writes.len, &writes, 0, null);
}

pub fn bindCompute(self: Self, cmd: vk.CommandBuffer) void {
    vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, self.compute_pipeline);
}

pub fn bindGraphics(self: Self, cmd: vk.CommandBuffer) void {
    vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);
}

pub fn recordCommandsCompute(
    self: Self,
    alloc_resources: core.resources.Manager.AllocatedData,
    global_descriptor_set: vk.DescriptorSet,
    my_sets: DescriptorSets,
    maze_system: core.engine.systems.Maze,
    cmd: vk.CommandBuffer,
) void {
    const sets = [_]vk.DescriptorSet{
        global_descriptor_set, my_sets.write_texture, my_sets.mapped_buffer,
    };
    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_COMPUTE,
        self.compute_pipeline_layout,
        0,
        sets.len,
        &sets,
        0,
        null,
    );

    vk.CmdPushConstants(
        cmd,
        self.compute_pipeline_layout,
        vk.SHADER_STAGE_COMPUTE_BIT,
        0,
        @sizeOf(core.engine.systems.Maze.PushConstants),
        &maze_system.push_constants,
    );

    const maze_image = alloc_resources.materials.textures.get("maze").?.image_alloc;

    // transition to GENERAL for compute write
    core.bindings.vulkan_util.transitionImageLayout(
        cmd,
        maze_image.image,
        vk.IMAGE_LAYOUT_UNDEFINED,
        vk.IMAGE_LAYOUT_GENERAL,
        0,
        vk.ACCESS_SHADER_WRITE_BIT,
        vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
    );
    const w: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(maze_system.maze.width * maze_system.push_constants.pixels_per_cell)) / 8.0));
    const h: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(maze_system.maze.height * maze_system.push_constants.pixels_per_cell)) / 8.0));
    vk.CmdDispatch(cmd, w, h, 1);

    // transition to SHADER_READ_ONLY so HUD can sample it
    core.bindings.vulkan_util.transitionImageLayout(
        cmd,
        maze_image.image,
        vk.IMAGE_LAYOUT_GENERAL,
        vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        vk.ACCESS_SHADER_WRITE_BIT,
        vk.ACCESS_SHADER_READ_BIT,
        vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    );
}

pub fn recordCommandsGraphics(
    self: Self,
    world: *core.engine.world.GameWorld,
    window_extent: vk.Extent2D,
    alloc_resources: core.resources.Manager.AllocatedData,
    global_descriptor_set: vk.DescriptorSet,
    meshes_set: vk.DescriptorSet,
    tx_set: vk.DescriptorSet,
    cmd: vk.CommandBuffer,
) void {
    // should match order of set_layouts in `initGraphicsPipeline`
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
