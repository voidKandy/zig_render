const std = @import("std");
const mem = std.mem;
const core = @import("../../root.zig");
const imgui = core.clibs.imgui;
const log = std.log.scoped(.MeshPipeline);
const mesh_mod = core.lib.mesh;
const vki = core.bindings.vulkan_init;
const vk = core.clibs.vk;
const vma = core.clibs.vma;
const vma_usage = core.bindings.vma_usage;
const checkVk = vki.checkVk;
const Mesh = mesh_mod.Mesh3D;
const Meshes3D = core.resources.Meshes3D;
const Meshes2D = core.resources.Meshes2D;

pub const AllocatedData = struct {
    pub const CreateData = struct {
        const CreateMesh = union(enum) {
            obj: core.loaders.obj.ObjFile,
            info: struct {
                mesh: Mesh,
                material_idx: u32,
            },
        };
        pub const MeshCreateInfo = struct {
            create_mesh: CreateMesh,
            transform: core.lib.math.Mat4 = .IDENTITY,
        };
        materials_files: []const core.loaders.mtl.MtlFile,
        create_meshes: []const MeshCreateInfo,
    };

    const MaterialEntry = struct {
        alloc_data: core.resources.Materials.AllocatedData,
        offset: u32,
    };
    materials: std.StringHashMap(MaterialEntry),
    meshes: Meshes3D.AllocatedData,

    pub fn deinit(self: *@This(), allocs: core.engine.Engine.Allocators, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        self.meshes.deinit(allocs);
        var iter = self.materials.valueIterator();
        while (iter.next()) |mt|
            mt.alloc_data.deinit(allocs, device, alloc_cbs);
        self.materials.deinit();
    }

    pub fn create(
        allocs: core.engine.Engine.Allocators,
        ecs: *core.engine.data.Ecs,
        upload_ctx: *core.bindings.vulkan_init.UploadContext,
        logical_device: core.bindings.vulkan_init.LogicalDevice,
        physical_device: core.bindings.vulkan_init.PhysicalDevice,
        cd: CreateData,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) std.mem.Allocator.Error!struct {
        @This(),
        Gui,
    } {
        var all_uploaded_materials = std.StringHashMap(MaterialEntry).init(allocs.std);
        var material_names = std.ArrayList([:0]u8).empty;

        var current_mtl_offset: u32 = 0;
        for (cd.materials_files) |mtl| {
            var materials = core.resources.Materials.initFromMaterialFile(allocs.std, mtl) catch @panic("failed to create MTL");
            defer materials.deinit(allocs.std);
            const uploaded = materials.upload(
                allocs,
                upload_ctx,
                logical_device,
                physical_device,
                alloc_cbs,
            );

            var iter = uploaded.indices.keyIterator();
            while (iter.next()) |name| {
                log.warn("material name: {s}", .{name.*});
                try material_names.append(allocs.std, try allocs.std.dupeZ(u8, name.*));
            }

            try all_uploaded_materials.put(mtl.name, .{ .alloc_data = uploaded, .offset = current_mtl_offset });
            current_mtl_offset += @as(u32, @intCast(uploaded.textures.len));
        }

        var meshes = try Meshes3D.init(allocs.std);
        defer meshes.deinit(allocs.std);

        for (cd.create_meshes) |create_mesh| {
            switch (create_mesh.create_mesh) {
                .obj => |obj| {
                    const this_mat_lib =
                        all_uploaded_materials.get(obj.material_library_name) orelse std.debug.panic(
                            \\ Failed to get material library "{s}"
                        , .{obj.material_library_name});

                    const mesh = core.lib.mesh.Mesh3D.fromObjFile(allocs.std, obj) catch @panic("failed to load mesh");
                    defer mesh.deinit(allocs.std);
                    meshes.appendMeshWithMaterialLookup(
                        allocs.std,
                        mesh,
                        create_mesh.transform,
                        this_mat_lib.offset,
                        this_mat_lib.alloc_data.indices,
                        obj.objects[0].material_ranges,
                    ) catch @panic("OOM");
                },
                .info => |info| {
                    meshes.appendMeshWithMaterialIndex(
                        allocs.std,
                        info.mesh,
                        create_mesh.transform,
                        info.material_idx,
                    ) catch @panic("OOM");
                },
            }
        }

        const uploaded_meshes = meshes.upload(allocs, upload_ctx, logical_device);

        for (meshes.meshes.items) |mesh_handle| {
            var ent = try ecs.entities.register(null);
            ent.addComponent(.mesh3D, core.engine.data.Mesh3DComponent{
                .handle = mesh_handle,
            });
        }

        return .{
            @This(){
                .materials = all_uploaded_materials,
                .meshes = uploaded_meshes,
            },
            Gui{
                // .mesh_scale_factors = blk: {
                //     const scale_factors = try allocs.std.alloc(f32, meshes.meshes.items.len);
                //     for (0..meshes.meshes.items.len) |i|
                //         scale_factors[i] = 1.0;
                //     break :blk scale_factors;
                // },
                // .meshes = try meshes.meshes.toOwnedSlice(allocs.std),
                .mesh_metadatas = try meshes.meta_data.toOwnedSlice(allocs.std),
                .material_names = try material_names.toOwnedSlice(allocs.std),
            },
        };
    }
};

pub const Gui = struct {
    /// ALL mesh metadatas, passed from `Meshes3D` upon startup
    /// slices into this are used when creating draw calls
    mesh_metadatas: []Meshes3D.MetaData,
    /// passed from `Materials` upon startup
    material_names: [][:0]u8,

    /// system side data associated with meshes
    mesh_data: std.AutoHashMapUnmanaged(u32, struct {
        /// allows for abitrary scaling of meshes
        scale_factor: f32,
    }) = .empty,
    /// edited meshes by entity id
    edited_meshes: std.ArrayListUnmanaged(u32) = .empty,

    pub fn deinit(self: *@This(), allocs: core.engine.Engine.Allocators) void {
        allocs.std.free(self.mesh_metadatas);
        self.mesh_data.deinit(allocs.std);
        for (self.material_names) |name|
            allocs.std.free(name);
        allocs.std.free(self.material_names);
        self.edited_meshes.deinit(allocs.std);
    }

    pub fn update(
        self: *@This(),
        ecs: *core.engine.data.Ecs,
        alloc_data: AllocatedData,
    ) void {
        if (self.edited_meshes.items.len > 0) {
            const aligned_metadatas: [*]Meshes3D.MetaData = @ptrCast(@alignCast(alloc_data.meshes.metadata.mapped));
            for (self.edited_meshes.items) |id| {
                var mesh_entity = ecs.entityHandle(id) catch std.debug.panic(
                    \\ No entity matching id: {}
                , .{id});
                const mesh_component = mesh_entity.accessComponent(.mesh3D) catch @panic("mesh component access failed");
                const mesh_handle = mesh_component.mesh3D.handle;
                const mds = self.mesh_metadatas[mesh_handle.ranges.metadata.offset .. mesh_handle.ranges.metadata.offset + mesh_handle.ranges.metadata.range];
                for (0..mds.len) |k| {
                    const md = mds[k];
                    const gpu_md: Meshes3D.MetaData = .{
                        .material_index = md.material_index,
                        .index_offset = md.index_offset,
                        .index_count = md.index_count,
                        .vertex_offset = md.vertex_offset,
                        .model_transform = md.model_transform,
                    };
                    aligned_metadatas[k + mesh_handle.ranges.metadata.offset] = gpu_md;
                }
            }

            self.edited_meshes.clearRetainingCapacity();
        }
    }

    fn markMeshEdited(
        self: *@This(),
        allocator: std.mem.Allocator,
        entity_id: u32,
    ) void {
        if (std.mem.indexOfScalar(u32, self.edited_meshes.items, entity_id) == null) {
            self.edited_meshes.append(allocator, entity_id) catch @panic("OOM");
        }
    }

    pub fn drawImgui(
        self: *@This(),
        a: std.mem.Allocator,
        pipeline: *Self,
        ecs: *core.engine.data.Ecs,
    ) void {
        var open = true;
        const shown = imgui.Begin("Mesh Pipeline", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
        defer imgui.End();

        if (!shown) return;

        const current_pipeline_name = @tagName(pipeline.current_pipeline);

        if (imgui.BeginCombo("Selected Pipeline", current_pipeline_name.ptr, 0)) {
            defer imgui.EndCombo();

            for (std.meta.tags(PipelineOptions)) |tag| {
                const name = @tagName(tag);
                if (imgui.Selectable(name))
                    pipeline.current_pipeline = tag;
            }
        }

        var idx: usize = 0;
        const query = core.engine.data.Ecs.Query{ .is = .{ .rule = .at_least, .sig = s: {
            var s = core.engine.data.Ecs.Signature.initEmpty();
            s.set(@intFromEnum(core.engine.data.Ecs.Meta.ComponentTag.mesh3D));
            break :s s;
        } } };
        var mesh_entities_iter = ecs.queryEntities(query);
        imgui.Text("Meshes");

        while (mesh_entities_iter.next()) |handle| : (idx += 1) {
            var mutable_handle = handle;

            const mesh_component =
                mutable_handle.accessComponent(.mesh3D) catch unreachable;

            const mesh: core.engine.data.Mesh3DComponent = mesh_component.mesh3D;

            const ranges = mesh.handle.ranges;
            const mesh_metadatas =
                self.mesh_metadatas[ranges.metadata.offset .. ranges.metadata.offset + ranges.metadata.range];

            var transform = mesh_metadatas[0].model_transform;

            const label = std.fmt.allocPrintSentinel(
                std.heap.c_allocator,
                "Mesh {d}",
                .{idx},
                0,
            ) catch @panic("OOM");
            defer std.heap.c_allocator.free(label);

            if (imgui.TreeNode(label)) {
                defer imgui.TreePop();

                var mat_idx: c_int = @intCast(mesh_metadatas[0].material_index);
                imgui.Text("Material Name: %s", self.material_names[@as(usize, @intCast(mat_idx))].ptr);

                if (imgui.InputInt("Material Index", &mat_idx)) {
                    mesh_metadatas[0].material_index = @as(u32, @intCast(mat_idx));
                    self.markMeshEdited(a, handle.identifier);
                }

                var translation: [3]f32 = .{
                    transform.t.x,
                    transform.t.y,
                    transform.t.z,
                };

                if (imgui.DragFloat3("Position", &translation)) {
                    transform.t.x = translation[0];
                    transform.t.y = translation[1];
                    transform.t.z = translation[2];

                    mesh_metadatas[0].model_transform = transform;

                    self.markMeshEdited(
                        a,
                        handle.identifier,
                    );
                }

                var scale_factor = blk: {
                    const result = self.mesh_data.getOrPut(a, handle.identifier) catch @panic("OOM");
                    break :blk if (result.found_existing)
                        result.value_ptr.scale_factor
                    else
                        1.0;
                };
                if (imgui.SliderFloat("Scale", &scale_factor, 0.0, 10.0)) {
                    if (scale_factor != 1.0) {
                        self.mesh_data.put(a, handle.identifier, .{ .scale_factor = scale_factor }) catch @panic("OOM");
                        const s = core.lib.math.Mat4.scale(core.lib.math.Vec3.make(scale_factor, scale_factor, scale_factor));
                        const t = core.lib.math.Mat4.translation(core.lib.math.Vec3.make(translation[0], translation[1], translation[2]));
                        mesh_metadatas[0].model_transform = core.lib.math.Mat4.mul(t, s);

                        self.markMeshEdited(a, handle.identifier);
                    }
                }
            }
        }

        imgui.Separator();
    }
};

pub const Description = struct {
    global_descriptor_set_layout: vk.DescriptorSetLayout = undefined,
    device: vk.Device = undefined,
    render_pass: vk.RenderPass = undefined,
    window_extent: vk.Extent2D,
    vertex_shader: vk.ShaderModule = undefined,
    fragment_shader: vk.ShaderModule = undefined,
    depth_compare_op: vk.CompareOp = vk.COMPARE_OP_LESS,
};

const Bindings = struct {
    /// Set 0
    const VERTEX = 0;
    const INDEX = 1;
    /// Set 1
    const TEXTURE2D = 0;
    const METADATA = 1;
};

pub const MAX_TEXTURES = 16;

const PipelineOptions = enum {
    solid,
    line,
};

current_pipeline: PipelineOptions = .solid,
solid_pipeline: vk.Pipeline = undefined,
/// for debugging
line_pipeline: vk.Pipeline = undefined,
pipeline_layout: vk.PipelineLayout = undefined,
descriptor_pool: vk.DescriptorPool = undefined,
descriptor_set_layout: vk.DescriptorSetLayout = undefined,
texture_set_layout: vk.DescriptorSetLayout = undefined,

const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
    vk.DestroyDescriptorSetLayout(device, self.texture_set_layout, alloc_cbs);
    vk.DestroyPipeline(device, self.solid_pipeline, alloc_cbs);
    vk.DestroyPipeline(device, self.line_pipeline, alloc_cbs);
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
        pd.global_descriptor_set_layout,
        self.texture_set_layout,
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
        &self.texture_set_layout,
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

pub fn allocateTextureDescriptorSet(self: Self, device: vk.Device) vk.DescriptorSet {
    var set: vk.DescriptorSet = undefined;
    const ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.texture_set_layout,
    };
    checkVk(vk.AllocateDescriptorSets(device, &ai, &set)) catch |e| {
        log.err(
            \\failed to allocate texture descriptor set: {s}
        , .{@errorName(e)});
        @panic("failed to allocate texture descriptor set");
    };
    return set;
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
    const texture_count = blk: {
        var i: usize = 0;
        var iter = alloc_data.materials.valueIterator();
        while (iter.next()) |val| {
            i += val.alloc_data.textures.len;
        }
        break :blk i;
    };
    log.debug(
        \\ materials count: {}
    , .{texture_count});
    var image_infos = try a.alloc(vk.DescriptorImageInfo, texture_count);
    defer a.free(image_infos);

    var iter = alloc_data.materials.valueIterator();
    var i: usize = 0;
    while (iter.next()) |val| {
        for (val.alloc_data.textures) |tx| {
            image_infos[i] = .{
                .sampler = tx.sampler,
                .imageView = tx.image_alloc.view,
                .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            i += 1;
        }
    }

    std.debug.assert(i == texture_count);

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

pub fn recordCommands(
    self: Self,
    ecs: *core.engine.data.Ecs,
    global_descriptor_set: vk.DescriptorSet,
    set: vk.DescriptorSet,
    tx_set: vk.DescriptorSet,
    cmd: vk.CommandBuffer,
) void {
    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.pipeline_layout,
        0,
        1,
        &global_descriptor_set,
        0,
        null,
    );
    // bind set 1: textures + metadata (global, same for all submeshes)
    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.pipeline_layout,
        1, // set index 1
        1,
        &tx_set,
        0,
        null,
    );

    const query = core.engine.data.Ecs.Query{ .is = .{ .rule = .at_least, .sig = s: {
        var s = core.engine.data.Ecs.Signature.initEmpty();
        s.set(@intFromEnum(core.engine.data.Ecs.Meta.ComponentTag.mesh3D));
        break :s s;
    } } };
    var mesh_entities_iter = ecs.queryEntities(query);

    var idx: usize = 0;
    while (mesh_entities_iter.next()) |handle| : (idx += 1) {
        var mutable_handle = handle;
        const mesh_component = mutable_handle.accessComponent(.mesh3D) catch unreachable;
        const mesh: core.engine.data.Mesh3DComponent = mesh_component.mesh3D;
        const ranges = mesh.handle.ranges;
        // bind set 0: VB, IB, UBO for this submesh
        vk.CmdBindDescriptorSets(
            cmd,
            vk.PIPELINE_BIND_POINT_GRAPHICS,
            self.pipeline_layout,
            2, // set index 0
            1,
            &set,
            0,
            null,
        );
        vk.CmdDraw(
            cmd,
            @as(u32, @intCast(ranges.index.range)),
            1, // num instances
            @as(u32, @intCast(ranges.index.offset)),
            @as(u32, @intCast(idx)), // first instance
        );
    }
}
