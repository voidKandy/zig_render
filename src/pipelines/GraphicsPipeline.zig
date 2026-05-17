const std = @import("std");
const mem = std.mem;
const root = @import("../root.zig");
const pipelines = @import("root.zig");
const log = std.log.scoped(.GraphicsPipeline);
const mesh_mod = root.mesh;
const vki = root.vulkan_init;
const vk = root.clibs.vk;
const vma = root.clibs.vma;
const vma_usage = root.vma_usage;
const checkVk = vki.checkVk;

pub const MetaData = struct {
    material_index: u32,
    index_offset: u32,
    index_count: u32,
    vertex_offset: u32,
};

/// Allocated data associated with Pipeline
pub const AllocatedData = struct {
    const CreateInfo = struct {
        camera_gpu_data: root.Camera.GPUData,
        materials_file: root.mtl_loader.MtlFile,
        objects: []const root.obj_loader.ObjFile,
    };
    /// TODO
    /// move camera related logic into GraphicsPipeline
    camera_uniform: vma_usage.MappedBuffer,
    textures: []root.Materials.Texture,
    meshes_vertex_buffer: vma_usage.AllocatedBuffer,
    meshes_index_buffer: vma_usage.AllocatedBuffer,
    mesh_ranges: []MeshRanges,
    meta_data: vma_usage.MappedBuffer,

    const RangeDesc = struct {
        offset: vk.DeviceSize = 0,
        range: vk.DeviceSize = 0,
    };

    const MeshRanges = struct {
        vertex_range: RangeDesc,
        index_range: RangeDesc,
        // uniform_range: RangeDesc,
    };

    pub fn create(
        allocs: root.VulkanEngine.Allocators,
        upload_ctx: *root.vulkan_init.UploadContext,
        logical_device: root.vulkan_init.LogicalDevice,
        physical_device: root.vulkan_init.PhysicalDevice,
        ci: CreateInfo,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) std.mem.Allocator.Error!@This() {
        var materials = root.Materials.initFromMaterialFile(allocs.std, ci.materials_file) catch @panic("failed to create MTL");
        var mat_iter = materials.metadata.keyIterator();
        defer materials.deinit(allocs.std);
        var material_indices = std.StringHashMapUnmanaged(u32){};
        defer material_indices.deinit(allocs.std);
        const textures = try allocs.std.alloc(root.Materials.Texture, materials.metadata.size);

        var k: u32 = 0;
        while (mat_iter.next()) |key| : (k += 1) {
            const mat = materials.getMaterialData(key.*) orelse @panic("No material found?");
            const mat_texture = mat.upload(
                allocs.vma,
                upload_ctx,
                logical_device,
                physical_device,
                alloc_cbs,
            ) catch @panic("failed to upload material");
            log.warn(
                \\ Adding {s} as {d}
            , .{ mat.name, k });
            try material_indices.put(allocs.std, mat.name, k);
            textures[k] =
                mat_texture;
        }

        var all_ranges = try allocs.std.alloc(MeshRanges, ci.objects.len);

        var meshes = try allocs.std.alloc(root.mesh.Mesh3D, ci.objects.len);
        var all_metadata = try allocs.std.alloc(MetaData, meshes.len);
        var vertices = try std.ArrayList(root.mesh.Vertex3D).initCapacity(allocs.std, 64);
        var indices = try std.ArrayList(u32).initCapacity(allocs.std, 64);
        defer {
            allocs.std.free(meshes);
            allocs.std.free(all_metadata);
            vertices.deinit(allocs.std);
            indices.deinit(allocs.std);
        }

        var total_verts: usize = 0;
        var total_idcs: usize = 0;

        for (0..ci.objects.len) |i| {
            const obj_file = ci.objects[i];
            const mesh = try root.mesh.Mesh3D.fromObjFile(allocs.std, obj_file);
            defer mesh.deinit(allocs.std);
            const range = MeshRanges{
                .vertex_range = .{
                    .offset = total_verts,
                    .range = mesh.vertices.len,
                },
                .index_range = .{
                    .offset = total_idcs,
                    .range = mesh.indices.len,
                },
            };

            if (!std.mem.eql(u8, obj_file.material_library_name, materials.library_name)) {
                const msg =
                    try std.fmt.allocPrint(allocs.std,
                        \\ Obj file references a materials library that is not loaded: `{s}`
                    , .{obj_file.material_library_name});
                defer allocs.std.free(msg);
                @panic(msg);
            }

            const metadata = MetaData{
                .material_index = material_indices.get(obj_file.objects[0].material_name) orelse {
                    const msg = try std.fmt.allocPrint(allocs.std,
                        \\ Could not find material with name `{s}`
                    , .{obj_file.objects[0].material_name});
                    defer allocs.std.free(msg);
                    @panic(msg);
                },
                .index_count = @as(u32, @intCast(range.index_range.range)),
                .index_offset = @as(u32, @intCast(range.index_range.offset)),
                .vertex_offset = @as(u32, @intCast(range.vertex_range.offset)),
            };

            try vertices.appendSlice(allocs.std, mesh.vertices);
            try indices.appendSlice(allocs.std, mesh.indices);

            total_verts += mesh.vertices.len;
            total_idcs += mesh.indices.len;

            all_metadata[i] = metadata;
            all_ranges[i] = range;
            meshes[i] = mesh;
        }

        const vert_alloc_size, const idx_alloc_size = .{
            vertices.items.len * @sizeOf(root.mesh.Vertex3D),
            indices.items.len * @sizeOf(u32),
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

            const vert_aligned_data: [*]root.mesh.Vertex3D = @ptrCast(@alignCast(data));
            @memcpy(vert_aligned_data, vertices.items);

            data = undefined;
            checkVk(vma.MapMemory(allocs.vma, idx_staging_buffer.allocation, &data)) catch @panic("failed to map memory");
            defer vma.UnmapMemory(allocs.vma, idx_staging_buffer.allocation);

            const idx_aligned_data: [*]u32 = @ptrCast(@alignCast(data));
            @memcpy(idx_aligned_data, indices.items);
        }

        const meshes_vertex_buffer = vma_usage.AllocatedBuffer.create(
            allocs.vma,
            vert_alloc_size,
            vk.BUFFER_USAGE_INDEX_BUFFER_BIT | vk.BUFFER_USAGE_TRANSFER_DST_BIT | vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vma.MEMORY_USAGE_GPU_ONLY,
            0,
        );
        const meshes_index_buffer = vma_usage.AllocatedBuffer.create(
            allocs.vma,
            idx_alloc_size,
            vk.BUFFER_USAGE_INDEX_BUFFER_BIT | vk.BUFFER_USAGE_TRANSFER_DST_BIT | vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vma.MEMORY_USAGE_GPU_ONLY,
            0,
        );

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

        log.debug(
            \\Vertex buffer size: {}
            \\Index buffer size: {}
        , .{ meshes_vertex_buffer.size, meshes_index_buffer.size });

        upload_ctx.immediateSubmit(logical_device, SubmitCtx{
            .mesh_buffer = meshes_vertex_buffer.buffer,
            .staging_buffer = vert_staging_buffer.buffer,
            .size = vert_alloc_size,
        });

        upload_ctx.immediateSubmit(logical_device, SubmitCtx{
            .mesh_buffer = meshes_index_buffer.buffer,
            .staging_buffer = idx_staging_buffer.buffer,
            .size = idx_alloc_size,
        });

        const metadata_alloc = vma_usage.AllocatedBuffer.create(
            allocs.vma,
            @sizeOf(MetaData) * meshes.len,
            vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vma.MEMORY_USAGE_CPU_TO_GPU,
            0,
        );

        var mapped_metadata = vma_usage.MappedBuffer{
            .allocation = metadata_alloc,
        };

        checkVk(vma.MapMemory(
            allocs.vma,
            metadata_alloc.allocation,
            &mapped_metadata.mapped,
        )) catch @panic("Failed to map metadata");

        // const aligned_metadata: *GraphicsPipeline.MetaData = @ptrCast(@alignCast(mapped_metadata.mapped));
        const aligned_metadata: [*]MetaData =
            @ptrCast(@alignCast(mapped_metadata.mapped));

        @memcpy(aligned_metadata, all_metadata);

        const camera_alloc = vma_usage.AllocatedBuffer.create(
            allocs.vma,
            @sizeOf(root.Camera.GPUData),
            vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            vma.MEMORY_USAGE_CPU_TO_GPU,
            0,
        );
        var mapped_camera: vma_usage.MappedBuffer = .{
            .allocation = camera_alloc,
        };
        checkVk(vma.MapMemory(allocs.vma, camera_alloc.allocation, &mapped_camera.mapped)) catch @panic("Failed to map camera");

        const aligned_camera: *root.Camera.GPUData = @ptrCast(@alignCast(mapped_camera.mapped));

        aligned_camera.* = ci.camera_gpu_data;
        aligned_camera.*.proj.j.y *= -1;

        return AllocatedData{
            .mesh_ranges = all_ranges,
            .camera_uniform = mapped_camera,
            .textures = textures,
            .meshes_vertex_buffer = meshes_vertex_buffer,
            .meshes_index_buffer = meshes_index_buffer,
            .meta_data = mapped_metadata,
        };
    }

    pub fn deinit(self: @This(), device: vk.Device, allocs: root.VulkanEngine.Allocators, alloc_cbs: ?*vk.AllocationCallbacks) void {
        self.meshes_vertex_buffer.deinit(allocs.vma);
        self.meshes_index_buffer.deinit(allocs.vma);
        self.meta_data.deinit(allocs.vma);

        self.camera_uniform.deinit(allocs.vma);

        // perhaps this should be in a separate deinit function for TextureInfo?
        for (self.textures) |mat| {
            mat.image_alloc.deinit(allocs.vma, device, alloc_cbs);
            vk.DestroySampler(device, mat.sampler, alloc_cbs);
        }

        allocs.std.free(self.textures);
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

const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout_textures, alloc_cbs);
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
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = Bindings.VERTEX,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        },

        .{
            .binding = Bindings.INDEX,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        },

        // Current uniform stores camera data
        .{
            .binding = Bindings.UNIFORM,
            .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        },
    };

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = 0,
        .bindingCount = @as(u32, @intCast(bindings.len)),
        .pBindings = &bindings,
    };
    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.descriptor_set_layout)) catch
        @panic("failed to create descriptor set layout");
}

fn createDescriptorSetLayoutTextures(
    self: *Self,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = Bindings.TEXTURE2D,
            .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = MAX_TEXTURES,
            .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
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
    set: vk.DescriptorSet,
    textures_set: vk.DescriptorSet,
) mem.Allocator.Error!void {
    try updateTextureDescriptorSet(device, a, alloc_data, textures_set);

    const vertex_info = vk.DescriptorBufferInfo{
        .buffer = alloc_data.meshes_vertex_buffer.buffer,
        .offset = 0,
        .range = alloc_data.meshes_vertex_buffer.size,
    };
    const index_info = vk.DescriptorBufferInfo{
        .buffer = alloc_data.meshes_index_buffer.buffer,
        .offset = 0,
        .range = alloc_data.meshes_index_buffer.size,
    };
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
                .dstBinding = Bindings.VERTEX,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pBufferInfo = &vertex_info,
            },

            .{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = set,
                .dstBinding = Bindings.INDEX,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pBufferInfo = &index_info,
            },

            .{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = set,
                .dstBinding = Bindings.UNIFORM,
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

fn updateTextureDescriptorSet(
    device: vk.Device,
    a: mem.Allocator,
    alloc_data: AllocatedData,
    texture_set: vk.DescriptorSet,
) mem.Allocator.Error!void {
    const texture_count = alloc_data.textures.len;
    log.warn(
        \\ materials count: {}
    , .{texture_count});
    var image_infos = try a.alloc(vk.DescriptorImageInfo, texture_count);
    defer a.free(image_infos);

    for (0..texture_count) |i| {
        image_infos[i] = .{
            .sampler = alloc_data.textures[i].sampler,
            .imageView = alloc_data.textures[i].image_alloc.view,
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
