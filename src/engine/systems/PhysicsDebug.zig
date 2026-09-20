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

lines: std.ArrayListUnmanaged(DebugLine) = .empty,
pipeline_description: GraphicsPipeline.Description = undefined,
pipeline: GraphicsPipeline = undefined,

pub fn deinit(
    self: *@This(),
    allocs: core.engine.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.lines.deinit(allocs.std);
    self.pipeline.deinit(device, alloc_cbs);
}

pub fn initPipeline(
    self: *@This(),
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.pipeline =
        GraphicsPipeline.init(self.pd, alloc_cbs);
}

const DebugLine = struct {
    start: core.lib.math.Vec3,
    end: core.lib.math.Vec3,
    color: u32,
};

pub fn reset(self: *Debug) void {
    self.lines.clearRetainingCapacity();
}

pub fn addLine(self: *@This(), a: std.mem.allocator, p1: core.lib.math.Vec3, p2: core.lib.math.Vec3, color: u32) void {
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
    pipeline_layout: vk.PipelineLayout = undefined,

    const Self = @This();

    pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
        vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);
    }

    pub const Description = core.engine.graphics_pipelines.Description(.{
        .Enum = enum { camera },
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
            .width = @as(f32, @floatFromInt(pd.window_extent.width)),
            .height = @as(f32, @floatFromInt(pd.window_extent.height)),
            .minDepth = 0.0,
            .maxDepth = 1.0,
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
            .depthCompareOp = pd.depth_compare_op orelse @panic("DebugLinePipeline was not passed a depth comparison operation?"),
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

        self.pipeline_layout = pd.createPipelineLayout(null, alloc_cbs); // no push constants needed

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
            .layout = self.pipeline_layout,
            .renderPass = pd.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };
        checkVk(vk.CreateGraphicsPipelines(pd.device, null, 1, &pipeline_ci, alloc_cbs, &self.pipeline)) catch
            @panic("failed to create debug line pipeline");

        return self;
    }

    pub fn bind(self: Self, cmd: vk.CommandBuffer) void {
        vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
    }

    pub fn recordCommands(
        self: Self,
        vertex_buffer: vk.Buffer,
        vertex_count: u32,
        sets: Description.Sets,
        cmd: vk.CommandBuffer,
    ) void {
        if (vertex_count == 0) return;

        vk.CmdBindDescriptorSets(
            cmd,
            vk.PIPELINE_BIND_POINT_GRAPHICS,
            self.pipeline_layout,
            0,
            sets.values.len,
            &sets.values,
            0,
            null,
        );

        const offsets = [_]vk.DeviceSize{0};
        vk.CmdBindVertexBuffers(cmd, 0, 1, &vertex_buffer, &offsets);
        vk.CmdDraw(cmd, vertex_count, 1, 0, 0);
    }
};
