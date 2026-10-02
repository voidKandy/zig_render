const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.PhysicsDebugRendering);
const imgui = core.clibs.imgui;
const vk = core.clibs.vk;
const box3d = core.clibs.box3d;
const box3d_usage = core.bindings.box3d_usage;
const checkVk = core.bindings.vulkan_init.checkVk;

pub const DebugVertex = extern struct {
    position: core.lib.math.Vec3,
    _pad: f32 = 0,
    color: core.lib.math.Vec4,
};

const SET_NAME = "box3D_debug_set";
const VERTEX_BUFFER_NAME = "box3D_debug_vertices";
pub const MAX_DEBUG_LINES = 1024 * 32;

pipeline: GraphicsPipeline = undefined,
debug_ctx_ptr: *const core.engine.Physics.DebugContext,

pub fn updateSets(
    device: vk.Device,
    allocated_resources: *core.resources.Manager.AllocatedData,
) void {
    allocated_resources.mapped_buffers.updateBufferSet(
        device,
        SET_NAME,
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
        VERTEX_BUFFER_NAME,

        .{
            .alloc_size = @sizeOf(DebugVertex) * MAX_DEBUG_LINES,
            .buffer_usage = vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .mem_usage = core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
            .flags = 0,
        },
    );

    try resources.mapped_buffers.createAndRegisterBufferSetLayout(
        a,
        SET_NAME,
        &[_]core.resources.MappedBuffers.CreateBufferInfo{
            .{
                .name = VERTEX_BUFFER_NAME,
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
    _: core.engine.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.pipeline.deinit(device, alloc_cbs);
}

pub fn syncResources(self: *const @This(), alloc_resources: *const core.resources.Manager.AllocatedData) void {
    const buffer =
        alloc_resources.mapped_buffers.buffers.get(VERTEX_BUFFER_NAME).?;

    std.debug.assert(
        self.debug_ctx_ptr.vertices.items.len * @sizeOf(DebugVertex) <= buffer.allocation.size,
    );
    const aligned: [*]DebugVertex = @ptrCast(@alignCast(buffer.mapped));

    for (self.debug_ctx_ptr.vertices.items, 0..) |vertex, i| {
        aligned[i] = vertex;
    }
}

pub fn initPipeline(
    self: *@This(),
    common: core.engine.pipelines.Common,
    resources: *const core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const vert_shader = core.engine.shaders.createShaderModule(
        "box3D_debug.vert",
        common.device,
        alloc_cbs,
    ) orelse @panic("failed to create vert shader module");
    defer vk.DestroyShaderModule(
        common.device,
        vert_shader,
        alloc_cbs,
    );

    const frag_shader = core.engine.shaders.createShaderModule(
        "box3D_debug.frag",
        common.device,
        alloc_cbs,
    ) orelse @panic("failed to create frag shader module");

    defer vk.DestroyShaderModule(
        common.device,
        frag_shader,
        alloc_cbs,
    );

    const layouts = GraphicsPipeline.Description.Layouts.init(.{
        .camera = resources.mapped_buffers.buffer_set_layouts.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.layout,
        .vertex_buffer = resources.mapped_buffers.buffer_set_layouts.get(SET_NAME).?.layout,
    });

    self.pipeline =
        GraphicsPipeline.init(.{
            .layouts = layouts,
            .common = common,
            .vertex_shader = vert_shader,
            .fragment_shader = frag_shader,
        }, alloc_cbs);
}

pub fn recordCommands(
    self: @This(),
    allocated_resources: *const core.resources.Manager.AllocatedData,
    cmd: vk.CommandBuffer,
) void {
    self.pipeline.bind(cmd);

    const sets = GraphicsPipeline.Description.Sets.init(.{
        .camera = allocated_resources.mapped_buffers.buffer_sets.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.set,
        .vertex_buffer = allocated_resources.mapped_buffers.buffer_sets.get(SET_NAME).?.set,
    });

    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.pipeline.layout,
        0,
        sets.values.len,
        &sets.values,
        0,
        null,
    );

    vk.CmdDraw(cmd, @intCast(self.debug_ctx_ptr.vertices.items.len), 1, 0, 0);
}

pub fn drawImgui(_: *@This(), ctx: core.engine.systems.manager.DrawImguiContext) void {
    var open = true;
    const shown = imgui.Begin("Physics", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    if (!shown) return;
    defer imgui.End();
    var query = ctx.world.queryEntities(.{ .is = .{ .rule = .at_least, .sig = .initOne(.rigid_body) } });
    while (query.next()) |*ent| {
        const transform: ?*core.engine.world.WorldTransform = if (ent.accessComponentPtr(.world_transform) catch null) |trans| trans.world_transform else null;
        const body: *core.engine.world.RigidBody = (ent.accessComponentPtr(.rigid_body) catch unreachable).rigid_body;

        imgui.Text("Entity: '%d'\nBody: '%d'", ent.identifier, body.id);

        if (transform) |trans| {
            var arr: [3]f32 = .{
                trans.position.x,
                trans.position.y,
                trans.position.z,
            };

            var label_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "Position##{d}", .{ent.identifier.*}) catch "Position";

            if (imgui.SliderFloat3(label.ptr, &arr, 0.0, 20.0)) {
                trans.position.x = arr[0];
                trans.position.y = arr[1];
                trans.position.z = arr[2];
                box3d.Body_SetTransform(
                    body.id,
                    box3d_usage.fromCoreVec3(trans.position),
                    box3d_usage.fromCoreVec4(trans.rotation),
                );

                box3d.Body_SetAwake(
                    body.id,
                    true,
                );
            }
        }
    }
}

const GraphicsPipeline = struct {
    pipeline: vk.Pipeline = undefined,
    layout: vk.PipelineLayout = undefined,

    const Self = @This();

    pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
        vk.DestroyPipelineLayout(device, self.layout, alloc_cbs);
    }

    pub const Description = core.engine.pipelines.Description(.{
        .DescriptorSets = enum {
            camera,
            vertex_buffer,
        },
    });

    pub fn init(
        pd: Description,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) Self {
        var self = Self{};

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = vk.SHADER_STAGE_VERTEX_BIT,
                .module = pd.vertex_shader,
                .pName = "main",
            },
            .{
                .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = vk.SHADER_STAGE_FRAGMENT_BIT,
                .module = pd.fragment_shader,
                .pName = "main",
            },
        };

        const vertex_input_ci = vk.PipelineVertexInputStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };

        const input_assembly_ci = vk.PipelineInputAssemblyStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = vk.PRIMITIVE_TOPOLOGY_LINE_LIST,
            .primitiveRestartEnable = vk.FALSE,
        };

        const viewport = vk.Viewport{
            .x = 0.0,
            .y = 0.0,
            .width = @as(f32, @floatFromInt(pd.common.window_extent.width)),
            .height = @as(f32, @floatFromInt(pd.common.window_extent.height)),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = pd.common.window_extent,
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
            .polygonMode = vk.POLYGON_MODE_FILL, // irrelevant for LINE_LIST primitives, FILL is the safe default
            .cullMode = vk.CULL_MODE_NONE, // lines have no "back face"
            .frontFace = vk.FRONT_FACE_COUNTER_CLOCKWISE,
            .lineWidth = 1.0,
        };

        const multisample_ci = vk.PipelineMultisampleStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = vk.SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = vk.FALSE,
            .minSampleShading = 1.0,
        };

        // Depth test ON, so debug lines get properly occluded by solid geometry.
        // Depth write OFF, so lines don't interfere with the depth buffer for things drawn after.
        const depth_stencil_ci = vk.PipelineDepthStencilStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .depthTestEnable = vk.TRUE,
            .depthWriteEnable = vk.FALSE,
            .depthCompareOp = vk.COMPARE_OP_LESS,
            .depthBoundsTestEnable = vk.FALSE,
            .stencilTestEnable = vk.FALSE,
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
            .front = .{},
            .back = .{},
        };

        const blend_attach_state = vk.PipelineColorBlendAttachmentState{
            .blendEnable = vk.FALSE,
            .colorWriteMask = vk.COLOR_COMPONENT_R_BIT | vk.COLOR_COMPONENT_G_BIT |
                vk.COLOR_COMPONENT_B_BIT | vk.COLOR_COMPONENT_A_BIT,
        };
        const blend_ci = vk.PipelineColorBlendStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = vk.FALSE,
            .logicOp = vk.LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &blend_attach_state,
        };

        self.layout = Description.createPipelineLayout(pd.layouts, pd.common.device, alloc_cbs);

        const dynamic_states = [_]vk.DynamicState{ vk.DYNAMIC_STATE_VIEWPORT, vk.DYNAMIC_STATE_SCISSOR };
        const dynamic_state_ci = vk.PipelineDynamicStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        const pipeline_ci = vk.GraphicsPipelineCreateInfo{
            .sType = vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .pDynamicState = &dynamic_state_ci,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_ci,
            .pInputAssemblyState = &input_assembly_ci,
            .pViewportState = &viewport_ci,
            .pRasterizationState = &raster_ci,
            .pMultisampleState = &multisample_ci,
            .pDepthStencilState = &depth_stencil_ci,
            .pColorBlendState = &blend_ci,
            .layout = self.layout,
            .renderPass = pd.common.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };
        checkVk(vk.CreateGraphicsPipelines(pd.common.device, null, 1, &pipeline_ci, alloc_cbs, &self.pipeline)) catch
            @panic("failed to create debug line pipeline");

        return self;
    }

    fn bind(self: Self, cmd: vk.CommandBuffer) void {
        vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
    }
};
