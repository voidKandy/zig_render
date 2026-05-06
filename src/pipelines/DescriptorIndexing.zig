const std = @import("std");
const mem = std.mem;
const engine = @import("../root.zig");
const log = std.log.scoped(.DescriptorIndexing);
const mesh_mod = engine.mesh;
const vki = engine.vulkan_init;
const vk = engine.clibs.vk;
const checkVk = vki.checkVk;

const RangeDesc = struct {
    offset: vk.DeviceSize = 0,
    range: vk.DeviceSize = 0,
};

pub const MetaData = struct {
    material_index: u32,
    index_offset: u32,
    index_count: u32,
    vertex_offset: u32,
};

const SubmeshRanges = struct {
    vertex_range: RangeDesc,
    index_range: RangeDesc,
    uniform_range: RangeDesc,
};

pub const TextureInfo = struct {
    sampler: vk.Sampler,
    image_view: vk.ImageView,
};

pub const ModelDesc = struct {
    vertex_buffer: vk.Buffer,
    index_buffer: vk.Buffer,
    meta_data: vk.Buffer,
    uniforms: []vk.Buffer,
    materials: []TextureInfo,
    ranges: []SubmeshRanges,

    pub fn deinit(self: @This(), a: mem.Allocator) void {
        a.free(self.uniforms);
        a.free(self.materials);
        a.free(self.ranges);
    }
};

pub const PipelineDescription = struct {
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
const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout_textures, alloc_cbs);
    vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);
    vk.DestroyDescriptorPool(device, self.descriptor_pool, alloc_cbs);
}
/// should device be a field of pd?
pub fn init(a: mem.Allocator, pd: PipelineDescription, alloc_cbs: ?*vk.AllocationCallbacks) mem.Allocator.Error!@This() {
    var self = @This(){
        .num_images = pd.num_images,
    };

    try self.createDescriptorSetLayout(
        pd.device,
        a,
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

    self.initCommon(
        pd.window_extent,
        pd.device,
        pd.render_pass,
        pd.vertex_shader,
        pd.fragment_shader,
        pd.depth_compare_op,
        alloc_cbs,
    );

    return self;
}

fn initCommon(
    self: *Self,
    window_extent: vk.Extent2D,
    device: vk.Device,
    render_pass: vk.RenderPass,
    vert_shader: vk.ShaderModule,
    frag_shader: vk.ShaderModule,
    depth_compare_op: vk.CompareOp,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const shader_stage_ci = [_]vk.PipelineShaderStageCreateInfo{ .{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = vk.SHADER_STAGE_VERTEX_BIT,
        .module = vert_shader,
        .pName = "main",
    }, .{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = vk.SHADER_STAGE_FRAGMENT_BIT,
        .module = frag_shader,
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
        .width = @as(f32, (@floatFromInt(window_extent.width))),
        .height = @as(f32, (@floatFromInt(window_extent.height))),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    const scissor = vk.Rect2D{
        .offset = .{
            .x = 0,
            .y = 0,
        },
        .extent = window_extent,
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
        .depthCompareOp = depth_compare_op,
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

    checkVk(vk.CreatePipelineLayout(device, &layout_ci, alloc_cbs, &self.pipeline_layout)) catch
        @panic("failed to create triangle pipeline layout");

    const pipeline_ci = vk.GraphicsPipelineCreateInfo{
        .sType = vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
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
        .renderPass = render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    checkVk(vk.CreateGraphicsPipelines(
        device,
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
    a: mem.Allocator,
    texture_count: u32,
    uniform_buffer_count: u32,
    storage_buffer_count: u32,
    max_sets: u32,
    alloc_cbs: ?*vk.AllocationCallbacks,
) mem.Allocator.Error!void {
    var pool_sizes = try std.ArrayList(vk.DescriptorPoolSize).initCapacity(a, 3);

    if (texture_count > 0) {
        const size = vk.DescriptorPoolSize{
            .type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = texture_count,
        };
        pool_sizes.appendAssumeCapacity(size);
    }
    if (uniform_buffer_count > 0) {
        const size = vk.DescriptorPoolSize{
            .type = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = uniform_buffer_count,
        };
        pool_sizes.appendAssumeCapacity(size);
    }
    if (storage_buffer_count > 0) {
        const size = vk.DescriptorPoolSize{
            .type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = storage_buffer_count,
        };
        pool_sizes.appendAssumeCapacity(size);
    }

    const slice = try pool_sizes.toOwnedSlice(a);

    const ci = vk.DescriptorPoolCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = 0,
        .maxSets = max_sets,
        .poolSizeCount = @as(u32, @intCast(slice.len)),
        .pPoolSizes = slice.ptr,
    };

    checkVk(vk.CreateDescriptorPool(device, &ci, alloc_cbs, &self.descriptor_pool)) catch
        @panic("failed to create descriptor pool");
}

fn createDescriptorSetLayout(
    self: *Self,
    device: vk.Device,
    a: mem.Allocator,
    is_vertex_buffer: bool,
    is_index_buffer: bool,
    is_uniform_buffer: bool,
    alloc_cbs: ?*vk.AllocationCallbacks,
) mem.Allocator.Error!void {
    var bindings = try std.ArrayList(vk.DescriptorSetLayoutBinding).initCapacity(a, 3);

    if (is_vertex_buffer) {
        const binding = vk.DescriptorSetLayoutBinding{
            .binding = Bindings.VERTEX,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        };
        bindings.appendAssumeCapacity(binding);
    }
    if (is_index_buffer) {
        const binding = vk.DescriptorSetLayoutBinding{
            .binding = Bindings.INDEX,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        };
        bindings.appendAssumeCapacity(binding);
    }
    if (is_uniform_buffer) {
        const binding = vk.DescriptorSetLayoutBinding{
            .binding = Bindings.UNIFORM,
            .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        };
        bindings.appendAssumeCapacity(binding);
    }

    const slice = try bindings.toOwnedSlice(a);
    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = 0,
        .bindingCount = @as(u32, @intCast(slice.len)),
        .pBindings = slice.ptr,
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

    var layouts = try std.ArrayList(vk.DescriptorSetLayout).initCapacity(a, num_submeshes);
    try layouts.appendNTimes(a, self.descriptor_set_layout, num_submeshes);

    const slice = try layouts.toOwnedSlice(a);
    const ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = @as(u32, @intCast(slice.len)),
        .pSetLayouts = slice.ptr,
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
    self: *Self,
    device: vk.Device,
    a: mem.Allocator,
    model_desc: ModelDesc,
    sets: *std.ArrayList(std.ArrayList(vk.DescriptorSet)),
    textures_set: vk.DescriptorSet,
) mem.Allocator.Error!void {
    try updateTextureDescriptorSet(device, a, model_desc, textures_set);

    const num_submeshes = sets.items[0].items.len;
    const num_bindings = 3; // VB, IB, Uniform

    const write_sets_size = self.num_images * num_submeshes * num_bindings;
    var write_sets = try std.ArrayList(vk.WriteDescriptorSet).initCapacity(a, write_sets_size);

    var buf_info_vertex = try std.ArrayList(vk.DescriptorBufferInfo).initCapacity(a, num_submeshes);
    defer buf_info_vertex.deinit(a);

    var buf_info_index = try std.ArrayList(vk.DescriptorBufferInfo).initCapacity(a, num_submeshes);
    defer buf_info_index.deinit(a);

    var buf_info_uniform = try std.ArrayList(std.ArrayList(vk.DescriptorBufferInfo)).initCapacity(a, self.num_images);
    defer buf_info_uniform.deinit(a);

    for (0..num_submeshes) |i| {
        buf_info_vertex.appendAssumeCapacity(.{
            .buffer = model_desc.vertex_buffer,
            .offset = model_desc.ranges[i].vertex_range.offset,
            .range = model_desc.ranges[i].vertex_range.range,
        });
        buf_info_index.appendAssumeCapacity(.{
            .buffer = model_desc.index_buffer,
            .offset = model_desc.ranges[i].index_range.offset,
            .range = model_desc.ranges[i].index_range.range,
        });
    }

    for (0..self.num_images) |i| {
        var inner = try std.ArrayList(vk.DescriptorBufferInfo).initCapacity(a, num_submeshes);
        for (0..num_submeshes) |k| {
            inner.appendAssumeCapacity(.{
                .buffer = model_desc.uniforms[i],
                .offset = model_desc.ranges[k].uniform_range.offset,
                .range = model_desc.ranges[k].uniform_range.range,
            });
        }
        buf_info_uniform.appendAssumeCapacity(inner);
    }

    var wds_index: u32 = 0;

    for (0..self.num_images) |i| {
        for (0..num_submeshes) |k| {
            const dst_set = sets.items[i].items[k];

            var wds = vk.WriteDescriptorSet{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = dst_set,
                .dstBinding = Bindings.VERTEX,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pBufferInfo = &buf_info_vertex.items[k],
            };
            std.debug.assert(wds_index < write_sets.items.len);
            write_sets.items[wds_index] = wds;
            wds_index += 1;

            wds = .{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = dst_set,
                .dstBinding = Bindings.INDEX,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pBufferInfo = &buf_info_index.items[k],
            };
            std.debug.assert(wds_index < write_sets.items.len);
            write_sets.items[wds_index] = wds;
            wds_index += 1;

            wds = .{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = dst_set,
                .dstBinding = Bindings.UNIFORM,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .pBufferInfo = &buf_info_uniform.items[i].items[k],
            };
            std.debug.assert(wds_index < write_sets.items.len);
            write_sets.items[wds_index] = wds;
            wds_index += 1;
        }
    }

    const slice = try write_sets.toOwnedSlice(a);

    vk.UpdateDescriptorSets(
        device,
        wds_index,
        slice.ptr,
        0,
        null,
    );
}

fn updateTextureDescriptorSet(
    device: vk.Device,
    a: mem.Allocator,
    model_desc: ModelDesc,
    texture_set: vk.DescriptorSet,
) mem.Allocator.Error!void {
    const texture_count = model_desc.materials.len;
    log.warn(
        \\ materials count: {}
    , .{texture_count});
    var image_infos = try std.ArrayList(vk.DescriptorImageInfo).initCapacity(a, texture_count);

    for (0..texture_count) |i| {
        image_infos.appendAssumeCapacity(.{
            .sampler = model_desc.materials[i].sampler,
            .imageView = model_desc.materials[i].image_view,
            .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        });
    }

    const buffer_info = vk.DescriptorBufferInfo{
        .buffer = model_desc.meta_data,
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
            .pImageInfo = image_infos.items.ptr,
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
