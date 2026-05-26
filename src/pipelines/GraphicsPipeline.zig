const std = @import("std");
const mem = std.mem;
const core = @import("../root.zig");
const imgui = core.clibs.imgui;
const log = std.log.scoped(.GraphicsPipeline);
const mesh_mod = core.mesh;
const vki = core.vulkan_init;
const vk = core.clibs.vk;
const vma = core.clibs.vma;
const vma_usage = core.vma_usage;
const checkVk = vki.checkVk;
const Mesh = mesh_mod.Mesh3D;

pub const AllocatedData = struct {
    pub const CreateData = struct {
        camera: core.Camera,
        materials_file: core.mtl_loader.MtlFile,
        meshes_path: []const u8,

        // for now, we support a single terrain file
        // eventually, we will have both the heightmap file & type file
        terrain_heightmap_file_name: []const u8,
        terrain_material_name: []const u8,
    };

    materials: core.Materials.AllocatedData,
    meshes: core.mesh.Meshes.AllocatedData,
    camera_uniform: vma_usage.MappedBuffer,

    pub fn deinit(self: *@This(), allocs: core.VulkanEngine.Allocators, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        self.meshes.deinit(allocs);
        self.camera_uniform.deinit(allocs.vma);
        self.materials.deinit(allocs, device, alloc_cbs);
    }
    pub fn create(
        allocs: core.VulkanEngine.Allocators,
        upload_ctx: *core.vulkan_init.UploadContext,
        logical_device: core.vulkan_init.LogicalDevice,
        physical_device: core.vulkan_init.PhysicalDevice,
        camera_extent: vk.Extent2D,
        cd: CreateData,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) std.mem.Allocator.Error!@This() {
        var materials = core.Materials.initFromMaterialFile(allocs.std, cd.materials_file) catch @panic("failed to create MTL");
        defer materials.deinit(allocs.std);
        const uploaded_materials = materials.upload(
            allocs,
            upload_ctx,
            logical_device,
            physical_device,
            alloc_cbs,
        );
        var meshes = try core.mesh.Meshes.init(allocs.std);
        defer meshes.deinit(allocs.std);

        const terrain_material = uploaded_materials.indices.get(cd.terrain_material_name) orelse @panic("failed to get material for object");
        const heightmap_mesh =
            try core.terrain.fromHeightmap(
                allocs.std,
                cd.terrain_heightmap_file_name,
                128, // vertex resolution X
                128, // vertex resolution Z
                2.0, // max height
                10.0, // world size
            );
        meshes.appendMesh(allocs.std, heightmap_mesh, core.math.Mat4.IDENTITY, terrain_material) catch @panic("OOM");
        defer heightmap_mesh.deinit(allocs.std);

        const meshes_object_files = core.obj_loader.readObjDirectory(allocs.std, cd.meshes_path) catch @panic("failed to read objects");
        defer allocs.std.free(meshes_object_files);

        for (meshes_object_files) |*obj| {
            const mesh = core.mesh.Mesh3D.fromObjFile(allocs.std, obj.*) catch @panic("failed to load mesh");
            defer mesh.deinit(allocs.std);
            defer obj.deinit();

            const material_index = uploaded_materials.indices.get(obj.*.objects[0].material_name) orelse @panic("failed to get material for object");
            const transform = core.math.Mat4.IDENTITY;

            meshes.appendMesh(allocs.std, mesh, transform, material_index) catch @panic("OOM");
        }

        const camera_alloc = vma_usage.AllocatedBuffer.create(
            allocs.vma,
            @sizeOf(core.Camera.GPUData),
            vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
            0,
        );
        var mapped_camera: vma_usage.MappedBuffer = .{ .allocation = camera_alloc };
        checkVk(core.clibs.vma.MapMemory(allocs.vma, camera_alloc.allocation, &mapped_camera.mapped)) catch @panic("Failed to map camera");

        const aligned_camera: *core.Camera.GPUData = @ptrCast(@alignCast(mapped_camera.mapped));

        aligned_camera.* = cd.camera.createGPUData(camera_extent);
        aligned_camera.*.proj.j.y *= -1;

        const uploaded_meshes = meshes.upload(allocs, upload_ctx, logical_device);

        return .{
            .materials = uploaded_materials,
            .meshes = uploaded_meshes,
            .camera_uniform = mapped_camera,
        };
    }
};

pub const SystemsData = struct {
    camera: core.Camera,

    pub fn update(
        self: *@This(),
        alloc_data: AllocatedData,
        input: core.Input,
        screen_extent: vk.Extent2D,
    ) void {
        const State = struct {
            var start: i128 = 0;
            var yaw: f32 = 0.0;
        };
        if (State.start == 0)
            State.start = std.time.nanoTimestamp();

        const zoom_speed = 0.1;
        const min_distance = 0.2;
        const max_distance = 10.0;

        self.camera.distance = std.math.clamp(self.camera.distance - input.scroll * zoom_speed, min_distance, max_distance);

        // this could also be computed with a yaw/pitch if those should be added to camera
        const dir = self.camera.target.sub(self.camera.eye).normalized();
        self.camera.eye = self.camera.target.sub(dir.mul(self.camera.distance));

        const now = std.time.nanoTimestamp();
        const delta_ns = now - State.start;
        const time: f32 = @as(f32, (@floatFromInt(delta_ns))) / @as(f32, (@floatFromInt(std.time.ns_per_s)));
        State.yaw = time * 1.0;

        const aspect =
            @as(f32, @floatFromInt(screen_extent.width)) /
            @as(f32, @floatFromInt(screen_extent.height));

        const eye = core.math.Vec3.make(
            self.camera.target.x + self.camera.distance * @sin(State.yaw),
            self.camera.target.y + self.camera.distance * @cos(State.yaw),
            self.camera.target.z,
        );

        var ubo = switch (self.camera.mode) {
            .rotate_around => core.Camera.GPUData{
                .view = core.math.Mat4.lookAt(eye, core.math.Vec3.ZERO, core.math.Vec3.UP),
                .proj = core.math.Mat4.perspective(self.camera.fov, aspect, self.camera.near_plane, self.camera.far_plane),
            },
            .user_input => core.Camera.GPUData{
                .view = core.math.Mat4.lookAt(self.camera.eye, core.math.Vec3.ZERO, core.math.Vec3.UP),
                .proj = core.math.Mat4.perspective(self.camera.fov, aspect, self.camera.near_plane, self.camera.far_plane),
            },
        };

        ubo.proj.j.y *= -1;

        const aligned_data: *core.Camera.GPUData = @ptrCast(@alignCast(alloc_data.camera_uniform.mapped));
        aligned_data.* = ubo;
    }
};

pub const Description = struct {
    device: vk.Device = undefined,
    render_pass: vk.RenderPass = undefined,
    window_extent: vk.Extent2D,
    vertex_shader: vk.ShaderModule = undefined,
    fragment_shader: vk.ShaderModule = undefined,
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
        .buffer = alloc_data.meshes.vertex_buffer.buffer,
        .offset = 0,
        .range = alloc_data.meshes.vertex_buffer.size,
    };
    const index_info = vk.DescriptorBufferInfo{
        .buffer = alloc_data.meshes.index_buffer.buffer,
        .offset = 0,
        .range = alloc_data.meshes.index_buffer.size,
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
    const texture_count = alloc_data.materials.textures.len;
    log.debug(
        \\ materials count: {}
    , .{texture_count});
    var image_infos = try a.alloc(vk.DescriptorImageInfo, texture_count);
    defer a.free(image_infos);

    for (0..texture_count) |i| {
        image_infos[i] = .{
            .sampler = alloc_data.materials.textures[i].sampler,
            .imageView = alloc_data.materials.textures[i].image_alloc.view,
            .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
    }

    const buffer_info = vk.DescriptorBufferInfo{
        .buffer = alloc_data.meshes.metadata.allocation.buffer,
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

pub fn drawImgui(self: *Self, system_data: *SystemsData) void {
    _ = self;
    var open = true;
    const shown = imgui.Begin("camera", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    defer imgui.End();

    if (shown) {
        imgui.Text("Selected mode: ", @tagName(system_data.camera.mode).ptr);
        if (imgui.BeginCombo("Camera Modes", @tagName(system_data.camera.mode).ptr, 0)) {
            defer imgui.EndCombo();
            for (std.meta.tags(core.Camera.Mode)) |tag| {
                if (imgui.Selectable(@tagName(tag))) {
                    system_data.camera.mode = tag;
                    break;
                }
            }
        }
    }
}
