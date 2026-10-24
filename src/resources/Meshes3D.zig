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

pub const Bindings = enum(u32) {
    index = 0,
    position = 1,
    uv = 2,
    normal = 3,
    albedo = 4,
};

pub const AllocatedData = struct {
    positions_buffer: vma_usage.AllocatedBuffer,
    uvs_buffer: vma_usage.AllocatedBuffer,
    normals_buffer: vma_usage.AllocatedBuffer,
    albedo_buffer: vma_usage.AllocatedBuffer,

    index_buffer: vma_usage.AllocatedBuffer,
    descriptor_set: vk.DescriptorSet,

    pub fn deinit(
        self: @This(),
        allocs: core.engine.Allocators,
    ) void {
        self.positions_buffer.deinit(allocs.vma);
        self.uvs_buffer.deinit(allocs.vma);
        self.normals_buffer.deinit(allocs.vma);
        self.albedo_buffer.deinit(allocs.vma);
        self.index_buffer.deinit(allocs.vma);
    }

    pub fn updateDescriptorSet(
        self: @This(),
        device: vk.Device,
    ) std.mem.Allocator.Error!void {
        const infos = [_]struct { Bindings, vk.DescriptorBufferInfo }{
            .{ Bindings.index, .{
                .buffer = self.index_buffer.buffer,
                .offset = 0,
                .range = self.index_buffer.size,
            } },
            .{ Bindings.position, .{
                .buffer = self.positions_buffer.buffer,
                .offset = 0,
                .range = self.positions_buffer.size,
            } },
            .{ Bindings.uv, .{
                .buffer = self.uvs_buffer.buffer,
                .offset = 0,
                .range = self.uvs_buffer.size,
            } },
            .{ Bindings.normal, .{
                .buffer = self.normals_buffer.buffer,
                .offset = 0,
                .range = self.normals_buffer.size,
            } },
            .{ Bindings.albedo, .{
                .buffer = self.albedo_buffer.buffer,
                .offset = 0,
                .range = self.albedo_buffer.size,
            } },
        };

        var writes: [5]vk.WriteDescriptorSet = undefined;

        for (&writes, 0..) |*write, i| {
            const binding = infos[i].@"0";
            write.* = .{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = self.descriptor_set,
                .dstBinding = @intFromEnum(binding),
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
    mesh: core.lib.mesh.Mesh3D,
) std.mem.Allocator.Error!void {
    defer log.debug(
        \\ added mesh: '{s}'
    , .{name});

    const verts = mesh.vertices;
    const bounds = Aabb.fromVertices(verts);

    const idx = self.ranges.items.len;
    try self.mesh_indices.put(a, name, idx);

    const zname = try a.dupeZ(u8, name);
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
            .binding = @intFromEnum(Bindings.position),
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        },
        .{
            .binding = @intFromEnum(Bindings.uv),
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        },
        .{
            .binding = @intFromEnum(Bindings.normal),
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        },
        .{
            .binding = @intFromEnum(Bindings.albedo),
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        },
        .{
            .binding = @intFromEnum(Bindings.index),
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

const VertexData = struct {
    positions: []core.lib.math.Vec4,
    uvs: []core.lib.math.Vec2,
    normals: []core.lib.math.Vec4,
    albedos: []core.lib.math.Vec4,
};

fn prepareVertexData(
    self: *const @This(),
    a: std.mem.Allocator,
) std.mem.Allocator.Error!VertexData {
    var dat = VertexData{
        .positions = try a.alloc(core.lib.math.Vec4, self.vertices.items.len),
        .uvs = try a.alloc(core.lib.math.Vec2, self.vertices.items.len),
        .normals = try a.alloc(core.lib.math.Vec4, self.vertices.items.len),
        .albedos = try a.alloc(core.lib.math.Vec4, self.vertices.items.len),
    };

    for (self.vertices.items, 0..) |vertex, i| {
        dat.positions[i] = vertex.position;
        dat.uvs[i] = vertex.uv;
        dat.normals[i] = vertex.normal;
        dat.albedos[i] = vertex.color;
    }

    return dat;
}

pub fn upload(
    self: *@This(),
    allocs: core.engine.Allocators,
    pool: vk.DescriptorPool,
    upload_ctx: *core.bindings.vulkan_init.UploadContext,
    device: core.bindings.vulkan_init.LogicalDevice,
) AllocatedData {
    const vrt_data = self.prepareVertexData(allocs.std) catch @panic("failed to prepare vertex data");
    defer {
        allocs.std.free(vrt_data.positions);
        allocs.std.free(vrt_data.uvs);
        allocs.std.free(vrt_data.normals);
        allocs.std.free(vrt_data.albedos);
    }

    const index_size = self.indices.items.len * @sizeOf(u32);

    const vertex_count = self.vertices.items.len;
    const position_size = vertex_count * @sizeOf(core.lib.math.Vec4);
    const uv_size = vertex_count * @sizeOf(core.lib.math.Vec2);
    const normal_size = vertex_count * @sizeOf(core.lib.math.Vec4);
    const albedo_size = vertex_count * @sizeOf(core.lib.math.Vec4);

    const position_offset: usize = 0;
    const uv_offset = position_offset + position_size;
    const normal_offset = uv_offset + uv_size;
    const albedo_offset = normal_offset + normal_size;
    const total_size = albedo_offset + albedo_size;

    var idx_staging_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        index_size,
        vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        core.clibs.vma.MEMORY_USAGE_CPU_ONLY,
        0,
    );

    var vert_staging_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        total_size,
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
        var mapped: ?*anyopaque = null;
        checkVk(core.clibs.vma.MapMemory(allocs.vma, vert_staging_buffer.allocation, &mapped)) catch @panic("failed to map vertex staging");

        const bytes: [*]u8 = @ptrCast(mapped.?);

        @memcpy(bytes[position_offset..][0..position_size], std.mem.sliceAsBytes(vrt_data.positions));
        @memcpy(bytes[uv_offset..][0..uv_size], std.mem.sliceAsBytes(vrt_data.uvs));
        @memcpy(bytes[normal_offset..][0..normal_size], std.mem.sliceAsBytes(vrt_data.normals));
        @memcpy(bytes[albedo_offset..][0..albedo_size], std.mem.sliceAsBytes(vrt_data.albedos));

        core.clibs.vma.UnmapMemory(allocs.vma, vert_staging_buffer.allocation);

        mapped = null;
        checkVk(core.clibs.vma.MapMemory(allocs.vma, idx_staging_buffer.allocation, &mapped)) catch @panic("failed to map index staging");
        const indices: [*]u32 = @ptrCast(@alignCast(mapped.?));
        @memcpy(indices[0..self.indices.items.len], self.indices.items);
        core.clibs.vma.UnmapMemory(allocs.vma, idx_staging_buffer.allocation);
    }

    const gpu_usage =
        vk.BUFFER_USAGE_TRANSFER_DST_BIT |
        vk.BUFFER_USAGE_STORAGE_BUFFER_BIT;

    const index_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        index_size,
        gpu_usage,
        core.clibs.vma.MEMORY_USAGE_GPU_ONLY,
        0,
    );

    const positions_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        position_size,
        gpu_usage,
        core.clibs.vma.MEMORY_USAGE_GPU_ONLY,
        0,
    );
    const uvs_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        uv_size,
        gpu_usage,
        core.clibs.vma.MEMORY_USAGE_GPU_ONLY,
        0,
    );
    const normals_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        normal_size,
        gpu_usage,
        core.clibs.vma.MEMORY_USAGE_GPU_ONLY,
        0,
    );
    const albedo_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        albedo_size,
        gpu_usage,
        core.clibs.vma.MEMORY_USAGE_GPU_ONLY,
        0,
    );

    const Copy = struct {
        src: vk.Buffer,
        dst: vk.Buffer,
        src_offset: usize,
        size: usize,

        pub fn submit(ctx: @This(), cmd: vk.CommandBuffer) void {
            const region = vk.BufferCopy{
                .srcOffset = ctx.src_offset,
                .dstOffset = 0,
                .size = ctx.size,
            };
            vk.CmdCopyBuffer(cmd, ctx.src, ctx.dst, 1, &region);
        }
    };

    const copies = [_]Copy{
        .{
            .src = vert_staging_buffer.buffer,
            .dst = positions_buffer.buffer,
            .src_offset = position_offset,
            .size = position_size,
        },
        .{
            .src = vert_staging_buffer.buffer,
            .dst = uvs_buffer.buffer,
            .src_offset = uv_offset,
            .size = uv_size,
        },
        .{
            .src = vert_staging_buffer.buffer,
            .dst = normals_buffer.buffer,
            .src_offset = normal_offset,
            .size = normal_size,
        },
        .{
            .src = vert_staging_buffer.buffer,
            .dst = albedo_buffer.buffer,
            .src_offset = albedo_offset,
            .size = albedo_size,
        },
        .{
            .src = idx_staging_buffer.buffer,
            .dst = index_buffer.buffer,
            .src_offset = 0,
            .size = index_size,
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
        .positions_buffer = positions_buffer,
        .uvs_buffer = uvs_buffer,
        .normals_buffer = normals_buffer,
        .albedo_buffer = albedo_buffer,
        .index_buffer = index_buffer,
        .descriptor_set = desc_set,
    };
}
