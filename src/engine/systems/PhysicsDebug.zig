const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.PhysicsDebugSystem);
const imgui = core.clibs.imgui;
const vk = core.clibs.vk;
const box3d = core.clibs.box3d;
const box3d_usage = core.bindings.box3d_usage;
const checkVk = core.bindings.vulkan_init.checkVk;

const DrawShapeFcn = *const fn (?*anyopaque, box3d.WorldTransform, box3d.HexColor, ?*anyopaque) callconv(.c) bool;
const DrawSegmentFcn = *const fn (box3d.Pos, box3d.Pos, box3d.HexColor, ?*anyopaque) callconv(.c) void;
const DrawTransformFcn = *const fn (box3d.WorldTransform, ?*anyopaque) callconv(.c) void;
const DrawPointFcn = *const fn (box3d.Pos, f32, box3d.HexColor, ?*anyopaque) callconv(.c) void;
const DrawSphereFcn = *const fn (box3d.Pos, f32, box3d.HexColor, f32, ?*anyopaque) callconv(.c) void;
const DrawCapsuleFcn = *const fn (box3d.Pos, box3d.Pos, f32, box3d.HexColor, f32, ?*anyopaque) callconv(.c) void;
const DrawBoundsFcn = *const fn (box3d.AABB, box3d.HexColor, ?*anyopaque) callconv(.c) void;
const DrawBoxFcn = *const fn (box3d.Vec3, box3d.WorldTransform, box3d.HexColor, ?*anyopaque) callconv(.c) void;
const DrawStringFcn = *const fn (box3d.Pos, [*:0]const u8, box3d.HexColor, ?*anyopaque) callconv(.c) void;

const PhysicsDebug = @This();
const SET_NAME = "box3D_debug_set";
const VERTEX_BUFFER_NAME = "box3D_debug_vertices";

pub const DebugVertex = extern struct {
    position: core.lib.math.Vec3,
    _pad: f32 = 0,
    color: core.lib.math.Vec4,
};

const MAX_DEBUG_LINES = 1024 * 32;
vertices: std.ArrayListUnmanaged(DebugVertex),
pipeline: GraphicsPipeline = undefined,
allocator: std.mem.Allocator,

pub fn init(a: std.mem.Allocator, resources: *core.resources.Manager) std.mem.Allocator.Error!@This() {
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
    return .{
        .allocator = a,
        .vertices = try .initCapacity(a, MAX_DEBUG_LINES),
    };
}

pub fn deinit(
    self: *@This(),
    allocs: core.engine.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.vertices.deinit(allocs.std);
    self.pipeline.deinit(device, alloc_cbs);
}

pub fn trySyncResources(self: *@This(), alloc_resources: core.resources.Manager.AllocatedData) void {
    const buffer =
        alloc_resources.mapped_buffers.buffers.get(VERTEX_BUFFER_NAME).?;

    std.debug.assert(
        self.vertices.items.len * @sizeOf(DebugVertex) <= buffer.allocation.size,
    );
    const aligned: [*]DebugVertex = @ptrCast(@alignCast(buffer.mapped));

    for (self.vertices.items, 0..) |vertex, i| {
        aligned[i] = vertex;
    }
}

pub fn registerSets(a: std.mem.Allocator, device: vk.Device, resources: *core.resources.Manager, alloc_cbs: ?*vk.AllocationCallbacks) std.mem.Allocator.Error!void {
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

pub fn updateSets(
    device: vk.Device,
    allocated_resources: *core.resources.Manager.AllocatedData,
) void {
    allocated_resources.mapped_buffers.updateBufferSet(
        device,
        SET_NAME,
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

pub fn recordGraphicsCommands(
    self: @This(),
    _: core.resources.Manager,
    allocated_resources: core.resources.Manager.AllocatedData,
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

    vk.CmdDraw(cmd, @intCast(self.vertices.items.len), 1, 0, 0);
}

pub fn reset(self: *@This()) void {
    self.vertices.clearRetainingCapacity();
}

pub fn addLine(
    self: *@This(),
    p1: box3d.Vec3,
    p2: box3d.Vec3,
    color: box3d.HexColor,
) void {
    self.vertices.appendAssumeCapacity(.{
        .position = box3d_usage.toCoreVec3(p1),
        .color = box3d_usage.unpackHexColor(color),
    });

    self.vertices.appendAssumeCapacity(.{
        .position = box3d_usage.toCoreVec3(p2),
        .color = box3d_usage.unpackHexColor(color),
    });
}

pub fn drawSegment(p1: box3d.Pos, p2: box3d.Pos, color: box3d.HexColor, context: ?*anyopaque) callconv(.c) void {
    const self: *@This() = @ptrCast(@alignCast(context.?));
    self.addLine(
        core.lib.math.Vec3.make(p1.x, p1.y, p1.z),
        core.lib.math.Vec3.make(p2.x, p2.y, p2.z),
        box3d_usage.unpackHexColor(color),
    );
}

pub fn drawBox(extents: box3d.Vec3, transform: box3d.WorldTransform, color: box3d.HexColor, context: ?*anyopaque) callconv(.c) void {
    const self: *@This() = @ptrCast(@alignCast(context.?));
    _ = self;
    _ = extents;
    _ = transform;
    _ = color;
    // ... build/add lines as before
}

// Build the actual b3DebugDraw struct to hand to box3d, pointing at `self`.
// pub fn makeDebugDraw(self: *@This()) box3d.DebugDraw {
//     var draw = box3d.DefaultDebugDraw();
//     draw.DrawSegmentFcn = drawSegment;
//     draw.DrawBoxFcn = drawBox;
//     draw.drawShapes = true;
//     draw.context = @ptrCast(self);
//     return draw;
// }
pub fn makeDebugDraw(self: *@This()) box3d.DebugDraw {
    // should be called in an update function or something
    self.reset();
    var draw = box3d.DefaultDebugDraw();

    draw.DrawShapeFcn = struct {
        fn call(userShape: ?*anyopaque, transform: box3d.WorldTransform, color: box3d.HexColor, context: ?*anyopaque) callconv(.c) void {
            _ = userShape;
            _ = transform;
            _ = color;
            _ = context;
            log.warn("DrawShapeFcn called", .{});
        }
    }.call;

    draw.DrawSegmentFcn = struct {
        fn call(p1: box3d.Pos, p2: box3d.Pos, color: box3d.HexColor, context: ?*anyopaque) callconv(.c) void {
            _ = p1;
            _ = p2;
            _ = color;
            _ = context;
            log.warn("DrawSegmentFcn called", .{});
        }
    }.call;

    draw.DrawTransformFcn = struct {
        fn call(transform: box3d.WorldTransform, context: ?*anyopaque) callconv(.c) void {
            _ = transform;
            _ = context;
            log.warn("DrawTransformFcn called", .{});
        }
    }.call;

    draw.DrawPointFcn = struct {
        fn call(p: box3d.Pos, size: f32, color: box3d.HexColor, context: ?*anyopaque) callconv(.c) void {
            _ = p;
            _ = size;
            _ = color;
            _ = context;
            log.warn("DrawPointFcn called", .{});
        }
    }.call;

    draw.DrawSphereFcn = struct {
        fn call(p: box3d.Pos, radius: f32, color: box3d.HexColor, alpha: f32, context: ?*anyopaque) callconv(.c) void {
            _ = p;
            _ = radius;
            _ = color;
            _ = alpha;
            _ = context;
            log.warn("DrawSphereFcn called", .{});
        }
    }.call;

    draw.DrawCapsuleFcn = struct {
        fn call(p1: box3d.Pos, p2: box3d.Pos, radius: f32, color: box3d.HexColor, alpha: f32, context: ?*anyopaque) callconv(.c) void {
            _ = p1;
            _ = p2;
            _ = radius;
            _ = color;
            _ = alpha;
            _ = context;
            log.warn("DrawCapsuleFcn called", .{});
        }
    }.call;

    draw.DrawBoundsFcn = struct {
        fn call(aabb: box3d.AABB, color: box3d.HexColor, context: ?*anyopaque) callconv(.c) void {
            const debug: *PhysicsDebug = @ptrCast(@alignCast(context.?));

            const min = aabb.lowerBound;
            const max = aabb.upperBound;

            const corners = [_]box3d.Pos{
                .{ .x = min.x, .y = min.y, .z = min.z },
                .{ .x = max.x, .y = min.y, .z = min.z },
                .{ .x = max.x, .y = max.y, .z = min.z },
                .{ .x = min.x, .y = max.y, .z = min.z },

                .{ .x = min.x, .y = min.y, .z = max.z },
                .{ .x = max.x, .y = min.y, .z = max.z },
                .{ .x = max.x, .y = max.y, .z = max.z },
                .{ .x = min.x, .y = max.y, .z = max.z },
            };

            const edges = [_][2]usize{
                // Bottom
                .{ 0, 1 },
                .{ 1, 2 },
                .{ 2, 3 },
                .{ 3, 0 },

                // Top
                .{ 4, 5 },
                .{ 5, 6 },
                .{ 6, 7 },
                .{ 7, 4 },

                // Vertical
                .{ 0, 4 },
                .{ 1, 5 },
                .{ 2, 6 },
                .{ 3, 7 },
            };

            for (edges) |edge| {
                debug.addLine(
                    corners[edge[0]],
                    corners[edge[1]],
                    color,
                );
            }
        }
    }.call;

    draw.DrawBoxFcn = struct {
        fn call(extents: box3d.Vec3, transform: box3d.WorldTransform, color: box3d.HexColor, context: ?*anyopaque) callconv(.c) void {
            _ = extents;
            _ = transform;
            _ = color;
            _ = context;
            log.warn("DrawBoxFcn called", .{});
        }
    }.call;

    draw.DrawStringFcn = struct {
        fn call(p: box3d.Pos, s: [*c]const u8, color: box3d.HexColor, context: ?*anyopaque) callconv(.c) void {
            _ = p;
            _ = s;
            _ = color;
            _ = context;
            log.warn("DrawStringFcn called", .{});
        }
    }.call;

    draw.drawShapes = true;
    draw.drawBounds = true;
    draw.drawingBounds = .{
        .lowerBound = .{
            .x = -100.0,
            .y = -100.0,
            .z = -100.0,
        },
        .upperBound = .{
            .x = 100.0,
            .y = 100.0,
            .z = 100.0,
        },
    };

    draw.context = @ptrCast(self);
    return draw;
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
