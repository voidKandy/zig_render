const std = @import("std");
const mem = std.mem;
const core = @import("../root.zig");
const imgui = core.clibs.imgui;
const log = std.log.scoped(.MainComputePipeline);
const vki = core.bindings.vulkan_init;
const vk = core.clibs.vk;
const vma_usage = core.bindings.vma_usage;
const checkVk = vki.checkVk;

const Bindings = struct {
    /// Set 0
    const OUTPUT_IMAGE = 0;
    const MAZE_STATE = 1;
    /// Set 1
    const TEXTURE2D = 0;
    const METADATA = 1;
};

const ComputePushConstants = extern struct {
    width: u32,
    height: u32,
    pixels_per_cell: u32,
    /// size of maze mesh cells in world scale
    cell_size: f32,
    maze_origin: core.lib.math.Vec3,
};

const GraphicsPushConstants = struct {
    inverse_window_resolution: core.lib.math.Vec2,
};

const GPUMazeCell = extern struct {
    walls: u32,

    fn arrayFromCellArray(a: std.mem.Allocator, arr: []core.lib.Maze.Cell) std.mem.Allocator.Error![]GPUMazeCell {
        var all = try a.alloc(GPUMazeCell, arr.len);
        for (arr, 0..) |item, i| {
            all[i].walls =
                (@as(u32, @intFromBool(item.walls.north)) << 0) |
                (@as(u32, @intFromBool(item.walls.south)) << 1) |
                (@as(u32, @intFromBool(item.walls.east)) << 2) |
                (@as(u32, @intFromBool(item.walls.west)) << 3);
        }
        return all;
    }
};

pub const AllocatedData = struct {
    pub const CreateData = struct {
        pub const MeshCreateInfo = struct {
            mesh: core.lib.mesh.Mesh2D,
            screen_coordinates: core.lib.math.Vec2,
        };
        pub const HudMesh = union(enum) {
            maze: MeshCreateInfo,
        };

        meshes: []const HudMesh,

        maze: core.lib.Maze,
        pixels_per_cell: u32,
        cell_size: f32,
        maze_origin: core.lib.math.Vec3,
    };

    meshes: core.resources.Meshes2D.AllocatedData,

    maze_image: vma_usage.AllocatedImage,
    maze_sampler: vk.Sampler,
    maze_state: vma_usage.MappedBuffer,

    // this is not alloc data
    // should be moved to some kind of struct for maze
    // maybe like metadata for meshes?
    // the reason it is included here is because this is the push constants
    // for the compute pipeline
    maze_mesh_idx: u32,
    maze_dimensions: vk.Extent2D,
    pixels_per_cell: u32,
    cell_size: f32,
    maze_origin: core.lib.math.Vec3,

    pub fn create(
        allocs: core.engine.Engine.Allocators,
        upload_ctx: *vki.UploadContext,
        logical_device: vki.LogicalDevice,
        physical_device: vki.PhysicalDevice,
        cd: CreateData,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) std.mem.Allocator.Error!struct { @This(), SystemsData } {
        // output image — STORAGE_BIT for compute write, SAMPLED_BIT for HUD read
        const maze_extent = vk.Extent3D{
            .width = cd.maze.width * cd.pixels_per_cell,
            .height = cd.maze.height * cd.pixels_per_cell,
            .depth = 1,
        };

        log.warn(
            \\ creating maze image: width={} height={} pixels_per_cell={}
        , .{ maze_extent.width, maze_extent.height, cd.pixels_per_cell });
        var image = vma_usage.AllocatedImage.init(
            allocs.vma,
            vk.FORMAT_R8G8B8A8_UNORM,
            maze_extent,
            vk.IMAGE_USAGE_STORAGE_BIT |
                vk.IMAGE_USAGE_SAMPLED_BIT |
                vk.IMAGE_USAGE_TRANSFER_DST_BIT,
        );
        const view_ci = vki.imageViewCreateInfo(image.format, image.image, vk.IMAGE_ASPECT_COLOR_BIT);
        checkVk(vk.CreateImageView(logical_device.handle, &view_ci, alloc_cbs, &image.view)) catch
            @panic("failed to create maze image view");

        // transition to GENERAL for compute writes
        upload_ctx.immediateSubmit(logical_device, struct {
            img: vk.Image,
            pub fn submit(self: @This(), cmd: vk.CommandBuffer) void {
                core.bindings.vulkan_util.transitionImageLayout(
                    cmd,
                    self.img,
                    vk.IMAGE_LAYOUT_UNDEFINED,
                    vk.IMAGE_LAYOUT_GENERAL,
                    0,
                    vk.ACCESS_SHADER_WRITE_BIT,
                    vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                    vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                );
            }
        }{ .img = image.image });

        // nearest sampler for pixel-perfect maze display
        var sampler: vk.Sampler = undefined;
        checkVk(vk.CreateSampler(logical_device.handle, &vk.SamplerCreateInfo{
            .sType = vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = vk.FILTER_NEAREST,
            .minFilter = vk.FILTER_NEAREST,
            .addressModeU = vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        }, alloc_cbs, &sampler)) catch @panic("failed to create maze sampler");

        // persistently mapped maze state buffer — one u32 per cell
        // const state_size = cd.maze_width * cd.maze_height * @sizeOf(u32);
        const maze_alloc = vma_usage.AllocatedBuffer.create(
            allocs.vma,
            @sizeOf(GPUMazeCell) * cd.maze.width * cd.maze.height,
            vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
            0,
        );
        var maze_state = vma_usage.MappedBuffer{
            .allocation = maze_alloc,
        };

        checkVk(core.clibs.vma.MapMemory(
            allocs.vma,
            maze_alloc.allocation,
            &maze_state.mapped,
        )) catch @panic("failed to map maze state buffer");

        const aligned_maze: [*]GPUMazeCell = @ptrCast(@alignCast(maze_state.mapped));
        const cells = try GPUMazeCell.arrayFromCellArray(allocs.std, cd.maze.cells);
        defer allocs.std.free(cells);
        @memcpy(aligned_maze, cells);

        _ = physical_device;

        var meshes = try core.resources.Meshes2D.init(allocs.std);
        defer meshes.deinit(allocs.std);

        for (cd.meshes) |mesh| {
            switch (mesh) {
                .maze => |maze| {
                    try meshes.appendMesh(
                        allocs.std,
                        maze.mesh,
                        maze.screen_coordinates,
                        // BAD
                        // we have to use a dummy 0 for material index since the material is a sampled image not stored in a materails
                        0,
                    );
                },
            }
        }

        const uploaded_meshes = meshes.upload(allocs, upload_ctx, logical_device);

        return .{
            .{
                .maze_image = image,
                .maze_sampler = sampler,
                .maze_state = maze_state,
                .maze_dimensions = vk.Extent2D{
                    .width = cd.maze.width,
                    .height = cd.maze.height,
                },
                .meshes = uploaded_meshes,
                // BAD
                .maze_mesh_idx = 0,
                .cell_size = cd.cell_size,
                .pixels_per_cell = cd.pixels_per_cell,
                .maze_origin = cd.maze_origin,
            },
            SystemsData{
                .mesh_ranges = try meshes.ranges.toOwnedSlice(allocs.std),
                .maze = cd.maze,
            },
        };
    }

    pub fn deinit(
        self: *@This(),
        allocs: core.engine.Engine.Allocators,
        device: vk.Device,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) void {
        self.maze_state.deinit(allocs.vma);
        self.maze_image.deinit(allocs.vma, device, alloc_cbs);
        vk.DestroySampler(device, self.maze_sampler, alloc_cbs);
        self.meshes.deinit(allocs);
    }
};

pub const SystemsData = struct {
    mesh_ranges: []core.resources.Meshes2D.MeshRanges,

    maze: core.lib.Maze,
    maze_update: bool = false,

    pub fn deinit(self: *@This(), allocs: core.engine.Engine.Allocators) void {
        allocs.std.free(self.mesh_ranges);
    }

    pub fn update(
        self: *@This(),
        a: std.mem.Allocator,
        alloc_data: AllocatedData,
    ) void {
        if (self.maze_update) {

            // TEMP
            for (self.maze.cells) |*c|
                c.walls = .{};

            self.maze.generate(a, self.maze.threshold.?, self.maze.seed.?);

            // alloc_data.maze_mesh_idx
            const cells = GPUMazeCell.arrayFromCellArray(a, self.maze.cells) catch @panic("OOM");
            defer a.free(cells);

            const aligned_maze: [*]GPUMazeCell = @ptrCast(@alignCast(alloc_data.maze_state.mapped));
            @memcpy(aligned_maze, cells);

            self.maze_update = false;
        }
    }
};

pub const Description = struct {
    global_descriptor_set_layout: vk.DescriptorSetLayout,
    device: vk.Device,
    render_pass: vk.RenderPass,
    window_extent: vk.Extent2D,
    vert_shader: vk.ShaderModule,
    frag_shader: vk.ShaderModule,
};

graphics_pipeline: vk.Pipeline = undefined,
graphics_pipeline_layout: vk.PipelineLayout = undefined,
graphics_descriptor_set_layout: vk.DescriptorSetLayout = undefined,
compute_pipeline: vk.Pipeline = undefined,
compute_pipeline_layout: vk.PipelineLayout = undefined,
compute_descriptor_set_layout: vk.DescriptorSetLayout = undefined,
descriptor_pool: vk.DescriptorPool = undefined,

const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyPipeline(device, self.graphics_pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.graphics_pipeline_layout, alloc_cbs);
    vk.DestroyDescriptorSetLayout(device, self.graphics_descriptor_set_layout, alloc_cbs);
    vk.DestroyPipeline(device, self.compute_pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.compute_pipeline_layout, alloc_cbs);
    vk.DestroyDescriptorSetLayout(device, self.compute_descriptor_set_layout, alloc_cbs);
    vk.DestroyDescriptorPool(device, self.descriptor_pool, alloc_cbs);
}

pub fn init(pd: Description, alloc_cbs: ?*vk.AllocationCallbacks) Self {
    var self = Self{};
    self.createDescriptorSetLayout(pd.device, alloc_cbs);
    self.createDescriptorPool(pd.device, alloc_cbs);
    self.initComputePipeline(pd, alloc_cbs);
    self.initGraphicsPipeline(pd, alloc_cbs);
    return self;
}

fn createDescriptorSetLayout(
    self: *Self,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const compute_bindings = &[_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = Bindings.OUTPUT_IMAGE,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
        },
        .{
            .binding = Bindings.MAZE_STATE,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
        },
    };
    const graphics_bindings = &[_]vk.DescriptorSetLayoutBinding{
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

    const all_bindings =
        &[_][]const vk.DescriptorSetLayoutBinding{
            compute_bindings,
            graphics_bindings,
        };

    for (all_bindings, 0..) |b, i| {
        const ci = vk.DescriptorSetLayoutCreateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = @as(u32, @intCast(b.len)),
            .pBindings = b.ptr,
        };

        if (i == 0)
            checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.compute_descriptor_set_layout)) catch
                @panic("failed to create main compute descriptor set layout")
        else
            checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.graphics_descriptor_set_layout)) catch
                @panic("failed to create main compute descriptor set layout");
    }
}

pub const MAX_TEXTURES = 16;
fn createDescriptorPool(
    self: *Self,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1 },
        .{ .type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 2 },
        .{ .type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = MAX_TEXTURES },
    };
    const ci = vk.DescriptorPoolCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 2,
        .poolSizeCount = pool_sizes.len,
        .pPoolSizes = &pool_sizes,
    };
    checkVk(vk.CreateDescriptorPool(device, &ci, alloc_cbs, &self.descriptor_pool)) catch
        @panic("failed to create main compute descriptor pool");
}

/// instead of the user passing a shader module, this
/// pipeline manages its own compute shaders internally
fn initComputePipeline(
    self: *Self,
    pd: Description,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const maze_shader = core.engine.shaders.createShaderModule(
        "maze.comp",
        pd.device,
        alloc_cbs,
    ) orelse @panic("failed to create maze compute shader module");
    defer vk.DestroyShaderModule(pd.device, maze_shader, alloc_cbs);
    const push_constant = vk.PushConstantRange{
        .offset = 0,
        .size = @sizeOf(ComputePushConstants),
        .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
    };

    const set_layouts = [_]vk.DescriptorSetLayout{
        pd.global_descriptor_set_layout,
        self.compute_descriptor_set_layout,
    };

    const layout_ci = vk.PipelineLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = set_layouts.len,
        .pSetLayouts = &set_layouts,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant,
    };
    checkVk(vk.CreatePipelineLayout(pd.device, &layout_ci, alloc_cbs, &self.compute_pipeline_layout)) catch
        @panic("failed to create main compute pipeline layout");

    const stage = vk.PipelineShaderStageCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = vk.SHADER_STAGE_COMPUTE_BIT,
        .module = maze_shader,
        .pName = "main",
    };
    const ci = vk.ComputePipelineCreateInfo{
        .sType = vk.STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .layout = self.compute_pipeline_layout,
        .stage = stage,
    };
    checkVk(vk.CreateComputePipelines(pd.device, null, 1, &ci, alloc_cbs, &self.compute_pipeline)) catch
        @panic("failed to create main compute pipeline");
}

fn initGraphicsPipeline(
    self: *Self,
    pd: Description,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.SHADER_STAGE_VERTEX_BIT,
            .module = pd.vert_shader,
            .pName = "main",
        },
        .{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.SHADER_STAGE_FRAGMENT_BIT,
            .module = pd.frag_shader,
            .pName = "main",
        },
    };

    // Vertex2D: vec2 position at offset 0, vec2 uv at offset 8
    const binding_desc = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(core.lib.mesh.Vertex2D),
        .inputRate = vk.VERTEX_INPUT_RATE_VERTEX,
    };
    const attr_descs = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = vk.FORMAT_R32G32_SFLOAT,
            .offset = @offsetOf(core.lib.mesh.Vertex2D, "position"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = vk.FORMAT_R32G32_SFLOAT,
            .offset = @offsetOf(core.lib.mesh.Vertex2D, "uv"),
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

    const push_constant = vk.PushConstantRange{
        .offset = 0,
        .size = @sizeOf(GraphicsPushConstants),
        .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
    };

    const set_layouts = [_]vk.DescriptorSetLayout{
        pd.global_descriptor_set_layout,
        self.graphics_descriptor_set_layout,
    };

    const layout_ci = vk.PipelineLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = set_layouts.len,
        .pSetLayouts = &set_layouts,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant,
    };
    checkVk(vk.CreatePipelineLayout(pd.device, &layout_ci, alloc_cbs, &self.graphics_pipeline_layout)) catch
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
        .layout = self.graphics_pipeline_layout,
        .renderPass = pd.render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };
    checkVk(vk.CreateGraphicsPipelines(pd.device, null, 1, &pipeline_ci, alloc_cbs, &self.graphics_pipeline)) catch
        @panic("failed to create hud pipeline");
}

pub const DescriptorSets = struct {
    compute: vk.DescriptorSet,
    graphics: vk.DescriptorSet,
    ui: vk.DescriptorSet,
};

pub fn allocateDescriptorSets(self: Self, device: vk.Device, alloc_data: AllocatedData) DescriptorSets {
    var compute_set: vk.DescriptorSet = undefined;
    const cmpt_ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.compute_descriptor_set_layout,
    };
    checkVk(vk.AllocateDescriptorSets(device, &cmpt_ai, &compute_set)) catch
        @panic("failed to allocate main compute descriptor set");

    var graphics_set: vk.DescriptorSet = undefined;

    const grphx_ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.graphics_descriptor_set_layout,
    };
    checkVk(vk.AllocateDescriptorSets(device, &grphx_ai, &graphics_set)) catch
        @panic("failed to allocate main compute descriptor set");

    const ui_set = imgui.impl_vulkan.AddTexture(alloc_data.maze_sampler, alloc_data.maze_image.view, vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    return .{
        .compute = compute_set,
        .graphics = graphics_set,
        .ui = ui_set,
    };
}

/// does nothing with graphics set?
pub fn updateDescriptorSets(
    device: vk.Device,
    alloc_data: AllocatedData,
    sets: DescriptorSets,
) void {
    const compute_image_info = vk.DescriptorImageInfo{
        .imageLayout = vk.IMAGE_LAYOUT_GENERAL,
        .imageView = alloc_data.maze_image.view,
    };
    const graphics_image_info = vk.DescriptorImageInfo{
        .sampler = alloc_data.maze_sampler,
        .imageView = alloc_data.maze_image.view,
        .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    const maze_state_buffer_info = vk.DescriptorBufferInfo{
        .buffer = alloc_data.maze_state.allocation.buffer,
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    };
    const metadata_buffer_info = vk.DescriptorBufferInfo{
        .buffer = alloc_data.meshes.metadata.allocation.buffer,
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    };
    const writes = [_]vk.WriteDescriptorSet{
        .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = sets.compute,
            .dstBinding = Bindings.OUTPUT_IMAGE,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .pImageInfo = &compute_image_info,
        },
        .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = sets.compute,
            .dstBinding = Bindings.MAZE_STATE,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &maze_state_buffer_info,
        },
        .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = sets.graphics,
            .dstBinding = Bindings.TEXTURE2D,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &graphics_image_info,
        },
        .{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = sets.graphics,
            .dstBinding = Bindings.METADATA,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &metadata_buffer_info,
        },
    };
    vk.UpdateDescriptorSets(device, writes.len, &writes, 0, null);
}

pub fn bindCompute(self: Self, cmd: vk.CommandBuffer) void {
    vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, self.compute_pipeline);
}

pub fn bindGraphics(self: Self, cmd: vk.CommandBuffer) void {
    vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);
}

pub fn recordCommandsCompute(
    self: Self,
    alloc_data: AllocatedData,
    global_descriptor_set: vk.DescriptorSet,
    set: vk.DescriptorSet,
    cmd: vk.CommandBuffer,
) void {
    const sets = [_]vk.DescriptorSet{
        global_descriptor_set, set,
    };
    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_COMPUTE,
        self.compute_pipeline_layout,
        0,
        sets.len,
        &sets,
        0,
        null,
    );

    const pc = ComputePushConstants{
        .width = alloc_data.maze_dimensions.width,
        .height = alloc_data.maze_dimensions.height,
        .pixels_per_cell = alloc_data.pixels_per_cell,
        .cell_size = alloc_data.cell_size,
        .maze_origin = alloc_data.maze_origin,
    };
    vk.CmdPushConstants(
        cmd,
        self.compute_pipeline_layout,
        vk.SHADER_STAGE_COMPUTE_BIT,
        0,
        @sizeOf(ComputePushConstants),
        &pc,
    );

    // transition to GENERAL for compute write
    core.bindings.vulkan_util.transitionImageLayout(
        cmd,
        alloc_data.maze_image.image,
        vk.IMAGE_LAYOUT_UNDEFINED,
        vk.IMAGE_LAYOUT_GENERAL,
        0,
        vk.ACCESS_SHADER_WRITE_BIT,
        vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
    );
    const w: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(alloc_data.maze_dimensions.width * alloc_data.pixels_per_cell)) / 8.0));
    const h: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(alloc_data.maze_dimensions.height * alloc_data.pixels_per_cell)) / 8.0));
    vk.CmdDispatch(cmd, w, h, 1);

    // transition to SHADER_READ_ONLY so HUD can sample it
    core.bindings.vulkan_util.transitionImageLayout(
        cmd,
        alloc_data.maze_image.image,
        vk.IMAGE_LAYOUT_GENERAL,
        vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        vk.ACCESS_SHADER_WRITE_BIT,
        vk.ACCESS_SHADER_READ_BIT,
        vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    );
}

pub fn recordCommandsGraphics(
    self: Self,
    window_extent: vk.Extent2D,
    sys_data: SystemsData,
    alloc_data: AllocatedData,
    global_descriptor_set: vk.DescriptorSet,
    set: vk.DescriptorSet,
    cmd: vk.CommandBuffer,
) void {
    const sets = [_]vk.DescriptorSet{
        global_descriptor_set, set,
    };

    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.graphics_pipeline_layout,
        0,
        sets.len,
        &sets,
        0,
        null,
    );
    const pc = GraphicsPushConstants{
        .inverse_window_resolution = core.lib.math.Vec2.make(
            1.0 / @as(f32, @floatFromInt(window_extent.width)),
            1.0 / @as(f32, @floatFromInt(window_extent.height)),
        ),
    };

    vk.CmdPushConstants(
        cmd,
        self.graphics_pipeline_layout,
        vk.SHADER_STAGE_VERTEX_BIT,
        0,
        @sizeOf(GraphicsPushConstants),
        &pc,
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

pub fn drawImgui(
    self: *Self,
    system_data: *SystemsData,
    ui_set: vk.DescriptorSet,
) void {
    _ = self;
    var open = true;
    const shown = imgui.Begin("Maze", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    var seed: c_int = @intCast(system_data.maze.seed.?);
    if (imgui.InputInt("seed", &seed)) {
        system_data.maze.seed = @as(u64, @intCast(seed));
        system_data.maze_update = true;
    }
    defer imgui.End();
    if (!shown) return;
    imgui.Image(ui_set, imgui.ImVec2{ .x = 400, .y = 400 });
}
