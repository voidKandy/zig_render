const std = @import("std");
const mem = std.mem;
const core = @import("../root.zig");
const imgui = core.clibs.imgui;
const log = std.log.scoped(.HudPipeline);
const vki = core.vulkan_init;
const vk = core.clibs.vk;
const vma_usage = core.vma_usage;
const checkVk = vki.checkVk;

pub const AllocatedData = struct {
    pub const CreateData = struct {
        pub const MeshCreateInfo = struct {
            mesh: core.mesh.Mesh2D,
            material_index: u32,
        };
        materials_file: core.mtl_loader.MtlFile,
        mesh_objs: []const MeshCreateInfo,
    };

    materials: core.Materials.AllocatedData,
    meshes: core.mesh.Meshes2D.AllocatedData,

    pub fn create(
        allocs: core.VulkanEngine.Allocators,
        upload_ctx: *core.vulkan_init.UploadContext,
        logical_device: core.vulkan_init.LogicalDevice,
        physical_device: core.vulkan_init.PhysicalDevice,
        cd: CreateData,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) std.mem.Allocator.Error!struct { @This(), SystemsData } {
        var materials = core.Materials.initFromMaterialFile(allocs.std, cd.materials_file) catch @panic("failed to create MTL");
        defer materials.deinit(allocs.std);

        const uploaded = materials.upload(
            allocs,
            upload_ctx,
            logical_device,
            physical_device,
            alloc_cbs,
        );

        var meshes = try core.mesh.Meshes2D.init(allocs.std);
        defer meshes.deinit(allocs.std);

        for (cd.mesh_objs) |obj| {
            try meshes.appendMesh(allocs.std, obj.mesh, obj.material_index);
        }

        const uploaded_meshes = meshes.upload(allocs, upload_ctx, logical_device);

        return .{
            .{
                .materials = uploaded,
                .meshes = uploaded_meshes,
            },
            .{
                .mesh_ranges = try meshes.ranges.toOwnedSlice(allocs.std),
            },
        };
    }

    pub fn deinit(
        self: *@This(),
        allocs: core.VulkanEngine.Allocators,
        device: vk.Device,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) void {
        self.materials.deinit(allocs, device, alloc_cbs);
        self.meshes.deinit(allocs);
    }
};

pub const SystemsData = struct {
    mesh_ranges: []core.mesh.Meshes2D.MeshRanges,

    pub fn deinit(self: *@This(), allocs: core.VulkanEngine.Allocators) void {
        allocs.std.free(self.mesh_ranges);
    }

    pub fn update(_: *@This()) void {}
};

pub const Description = struct {
    device: vk.Device,
    render_pass: vk.RenderPass,
    window_extent: vk.Extent2D,
    vertex_shader: vk.ShaderModule,
    fragment_shader: vk.ShaderModule,
};

const Bindings = struct {
    const TEXTURE2D = 0;
    const METADATA = 1;
};

pub const MAX_TEXTURES = 16;

///{x,y} as proportions of the window extent
const MARGINS: struct { f32, f32 } = .{ 0.02, 0.02 };
descriptor_pool: vk.DescriptorPool = undefined,
descriptor_set_layout: vk.DescriptorSetLayout = undefined,
pipeline_layout: vk.PipelineLayout = undefined,
pipeline: vk.Pipeline = undefined,

const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
    vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);
    vk.DestroyDescriptorPool(device, self.descriptor_pool, alloc_cbs);
}

pub fn init(pd: Description, alloc_cbs: ?*vk.AllocationCallbacks) Self {
    var self = Self{};
    self.createDescriptorSetLayout(pd.device, alloc_cbs);
    self.createDescriptorPool(pd.device, alloc_cbs);
    self.initPipeline(pd, alloc_cbs);
    return self;
}

fn createDescriptorSetLayout(
    self: *Self,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = Bindings.TEXTURE2D,
            .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
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
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };
    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.descriptor_set_layout)) catch
        @panic("failed to create hud descriptor set layout");
}

fn createDescriptorPool(
    self: *Self,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = MAX_TEXTURES,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
        },
    };
    const ci = vk.DescriptorPoolCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1,
        .poolSizeCount = pool_sizes.len,
        .pPoolSizes = &pool_sizes,
    };

    checkVk(vk.CreateDescriptorPool(device, &ci, alloc_cbs, &self.descriptor_pool)) catch
        @panic("failed to create hud descriptor pool");
}

fn initPipeline(
    self: *Self,
    pd: Description,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
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

    // Vertex2D: vec2 position at offset 0, vec2 uv at offset 8
    const binding_desc = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(core.mesh.Vertex2D),
        .inputRate = vk.VERTEX_INPUT_RATE_VERTEX,
    };
    const attr_descs = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = vk.FORMAT_R32G32_SFLOAT,
            .offset = @offsetOf(core.mesh.Vertex2D, "position"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = vk.FORMAT_R32G32_SFLOAT,
            .offset = @offsetOf(core.mesh.Vertex2D, "uv"),
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
        .topology = vk.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = vk.FALSE,
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(pd.window_extent.width),
        .height = @floatFromInt(pd.window_extent.height),
        .minDepth = 0,
        .maxDepth = 1,
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
        .polygonMode = vk.POLYGON_MODE_FILL,
        // BAD
        .cullMode = vk.CULL_MODE_NONE,
        .frontFace = vk.FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1.0,
    };

    const multisample_ci = vk.PipelineMultisampleStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = vk.SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = vk.FALSE,
        .minSampleShading = 1.0,
    };

    // no depth test — HUD always renders on top
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

    // alpha blending so the HUD can be transparent
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

    const layout_ci = vk.PipelineLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &self.descriptor_set_layout,
    };
    checkVk(vk.CreatePipelineLayout(pd.device, &layout_ci, alloc_cbs, &self.pipeline_layout)) catch
        @panic("failed to create hud pipeline layout");

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
        .layout = self.pipeline_layout,
        .renderPass = pd.render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };
    checkVk(vk.CreateGraphicsPipelines(pd.device, null, 1, &pipeline_ci, alloc_cbs, &self.pipeline)) catch
        @panic("failed to create hud pipeline");
}

pub fn allocateDescriptorSet(self: Self, device: vk.Device) vk.DescriptorSet {
    var set: vk.DescriptorSet = undefined;
    const ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.descriptor_set_layout,
    };
    checkVk(vk.AllocateDescriptorSets(device, &ai, &set)) catch
        @panic("failed to allocate hud descriptor set");
    return set;
}

pub fn updateDescriptorSet(
    device: vk.Device,
    a: mem.Allocator,
    alloc_data: AllocatedData,
    set: vk.DescriptorSet,
) std.mem.Allocator.Error!void {
    const texture_count = alloc_data.materials.textures.len;

    var image_infos = try a.alloc(vk.DescriptorImageInfo, texture_count);
    defer a.free(image_infos);

    for (alloc_data.materials.textures, 0..) |tx, i| {
        image_infos[i] = .{
            .sampler = tx.sampler,
            .imageView = tx.image_alloc.view,
            .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
    }

    const metadata_buffer_info = vk.DescriptorBufferInfo{
        .buffer = alloc_data.meshes.metadata.allocation.buffer,
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    };

    const write_sets = [_]vk.WriteDescriptorSet{
        .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = Bindings.TEXTURE2D,
            .dstArrayElement = 0,
            .descriptorCount = @intCast(texture_count),
            .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = image_infos.ptr,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = Bindings.METADATA,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &metadata_buffer_info,
            .pTexelBufferView = null,
        },
    };

    vk.UpdateDescriptorSets(device, write_sets.len, &write_sets, 0, null);
}

pub fn bind(self: Self, cmd: vk.CommandBuffer) void {
    vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
}

pub fn recordCommands(
    self: Self,
    sys_data: SystemsData,
    alloc_data: AllocatedData,
    set: vk.DescriptorSet,
    cmd: vk.CommandBuffer,
) void {
    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.pipeline_layout,
        0,
        1,
        &set,
        0,
        null,
    );

    const offsets = [_]vk.DeviceSize{0};
    vk.CmdBindVertexBuffers(cmd, 0, 1, &alloc_data.meshes.vertex_buffer.buffer, &offsets);
    vk.CmdBindIndexBuffer(cmd, alloc_data.meshes.index_buffer.buffer, 0, vk.INDEX_TYPE_UINT32);

    for (sys_data.mesh_ranges, 0..) |range, idx| {
        vk.CmdDrawIndexed(
            cmd,
            @intCast(range.index.range), // index count
            1, // instance count
            @intCast(range.index.offset), // first index
            0, // vertex offset (already baked in during appendMesh)
            @intCast(idx), // first instance — used to look up MetaData in shader
        );
    }
}
