const std = @import("std");
const core = @import("../../root.zig");
const math_mod = core.lib.math;
const log = std.log.scoped(.Mesh2DRendering);
const imgui = core.clibs.imgui;
const mesh_mod = core.lib.mesh;
const vki = core.bindings.vulkan_init;
const vk = core.clibs.vk;
const vma = core.clibs.vma;
const vma_usage = core.bindings.vma_usage;
const checkVk = vki.checkVk;
const Mesh = mesh_mod.Mesh2D;
const Meshes3D = core.resources.Meshes2D;

const Instance = extern struct {
    mesh_idx: u32,
    material_idx: u32,
    screen_coordinates: core.lib.math.Vec2,
};

/// HOLDS pointers to data owned by ECS
/// REMOVAL OF ENTITIES WILL BREAK THIS SO THAT NEEDS TO BE FIGURED OUT
const InstanceEntry = struct {
    entity_id: u32,
    mesh_idx: *u32,
    material_idx: *u32,
    screen_coordinates: *core.lib.math.Vec2,
};

pub const INSTANCES_BUFFER_NAME = "instances2D";
pub const INSTANCE_SET_NAME = "instance2D_set";
const INSTANCE_SIGNATURE = core.engine.world.GameWorld.Signature.initMany(&.{
    .screen_transform,
    .mesh2D,
});

ranges: std.AutoHashMap(u32, core.lib.mesh.RangeDesc),
instances: []InstanceEntry,
window_extent: vk.Extent2D,
pipeline: GraphicsPipeline = undefined,

pub fn init(
    a: std.mem.Allocator,
    world: *core.engine.world.GameWorld,
    resources: *core.resources.Manager,
    window_extent: vk.Extent2D,
) std.mem.Allocator.Error!@This() {
    var self = try getInstances(a, world);
    self.window_extent = window_extent;

    std.debug.assert(self.instances.len > 0);

    try resources.mapped_buffers.creates.put(
        a,
        INSTANCES_BUFFER_NAME,
        .{
            .alloc_size = @sizeOf(Instance) * self.instances.len,
            .buffer_usage = vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .mem_usage = core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
            .flags = 0,
        },
    );
    return self;
}

pub fn deinit(
    self: *@This(),
    allocs: core.engine.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.ranges.deinit();
    allocs.std.free(self.instances);
    self.pipeline.deinit(device, alloc_cbs);
}

pub fn updateSets(
    device: vk.Device,
    allocated_resources: *core.resources.Manager.AllocatedData,
) void {
    allocated_resources.mapped_buffers.updateBufferSet(
        device,
        INSTANCE_SET_NAME,
    );
}

pub fn registerSets(
    a: std.mem.Allocator,
    device: vk.Device,
    resources: *core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) std.mem.Allocator.Error!void {
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

pub fn trySyncResources(self: *@This(), alloc_resources: core.resources.Manager.AllocatedData) void {
    const aligned: [*]Instance = @ptrCast(
        @alignCast(alloc_resources.mapped_buffers.buffers.get(INSTANCES_BUFFER_NAME).?.mapped),
    );
    for (self.instances, 0..) |entry, i|
        aligned[i] = Instance{
            .mesh_idx = entry.mesh_idx.*,
            .material_idx = entry.material_idx.*,
            .screen_coordinates = entry.screen_coordinates.*,
        };
}

pub fn recordGraphicsCommands(
    self: @This(),
    resources: core.resources.Manager,
    alloc_resources: core.resources.Manager.AllocatedData,
    cmd: vk.CommandBuffer,
) void {
    const sets = GraphicsPipeline.Description.Sets.init(.{
        .samplers = alloc_resources.materials.sampler_set,
        .texture = alloc_resources.materials.all_textures_descriptor_set,
        .instances = alloc_resources.mapped_buffers.buffer_sets.get(INSTANCE_SET_NAME).?.set,
    });

    self.pipeline.bind(cmd);
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
    vk.CmdBindVertexBuffers(cmd, 0, 1, &alloc_resources.meshes2D.vertex_buffer.buffer, &offsets);
    vk.CmdBindIndexBuffer(cmd, alloc_resources.meshes2D.index_buffer.buffer, 0, vk.INDEX_TYPE_UINT32);
    var i: u32 = 0;
    for (resources.meshes2D.ranges.items) |m2d_rg| {
        defer i += 1;

        const pc = GraphicsPipeline.PushConstants{
            .inverse_window_resolution = core.lib.math.Vec2.make(
                1.0 / @as(f32, @floatFromInt(self.window_extent.width)),
                1.0 / @as(f32, @floatFromInt(self.window_extent.height)),
            ),
            .vertex_offset = m2d_rg.vertex.offset,
            .index_offset = m2d_rg.index.offset,
        };

        vk.CmdPushConstants(
            cmd,
            self.pipeline.layout,
            vk.SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(GraphicsPipeline.PushConstants),
            &pc,
        );

        const instances_range = self.ranges.get(i) orelse continue;
        vk.CmdDrawIndexed(
            cmd,
            @as(u32, @intCast(m2d_rg.index.range)),
            instances_range.range,
            @as(u32, @intCast(m2d_rg.index.offset)),
            @as(i32, @intCast(m2d_rg.vertex.offset)),
            instances_range.offset,
        );
    }
}

pub fn initGraphicsPipelines(
    self: *@This(),
    common: core.engine.pipelines.Common,
    resources: core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const vert_shader = core.engine.shaders.createShaderModule(
        "mesh2D.vert",
        common.device,
        alloc_cbs,
    ) orelse @panic("failed to create vert shader module");
    defer vk.DestroyShaderModule(
        common.device,
        vert_shader,
        alloc_cbs,
    );

    const frag_shader = core.engine.shaders.createShaderModule(
        "mesh2D.frag",
        common.device,
        alloc_cbs,
    ) orelse @panic("failed to create frag shader module");

    defer vk.DestroyShaderModule(
        common.device,
        frag_shader,
        alloc_cbs,
    );

    const layouts = GraphicsPipeline.Description.Layouts.init(.{
        .samplers = resources.materials.samplers_descriptor_set_layout,
        .texture = resources.materials.all_textures_descriptor_set_layout,
        .instances = resources.mapped_buffers.buffer_set_layouts.get(INSTANCE_SET_NAME).?.layout,
    });

    self.pipeline =
        GraphicsPipeline.init(.{
            .layouts = layouts,
            .common = common,
            .vertex_shader = vert_shader,
            .fragment_shader = frag_shader,
        }, alloc_cbs);
}

fn getInstances(a: std.mem.Allocator, world: *core.engine.world.GameWorld) std.mem.Allocator.Error!@This() {
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
            (entity.accessComponentPtr(.mesh2D) catch @panic("NO MESH?")).mesh2D;
        const transform =
            (entity.accessComponentPtr(.screen_transform) catch @panic("NO TRANSFORM?")).screen_transform;

        const result = try buckets.getOrPut(mesh.mesh_index);

        if (!result.found_existing) {
            result.value_ptr.* = try std.ArrayList(InstanceEntry).initCapacity(a, 16);
        }

        log.debug(
            \\creating instance: entity={} mesh={} material={} position=({d:.3}, {d:.3})
        ,
            .{
                entity.identifier,
                mesh.mesh_index,
                mesh.material_index,
                transform.coords.x,
                transform.coords.y,
            },
        );

        try result.value_ptr.append(a, .{
            .entity_id = entity.identifier,
            .screen_coordinates = &transform.coords,
            .mesh_idx = &mesh.mesh_index,
            .material_idx = &mesh.material_index,
        });
    }

    var instances = try std.ArrayList(InstanceEntry).initCapacity(a, 128);
    var ranges = std.AutoHashMap(u32, core.lib.mesh.RangeDesc).init(a);

    var bucket_iter = buckets.iterator();

    while (bucket_iter.next()) |entry| {
        const mesh_idx = entry.key_ptr.*;
        const bucket = entry.value_ptr.*;
        log.warn(
            \\ bucket size: {d}
        , .{bucket.items.len});

        const offset = instances.items.len;

        try instances.appendSlice(a, bucket.items);

        try ranges.put(@intCast(mesh_idx), .{
            .offset = @intCast(offset),
            .range = @intCast(bucket.items.len),
        });
    }

    return .{
        .ranges = ranges,
        .instances = try instances.toOwnedSlice(a),
        .window_extent = undefined,
    };
}

pub fn drawImgui(self: *@This(), ctx: core.engine.systems.manager.DrawImguiContext) void {
    var open = true;
    const shown = imgui.Begin("Mesh2D Rendering", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    if (!shown) return;
    defer imgui.End();

    var iter = self.ranges.iterator();

    while (iter.next()) |entry| {
        const name = ctx.resources.meshes2D.mesh_names_reverse_lookup.get(@intCast(entry.key_ptr.*)) orelse std.debug.panic(
            \\ tried to get an invalid mesh index: {d}
        , .{entry.key_ptr.*});

        imgui.Text("Mesh: '%s'", name.ptr);

        const start = entry.value_ptr.*.offset;
        const end = start + entry.value_ptr.range;

        for (self.instances[start..end]) |inst| {
            var buf: [64]u8 = undefined;
            const zbuf = std.fmt.bufPrintZ(&buf, "instance: {d}", .{inst.entity_id}) catch @panic("Buffer couldnt print??");
            if (imgui.TreeNode(zbuf.ptr)) {
                defer imgui.TreePop();
                const mtl_name = ctx.resources.materials.material_names_reverse_lookup.get(inst.material_idx.*) orelse @panic("No material??");
                imgui.Text("Material: %s, index: %d", mtl_name.ptr, inst.material_idx.*);

                const coords = inst.screen_coordinates.*;

                imgui.Text(
                    "x: %.3f, y: %.3f",
                    coords.x,
                    coords.y,
                );
            }
        }
    }
}

const GraphicsPipeline = struct {
    const PushConstants = struct {
        inverse_window_resolution: core.lib.math.Vec2,
        vertex_offset: u32,
        index_offset: u32,
    };

    pub const Description = core.engine.pipelines.Description(.{
        .DescriptorSets = enum {
            samplers,
            texture,
            instances,
        },
        .push_constants = .{
            PushConstants,
            vk.SHADER_STAGE_VERTEX_BIT,
        },
    });

    pipeline: vk.Pipeline = undefined,
    layout: vk.PipelineLayout = undefined,

    fn deinit(self: *@This(), device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
        vk.DestroyPipelineLayout(device, self.layout, alloc_cbs);
    }

    fn bind(self: @This(), cmd: vk.CommandBuffer) void {
        vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
    }

    fn init(
        pd: Description,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) @This() {
        var self = @This(){};
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
            .width = @floatFromInt(pd.common.window_extent.width),
            .height = @floatFromInt(pd.common.window_extent.height),
            .minDepth = 0,
            .maxDepth = 1,
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

        self.layout = Description.createPipelineLayout(pd.layouts, pd.common.device, alloc_cbs);

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
            .layout = self.layout,
            .renderPass = pd.common.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };
        checkVk(vk.CreateGraphicsPipelines(pd.common.device, null, 1, &pipeline_ci, alloc_cbs, &self.pipeline)) catch
            @panic("failed to create hud pipeline");

        return self;
    }
};
