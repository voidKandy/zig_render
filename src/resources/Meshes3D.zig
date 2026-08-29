const std = @import("std");
const core = @import("../root.zig");
const vma_usage = core.bindings.vma_usage;
const AllocatedBuffer = vma_usage.AllocatedBuffer;
const checkVk = core.bindings.vulkan_init.checkVk;
const c = core.clibs;
const math_mod = core.lib.math;
const vk = c.vk;
const log = std.log.scoped(.Meshes3D);

pub const MetaData = extern struct {
    material_index: u32,
    index_offset: u32,
    index_count: u32,
    vertex_offset: u32,
    model_transform: math_mod.Mat4,
};

pub const MeshRanges = struct {
    vertex: core.lib.mesh.RangeDesc,
    index: core.lib.mesh.RangeDesc,
    metadata: core.lib.mesh.RangeDesc,
};

pub const MeshHandle = struct {
    ranges: MeshRanges,
};

pub const Bindings = struct {
    vertex: u32,
    index: u32,
    metadata: u32,
};

pub const DEFAULT_BINDINGS = Bindings{
    .vertex = 0,
    .index = 1,
    .metadata = 2,
};

pub const AllocatedData = struct {
    vertex_buffer: vma_usage.AllocatedBuffer,
    index_buffer: vma_usage.AllocatedBuffer,
    metadata: vma_usage.MappedBuffer,
    descriptor_set: vk.DescriptorSet,

    pub fn deinit(
        self: @This(),
        allocs: core.engine.Allocators,
    ) void {
        self.vertex_buffer.deinit(allocs.vma);
        self.index_buffer.deinit(allocs.vma);
        self.metadata.deinit(allocs.vma);
    }

    pub fn updateDescriptorSet(
        self: @This(),
        device: vk.Device,
        bindings: Bindings,
    ) std.mem.Allocator.Error!void {
        const vertex_info = vk.DescriptorBufferInfo{
            .buffer = self.vertex_buffer.buffer,
            .offset = 0,
            .range = self.vertex_buffer.size,
        };
        const index_info = vk.DescriptorBufferInfo{
            .buffer = self.index_buffer.buffer,
            .offset = 0,
            .range = self.index_buffer.size,
        };
        const buffer_info = vk.DescriptorBufferInfo{
            .buffer = self.metadata.allocation.buffer,
            .offset = 0,
            .range = vk.WHOLE_SIZE,
        };

        const write_sets =
            &[_]vk.WriteDescriptorSet{
                .{
                    .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstSet = self.descriptor_set,
                    .dstBinding = bindings.vertex,
                    .dstArrayElement = 0,
                    .descriptorCount = 1,
                    .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                    .pBufferInfo = &vertex_info,
                },

                .{
                    .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstSet = self.descriptor_set,
                    .dstBinding = bindings.index,
                    .dstArrayElement = 0,
                    .descriptorCount = 1,
                    .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                    .pBufferInfo = &index_info,
                },

                .{
                    .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .pNext = null,
                    .dstSet = self.descriptor_set,
                    .dstBinding = bindings.metadata,
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
            @as(u32, @intCast(write_sets.len)),
            write_sets.ptr,
            0,
            null,
        );
    }
};

vertices: std.ArrayList(core.lib.mesh.Vertex3D),
indices: std.ArrayList(u32),
meta_data: std.ArrayList(MetaData),
meshes: std.ArrayList(MeshHandle),
amt_meshes: usize = 0,

descriptor_set_layout: vk.DescriptorSetLayout = undefined,

pub fn init(a: std.mem.Allocator) std.mem.Allocator.Error!@This() {
    return .{
        .vertices = try std.ArrayList(core.lib.mesh.Vertex3D).initCapacity(a, 64),
        .indices = try std.ArrayList(u32).initCapacity(a, 64),
        .meta_data = try std.ArrayList(MetaData).initCapacity(a, 16),
        .meshes = try std.ArrayList(MeshHandle).initCapacity(a, 16),
    };
}

/// DOES NOT FREE RANGES
/// passes ownership to allocated data
pub fn deinit(self: *@This(), a: std.mem.Allocator, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    self.vertices.deinit(a);
    self.indices.deinit(a);
    self.meta_data.deinit(a);
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
}

pub fn appendMeshWithMaterialIndex(
    self: *@This(),
    a: std.mem.Allocator,
    mesh: core.lib.mesh.Mesh3D,
    transform: core.lib.math.Mat4,
    material_index: u32,
) std.mem.Allocator.Error!void {
    defer self.amt_meshes += 1;
    const mesh_range = MeshRanges{
        .vertex = .{
            .offset = @as(u32, @intCast(self.vertices.items.len)),
            .range = @as(u32, @intCast(mesh.vertices.len)),
        },
        .index = .{
            .offset = @as(u32, @intCast(self.indices.items.len)),
            .range = @as(u32, @intCast(mesh.indices.len)),
        },
        .metadata = .{
            .offset = @as(u32, @intCast(self.meta_data.items.len)),
            .range = 1,
        },
    };

    try self.vertices.appendSlice(a, mesh.vertices);
    try self.indices.appendSlice(a, mesh.indices);

    try self.meta_data.append(a, MetaData{
        .model_transform = transform,
        .material_index = material_index,
        .index_count = @as(u32, @intCast(mesh.indices.len)),
        .index_offset = @intCast(mesh_range.index.offset),
        .vertex_offset = @intCast(mesh_range.vertex.offset),
    });
    try self.meshes.append(a, .{
        .ranges = mesh_range,
    });
}

pub fn appendMeshWithMaterialLookup(
    self: *@This(),
    a: std.mem.Allocator,
    mesh: core.lib.mesh.Mesh3D,
    transform: core.lib.math.Mat4,
    material_lookup_offset: u32,
    mat_lib: core.resources.Materials.MaterialLibrary,
    material_infos: []core.loaders.obj.MaterialInfo,
) std.mem.Allocator.Error!void {
    defer self.amt_meshes += 1;
    const mesh_range = MeshRanges{
        .vertex = .{
            .offset = @as(u32, @intCast(self.vertices.items.len)),
            .range = @as(u32, @intCast(mesh.vertices.len)),
        },
        .index = .{
            .offset = @as(u32, @intCast(self.indices.items.len)),
            .range = @as(u32, @intCast(mesh.indices.len)),
        },
        .metadata = .{
            .offset = @as(u32, @intCast(self.meta_data.items.len)),
            .range = @as(u32, @intCast(material_infos.len)),
        },
    };

    try self.vertices.appendSlice(a, mesh.vertices);
    try self.indices.appendSlice(a, mesh.indices);

    for (material_infos) |mat_info| {
        const material_entry = mat_lib.metadata.get(mat_info.material_name) orelse std.debug.panic(
            \\ Material not found: {s}
        , .{mat_info.material_name}) + material_lookup_offset;

        try self.meta_data.append(a, MetaData{
            .model_transform = transform,
            .material_index = @as(u32, @intCast(material_entry.@"0")),
            .index_count = mat_info.range.range,
            .index_offset = @intCast(mesh_range.index.offset + mat_info.range.offset),
            .vertex_offset = @intCast(mesh_range.vertex.offset),
        });
    }
    try self.meshes.append(a, .{
        .ranges = mesh_range,
    });
}

pub fn createDescriptorSetLayout(
    self: *@This(),
    bindings: Bindings,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const layout_bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = bindings.vertex,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        },
        .{
            .binding = bindings.index,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        },
        .{
            .binding = bindings.metadata,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        },
    };

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = 0,
        .bindingCount = @as(u32, @intCast(layout_bindings.len)),
        .pBindings = &layout_bindings,
    };
    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.descriptor_set_layout)) catch
        @panic("failed to create descriptor set layout");
}

pub fn upload(
    self: *@This(),
    allocs: core.engine.Allocators,
    pool: vk.DescriptorPool,
    upload_ctx: *core.bindings.vulkan_init.UploadContext,
    device: core.bindings.vulkan_init.LogicalDevice,
) AllocatedData {
    var vertex_buffer: vma_usage.AllocatedBuffer = undefined;
    var index_buffer: vma_usage.AllocatedBuffer = undefined;
    var metadata: vma_usage.MappedBuffer = undefined;
    var desc_set: vk.DescriptorSet = undefined;

    const vert_alloc_size, const idx_alloc_size = .{
        self.vertices.items.len * @sizeOf(core.lib.mesh.Vertex3D),
        self.indices.items.len * @sizeOf(u32),
    };

    var vert_staging_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        vert_alloc_size,
        vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        core.clibs.vma.MEMORY_USAGE_CPU_ONLY,
        0,
    );
    var idx_staging_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        idx_alloc_size,
        vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        core.clibs.vma.MEMORY_USAGE_CPU_ONLY,
        0,
    );

    defer {
        vert_staging_buffer.deinit(allocs.vma);
        idx_staging_buffer.deinit(allocs.vma);
    }

    // mapping memory
    {
        var data: ?*anyopaque = undefined;
        checkVk(core.clibs.vma.MapMemory(allocs.vma, vert_staging_buffer.allocation, &data)) catch @panic("failed to map memory");
        defer core.clibs.vma.UnmapMemory(allocs.vma, vert_staging_buffer.allocation);

        const vert_aligned_data: [*]core.lib.mesh.Vertex3D = @ptrCast(@alignCast(data));
        @memcpy(vert_aligned_data, self.vertices.items);

        data = undefined;
        checkVk(core.clibs.vma.MapMemory(allocs.vma, idx_staging_buffer.allocation, &data)) catch @panic("failed to map memory");
        defer core.clibs.vma.UnmapMemory(allocs.vma, idx_staging_buffer.allocation);

        const idx_aligned_data: [*]u32 = @ptrCast(@alignCast(data));
        @memcpy(idx_aligned_data, self.indices.items);
    }

    vertex_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        vert_alloc_size,
        vk.BUFFER_USAGE_VERTEX_BUFFER_BIT | vk.BUFFER_USAGE_TRANSFER_DST_BIT | vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
        core.clibs.vma.MEMORY_USAGE_GPU_ONLY,
        0,
    );
    index_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        vert_alloc_size,
        vk.BUFFER_USAGE_INDEX_BUFFER_BIT | vk.BUFFER_USAGE_TRANSFER_DST_BIT | vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
        core.clibs.vma.MEMORY_USAGE_GPU_ONLY,
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

    upload_ctx.immediateSubmit(device, SubmitCtx{
        .mesh_buffer = vertex_buffer.buffer,
        .staging_buffer = vert_staging_buffer.buffer,
        .size = vert_alloc_size,
    });

    upload_ctx.immediateSubmit(device, SubmitCtx{
        .mesh_buffer = index_buffer.buffer,
        .staging_buffer = idx_staging_buffer.buffer,
        .size = idx_alloc_size,
    });

    const metadata_alloc = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        @sizeOf(MetaData) * self.amt_meshes,
        vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
        core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
        0,
    );

    metadata = vma_usage.MappedBuffer{
        .allocation = metadata_alloc,
    };

    checkVk(core.clibs.vma.MapMemory(
        allocs.vma,
        metadata_alloc.allocation,
        &metadata.mapped,
    )) catch @panic("Failed to map metadata");

    const aligned_metadata: [*]MetaData = @ptrCast(@alignCast(metadata.mapped));

    @memcpy(aligned_metadata, self.meta_data.items);

    const ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.descriptor_set_layout,
    };

    checkVk(vk.AllocateDescriptorSets(device.handle, &ai, &desc_set)) catch
        @panic("failed to allocate descriptor sets");

    return .{
        .index_buffer = index_buffer,
        .metadata = metadata,
        .vertex_buffer = vertex_buffer,
        .descriptor_set = desc_set,
    };
}
