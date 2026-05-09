const std = @import("std");
const mem = std.mem;
const core = @import("../root.zig");
const pipelines = @import("root.zig");
const log = std.log.scoped(.DescriptorIndexing);
const mesh_mod = core.mesh;
const vki = core.vulkan_init;
const vk = core.clibs.vk;
const vma = core.clibs.vma;
const vma_usage = core.vma_usage;
const checkVk = vki.checkVk;

pub const MetaData = struct {
    material_index: u32,
    index_offset: u32,
    index_count: u32,
    vertex_offset: u32,
};

/// Allocated data associated with Pipeline
pub const AllocatedData = struct {
    // meshes: []mesh_mod.Mesh3D,
    /// these should be chagned to vma AllocatedBuffer
    // vertex_buffer: vma_usage.AllocatedBuffer,
    // index_buffer: vma_usage.AllocatedBuffer,

    meta_data: vma_usage.MappedBuffer,
    /// TODO
    /// move camera related logic into GraphicsPipeline
    camera_uniform: vma_usage.MappedBuffer,
    materials: []core.textures.Texture,
    // ranges: []SubmeshRanges,
    meshes: []mesh_mod.Mesh3D,
    meshes_vertex_buffer: vma_usage.AllocatedBuffer = undefined,
    meshes_index_buffer: vma_usage.AllocatedBuffer = undefined,
    mesh_ranges: []MeshRanges = undefined,

    const RangeDesc = struct {
        offset: vk.DeviceSize = 0,
        range: vk.DeviceSize = 0,
    };

    const MeshRanges = struct {
        vertex_range: RangeDesc,
        index_range: RangeDesc,
        // uniform_range: RangeDesc,
    };

    /// turns all meshes into one large vertex and index buffer with an array of ranges
    fn concatenateMeshes(
        self: @This(),
        a: std.mem.Allocator,
    ) std.mem.Allocator.Error!struct {
        vertices: []core.mesh.Vertex3D,
        indices: []u16,
        ranges: []MeshRanges,
    } {
        var all_ranges = try a.alloc(MeshRanges, self.meshes.len);
        var vertices = try std.ArrayList(core.mesh.Vertex3D).initCapacity(a, 64);
        var indices = try std.ArrayList(u16).initCapacity(a, 64);

        var total_verts: usize = 0;
        var total_idcs: usize = 0;
        for (self.meshes, 0..) |m, i| {
            all_ranges[i] = MeshRanges{
                .vertex_range = .{
                    .offset = total_verts,
                    .range = m.vertices.len * @sizeOf(core.mesh.Vertex3D),
                },
                .index_range = .{
                    .offset = total_verts,
                    .range = m.indices.len * @sizeOf(u16),
                },
            };
            try vertices.appendSlice(a, m.vertices);
            try indices.appendSlice(a, m.indices);
            total_verts += m.vertices.len;
            total_idcs += m.indices.len;
        }

        return .{
            .vertices = try vertices.toOwnedSlice(a),
            .indices = try indices.toOwnedSlice(a),
            .ranges = all_ranges,
        };
    }

    pub fn createBuffers(
        self: *@This(),
        allocs: core.VulkanEngine.Allocators,
        upload_ctx: *core.vulkan_init.UploadContext,
        device: core.vulkan_init.LogicalDevice,
    ) void {
        const meshes_concat = self.concatenateMeshes(allocs.std) catch @panic("OOM");
        self.mesh_ranges = meshes_concat.ranges;

        defer {
            allocs.std.free(meshes_concat.vertices);
            allocs.std.free(meshes_concat.indices);
        }

        const vert_alloc_size, const idx_alloc_size = .{
            meshes_concat.vertices.len * @sizeOf(core.mesh.Vertex3D),
            meshes_concat.indices.len * @sizeOf(u16),
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
            checkVk(vma.CreateBuffer(allocs.vma, &vert_ci, &ai, &vert_buf.buffer, &vert_buf.allocation, null)) catch @panic("Failed to create vertex buffer");
            var idx_buf: vma_usage.AllocatedBuffer = undefined;
            checkVk(vma.CreateBuffer(allocs.vma, &idx_ci, &ai, &idx_buf.buffer, &idx_buf.allocation, null)) catch @panic("Failed to create index buffer");
            break :stage_cpu .{ vert_buf, idx_buf };
        };

        defer {
            vert_staging_buffer.deinit(allocs.vma);
            idx_staging_buffer.deinit(allocs.vma);
        }

        // mapping memory
        {
            var data: ?*anyopaque = undefined;
            checkVk(vma.MapMemory(allocs.vma, vert_staging_buffer.allocation, &data)) catch @panic("failed to map memory");
            defer vma.UnmapMemory(allocs.vma, vert_staging_buffer.allocation);

            const vert_aligned_data: [*]core.mesh.Vertex3D = @ptrCast(@alignCast(data));
            @memcpy(vert_aligned_data, meshes_concat.vertices);

            data = undefined;
            checkVk(vma.MapMemory(allocs.vma, idx_staging_buffer.allocation, &data)) catch @panic("failed to map memory");
            defer vma.UnmapMemory(allocs.vma, idx_staging_buffer.allocation);

            const idx_aligned_data: [*]u16 = @ptrCast(@alignCast(data));
            @memcpy(idx_aligned_data, meshes_concat.indices);
        }

        // gpu allocation
        // var buffers = Buffers{};
        {
            const vert_ci = vk.BufferCreateInfo{
                .sType = vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .size = vert_alloc_size,
                .usage = vk.BUFFER_USAGE_INDEX_BUFFER_BIT | vk.BUFFER_USAGE_TRANSFER_DST_BIT | vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            };
            const idx_ci = vk.BufferCreateInfo{
                .sType = vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .size = idx_alloc_size,
                .usage = vk.BUFFER_USAGE_INDEX_BUFFER_BIT | vk.BUFFER_USAGE_TRANSFER_DST_BIT | vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            };

            const ai = vma.AllocationCreateInfo{
                .usage = vma.MEMORY_USAGE_GPU_ONLY,
            };

            checkVk(vma.CreateBuffer(allocs.vma, &vert_ci, &ai, &self.meshes_vertex_buffer.buffer, &self.meshes_vertex_buffer.allocation, null)) catch @panic("Failed to create vertex buffer");
            checkVk(vma.CreateBuffer(allocs.vma, &idx_ci, &ai, &self.meshes_index_buffer.buffer, &self.meshes_index_buffer.allocation, null)) catch @panic("Failed to create index buffer");
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
            .mesh_buffer = self.meshes_vertex_buffer.buffer,
            .staging_buffer = vert_staging_buffer.buffer,
            .size = vert_alloc_size,
        });

        upload_ctx.immediateSubmit(device, SubmitCtx{
            .mesh_buffer = self.meshes_index_buffer.buffer,
            .staging_buffer = idx_staging_buffer.buffer,
            .size = idx_alloc_size,
        });
    }

    pub fn deinit(self: @This(), device: vk.Device, allocs: core.VulkanEngine.Allocators, alloc_cbs: ?*vk.AllocationCallbacks) void {
        for (self.meshes) |m| m.deinit(allocs.std);

        self.meshes_vertex_buffer.deinit(allocs.vma);
        self.meshes_index_buffer.deinit(allocs.vma);
        self.meta_data.deinit(allocs.vma);

        self.camera_uniform.deinit(allocs.vma);

        // perhaps this should be in a separate deinit function for TextureInfo?
        for (self.materials) |mat| {
            mat.image_alloc.deinit(allocs.vma, device, alloc_cbs);
            vk.DestroySampler(device, mat.sampler, alloc_cbs);
        }

        allocs.std.free(self.meshes);
        allocs.std.free(self.materials);
        allocs.std.free(self.mesh_ranges);
    }
};

pub const Description = struct {
    device: vk.Device = undefined,
    render_pass: vk.RenderPass = undefined,
    window_extent: vk.Extent2D,
    vertex_shader: vk.ShaderModule = undefined,
    fragment_shader: vk.ShaderModule = undefined,
    num_images: u32 = 0,
    // color_format: vk.Format = vk.FORMAT_UNDEFINED,
    // depth_format: vk.Format = vk.FORMAT_UNDEFINED,
    depth_compare_op: vk.CompareOp = vk.COMPARE_OP_LESS,
    is_vertex_buffer: bool = false,
    is_index_buffer: bool = false,
    is_uniform_buffer: bool = false,
    is_tex2d_buffer: bool = false,
};

const Bindings = struct {
    const VERTEX = 0;
    const INDEX = 1;
    const UNIFORM = 2;
    const TEXTURE2D = 0;
    const METADATA = 1;
};

pub const MAX_TEXTURES = 16;

pipeline: vk.Pipeline = undefined,
pipeline_layout: vk.PipelineLayout = undefined,
descriptor_pool: vk.DescriptorPool = undefined,
descriptor_set_layout: vk.DescriptorSetLayout = undefined,
descriptor_set_layout_textures: vk.DescriptorSetLayout = undefined,

num_images: u32,
/// THIS IS NOT A PIPELINE OBJECT
/// I THINK PROBABLY PIPELINE OBJECTS SHOULD BE REMOVED AS AN ABSTRACTION
/// THIS SHOULD BE THE NEW MAIN PIPELINE
/// SHOULD BE RENAMED GRAPHICS OR GRAPHICS_PIPELINE
const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout_textures, alloc_cbs);
    vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);
    vk.DestroyDescriptorPool(device, self.descriptor_pool, alloc_cbs);
}

pub fn init(pd: Description, alloc_cbs: ?*vk.AllocationCallbacks) @This() {
    var self = @This(){
        .num_images = pd.num_images,
    };

    self.createDescriptorSetLayout(
        pd.device,
        pd.is_vertex_buffer,
        pd.is_index_buffer,
        pd.is_uniform_buffer,
        alloc_cbs,
    );

    if (pd.is_tex2d_buffer)
        self.createDescriptorSetLayoutTextures(
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

    const rasterization_ci = vk.PipelineRasterizationStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = vk.POLYGON_MODE_FILL,
        .cullMode = vk.CULL_MODE_BACK_BIT,
        .frontFace = vk.FRONT_FACE_CLOCKWISE,
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
        .depthCompareOp = pd.depth_compare_op,
        .depthBoundsTestEnable = vk.FALSE,
        .stencilTestEnable = vk.FALSE,
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
        .front = .{},
        .back = .{},
    };

    const blend_attach_state = vk.PipelineColorBlendAttachmentState{
        .blendEnable = vk.TRUE,
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

    // in the tutorial but we aint doin dynamic rendering
    // const rendering_ci = vk.PipelineRenderingCreateInfo{
    //     .sType = vk.STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
    //     .viewMask = 0,
    //     .colorAttachmentCount = 1,
    //     .pColorAttachments = &color_format,
    //     .depthAttachmentFormat = &depth_format,
    //     .stencilAttachmentFormat = vk.FORMAT_UNDEFINED,
    // };

    const set_layouts = [_]vk.DescriptorSetLayout{
        self.descriptor_set_layout,
        self.descriptor_set_layout_textures,
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
    texture_count: u32,
    uniform_buffer_count: u32,
    storage_buffer_count: u32,
    max_sets: u32,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    var sizes: [3]vk.DescriptorPoolSize = undefined;
    var amt_sizes: usize = 0;

    if (texture_count > 0) {
        const size = vk.DescriptorPoolSize{
            .type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = texture_count,
        };
        sizes[amt_sizes] = size;
        amt_sizes += 1;
    }
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
    is_vertex_buffer: bool,
    is_index_buffer: bool,
    is_uniform_buffer: bool,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    var bindings: [3]vk.DescriptorSetLayoutBinding = undefined;
    var amt_bindings: usize = 0;
    // var bindings = try std.ArrayList(vk.DescriptorSetLayoutBinding).initCapacity(a, 3);

    if (is_vertex_buffer) {
        const binding = vk.DescriptorSetLayoutBinding{
            .binding = Bindings.VERTEX,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        };

        bindings[amt_bindings] = binding;
        amt_bindings += 1;
    }
    if (is_index_buffer) {
        const binding = vk.DescriptorSetLayoutBinding{
            .binding = Bindings.INDEX,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        };
        bindings[amt_bindings] = binding;
        amt_bindings += 1;
    }
    if (is_uniform_buffer) {
        const binding = vk.DescriptorSetLayoutBinding{
            .binding = Bindings.UNIFORM,
            .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        };
        bindings[amt_bindings] = binding;
        amt_bindings += 1;
    }

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = 0,
        .bindingCount = @as(u32, @intCast(amt_bindings)),
        .pBindings = bindings[0..amt_bindings].ptr,
    };

    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.descriptor_set_layout)) catch
        @panic("failed to create descriptor set layout");
}

pub fn createDescriptorSetLayoutTextures(
    self: *Self,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        // Textures
        .{
            .binding = Bindings.TEXTURE2D,
            .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = MAX_TEXTURES,
            .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Metadata
        .{
            .binding = Bindings.METADATA,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        },
    };

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .pBindings = &bindings,
        .bindingCount = bindings.len,
    };

    checkVk(vk.CreateDescriptorSetLayout(
        device,
        &ci,
        alloc_cbs,
        &self.descriptor_set_layout_textures,
    )) catch @panic("Failed to create descriptor set layout");
}

pub fn allocateDescriptorSets(
    self: Self,
    device: vk.Device,
    a: mem.Allocator,
    num_submeshes: usize,
) mem.Allocator.Error![]vk.DescriptorSet {
    const sets = try a.alloc(vk.DescriptorSet, num_submeshes);

    var layouts = try a.alloc(vk.DescriptorSetLayout, num_submeshes);
    defer a.free(layouts);
    for (0..num_submeshes) |i| layouts[i] = self.descriptor_set_layout;

    const ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = @as(u32, @intCast(layouts.len)),
        .pSetLayouts = layouts.ptr,
    };

    checkVk(vk.AllocateDescriptorSets(device, &ai, sets.ptr)) catch
        @panic("failed to allocate descriptor sets");

    return sets;
}

pub fn allocateTextureDescriptorSet(self: Self, device: vk.Device, set: *vk.DescriptorSet) void {
    const alloc_info = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.descriptor_set_layout_textures,
    };
    checkVk(vk.AllocateDescriptorSets(device, &alloc_info, set)) catch |e| {
        log.err(
            \\failed to allocate texture descriptor set: {s}
        , .{@errorName(e)});
        @panic("failed to allocate texture descriptor set");
    };
}

pub fn updateDescriptorSets(
    device: vk.Device,
    a: mem.Allocator,
    alloc_data: AllocatedData,
    sets: []vk.DescriptorSet,
    textures_set: vk.DescriptorSet,
) mem.Allocator.Error!void {
    try updateTextureDescriptorSet(device, a, alloc_data, textures_set);

    const num_submeshes = sets.len;
    const num_bindings = 3; // VB, IB, Uniform

    const write_sets_size = num_submeshes * num_bindings;
    var write_sets = try a.alloc(vk.WriteDescriptorSet, write_sets_size);
    defer a.free(write_sets);

    var buf_info_vertex = try std.ArrayList(vk.DescriptorBufferInfo).initCapacity(a, num_submeshes);
    defer buf_info_vertex.deinit(a);

    var buf_info_index = try std.ArrayList(vk.DescriptorBufferInfo).initCapacity(a, num_submeshes);
    defer buf_info_index.deinit(a);

    // var buf_info_uniform = try std.ArrayList(vk.DescriptorBufferInfo).initCapacity(a, num_submeshes);
    // defer buf_info_uniform.deinit(a);

    for (0..num_submeshes) |i| {
        buf_info_vertex.appendAssumeCapacity(.{
            .buffer = alloc_data.meshes_vertex_buffer.buffer,
            .offset = alloc_data.mesh_ranges[i].vertex_range.offset,
            .range = alloc_data.mesh_ranges[i].vertex_range.range,
        });
        buf_info_index.appendAssumeCapacity(.{
            .buffer = alloc_data.meshes_index_buffer.buffer,
            .offset = alloc_data.mesh_ranges[i].index_range.offset,
            .range = alloc_data.mesh_ranges[i].index_range.range,
        });
        // buf_info_uniform.appendAssumeCapacity(.{
        //     // idx here might be incorrect
        //     .buffer = alloc_data.uniforms[i].allocation.buffer,
        //     .offset = alloc_data.ranges[i].uniform_range.offset,
        //     .range = alloc_data.ranges[i].uniform_range.range,
        // });
    }

    const camera_uniform_info = vk.DescriptorBufferInfo{
        .buffer = alloc_data.camera_uniform.allocation.buffer,
        .offset = 0,
        .range = @as(u64, @intCast(alloc_data.camera_uniform.allocation.size)),
    };

    for (0..num_submeshes) |i| {
        const dst_set = sets[i];

        write_sets[i] = .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = dst_set,
            .dstBinding = Bindings.VERTEX,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &buf_info_vertex.items[i],
        };

        write_sets[i + 1] = .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = dst_set,
            .dstBinding = Bindings.INDEX,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &buf_info_index.items[i],
        };

        write_sets[i + 2] = .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = dst_set,
            .dstBinding = Bindings.UNIFORM,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pBufferInfo = &camera_uniform_info,
        };
    }

    vk.UpdateDescriptorSets(
        device,
        @as(u32, @intCast(write_sets.len)),
        write_sets.ptr,
        0,
        null,
    );
}

fn updateTextureDescriptorSet(
    device: vk.Device,
    a: mem.Allocator,
    alloc_data: AllocatedData,
    texture_set: vk.DescriptorSet,
) mem.Allocator.Error!void {
    const texture_count = alloc_data.materials.len;
    log.warn(
        \\ materials count: {}
    , .{texture_count});
    var image_infos = try a.alloc(vk.DescriptorImageInfo, texture_count);
    defer a.free(image_infos);

    for (0..texture_count) |i| {
        image_infos[i] = .{
            .sampler = alloc_data.materials[i].sampler,
            .imageView = alloc_data.materials[i].image_alloc.view,
            .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
    }

    const buffer_info = vk.DescriptorBufferInfo{
        .buffer = alloc_data.meta_data.allocation.buffer,
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    };

    const write_sets = [_]vk.WriteDescriptorSet{
        .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = texture_set,
            .dstBinding = Bindings.TEXTURE2D,
            .dstArrayElement = 0,
            .descriptorCount = @as(u32, @intCast(texture_count)),
            .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = image_infos.ptr,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = texture_set,
            .dstBinding = Bindings.METADATA,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_info,
            .pTexelBufferView = null,
        },
    };

    vk.UpdateDescriptorSets(
        device,
        write_sets.len,
        &write_sets,
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

pub fn drawImgui(self: *Self) void {
    _ = self;
}

// pub fn oldDraw(
//     self: Self,
//     sets: std.ArrayList(std.ArrayList(vk.DescriptorSet)),
//     window_extent: vk.Extent2D,
//     cmd: vk.CommandBuffer,
// ) void {
//     const viewport = vk.Viewport{
//         .x = 0,
//         .y = 0,
//         .width = @as(f32, (@floatFromInt(window_extent.width))),
//         .height = @as(f32, (@floatFromInt(window_extent.height))),
//         .minDepth = 0.0,
//         .maxDepth = 1.0,
//     };
//     vk.CmdSetViewport(cmd, 0, 1, &viewport);

//     const scissor = vk.Rect2D{
//         .offset = .{
//             .x = 0,
//             .y = 0,
//         },
//         .extent = window_extent,
//     };

//     vk.CmdSetScissor(cmd, 0, 1, &scissor);

//     for (sets.items) |set_array| {
//         vk.CmdBindDescriptorSets(
//             cmd,
//             vk.PIPELINE_BIND_POINT_GRAPHICS,
//             self.pipeline_layout,
//             0,
//             1,
//             set_array.items.ptr,
//             0,
//             null,
//         );
//     }
//     for (model_desc.ranges, 0..) |range, submesh_index| {
//         // bind set 0: VB, IB, UBO for this submesh
//         vk.CmdBindDescriptorSets(
//             cmd,
//             vk.PIPELINE_BIND_POINT_GRAPHICS,
//             self.pipeline_layout,
//             0, // set index 0
//             1,
//             &sets.items[submesh_index].items[0],
//             0,
//             null,
//         );

//         // no vertex/index buffer binding -- shader reads from storage buffers
//         // firstInstance = submesh_index so gl_BaseInstance == DrawId in shader
//         vk.CmdDrawIndexed(
//             cmd,
//             @intCast(range.index_range.range / @sizeOf(u16)),
//             1, // instance count
//             @intCast(range.index_range.offset / @sizeOf(u16)), // firstIndex
//             @intCast(range.vertex_range.offset / @sizeOf(mesh_mod.Vertex3D)), // vertexOffset... but unused since shader indexes manually
//             @intCast(submesh_index), // firstInstance = DrawId
//         );
//     }
// }
