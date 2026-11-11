const std = @import("std");
const core = @import("../root.zig");
const vma_usage = core.bindings.vma_usage;
const AllocatedBuffer = vma_usage.AllocatedBuffer;
const checkVk = core.bindings.vulkan_init.checkVk;
const math_mod = core.lib.math;
const vk = core.clibs.vk;
const log = std.log.scoped(.Meshes3D);
const Vec3 = core.lib.math.Vec3;

pub const MeshRanges = struct {
    vertex: core.lib.mesh.RangeDesc,
    index: core.lib.mesh.RangeDesc,
};

pub const Aabb = struct {
    min: Vec3,
    max: Vec3,

    pub fn empty() Aabb {
        return .{
            .min = .make(std.math.inf(f32), std.math.inf(f32), std.math.inf(f32)),
            .max = .make(-std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32)),
        };
    }

    pub fn isEmpty(self: @This()) bool {
        return self.min.x > self.max.x;
    }

    pub fn expand(self: *Aabb, p: Vec3) void {
        self.min.x = @min(self.min.x, p.x);
        self.min.y = @min(self.min.y, p.y);
        self.min.z = @min(self.min.z, p.z);
        self.max.x = @max(self.max.x, p.x);
        self.max.y = @max(self.max.y, p.y);
        self.max.z = @max(self.max.z, p.z);
    }

    /// Returns corners in order shown below
    ///     7------6
    ///    /|     /|
    ///   4------5 |
    ///   | |    | |
    ///   | 3----|-2
    ///   |/     |/
    ///   0------1
    ///
    pub fn corners(self: Aabb) [8]Vec3 {
        return .{
            Vec3.make(self.min.x, self.min.y, self.min.z), // 0
            Vec3.make(self.max.x, self.min.y, self.min.z), // 1
            Vec3.make(self.max.x, self.max.y, self.min.z), // 2
            Vec3.make(self.min.x, self.max.y, self.min.z), // 3

            Vec3.make(self.min.x, self.min.y, self.max.z), // 4
            Vec3.make(self.max.x, self.min.y, self.max.z), // 5
            Vec3.make(self.max.x, self.max.y, self.max.z), // 6
            Vec3.make(self.min.x, self.max.y, self.max.z), // 7
        };
    }

    pub fn diagonal(self: Aabb) f32 {
        return self.max.sub(self.min).norm();
    }

    pub fn merge(a: Aabb, b: Aabb) Aabb {
        return .{
            .min = .{
                @min(a.min.x, b.min.x),
                @min(a.min.y, b.min.y),
                @min(a.min.z, b.min.z),
            },
            .max = .{
                @max(a.max.x, b.max.x),
                @max(a.max.y, b.max.y),
                @max(a.max.z, b.max.z),
            },
        };
    }

    pub fn fromVertices(verts: []const core.lib.mesh.Vertex3D) Aabb {
        var box = Aabb.empty();
        for (verts) |v| box.expand(.make(
            v.position.x,
            v.position.y,
            v.position.z,
        ));
        return box;
    }

    pub fn center(self: Aabb) Vec3 {
        return .make(
            (self.min.x + self.max.x) * 0.5,
            (self.min.y + self.max.y) * 0.5,
            (self.min.z + self.max.z) * 0.5,
        );
    }

    pub fn extents(self: Aabb) Vec3 {
        return .make(
            (self.max.x - self.min.x) * 0.5,
            (self.max.y - self.min.y) * 0.5,
            (self.max.z - self.min.z) * 0.5,
        );
    }

    /// Transforms this object-space AABB by a 4x4 column-major matrix and
    /// returns a new world-space AABB. Uses the standard Arvo/Graphics-Gems
    /// trick: transform center+extents by the matrix's rotation/scale part
    /// (taking abs of each element) rather than transforming all 8 corners,
    /// which is both cheaper and always tight for an axis-aligned result.
    /// `m` is expected as 4 columns of 4 floats (mat[col][row]), matching
    /// typical Vulkan/GLM-style column-major layout — adjust indexing if
    /// your math_mod.Mat4 stores row-major instead.
    pub fn transform(self: Aabb, m: [4][4]f32) Aabb {
        const c = self.center();
        const e = self.extents();

        var new_center: Vec3 = undefined;
        var new_extents: Vec3 = .ZERO;

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

pub const Bindings = enum {
    index,
    vertex,
};

pub const AllocatedData = struct {
    vertex_buffer: vma_usage.AllocatedBuffer,
    index_buffer: vma_usage.AllocatedBuffer,
    descriptor_set: vk.DescriptorSet,

    pub fn deinit(
        self: @This(),
        allocs: core.engine.Allocators,
    ) void {
        self.index_buffer.deinit(allocs.vma);
        self.vertex_buffer.deinit(allocs.vma);
    }

    pub fn updateDescriptorSet(
        self: @This(),
        device: vk.Device,
    ) std.mem.Allocator.Error!void {
        const infos = [_]struct { Bindings, vk.DescriptorBufferInfo }{
            .{
                Bindings.index,
                .{
                    .buffer = self.index_buffer.buffer,
                    .offset = 0,
                    .range = self.index_buffer.size,
                },
            },
            .{
                Bindings.vertex,
                .{
                    .buffer = self.vertex_buffer.buffer,
                    .offset = 0,
                    .range = self.vertex_buffer.size,
                },
            },
        };

        var writes: [2]vk.WriteDescriptorSet = undefined;

        for (&writes, 0..) |*write, i| {
            const binding = infos[i].@"0";
            write.* = .{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = self.descriptor_set,
                .dstBinding = @backingInt(binding),
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pBufferInfo = &infos[i].@"1",
            };
        }

        vk.UpdateDescriptorSets(
            device,
            @as(u32, @intCast(writes.len)),
            &writes,
            0,
            null,
        );
    }
};

vertices: std.ArrayList(core.lib.mesh.Vertex3D),
indices: std.ArrayList(u32),
ranges: std.ArrayList(MeshRanges),
bounds: std.ArrayList(Aabb),

mesh_indices: std.StringArrayHashMapUnmanaged(usize) = .empty,
mesh_names_reverse_lookup: std.AutoHashMapUnmanaged(usize, [:0]const u8) = .empty,

descriptor_set_layout: vk.DescriptorSetLayout = undefined,

pub fn init(a: std.mem.Allocator) std.mem.Allocator.Error!@This() {
    return .{
        .vertices = try std.ArrayList(core.lib.mesh.Vertex3D).initCapacity(a, 64),
        .indices = try std.ArrayList(u32).initCapacity(a, 64),
        .ranges = try std.ArrayList(MeshRanges).initCapacity(a, 16),
        .bounds = try std.ArrayList(Aabb).initCapacity(a, 16),
    };
}

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
    raw_mesh: core.lib.mesh.Mesh3D,
) std.mem.Allocator.Error!void {
    const mesh = try core.lib.alpha_wrapping.wrapMesh3D(a, raw_mesh);
    const verts = mesh.vertices;
    const bounds = Aabb.fromVertices(verts);

    const idx = self.ranges.items.len;
    try self.mesh_indices.put(a, name, idx);

    const zname = try a.dupeSentinel(u8, name, 0);
    try self.mesh_names_reverse_lookup.put(a, idx, zname);

    const mesh_range = MeshRanges{
        .vertex = .{
            .offset = @as(u32, @intCast(self.vertices.items.len)),
            .range = @as(u32, @intCast(verts.len)),
        },
        .index = .{
            .offset = @as(u32, @intCast(self.indices.items.len)),
            .range = @as(u32, @intCast(mesh.indices.len)),
        },
    };
    var min: u32 = std.math.maxInt(u32);
    var max: u32 = 0;

    for (mesh.indices) |index| {
        min = @min(min, index);
        max = @max(max, index);
    }

    log.debug(
        "mesh '{s}'={} vertex_count={} index_count={} index_min={} index_max={}",
        .{ name, idx, verts.len, mesh.indices.len, min, max },
    );

    try self.vertices.appendSlice(a, verts);
    try self.indices.appendSlice(a, mesh.indices);
    try self.ranges.append(a, mesh_range);
    try self.bounds.append(a, bounds);
}

pub fn createDescriptorSetLayout(
    self: *@This(),
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const layout_bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = @backingInt(Bindings.index),
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        },
        .{
            .binding = @backingInt(Bindings.vertex),
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

    const vert_alloc_size, const idx_alloc_size = .{
        self.vertices.items.len * @sizeOf(core.lib.mesh.Vertex3D),
        self.indices.items.len * @sizeOf(u32),
    };

    var idx_staging_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        idx_alloc_size,
        vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        core.clibs.vma.MEMORY_USAGE_CPU_ONLY,
        0,
    );

    var vert_staging_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        vert_alloc_size,
        vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        core.clibs.vma.MEMORY_USAGE_CPU_ONLY,
        0,
    );

    defer {
        idx_staging_buffer.deinit(allocs.vma);
        vert_staging_buffer.deinit(allocs.vma);
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

    const gpu_usage =
        vk.BUFFER_USAGE_TRANSFER_DST_BIT |
        vk.BUFFER_USAGE_STORAGE_BUFFER_BIT;

    vertex_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        vert_alloc_size,
        vk.BUFFER_USAGE_VERTEX_BUFFER_BIT | gpu_usage,
        core.clibs.vma.MEMORY_USAGE_GPU_ONLY,
        0,
    );
    index_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        idx_alloc_size,
        vk.BUFFER_USAGE_INDEX_BUFFER_BIT | gpu_usage,
        core.clibs.vma.MEMORY_USAGE_GPU_ONLY,
        0,
    );

    const Copy =
        struct {
            src: vk.Buffer,
            dst: vk.Buffer,
            size: usize,

            pub fn submit(ctx: @This(), cmd: vk.CommandBuffer) void {
                const region = vk.BufferCopy{
                    .size = ctx.size,
                };
                vk.CmdCopyBuffer(cmd, ctx.src, ctx.dst, 1, &region);
            }
        };

    const copies = [_]Copy{
        .{
            .src = vert_staging_buffer.buffer,
            .dst = vertex_buffer.buffer,
            .size = vert_alloc_size,
        },

        .{
            .src = idx_staging_buffer.buffer,
            .dst = index_buffer.buffer,
            .size = idx_alloc_size,
        },
    };

    for (copies) |copy| {
        upload_ctx.immediateSubmit(device, copy);
    }

    var desc_set: vk.DescriptorSet = undefined;

    const ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.descriptor_set_layout,
    };

    checkVk(vk.AllocateDescriptorSets(device.handle, &ai, &desc_set)) catch @panic("failed to allocate descriptor set");

    return .{
        .index_buffer = index_buffer,
        .vertex_buffer = vertex_buffer,
        .descriptor_set = desc_set,
    };
}
