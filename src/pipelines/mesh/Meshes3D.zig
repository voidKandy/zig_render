const std = @import("std");
const core = @import("../../root.zig");
const vma_usage = core.vma_usage;
const AllocatedBuffer = vma_usage.AllocatedBuffer;
const checkVk = core.vulkan_init.checkVk;
const c = core.clibs;
const m3d = core.math;
const vk = c.vk;
const log = std.log.scoped(.Meshes3D);

pub const MetaData = extern struct {
    material_index: u32,
    index_offset: u32,
    index_count: u32,
    vertex_offset: u32,
    model_transform: core.math.Mat4,
};

pub const MeshRanges = struct {
    vertex: core.mesh.RangeDesc,
    index: core.mesh.RangeDesc,
    metadata: core.mesh.RangeDesc,
};

pub const MeshHandle = struct {
    ranges: MeshRanges,
};

pub const AllocatedData = struct {
    vertex_buffer: vma_usage.AllocatedBuffer = undefined,
    index_buffer: vma_usage.AllocatedBuffer = undefined,
    metadata: vma_usage.MappedBuffer = undefined,

    pub fn deinit(
        self: @This(),
        allocs: core.VulkanEngine.Allocators,
    ) void {
        self.vertex_buffer.deinit(allocs.vma);
        self.index_buffer.deinit(allocs.vma);
        self.metadata.deinit(allocs.vma);
    }
};

vertices: std.ArrayList(core.mesh.Vertex3D),
indices: std.ArrayList(u32),
meta_data: std.ArrayList(MetaData),
meshes: std.ArrayList(MeshHandle),
amt_meshes: usize = 0,

pub fn init(a: std.mem.Allocator) std.mem.Allocator.Error!@This() {
    return .{
        .vertices = try std.ArrayList(core.mesh.Vertex3D).initCapacity(a, 64),
        .indices = try std.ArrayList(u32).initCapacity(a, 64),
        .meta_data = try std.ArrayList(MetaData).initCapacity(a, 16),
        .meshes = try std.ArrayList(MeshHandle).initCapacity(a, 16),
    };
}

/// DOES NOT FREE RANGES
/// passes ownership to allocated data
pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
    self.vertices.deinit(a);
    self.indices.deinit(a);
    self.meta_data.deinit(a);
}

pub fn appendMeshWithMaterialIndex(
    self: *@This(),
    a: std.mem.Allocator,
    mesh: core.mesh.Mesh3D,
    transform: core.math.Mat4,
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
    mesh: core.mesh.Mesh3D,
    transform: core.math.Mat4,
    material_lookup_offset: u32,
    material_lookup: std.StringHashMapUnmanaged(u32),
    material_infos: []core.obj_loader.MaterialInfo,
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
        const material_index = material_lookup.get(mat_info.material_name) orelse std.debug.panic(
            \\ Material not found: {s}
        , .{mat_info.material_name}) + material_lookup_offset;

        try self.meta_data.append(a, MetaData{
            .model_transform = transform,
            .material_index = material_index,
            .index_count = mat_info.range.range,
            .index_offset = @intCast(mesh_range.index.offset + mat_info.range.offset),
            .vertex_offset = @intCast(mesh_range.vertex.offset),
        });
    }
    try self.meshes.append(a, .{
        .ranges = mesh_range,
    });
}

pub fn upload(
    self: *@This(),
    allocs: core.VulkanEngine.Allocators,
    upload_ctx: *core.vulkan_init.UploadContext,
    device: core.vulkan_init.LogicalDevice,
) AllocatedData {
    var alloc_data = AllocatedData{};
    const vert_alloc_size, const idx_alloc_size = .{
        self.vertices.items.len * @sizeOf(core.mesh.Vertex3D),
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

        const vert_aligned_data: [*]core.mesh.Vertex3D = @ptrCast(@alignCast(data));
        @memcpy(vert_aligned_data, self.vertices.items);

        data = undefined;
        checkVk(core.clibs.vma.MapMemory(allocs.vma, idx_staging_buffer.allocation, &data)) catch @panic("failed to map memory");
        defer core.clibs.vma.UnmapMemory(allocs.vma, idx_staging_buffer.allocation);

        const idx_aligned_data: [*]u32 = @ptrCast(@alignCast(data));
        @memcpy(idx_aligned_data, self.indices.items);
    }

    alloc_data.vertex_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        vert_alloc_size,
        vk.BUFFER_USAGE_VERTEX_BUFFER_BIT | vk.BUFFER_USAGE_TRANSFER_DST_BIT | vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
        core.clibs.vma.MEMORY_USAGE_GPU_ONLY,
        0,
    );
    alloc_data.index_buffer = vma_usage.AllocatedBuffer.create(
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
        .mesh_buffer = alloc_data.vertex_buffer.buffer,
        .staging_buffer = vert_staging_buffer.buffer,
        .size = vert_alloc_size,
    });

    upload_ctx.immediateSubmit(device, SubmitCtx{
        .mesh_buffer = alloc_data.index_buffer.buffer,
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

    alloc_data.metadata = vma_usage.MappedBuffer{
        .allocation = metadata_alloc,
    };

    checkVk(core.clibs.vma.MapMemory(
        allocs.vma,
        metadata_alloc.allocation,
        &alloc_data.metadata.mapped,
    )) catch @panic("Failed to map metadata");

    const aligned_metadata: [*]MetaData = @ptrCast(@alignCast(alloc_data.metadata.mapped));

    @memcpy(aligned_metadata, self.meta_data.items);

    return alloc_data;
}
