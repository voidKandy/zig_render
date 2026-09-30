const std = @import("std");
const core = @import("../root.zig");
const vma_usage = core.bindings.vma_usage;
const AllocatedBuffer = vma_usage.AllocatedBuffer;
const checkVk = core.bindings.vulkan_init.checkVk;
const math_mod = core.lib.math;
const vk = core.clibs.vk;
const log = std.log.scoped(.Meshes3D);

pub const MeshRanges = struct {
    vertex: core.lib.mesh.RangeDesc,
    index: core.lib.mesh.RangeDesc,
};

pub const Aabb3D = struct {
    min: [3]f32,
    max: [3]f32,

    pub fn empty() Aabb3D {
        return .{
            .min = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) },
            .max = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) },
        };
    }

    pub fn expand(self: *Aabb3D, p: [3]f32) void {
        self.min[0] = @min(self.min[0], p[0]);
        self.min[1] = @min(self.min[1], p[1]);
        self.min[2] = @min(self.min[2], p[2]);
        self.max[0] = @max(self.max[0], p[0]);
        self.max[1] = @max(self.max[1], p[1]);
        self.max[2] = @max(self.max[2], p[2]);
    }

    pub fn merge(a: Aabb3D, b: Aabb3D) Aabb3D {
        return .{
            .min = .{ @min(a.min[0], b.min[0]), @min(a.min[1], b.min[1]), @min(a.min[2], b.min[2]) },
            .max = .{ @max(a.max[0], b.max[0]), @max(a.max[1], b.max[1]), @max(a.max[2], b.max[2]) },
        };
    }

    pub fn fromVertices(verts: []const core.lib.mesh.Vertex3D) Aabb3D {
        var box = Aabb3D.empty();
        for (verts) |v| box.expand([3]f32{
            v.position.x,
            v.position.y,
            v.position.z,
        });
        return box;
    }

    pub fn center(self: Aabb3D) [3]f32 {
        return .{
            (self.min[0] + self.max[0]) * 0.5,
            (self.min[1] + self.max[1]) * 0.5,
            (self.min[2] + self.max[2]) * 0.5,
        };
    }

    pub fn extents(self: Aabb3D) [3]f32 {
        return .{
            (self.max[0] - self.min[0]) * 0.5,
            (self.max[1] - self.min[1]) * 0.5,
            (self.max[2] - self.min[2]) * 0.5,
        };
    }

    /// Transforms this object-space AABB by a 4x4 column-major matrix and
    /// returns a new world-space AABB. Uses the standard Arvo/Graphics-Gems
    /// trick: transform center+extents by the matrix's rotation/scale part
    /// (taking abs of each element) rather than transforming all 8 corners,
    /// which is both cheaper and always tight for an axis-aligned result.
    /// `m` is expected as 4 columns of 4 floats (mat[col][row]), matching
    /// typical Vulkan/GLM-style column-major layout — adjust indexing if
    /// your math_mod.Mat4 stores row-major instead.
    pub fn transform(self: Aabb3D, m: [4][4]f32) Aabb3D {
        const c = self.center();
        const e = self.extents();

        var new_center: [3]f32 = undefined;
        var new_extents: [3]f32 = .{ 0, 0, 0 };

        inline for (0..3) |row| {
            new_center[row] = m[3][row]; // translation column
            inline for (0..3) |col| {
                new_center[row] += m[col][row] * c[col];
                new_extents[row] += @abs(m[col][row]) * e[col];
            }
        }

        return .{
            .min = .{
                new_center[0] - new_extents[0],
                new_center[1] - new_extents[1],
                new_center[2] - new_extents[2],
            },
            .max = .{
                new_center[0] + new_extents[0],
                new_center[1] + new_extents[1],
                new_center[2] + new_extents[2],
            },
        };
    }
};

pub const Bindings = struct {
    vertex: u32,
    index: u32,
};

pub const DEFAULT_BINDINGS = Bindings{
    .vertex = 0,
    .index = 1,
};

pub const AllocatedData = struct {
    vertex_buffer: vma_usage.AllocatedBuffer,
    index_buffer: vma_usage.AllocatedBuffer,
    descriptor_set: vk.DescriptorSet,

    pub fn deinit(
        self: @This(),
        allocs: core.engine.Allocators,
    ) void {
        self.vertex_buffer.deinit(allocs.vma);
        self.index_buffer.deinit(allocs.vma);
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
ranges: std.ArrayList(MeshRanges),
bounds: std.ArrayList(Aabb3D),

mesh_indices: std.StringArrayHashMapUnmanaged(usize) = .empty,
mesh_names_reverse_lookup: std.AutoHashMapUnmanaged(usize, [:0]const u8) = .empty,

descriptor_set_layout: vk.DescriptorSetLayout = undefined,

pub fn init(a: std.mem.Allocator) std.mem.Allocator.Error!@This() {
    return .{
        .vertices = try std.ArrayList(core.lib.mesh.Vertex3D).initCapacity(a, 64),
        .indices = try std.ArrayList(u32).initCapacity(a, 64),
        .ranges = try std.ArrayList(MeshRanges).initCapacity(a, 16),
        .bounds = try std.ArrayList(Aabb3D).initCapacity(a, 16),
    };
}

/// passes ownership to allocated data
pub fn deinit(self: *@This(), a: std.mem.Allocator, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    self.vertices.deinit(a);
    self.indices.deinit(a);
    self.ranges.deinit(a);
    self.bounds.deinit(a);
    self.mesh_indices.deinit(a);
    self.mesh_names_reverse_lookup.deinit(a);
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
}

pub fn appendMesh(
    self: *@This(),
    a: std.mem.Allocator,
    name: []const u8,
    mesh: core.lib.mesh.Mesh3D,
) std.mem.Allocator.Error!void {
    defer log.debug(
        \\ added mesh: '{s}'
    , .{name});
    const idx = self.ranges.items.len;
    try self.mesh_indices.put(a, name, idx);

    const zname = try a.dupeZ(u8, name);
    try self.mesh_names_reverse_lookup.put(a, idx, zname);

    const mesh_range = MeshRanges{
        .vertex = .{
            .offset = @as(u32, @intCast(self.vertices.items.len)),
            .range = @as(u32, @intCast(mesh.vertices.len)),
        },
        .index = .{
            .offset = @as(u32, @intCast(self.indices.items.len)),
            .range = @as(u32, @intCast(mesh.indices.len)),
        },
    };

    try self.vertices.appendSlice(a, mesh.vertices);
    try self.indices.appendSlice(a, mesh.indices);
    try self.ranges.append(a, mesh_range);
    try self.bounds.append(a, Aabb3D.fromVertices(mesh.vertices));
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
        .vertex_buffer = vertex_buffer,
        .descriptor_set = desc_set,
    };
}
