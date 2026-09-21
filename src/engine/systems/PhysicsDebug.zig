const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.PhysicsDebugSystem);
const imgui = core.clibs.imgui;
const vk = core.clibs.vk;
const box3D = core.clibs.box3D;
const checkVk = core.bindings.vulkan_init.checkVk;

const DrawShapeFcn = *const fn (?*anyopaque, box3D.WorldTransform, box3D.HexColor, ?*anyopaque) callconv(.c) bool;
const DrawSegmentFcn = *const fn (box3D.Pos, box3D.Pos, box3D.HexColor, ?*anyopaque) callconv(.c) void;
const DrawTransformFcn = *const fn (box3D.WorldTransform, ?*anyopaque) callconv(.c) void;
const DrawPointFcn = *const fn (box3D.Pos, f32, box3D.HexColor, ?*anyopaque) callconv(.c) void;
const DrawSphereFcn = *const fn (box3D.Pos, f32, box3D.HexColor, f32, ?*anyopaque) callconv(.c) void;
const DrawCapsuleFcn = *const fn (box3D.Pos, box3D.Pos, f32, box3D.HexColor, f32, ?*anyopaque) callconv(.c) void;
const DrawBoundsFcn = *const fn (box3D.AABB, box3D.HexColor, ?*anyopaque) callconv(.c) void;
const DrawBoxFcn = *const fn (box3D.Vec3, box3D.WorldTransform, box3D.HexColor, ?*anyopaque) callconv(.c) void;
const DrawStringFcn = *const fn (box3D.Pos, [*:0]const u8, box3D.HexColor, ?*anyopaque) callconv(.c) void;

const Debug = @This();

const SET_NAME = "box3D_debug_set";
const BUFFER_NAME = "box3D_debug_vertices";

const DebugLine = extern struct {
    start: core.lib.math.Vec3,
    end: core.lib.math.Vec3,
    color: u32,
};

const MAX_DEBUG_LINES = 1024;
lines: std.ArrayListUnmanaged(DebugLine),
pipeline: GraphicsPipeline = undefined,

pub fn init(a: std.mem.Allocator, resources: *core.resources.Manager) std.mem.Allocator.Error!@This() {
    try resources.mapped_buffers.creates.put(
        a,
        BUFFER_NAME,

        .{
            .alloc_size = @sizeOf(DebugLine) * MAX_DEBUG_LINES,
            .buffer_usage = vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .mem_usage = core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
            .flags = 0,
        },
    );
    return .{
        .lines = .empty,
    };
}

pub fn deinit(
    self: *@This(),
    allocs: core.engine.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.lines.deinit(allocs.std);
    self.pipeline.deinit(device, alloc_cbs);
}

pub fn trySyncResources(self: *@This(), alloc_resources: core.resources.Manager.AllocatedData) void {
    const aligned: [*]DebugLine = @ptrCast(
        @alignCast(alloc_resources.mapped_buffers.buffers.get(BUFFER_NAME).?.mapped),
    );
    @memcpy(aligned, self.lines.items);
    // for (self.lines.items, 0..) |line, i|
    //     aligned[i] = line;
}

pub fn registerSets(a: std.mem.Allocator, device: vk.Device, resources: *core.resources.Manager, alloc_cbs: ?*vk.AllocationCallbacks) std.mem.Allocator.Error!void {
    try resources.mapped_buffers.createAndRegisterBufferSetLayout(
        a,
        SET_NAME,
        &[_]core.resources.MappedBuffers.CreateBufferInfo{
            .{
                .name = BUFFER_NAME,
                .descriptor_type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .binding = 0,
                .stage_flags = vk.SHADER_STAGE_VERTEX_BIT,
            },
        },
        device,
        alloc_cbs,
    );
}

pub fn initGraphicsPipelines(
    self: *@This(),
    common: core.engine.pipelines.Common,
    resources: core.resources.Manager,
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

    // need to load shaders here too
    const layouts = GraphicsPipeline.Description.Layouts.init(.{
        .camera = resources.mapped_buffers.buffer_set_layouts.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.layout,
        // .vertex_buffer = resources.mapped_buffers.buffer_set_layouts.get(SET_NAME).?.layout,
    });

    self.pipeline =
        GraphicsPipeline.init(.{
            .layouts = layouts,
            .common = common,
            .vertex_shader = vert_shader,
            .fragment_shader = frag_shader,
        }, alloc_cbs);
}

pub fn notrecordGraphicsCommands(
    self: @This(),
    _: core.resources.Manager,
    allocated_resources: core.resources.Manager.AllocatedData,
    cmd: vk.CommandBuffer,
) void {
    self.pipeline.bind(cmd);

    const sets = GraphicsPipeline.Description.Sets.init(.{
        .camera = allocated_resources.mapped_buffers.buffer_sets.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.set,
        // .vertex_buffer = allocated_resources.mapped_buffers.buffer_sets.get(SET_NAME).?.set,
    });

    const vert_buffer = allocated_resources.mapped_buffers.buffers.get(BUFFER_NAME).?.allocation;

    if (vert_buffer.size == 0) return;

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

    const offsets = [_]vk.DeviceSize{0};
    vk.CmdBindVertexBuffers(cmd, 0, 1, &vert_buffer.buffer, &offsets);
    vk.CmdDraw(cmd, @intCast(vert_buffer.size), 1, 0, 0);
}

fn reset(self: *Debug) void {
    self.lines.clearRetainingCapacity();
}

fn addLine(self: *@This(), a: std.mem.allocator, p1: core.lib.math.Vec3, p2: core.lib.math.Vec3, color: u32) void {
    self.lines.append(a, .{ .start = p1, .end = p2, .color = color }) catch {};
}

fn drawSegment(p1: box3D.Pos, p2: box3D.Pos, color: box3D.HexColor, context: ?*anyopaque) callconv(.c) void {
    const self: *Debug = @ptrCast(@alignCast(context.?));
    self.addLine(
        core.lib.math.Vec3.make(p1.x, p1.y, p1.z),
        core.lib.math.Vec3.make(p2.x, p2.y, p2.z),
        color,
    );
}

fn drawBox(extents: box3D.Vec3, transform: box3D.WorldTransform, color: box3D.HexColor, context: ?*anyopaque) callconv(.c) void {
    const self: *Debug = @ptrCast(@alignCast(context.?));
    _ = self;
    _ = extents;
    _ = transform;
    _ = color;
    // ... build/add lines as before
}

// Build the actual b3DebugDraw struct to hand to box3d, pointing at `self`.
pub fn makeDebugDraw(self: *@This()) box3D.DebugDraw {
    var draw = box3D.DefaultDebugDraw();
    draw.DrawSegmentFcn = drawSegment;
    draw.DrawBoxFcn = drawBox;
    draw.drawShapes = true;
    draw.context = @ptrCast(self);
    return draw;
}

const GraphicsPipeline = struct {
    pub const DebugVertex = extern struct {
        position: core.lib.math.Vec3,
        color: core.lib.math.Vec4,
    };

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
            // vertex_buffer,
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

        const binding_desc = vk.VertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(DebugVertex),
            .inputRate = vk.VERTEX_INPUT_RATE_VERTEX,
        };
        const attr_descs = [_]vk.VertexInputAttributeDescription{
            .{
                .location = 0,
                .binding = 0,
                .format = vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(DebugVertex, "position"),
            },
            .{
                .location = 1,
                .binding = 0,
                .format = vk.FORMAT_R32G32B32A32_SFLOAT,
                .offset = @offsetOf(DebugVertex, "color"),
            },
        };
        const vertex_input_ci = vk.PipelineVertexInputStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &binding_desc,
            .vertexAttributeDescriptionCount = attr_descs.len,
            .pVertexAttributeDescriptions = &attr_descs,
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
