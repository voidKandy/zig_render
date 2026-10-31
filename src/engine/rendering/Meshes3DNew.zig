const std = @import("std");
const core = @import("../../root.zig");
const math_mod = core.lib.math;
const log = std.log.scoped(.Mesh3DRendering);
const imgui = core.clibs.imgui;
const mesh_mod = core.lib.mesh;
const vki = core.bindings.vulkan_init;
const vk = core.clibs.vk;
const vma = core.clibs.vma;
const vma_usage = core.bindings.vma_usage;
const checkVk = vki.checkVk;
const Mesh = mesh_mod.Mesh3D;
const Meshes3D = core.resources.Meshes3D;

const Instance = extern struct {
    position: core.lib.math.Vec3,
    mesh_idx: u32,
    rotation: core.lib.math.Vec4,
    scale: core.lib.math.Vec3,
    material_idx: u32,
};

const InstanceEntry = struct {
    entity_id: u32,
    mesh_idx: *u32,
    material_idx: *u32,
    world_transform: *core.engine.world.WorldTransform,
};

pub const INSTANCES_BUFFER_NAME = "instances3D";
pub const INSTANCE_SET_NAME = "instance3D_set";
const INSTANCE_SIGNATURE = core.engine.world.GameWorld.Signature.initMany(&.{
    .world_transform,
    .mesh3D,
});
pub const MAX_INSTANCES = 64;

ranges: std.AutoHashMapUnmanaged(u32, core.lib.mesh.RangeDesc) = .empty,
instances: std.ArrayList(InstanceEntry) = .empty,
pipelines: GraphicsPipelines = undefined,

pub fn updateSets(
    device: vk.Device,
    allocated_resources: *core.resources.Manager.AllocatedData,
) void {
    allocated_resources.mapped_buffers.updateBufferSet(
        device,
        INSTANCE_SET_NAME,
    );
}

pub fn registerSetsAndBuffers(
    a: std.mem.Allocator,
    device: vk.Device,
    resources: *core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) std.mem.Allocator.Error!void {
    try resources.mapped_buffers.creates.put(
        a,
        INSTANCES_BUFFER_NAME,
        .{
            .alloc_size = @sizeOf(Instance) * MAX_INSTANCES,
            .buffer_usage = vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .mem_usage = core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
            .flags = 0,
        },
    );
    try resources.mapped_buffers.createAndRegisterBufferSetLayout(
        a,
        INSTANCE_SET_NAME,
        &[_]core.resources.MappedBuffers.CreateBufferInfo{
            .{
                .name = INSTANCES_BUFFER_NAME,
                .descriptor_type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .binding = 0,
                .stage_flags = vk.SHADER_STAGE_VERTEX_BIT,
            },
        },
        device,
        alloc_cbs,
    );
}

pub fn deinit(
    self: *@This(),
    allocs: core.engine.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.ranges.deinit(allocs.std);
    self.instances.deinit(allocs.std);
    self.pipelines.deinit(device, alloc_cbs);
}

pub fn syncResources(self: *const @This(), alloc_resources: *const core.resources.Manager.AllocatedData) void {
    const aligned: [*]Instance = @ptrCast(
        @alignCast(alloc_resources.mapped_buffers.buffers.get(INSTANCES_BUFFER_NAME).?.mapped),
    );
    for (self.instances.items, 0..) |entry, i|
        aligned[i] = Instance{
            .mesh_idx = entry.mesh_idx.*,
            .material_idx = entry.material_idx.*,
            .position = entry.world_transform.position,
            .rotation = entry.world_transform.rotation,
            .scale = entry.world_transform.scale,
        };
}

pub fn initPipeline(
    self: *@This(),
    common: core.engine.pipelines.Common,
    resources: *const core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const fin_shader = core.engine.shaders.createShaderModule(
        "deferred_final",
        common.device,
        alloc_cbs,
    ) orelse @panic("failed to create vert shader module");
    defer vk.DestroyShaderModule(
        common.device,
        fin_shader,
        alloc_cbs,
    );

    // const fin_frag_shader = core.engine.shaders.createShaderModule(
    //     "mesh3D.frag",
    //     common.device,
    //     alloc_cbs,
    // ) orelse @panic("failed to create frag shader module");

    // defer vk.DestroyShaderModule(
    //     common.device,
    //     fin_frag_shader,
    //     alloc_cbs,
    // );

    const final_layouts = GraphicsPipelines.FinalDescription.Layouts.init(.{
        .input_attachments = resources.subpass_input_attachments.final,
    });

    const gbuf_vert_shader = core.engine.shaders.createShaderModule(
        "gbuffer.vert",
        common.device,
        alloc_cbs,
    ) orelse @panic("failed to create vert shader module");
    defer vk.DestroyShaderModule(
        common.device,
        gbuf_vert_shader,
        alloc_cbs,
    );

    const gbuf_frag_shader = core.engine.shaders.createShaderModule(
        "gbuffer.frag",
        common.device,
        alloc_cbs,
    ) orelse @panic("failed to create frag shader module");

    defer vk.DestroyShaderModule(
        common.device,
        gbuf_frag_shader,
        alloc_cbs,
    );

    const gbuffer_layouts = GraphicsPipelines.GBufferDescription.Layouts.init(.{
        .camera = resources.mapped_buffers.buffer_set_layouts.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.layout,
        .samplers = resources.materials.samplers_descriptor_set_layout,
        .texture = resources.materials.all_textures_descriptor_set_layout,
        .meshes = resources.meshes3D.descriptor_set_layout,
        .instances = resources.mapped_buffers.buffer_set_layouts.get(INSTANCE_SET_NAME).?.layout,
    });

    self.pipelines =
        GraphicsPipelines.init(
            .{
                .layouts = gbuffer_layouts,
                .common = common,
                .subpass_idx = 0,
                .vertex_shader = gbuf_vert_shader,
                .fragment_shader = gbuf_frag_shader,
            },
            .{
                .layouts = final_layouts,
                .common = common,
                .subpass_idx = 1,
                .vertex_shader = fin_shader,
                .fragment_shader = fin_shader,
            },
            alloc_cbs,
        );
}

pub fn recordCommands(
    self: @This(),
    resources: *const core.resources.Manager,
    allocated_resources: *const core.resources.Manager.AllocatedData,
    cmd: vk.CommandBuffer,
) void {
    const gbuffer_sets = GraphicsPipelines.GBufferDescription.Sets.init(.{
        .camera = allocated_resources.mapped_buffers.buffer_sets.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.set,
        .samplers = allocated_resources.materials.sampler_set,
        .meshes = allocated_resources.meshes3D.descriptor_set,
        .instances = allocated_resources.mapped_buffers.buffer_sets.get(INSTANCE_SET_NAME).?.set,
        .texture = allocated_resources.materials.all_textures_descriptor_set,
    });

    const final_sets = GraphicsPipelines.FinalDescription.Sets.init(.{
        .input_attachments = allocated_resources.subpass_input_attachments.final,
    });

    self.pipelines.bindGbuffer(cmd);
    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.pipelines.gbuffer_layout,
        0,
        gbuffer_sets.values.len,
        &gbuffer_sets.values,
        0,
        null,
    );

    var i: u32 = 0;
    for (resources.meshes3D.ranges.items) |m3d_rg| {
        defer i += 1;
        vk.CmdPushConstants(
            cmd,
            self.pipelines.gbuffer_layout,
            vk.SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(GraphicsPipelines.PushConstants),
            &.{
                .vertex_offset = m3d_rg.vertex.offset,
                .index_offset = m3d_rg.index.offset,
            },
        );
        const instances_range = self.ranges.get(i) orelse continue;
        vk.CmdDraw(
            cmd,
            @as(u32, @intCast(m3d_rg.index.range)),
            instances_range.range, // num instances
            @as(u32, @intCast(m3d_rg.index.offset)),
            instances_range.offset, // first instance
        );
    }

    vk.CmdNextSubpass(cmd, vk.SUBPASS_CONTENTS_INLINE);

    self.pipelines.bindFinal(cmd);
    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.pipelines.final_layout,
        0,
        final_sets.values.len,
        &final_sets.values,
        0,
        null,
    );
    vk.CmdDraw(cmd, 3, 1, 0, 0);
}

pub fn getInstances(self: *@This(), a: std.mem.Allocator, world: *core.engine.world.GameWorld) std.mem.Allocator.Error!void {
    var buckets = std.AutoHashMap(usize, std.ArrayList(InstanceEntry)).init(a);
    defer {
        var it = buckets.valueIterator();
        while (it.next()) |list| {
            list.deinit(a);
        }
        buckets.deinit();
    }

    var iter = world.queryEntities(.{
        .is = .{
            .sig = INSTANCE_SIGNATURE,
            .rule = .at_least,
        },
    });

    while (iter.next()) |*entity| {
        const mesh =
            (entity.accessComponentPtr(.mesh3D) catch @panic("NO MESH?")).mesh3D;
        const transform =
            (entity.accessComponentPtr(.world_transform) catch @panic("NO TRANSFORM?")).world_transform;

        const result = try buckets.getOrPut(mesh.mesh_index);

        if (!result.found_existing) {
            result.value_ptr.* = try std.ArrayList(InstanceEntry).initCapacity(a, 16);
        }

        log.debug(
            \\creating instance: entity={} mesh={} material={} position=({d:.3}, {d:.3}, {d:.3})
        ,
            .{
                entity.identifier.*,
                mesh.mesh_index,
                mesh.material_index,
                transform.position.x,
                transform.position.y,
                transform.position.z,
            },
        );
        try result.value_ptr.append(a, .{
            .entity_id = entity.identifier.*,
            .world_transform = transform,
            .mesh_idx = &mesh.mesh_index,
            .material_idx = &mesh.material_index,
        });
    }

    var instances = try std.ArrayListUnmanaged(InstanceEntry).initCapacity(a, 128);
    var ranges = std.AutoHashMapUnmanaged(u32, core.lib.mesh.RangeDesc).empty;

    var bucket_iter = buckets.iterator();

    while (bucket_iter.next()) |entry| {
        const mesh_idx = entry.key_ptr.*;
        const bucket = entry.value_ptr.*;
        log.warn(
            \\ bucket size: {d}
        , .{bucket.items.len});

        const offset = instances.items.len;

        try instances.appendSlice(a, bucket.items);

        try ranges.put(a, @intCast(mesh_idx), .{
            .offset = @intCast(offset),
            .range = @intCast(bucket.items.len),
        });
    }

    self.ranges = ranges;
    self.instances = instances;
}

pub fn drawImgui(self: *@This(), ctx: core.engine.systems.manager.DrawImguiContext) void {
    var open = true;
    const shown = imgui.Begin("Mesh3D Rendering", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    if (!shown) return;
    defer imgui.End();

    var iter = self.ranges.iterator();

    while (iter.next()) |entry| {
        const name = ctx.resources.meshes3D.mesh_names_reverse_lookup.get(@intCast(entry.key_ptr.*)) orelse std.debug.panic(
            \\ tried to get an invalid mesh index: {d}
        , .{entry.key_ptr.*});

        imgui.Text("Mesh: '%s'", name.ptr);

        const start = entry.value_ptr.*.offset;
        const end = start + entry.value_ptr.range;

        for (self.instances.items[start..end]) |inst| {
            var buf: [64]u8 = undefined;
            const zbuf = std.fmt.bufPrintSentinel(&buf, "instance: {d}", .{inst.entity_id}, 0) catch @panic("Buffer couldnt print??");
            if (imgui.TreeNode(zbuf.ptr)) {
                defer imgui.TreePop();
                const mtl_name = ctx.resources.materials.material_names_reverse_lookup.get(inst.material_idx.*) orelse @panic("No material??");
                imgui.Text("Material: %s, index: %d", mtl_name.ptr, inst.material_idx.*);
            }
        }
    }
}

const GraphicsPipelines = struct {
    pub const GBufferDescription = core.engine.pipelines.Description(.{
        .DescriptorSets = enum { camera, meshes, instances, samplers, texture },
        .push_constants = .{
            PushConstants, vk.SHADER_STAGE_VERTEX_BIT,
        },
    });

    pub const FinalPipelineOptions = enum {
        solid,
        line,
    };

    pub const PushConstants = struct {
        vertex_offset: usize,
        index_offset: usize,
    };

    pub const FinalDescription = core.engine.pipelines.Description(.{
        .DescriptorSets = enum { input_attachments },
    });

    gbuffer_pipeline: vk.Pipeline = undefined,
    gbuffer_layout: vk.PipelineLayout = undefined,

    current_pipeline: FinalPipelineOptions = .solid,
    final_pipeline_solid: vk.Pipeline = undefined,
    final_pipeline_line: vk.Pipeline = undefined,
    final_layout: vk.PipelineLayout = undefined,

    const Self = @This();

    pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        vk.DestroyPipeline(device, self.gbuffer_pipeline, alloc_cbs);
        vk.DestroyPipelineLayout(device, self.gbuffer_layout, alloc_cbs);
        vk.DestroyPipeline(device, self.final_pipeline_solid, alloc_cbs);
        vk.DestroyPipeline(device, self.final_pipeline_line, alloc_cbs);
        vk.DestroyPipelineLayout(device, self.final_layout, alloc_cbs);
    }

    fn createFinalPipelines(
        self: *@This(),
        pd: FinalDescription,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) void {
        self.final_layout = FinalDescription.createPipelineLayout(
            pd.layouts,
            pd.common.device,
            alloc_cbs,
        );

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
            .width = @as(f32, (@floatFromInt(pd.common.window_extent.width))),
            .height = @as(f32, (@floatFromInt(pd.common.window_extent.height))),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        const scissor = vk.Rect2D{
            .offset = .{
                .x = 0,
                .y = 0,
            },
            .extent = pd.common.window_extent,
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

        const blend_attachment_state = [_]vk.PipelineColorBlendAttachmentState{
            .{
                .blendEnable = vk.FALSE,
                .colorWriteMask = vk.COLOR_COMPONENT_R_BIT |
                    vk.COLOR_COMPONENT_G_BIT |
                    vk.COLOR_COMPONENT_B_BIT |
                    vk.COLOR_COMPONENT_A_BIT,
            },
        };

        const blend_ci = vk.PipelineColorBlendStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = vk.FALSE,
            .logicOp = vk.LOGIC_OP_COPY,
            .attachmentCount = blend_attachment_state.len,
            .pAttachments = &blend_attachment_state,
        };

        const dynamic_states = [_]vk.DynamicState{
            vk.DYNAMIC_STATE_VIEWPORT,
            vk.DYNAMIC_STATE_SCISSOR,
        };

        const dynamic_state_ci = vk.PipelineDynamicStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        const final_shader_stage_ci = [_]vk.PipelineShaderStageCreateInfo{ .{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.SHADER_STAGE_VERTEX_BIT,
            .module = pd.vertex_shader,
            .pName = "vertexMain",
        }, .{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.SHADER_STAGE_FRAGMENT_BIT,
            .module = pd.vertex_shader,
            .pName = "fragmentMain",
        } };

        const final_solid_pipeline_ci = vk.GraphicsPipelineCreateInfo{
            .sType = vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .pDynamicState = &dynamic_state_ci,
            .stageCount = final_shader_stage_ci.len,
            .pStages = &final_shader_stage_ci,
            .pVertexInputState = &vertex_input_ci,
            .pInputAssemblyState = &input_assembly_ci,
            .pViewportState = &viewport_ci,
            .pRasterizationState = &solid_rasterization_ci,
            .pMultisampleState = &multisample_ci,
            .pDepthStencilState = null,
            .pColorBlendState = &blend_ci,
            .layout = self.final_layout,
            .renderPass = pd.common.render_pass,
            .subpass = pd.subpass_idx,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        var final_line_pipeline_ci = final_solid_pipeline_ci;
        final_line_pipeline_ci.pRasterizationState = &line_rasterization_ci;

        const cis = &[_]vk.GraphicsPipelineCreateInfo{
            final_solid_pipeline_ci,
            final_line_pipeline_ci,
        };

        var pipelines: [2]vk.Pipeline = @splat(undefined);
        checkVk(vk.CreateGraphicsPipelines(
            pd.common.device,
            null,
            cis.len,
            cis,
            null,
            &pipelines,
        )) catch @panic("failed to create graphics pipeline");

        self.final_pipeline_solid = pipelines[0];
        self.final_pipeline_line = pipelines[1];
    }

    fn createGBufferPipeline(
        self: *@This(),
        pd: GBufferDescription,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) void {
        self.gbuffer_layout = GBufferDescription.createPipelineLayout(
            pd.layouts,
            pd.common.device,
            alloc_cbs,
        );

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
            .width = @as(f32, (@floatFromInt(pd.common.window_extent.width))),
            .height = @as(f32, (@floatFromInt(pd.common.window_extent.height))),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        const scissor = vk.Rect2D{
            .offset = .{
                .x = 0,
                .y = 0,
            },
            .extent = pd.common.window_extent,
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
            .depthCompareOp = vk.COMPARE_OP_LESS,
            .depthBoundsTestEnable = vk.FALSE,
            .stencilTestEnable = vk.FALSE,
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
            .front = .{},
            .back = .{},
        };

        // BAD
        // maybe attachment information should be added to PipelineDescription
        // that way this number can be derived
        const amt_gbuf_blend_attachments = 3;
        const gbuf_blend_attachment_states: [amt_gbuf_blend_attachments]vk.PipelineColorBlendAttachmentState = @splat(
            vk.PipelineColorBlendAttachmentState{
                .blendEnable = vk.FALSE,
                .colorWriteMask = vk.COLOR_COMPONENT_R_BIT |
                    vk.COLOR_COMPONENT_G_BIT |
                    vk.COLOR_COMPONENT_B_BIT |
                    vk.COLOR_COMPONENT_A_BIT,
            },
        );

        const gbuf_blend_ci = vk.PipelineColorBlendStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = vk.FALSE,
            .logicOp = vk.LOGIC_OP_COPY,
            .attachmentCount = gbuf_blend_attachment_states.len,
            .pAttachments = &gbuf_blend_attachment_states,
        };

        const dynamic_states = [_]vk.DynamicState{
            vk.DYNAMIC_STATE_VIEWPORT,
            vk.DYNAMIC_STATE_SCISSOR,
        };

        const dynamic_state_ci = vk.PipelineDynamicStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        const gbuffer_shader_stage_ci = [_]vk.PipelineShaderStageCreateInfo{ .{
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

        const ci = vk.GraphicsPipelineCreateInfo{
            .sType = vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .pDynamicState = &dynamic_state_ci,
            .stageCount = gbuffer_shader_stage_ci.len,
            .pStages = &gbuffer_shader_stage_ci,
            .pVertexInputState = &vertex_input_ci,
            .pInputAssemblyState = &input_assembly_ci,
            .pViewportState = &viewport_ci,
            .pRasterizationState = &solid_rasterization_ci,
            .pMultisampleState = &multisample_ci,
            .pDepthStencilState = &depth_stencil_ci,
            .pColorBlendState = &gbuf_blend_ci,
            .layout = self.gbuffer_layout,
            .renderPass = pd.common.render_pass,
            .subpass = pd.subpass_idx,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        checkVk(vk.CreateGraphicsPipelines(
            pd.common.device,
            null,
            1,
            &ci,
            null,
            &self.gbuffer_pipeline,
        )) catch @panic("failed to create graphics pipeline");
    }

    pub fn init(
        gbuffer_pd: GBufferDescription,
        final_pd: FinalDescription,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) Self {
        var self = Self{};
        self.createGBufferPipeline(gbuffer_pd, alloc_cbs);
        self.createFinalPipelines(final_pd, alloc_cbs);
        return self;
    }

    fn bindGbuffer(self: Self, cmd_buf: vk.CommandBuffer) void {
        vk.CmdBindPipeline(
            cmd_buf,
            vk.PIPELINE_BIND_POINT_GRAPHICS,
            self.gbuffer_pipeline,
        );
    }
    fn bindFinal(self: Self, cmd_buf: vk.CommandBuffer) void {
        switch (self.current_pipeline) {
            .solid => vk.CmdBindPipeline(
                cmd_buf,
                vk.PIPELINE_BIND_POINT_GRAPHICS,
                self.final_pipeline_solid,
            ),
            .line => vk.CmdBindPipeline(
                cmd_buf,
                vk.PIPELINE_BIND_POINT_GRAPHICS,
                self.final_pipeline_line,
            ),
        }
    }
};
