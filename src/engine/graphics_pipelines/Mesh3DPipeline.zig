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

pub const PipelineOptions = enum {
    solid,
    line,
};

current_pipeline: PipelineOptions = .solid,
solid_pipeline: vk.Pipeline = undefined,
line_pipeline: vk.Pipeline = undefined,
pipeline_layout: vk.PipelineLayout = undefined,
// render_system: RenderSystem,

const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyPipeline(device, self.solid_pipeline, alloc_cbs);
    vk.DestroyPipeline(device, self.line_pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);
    // self.render_system.deinit(a);
}

pub const Description = core.engine.graphics_pipelines.Description(enum { camera, samplers, texture, meshes, instances });

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
        .depthCompareOp = pd.depth_compare_op orelse @panic("Mesh3DPipeline was not passed a depth comparison operation?"),
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

    self.pipeline_layout = pd.createPipelineLayout(PushConstants, alloc_cbs);

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

pub const PushConstants = struct {
    vertex_offset: usize,
    index_offset: usize,
};

pub fn recordCommands(
    self: Self,
    render_system: RenderSystem,
    resources: core.resources.Manager,
    sets: Description.Sets,
    cmd: vk.CommandBuffer,
) void {
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
    var i: u32 = 0;
    for (resources.meshes3D.meshes.items) |m3d| {
        defer i += 1;
        vk.CmdPushConstants(
            cmd,
            self.pipeline_layout,
            vk.SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(PushConstants),
            &.{
                .vertex_offset = m3d.ranges.vertex.offset,
                .index_offset = m3d.ranges.index.offset,
            },
        );

        const instances_range = render_system.ranges.get(i) orelse continue;

        vk.CmdDraw(
            cmd,
            @as(u32, @intCast(m3d.ranges.index.range)),
            instances_range.range, // num instances
            @as(u32, @intCast(m3d.ranges.index.offset)),
            instances_range.offset, // first instance
        );
    }

    // const query = core.engine.world.GameWorld.Query{ .is = .{
    //     .rule = .at_least,
    //     .sig = core.engine.world.GameWorld.Signature.initOne(.mesh3D),
    // } };
    // var mesh_entities_iter = world.queryEntities(query);

    // var idx: usize = 0;
    // while (mesh_entities_iter.next()) |handle| : (idx += 1) {
    //     var mutable_handle = handle;
    //     const mesh_component = mutable_handle.accessComponent(.mesh3D) catch unreachable;
    //     const mesh: core.engine.world.Mesh3DComponent = mesh_component.mesh3D;
    //     const ranges = resources.meshes3D.meshes.items[mesh.mesh_index].ranges;
    // bind set 0: VB, IB, UBO for this submesh
    // vk.CmdDraw(
    //     cmd,
    //     @as(u32, @intCast(ranges.index.range)),
    //     1, // num instances
    //     @as(u32, @intCast(ranges.index.offset)),
    //     @as(u32, @intCast(idx)), // first instance
    // );
    // }
}

pub const RenderSystem = struct {
    const Instance = extern struct {
        mesh_idx: u32,
        material_idx: u32,
        _: u64 = 0,
        model_transform: core.lib.math.Mat4,
    };

    /// HOLDS pointers to data owned by ECS
    /// REMOVAL OF ENTITIES WILL BREAK THIS SO THAT NEEDS TO BE FIGURED OUT
    const InstanceEntry = struct {
        entity_id: u32,
        mesh_idx: *u32,
        material_idx: *u32,
        model_transform: *core.lib.math.Mat4,
    };

    ranges: std.AutoHashMap(u32, core.lib.mesh.RangeDesc),
    instances: []InstanceEntry,

    pub fn init(
        a: std.mem.Allocator,
        world: *core.engine.world.GameWorld,
        resources: *core.resources.Manager,
    ) std.mem.Allocator.Error!@This() {
        const self = try getInstances(a, world);
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
        _: vk.Device,
        _: ?*vk.AllocationCallbacks,
    ) void {
        self.ranges.deinit();
        allocs.std.free(self.instances);
    }

    pub fn updateSets(
        device: vk.Device,
        allocated_resources: *core.resources.Manager.AllocatedData,
    ) void {
        allocated_resources.mapped_buffers.updateBufferSet(
            device,
            core.engine.graphics_pipelines.Mesh3DPipeline.RenderSystem.INSTANCE_SET_NAME,
        );
    }

    pub const INSTANCES_BUFFER_NAME = "instances";
    pub const INSTANCE_SET_NAME = "instance_set";

    pub fn trySyncResources(self: *@This(), alloc_resources: core.resources.Manager.AllocatedData) void {
        const aligned: [*]Instance = @ptrCast(
            @alignCast(alloc_resources.mapped_buffers.buffers.get(INSTANCES_BUFFER_NAME).?.mapped),
        );
        for (self.instances, 0..) |entry, i|
            aligned[i] = Instance{
                .mesh_idx = entry.mesh_idx.*,
                .material_idx = entry.material_idx.*,
                .model_transform = entry.model_transform.*,
            };
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

    const INSTANCE_SIGNATURE = core.engine.world.GameWorld.Signature.initMany(&.{
        .transform,
        .mesh3D,
    });

    pub fn updateInstances(self: *@This(), world: core.engine.world.GameWorld) void {
        for (self.instances) |entry| {
            const ent = world.entityHandle(entry.entity_id) catch {
                std.debug.panic(
                    \\ entity {d} no longer exists
                , .{entry.entity_id});
            };
            std.debug.assert(ent.signature.supersetOf(INSTANCE_SIGNATURE));
        }
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
                (entity.accessComponentPtr(.mesh3D) catch @panic("NO MESH?")).mesh3D;
            const transform =
                (entity.accessComponentPtr(.transform) catch @panic("NO TRANSFORM?")).transform;

            const result = try buckets.getOrPut(mesh.mesh_index);

            if (!result.found_existing) {
                result.value_ptr.* = try std.ArrayList(InstanceEntry).initCapacity(a, 16);
            }

            log.debug(
                \\creating instance: entity={} mesh={} material={} position=({d:.3}, {d:.3}, {d:.3})
            ,
                .{
                    entity.identifier,
                    mesh.mesh_index,
                    mesh.material_index,
                    transform.matrix.t.x,
                    transform.matrix.t.y,
                    transform.matrix.t.z,
                },
            );
            try result.value_ptr.append(a, .{
                .entity_id = entity.identifier,
                .model_transform = &transform.matrix,
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
        };
    }

    pub fn drawImgui(self: *@This(), engine: *core.engine.Engine) void {
        var open = true;
        const shown = imgui.Begin("Mesh3D Rendering", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
        if (!shown) return;
        defer imgui.End();

        var iter = self.ranges.iterator();

        while (iter.next()) |entry| {
            const name = engine.resources.meshes3D.mesh_names_reverse_lookup.get(@intCast(entry.key_ptr.*)) orelse std.debug.panic(
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
                    const mtl_name = engine.resources.materials.material_names_reverse_lookup.get(inst.material_idx.*) orelse @panic("No material??");
                    imgui.Text("Material: %s, index: %d", mtl_name.ptr, inst.material_idx.*);

                    const m = inst.model_transform.*;

                    imgui.Text(
                        "i: %.3f, %.3f, %.3f, %.3f",
                        m.i.x,
                        m.i.y,
                        m.i.z,
                        m.i.w,
                    );

                    imgui.Text(
                        "j: %.3f, %.3f, %.3f, %.3f",
                        m.j.x,
                        m.j.y,
                        m.j.z,
                        m.j.w,
                    );

                    imgui.Text(
                        "k: %.3f, %.3f, %.3f, %.3f",
                        m.k.x,
                        m.k.y,
                        m.k.z,
                        m.k.w,
                    );

                    imgui.Text(
                        "t: %.3f, %.3f, %.3f, %.3f",
                        m.t.x,
                        m.t.y,
                        m.t.z,
                        m.t.w,
                    );
                }
            }
        }
    }
};
