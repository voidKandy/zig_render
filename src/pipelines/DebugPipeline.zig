const std = @import("std");
const mem = std.mem;
const core = @import("../root.zig");
const imgui = core.clibs.imgui;
const log = std.log.scoped(.DebugPipeline);
const mesh_mod = core.mesh;
const vki = core.vulkan_init;
const vk = core.clibs.vk;
const vma = core.clibs.vma;
const vma_usage = core.vma_usage;
const checkVk = vki.checkVk;

pub const Description = struct {
    device: vk.Device = undefined,
    render_pass: vk.RenderPass = undefined,
    window_extent: vk.Extent2D,
    vertex_shader: vk.ShaderModule = undefined,
    fragment_shader: vk.ShaderModule = undefined,
    depth_compare_op: vk.CompareOp = vk.COMPARE_OP_LESS,
};

pub const AllocatedData = struct {
    gizmo_verts: vma_usage.AllocatedBuffer = undefined,
    gizmo_indices: vma_usage.AllocatedBuffer = undefined,

    pub fn deinit(self: @This(), vma_a: vma.Allocator) void {
        self.gizmo_indices.deinit(vma_a);
        self.gizmo_verts.deinit(vma_a);
    }
};

pub fn createAllocatedData(vma_a: vma.Allocator, upload_ctx: *core.vulkan_init.UploadContext, device: core.vulkan_init.LogicalDevice) AllocatedData {
    const vertices = [_]core.mesh.Vertex3D{
        // X axis (red)
        .{
            .position = core.math.Vec4.make(0, 0, 0, 1),
            .normal = core.math.Vec4.ZERO,
            .color = core.math.Vec4.make(1, 0, 0, 1),
            .uv = core.math.Vec2.ZERO,
        },
        .{
            .position = core.math.Vec4.make(1, 0, 0, 1),
            .normal = core.math.Vec4.ZERO,
            .color = core.math.Vec4.make(1, 0, 0, 1),
            .uv = core.math.Vec2.ZERO,
        },

        // Y axis (green)
        .{
            .position = core.math.Vec4.make(0, 0, 0, 1),
            .normal = core.math.Vec4.ZERO,
            .color = core.math.Vec4.make(0, 1, 0, 1),
            .uv = core.math.Vec2.ZERO,
        },
        .{
            .position = core.math.Vec4.make(0, 1, 0, 1),
            .normal = core.math.Vec4.ZERO,
            .color = core.math.Vec4.make(0, 1, 0, 1),
            .uv = core.math.Vec2.ZERO,
        },

        // Z axis (blue)
        .{
            .position = core.math.Vec4.make(0, 0, 0, 1),
            .normal = core.math.Vec4.ZERO,
            .color = core.math.Vec4.make(0, 0, 1, 1),
            .uv = core.math.Vec2.ZERO,
        },
        .{
            .position = core.math.Vec4.make(0, 0, 1, 1),
            .normal = core.math.Vec4.ZERO,
            .color = core.math.Vec4.make(0, 0, 1, 1),
            .uv = core.math.Vec2.ZERO,
        },
    };

    const indices = [_]u16{
        0, 1, // X
        2, 3, // Y
        4, 5, // Z
    };

    const vert_alloc_size, const idx_alloc_size = .{
        vertices.len * @sizeOf(core.mesh.Vertex3D),
        indices.len * @sizeOf(u32),
    };

    const vert_staging_buffer, const idx_staging_buffer = stage_cpu: {
        const vert_ci = vk.BufferCreateInfo{
            .sType = vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = vert_alloc_size,
            .usage = vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        };
        const idx_ci = vk.BufferCreateInfo{
            .sType = vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = idx_alloc_size,
            .usage = vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        };

        const ai = vma.AllocationCreateInfo{
            .usage = vma.MEMORY_USAGE_CPU_ONLY,
        };

        var vert_buf: vma_usage.AllocatedBuffer = undefined;
        checkVk(vma.CreateBuffer(vma_a, &vert_ci, &ai, &vert_buf.buffer, &vert_buf.allocation, null)) catch @panic("Failed to create vertex buffer");
        var idx_buf: vma_usage.AllocatedBuffer = undefined;
        checkVk(vma.CreateBuffer(vma_a, &idx_ci, &ai, &idx_buf.buffer, &idx_buf.allocation, null)) catch @panic("Failed to create index buffer");
        break :stage_cpu .{ vert_buf, idx_buf };
    };

    defer {
        vert_staging_buffer.deinit(vma_a);
        idx_staging_buffer.deinit(vma_a);
    }

    // mapping memory
    {
        var data: ?*anyopaque = undefined;
        checkVk(vma.MapMemory(vma_a, vert_staging_buffer.allocation, &data)) catch @panic("failed to map memory");
        defer vma.UnmapMemory(vma_a, vert_staging_buffer.allocation);

        const vert_aligned_data: [*]core.mesh.Vertex3D = @ptrCast(@alignCast(data));
        @memcpy(vert_aligned_data, vertices[0..vertices.len]);

        data = undefined;
        checkVk(vma.MapMemory(vma_a, idx_staging_buffer.allocation, &data)) catch @panic("failed to map memory");
        defer vma.UnmapMemory(vma_a, idx_staging_buffer.allocation);

        const idx_aligned_data: [*]u16 = @ptrCast(@alignCast(data));
        @memcpy(idx_aligned_data, indices[0..indices.len]);
    }

    // gpu allocation
    var alloc_data = AllocatedData{};
    {
        const vert_ci = vk.BufferCreateInfo{
            .sType = vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = vert_alloc_size,
            .usage = vk.BUFFER_USAGE_VERTEX_BUFFER_BIT | vk.BUFFER_USAGE_TRANSFER_DST_BIT | vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
        };
        const idx_ci = vk.BufferCreateInfo{
            .sType = vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = idx_alloc_size,
            .usage = vk.BUFFER_USAGE_INDEX_BUFFER_BIT | vk.BUFFER_USAGE_TRANSFER_DST_BIT | vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
        };

        const ai = vma.AllocationCreateInfo{
            .usage = vma.MEMORY_USAGE_GPU_ONLY,
        };

        checkVk(vma.CreateBuffer(vma_a, &vert_ci, &ai, &alloc_data.gizmo_verts.buffer, &alloc_data.gizmo_verts.allocation, null)) catch @panic("Failed to create vertex buffer");
        checkVk(vma.CreateBuffer(vma_a, &idx_ci, &ai, &alloc_data.gizmo_indices.buffer, &alloc_data.gizmo_indices.allocation, null)) catch @panic("Failed to create index buffer");
    }

    const SubmitCtx =
        struct {
            mesh_buffer: vk.Buffer,
            staging_buffer: vk.Buffer,
            size: usize,

            pub fn submit(ctx: @This(), cmd: vk.CommandBuffer) void {
                const copy_region = vk.BufferCopy{
                    .size = ctx.size,
                };
                vk.CmdCopyBuffer(cmd, ctx.staging_buffer, ctx.mesh_buffer, 1, &copy_region);
            }
        };

    upload_ctx.immediateSubmit(device, SubmitCtx{
        .mesh_buffer = alloc_data.gizmo_verts.buffer,
        .staging_buffer = vert_staging_buffer.buffer,
        .size = vert_alloc_size,
    });

    upload_ctx.immediateSubmit(device, SubmitCtx{
        .mesh_buffer = alloc_data.gizmo_indices.buffer,
        .staging_buffer = idx_staging_buffer.buffer,
        .size = idx_alloc_size,
    });

    return alloc_data;
}

pub const VertexInputDescription = struct {
    bindings: []const vk.VertexInputBindingDescription,
    attributes: []const vk.VertexInputAttributeDescription,

    flags: vk.PipelineVertexInputStateCreateFlags = 0,

    pub const VERTEX3D = @This(){
        .bindings = &.{
            vk.VertexInputBindingDescription{
                .binding = 0,
                .stride = @sizeOf(core.mesh.Vertex3D),
                .inputRate = vk.VERTEX_INPUT_RATE_VERTEX,
            },
        },
        .attributes = &.{
            vk.VertexInputAttributeDescription{
                .location = 0,
                .binding = 0,
                .format = vk.FORMAT_R32G32B32A32_SFLOAT,
                .offset = @offsetOf(core.mesh.Vertex3D, "position"),
            },
            vk.VertexInputAttributeDescription{
                .location = 1,
                .binding = 0,
                .format = vk.FORMAT_R32G32B32A32_SFLOAT,
                .offset = @offsetOf(core.mesh.Vertex3D, "normal"),
            },
            vk.VertexInputAttributeDescription{
                .location = 2,
                .binding = 0,
                .format = vk.FORMAT_R32G32B32A32_SFLOAT,
                .offset = @offsetOf(core.mesh.Vertex3D, "color"),
            },
            vk.VertexInputAttributeDescription{
                .location = 3,
                .binding = 0,
                .format = vk.FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(core.mesh.Vertex3D, "uv"),
            },
        },
    };
};

const Bindings = struct {
    const CAMERA = 0;
};

pipeline: vk.Pipeline = undefined,
pipeline_layout: vk.PipelineLayout = undefined,
descriptor_pool: vk.DescriptorPool = undefined,
descriptor_set_layout: vk.DescriptorSetLayout = undefined,

const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
    vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);
    vk.DestroyDescriptorPool(device, self.descriptor_pool, alloc_cbs);
}

pub fn init(pd: Description, alloc_cbs: ?*vk.AllocationCallbacks) @This() {
    var self = Self{};

    self.createDescriptorSetLayout(
        pd.device,
        alloc_cbs,
    );
    self.initCommon(pd, alloc_cbs);

    return self;
}

fn initCommon(
    self: *Self,
    pd: Description,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
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
        .vertexBindingDescriptionCount = VertexInputDescription.VERTEX3D.bindings.len,
        .pVertexBindingDescriptions = VertexInputDescription.VERTEX3D.bindings.ptr,
        .vertexAttributeDescriptionCount = VertexInputDescription.VERTEX3D.attributes.len,
        .pVertexAttributeDescriptions = VertexInputDescription.VERTEX3D.attributes.ptr,
        .flags = VertexInputDescription.VERTEX3D.flags,
    };

    const input_assembly_ci = vk.PipelineInputAssemblyStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = vk.PRIMITIVE_TOPOLOGY_LINE_LIST,
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

    const rasterization_ci = vk.PipelineRasterizationStateCreateInfo{
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
        self.descriptor_set_layout,
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

    const pipeline_ci = vk.GraphicsPipelineCreateInfo{
        .sType = vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .pDynamicState = &dynamic_state_ci,
        .stageCount = shader_stage_ci.len,
        .pStages = &shader_stage_ci[0],
        .pVertexInputState = &vertex_input_ci,
        .pInputAssemblyState = &input_assembly_ci,
        .pViewportState = &viewport_ci,
        .pRasterizationState = &rasterization_ci,
        .pMultisampleState = &multisample_ci,
        .pDepthStencilState = &depth_stencil_ci,
        .pColorBlendState = &blend_ci,
        .layout = self.pipeline_layout,
        .renderPass = pd.render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    checkVk(vk.CreateGraphicsPipelines(
        pd.device,
        null,
        1,
        &pipeline_ci,
        null,
        &self.pipeline,
    )) catch @panic("failed to create graphics pipeline");
}

pub fn createDescriptorPool(
    self: *Self,
    device: vk.Device,
    uniform_buffer_count: u32,
    storage_buffer_count: u32,
    max_sets: u32,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    var sizes: [3]vk.DescriptorPoolSize = undefined;
    var amt_sizes: usize = 0;

    if (uniform_buffer_count > 0) {
        const size = vk.DescriptorPoolSize{
            .type = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = uniform_buffer_count,
        };
        sizes[amt_sizes] = size;
        amt_sizes += 1;
    }

    if (storage_buffer_count > 0) {
        const size = vk.DescriptorPoolSize{
            .type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = storage_buffer_count,
        };
        sizes[amt_sizes] = size;
        amt_sizes += 1;
    }

    const ci = vk.DescriptorPoolCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = 0,
        .maxSets = max_sets,
        .poolSizeCount = @as(u32, @intCast(amt_sizes)),
        .pPoolSizes = sizes[0..amt_sizes].ptr,
    };

    checkVk(vk.CreateDescriptorPool(device, &ci, alloc_cbs, &self.descriptor_pool)) catch
        @panic("failed to create descriptor pool");
}

fn createDescriptorSetLayout(
    self: *Self,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = Bindings.CAMERA,
            .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        },
    };

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };

    checkVk(vk.CreateDescriptorSetLayout(
        device,
        &ci,
        alloc_cbs,
        &self.descriptor_set_layout,
    )) catch @panic("failed to create descriptor set layout");
}

pub fn allocateDescriptorSet(
    self: Self,
    device: vk.Device,
) mem.Allocator.Error!vk.DescriptorSet {
    var set: vk.DescriptorSet = undefined;

    const ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.descriptor_set_layout,
    };

    checkVk(vk.AllocateDescriptorSets(device, &ai, &set)) catch
        @panic("failed to allocate descriptor sets");

    return set;
}

pub fn updateDescriptorSets(
    device: vk.Device,
    alloc_data: core.GraphicsPipeline.AllocatedData,
    set: vk.DescriptorSet,
) mem.Allocator.Error!void {
    const camera_uniform_info = vk.DescriptorBufferInfo{
        .buffer = alloc_data.camera_uniform.allocation.buffer,
        .offset = 0,
        .range = @as(u64, @intCast(alloc_data.camera_uniform.allocation.size)),
    };

    const write_sets =
        &[_]vk.WriteDescriptorSet{
            .{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = set,
                .dstBinding = Bindings.CAMERA,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .pBufferInfo = &camera_uniform_info,
            },
        };
    vk.UpdateDescriptorSets(
        device,
        @as(u32, @intCast(write_sets.len)),
        write_sets.ptr,
        0,
        null,
    );
}

pub fn bind(self: Self, cmd_buf: vk.CommandBuffer) void {
    vk.CmdBindPipeline(
        cmd_buf,
        vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.pipeline,
    );
}

pub fn recordCommands(self: Self, alloc_data: AllocatedData, cmd_buf: vk.CommandBuffer, set: vk.DescriptorSet) void {
    // camera descriptor set
    vk.CmdBindDescriptorSets(
        cmd_buf,
        vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.pipeline_layout,
        0,
        1,
        &set,
        0,
        null,
    );

    // vertex buffer
    const vertex_buffers = [_]vk.Buffer{
        alloc_data.gizmo_verts.buffer,
    };

    const offsets = [_]vk.DeviceSize{0};

    vk.CmdBindVertexBuffers(
        cmd_buf,
        0,
        1,
        &vertex_buffers,
        &offsets,
    );

    // index buffer
    vk.CmdBindIndexBuffer(
        cmd_buf,
        alloc_data.gizmo_indices.buffer,
        0,
        vk.INDEX_TYPE_UINT16,
    );

    // draw indexed
    vk.CmdDrawIndexed(
        cmd_buf,
        6, // replace with actual index count
        1, // instance count
        0, // first index
        0, // vertex offset
        0, // first instance
    );
}
