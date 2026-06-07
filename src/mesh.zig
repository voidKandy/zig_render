const std = @import("std");
const core = @import("root.zig");
const vma_usage = core.vma_usage;
const AllocatedBuffer = vma_usage.AllocatedBuffer;
const checkVk = core.vulkan_init.checkVk;
const m3d = @import("math3d.zig");
const c = @import("clibs.zig");
const vk = c.vk;
const log = std.log.scoped(.mesh);

const Vec2 = m3d.Vec2;
const Vec3 = m3d.Vec3;
const Vec4 = m3d.Vec4;

pub const VertexInputDescription = struct {
    bindings: []const c.vk.VertexInputBindingDescription,
    attributes: []const c.vk.VertexInputAttributeDescription,

    flags: c.vk.PipelineVertexInputStateCreateFlags = 0,
};

pub const Vertex3D = extern struct {
    position: Vec4,
    normal: Vec4,
    color: Vec4,
    uv: Vec2,
    _: Vec2 = .ZERO,
};

/// i dont know where this should live
pub const RangeDesc = struct {
    offset: u32,
    range: u32,
};

pub const Mesh3D = struct {
    vertices: []Vertex3D,
    indices: []u32,

    pub const Buffers = struct {
        vertex: vma_usage.AllocatedBuffer = undefined,
        index: vma_usage.AllocatedBuffer = undefined,
    };

    /// vertex & index buffers are not present until `upload` method is called
    // vertex_buffer: AllocatedBuffer = undefined,
    // index_buffer: AllocatedBuffer = undefined,
    const Self = @This();

    pub fn init(a: std.mem.Allocator, vertices: []const Vertex3D, indices: []const u32) std.mem.Allocator.Error!Self {
        return .{
            .vertices = try a.dupe(Vertex3D, vertices),
            .indices = try a.dupe(u32, indices),
        };
    }

    const Vertex3DHash = struct {
        pub fn hash(cx: @This(), vertex: Vertex3D) u64 {
            _ = cx;
            var h: u64 = 0;
            for (std.mem.asBytes(&vertex)) |byte| {
                h = h *% 31 +% byte;
            }
            return h;
        }

        pub fn eql(cx: @This(), a: Vertex3D, b: Vertex3D) bool {
            _ = cx;
            return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
        }
    };

    pub fn fromObjFile(a: std.mem.Allocator, obj_file: core.obj_loader.ObjFile) std.mem.Allocator.Error!Self {
        if (obj_file.objects.len == 0) @panic("tried to turn an empty object into a mesh");
        if (obj_file.objects.len > 1) for (obj_file.objects) |object| {
            log.warn("multiple objects in obj file not implemented!: {s}", .{object.name});
            unreachable;
        };

        var indices = try std.ArrayList(u32).initCapacity(a, obj_file.vertices.len);
        var vertices = try std.ArrayList(Vertex3D).initCapacity(a, obj_file.vertices.len);
        var uniques = std.HashMap(
            Vertex3D,
            u32,
            Vertex3DHash,
            std.hash_map.default_max_load_percentage,
        ).init(a);
        defer uniques.deinit();
        var current_vert_idx: u32 = 0;
        const object = obj_file.objects[0];
        var face_base_idx: usize = 0;
        for (object.face_vertices) |face_vert_count| {
            if (face_vert_count == 2) {
                // line element
                for (0..2) |i| {
                    const idx = object.indices[face_base_idx + i];
                    const pos = obj_file.vertices[idx.vertex];
                    const vertex = Vertex3D{
                        .position = Vec4.make(pos[0], pos[1], pos[2], 0.0),
                        .uv = Vec2.ZERO,
                        .normal = Vec4.ZERO,
                        .color = Vec4.ZERO,
                    };
                    const entry = try uniques.getOrPut(vertex);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = current_vert_idx;
                        try vertices.append(a, vertex);
                        current_vert_idx += 1;
                    }
                    try indices.append(a, entry.value_ptr.*);
                }
            } else {
                // triangle fan
                for (0..face_vert_count - 2) |i| {
                    const tri_indices = [3]usize{
                        face_base_idx,
                        face_base_idx + i + 1,
                        face_base_idx + i + 2,
                    };
                    for (tri_indices) |fi| {
                        const idx = object.indices[fi];
                        var uv = Vec2.fromSizedArray(obj_file.uvs[idx.uv]);
                        uv.y = 1.0 - uv.y;
                        const pos = obj_file.vertices[idx.vertex];
                        const norm = obj_file.normals[idx.normal];
                        const vertex = Vertex3D{
                            .position = Vec4.make(pos[0], pos[1], pos[2], 0.0),
                            .uv = uv,
                            .normal = Vec4.make(norm[0], norm[1], norm[2], 0.0),
                            .color = Vec4.ZERO,
                        };
                        const entry = try uniques.getOrPut(vertex);
                        if (!entry.found_existing) {
                            entry.value_ptr.* = current_vert_idx;
                            try vertices.append(a, vertex);
                            current_vert_idx += 1;
                        }
                        try indices.append(a, entry.value_ptr.*);
                    }
                }
            }
            face_base_idx += face_vert_count;
        }
        return .{
            .vertices = try vertices.toOwnedSlice(a),
            .indices = try indices.toOwnedSlice(a),
        };
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
    }
};

pub const Meshes = struct {
    pub const MetaData = extern struct {
        material_index: u32,
        index_offset: u32,
        index_count: u32,
        vertex_offset: u32,
        model_transform: core.math.Mat4,
    };

    pub const MeshRanges = struct {
        vertex: RangeDesc,
        index: RangeDesc,
        metadata: RangeDesc,
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

    vertices: std.ArrayList(Vertex3D),
    indices: std.ArrayList(u32),
    meta_data: std.ArrayList(MetaData),
    ranges: std.ArrayList(MeshRanges),
    amt_meshes: usize = 0,

    pub fn init(a: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return .{
            .vertices = try std.ArrayList(Vertex3D).initCapacity(a, 64),
            .indices = try std.ArrayList(u32).initCapacity(a, 64),
            .meta_data = try std.ArrayList(MetaData).initCapacity(a, 16),
            .ranges = try std.ArrayList(MeshRanges).initCapacity(a, 16),
        };
    }

    /// DOES NOT FREE RANGES
    /// passes ownership to allocated data
    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        self.vertices.deinit(a);
        self.indices.deinit(a);
        self.meta_data.deinit(a);
    }

    pub fn appendMesh(
        self: *@This(),
        a: std.mem.Allocator,
        mesh: Mesh3D,
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
        try self.ranges.append(a, mesh_range);
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
};
