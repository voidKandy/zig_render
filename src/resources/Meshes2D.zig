const std = @import("std");
const core = @import("../root.zig");
const vma_usage = core.bindings.vma_usage;
const AllocatedBuffer = vma_usage.AllocatedBuffer;
const checkVk = core.bindings.vulkan_init.checkVk;
const c = core.clibs;
const math_mod = core.lib.math;
const vk = c.vk;
const log = std.log.scoped(.Meshes2D);

pub const MeshRanges = struct {
    vertex: core.lib.mesh.RangeDesc,
    index: core.lib.mesh.RangeDesc,
};

pub const AllocatedData = struct {
    vertex_buffer: vma_usage.AllocatedBuffer,
    index_buffer: vma_usage.AllocatedBuffer,

    pub fn deinit(self: @This(), allocs: core.engine.Allocators) void {
        self.vertex_buffer.deinit(allocs.vma);
        self.index_buffer.deinit(allocs.vma);
    }
};

vertices: std.ArrayList(core.lib.mesh.Vertex2D),
indices: std.ArrayList(u32),
ranges: std.ArrayList(MeshRanges),

mesh_indices: std.StringArrayHashMapUnmanaged(usize) = .empty,
mesh_names_reverse_lookup: std.AutoHashMapUnmanaged(usize, [:0]const u8) = .empty,

pub fn init(a: std.mem.Allocator) std.mem.Allocator.Error!@This() {
    return .{
        .vertices = try std.ArrayList(core.lib.mesh.Vertex2D).initCapacity(a, 64),
        .indices = try std.ArrayList(u32).initCapacity(a, 64),
        .ranges = try std.ArrayList(MeshRanges).initCapacity(a, 16),
    };
}

pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
    self.vertices.deinit(a);
    self.indices.deinit(a);
    self.ranges.deinit(a);
    self.mesh_indices.deinit(a);
    self.mesh_names_reverse_lookup.deinit(a);
}

pub const VERTEX_INPUT_ATTRIBUTE_DESCRIPTIONS = [_]vk.VertexInputAttributeDescription{
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

pub const VERTEX_INPUT_BINDING_DESCRIPTIONS = [_]vk.VertexInputBindingDescription{
    .{
        .binding = 0,
        .stride = @sizeOf(core.lib.mesh.Vertex2D),
        .inputRate = vk.VERTEX_INPUT_RATE_VERTEX,
    },
};

pub fn appendMesh(
    self: *@This(),
    a: std.mem.Allocator,
    name: []const u8,
    mesh: core.lib.mesh.Mesh2D,
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
            .offset = @intCast(self.vertices.items.len),
            .range = @intCast(mesh.vertices.len),
        },
        .index = .{
            .offset = @intCast(self.indices.items.len),
            .range = @intCast(mesh.indices.len),
        },
    };
    try self.vertices.appendSlice(a, mesh.vertices);
    try self.indices.appendSlice(a, mesh.indices);

    try self.ranges.append(a, mesh_range);
}

pub fn upload(
    self: *@This(),
    allocs: core.engine.Allocators,
    upload_ctx: *core.bindings.vulkan_init.UploadContext,
    device: core.bindings.vulkan_init.LogicalDevice,
) AllocatedData {
    var vertex_buffer: vma_usage.AllocatedBuffer = undefined;
    var index_buffer: vma_usage.AllocatedBuffer = undefined;

    const vert_alloc_size = self.vertices.items.len * @sizeOf(core.lib.mesh.Vertex2D);
    const idx_alloc_size = self.indices.items.len * @sizeOf(u32);

    var vert_staging = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        vert_alloc_size,
        vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        core.clibs.vma.MEMORY_USAGE_CPU_ONLY,
        0,
    );
    var idx_staging = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        idx_alloc_size,
        vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        core.clibs.vma.MEMORY_USAGE_CPU_ONLY,
        0,
    );
    defer {
        vert_staging.deinit(allocs.vma);
        idx_staging.deinit(allocs.vma);
    }

    {
        var data: ?*anyopaque = undefined;
        checkVk(core.clibs.vma.MapMemory(allocs.vma, vert_staging.allocation, &data)) catch @panic("failed to map memory");
        const dst: [*]core.lib.mesh.Vertex2D = @ptrCast(@alignCast(data));
        @memcpy(dst, self.vertices.items);
        core.clibs.vma.UnmapMemory(allocs.vma, vert_staging.allocation);

        data = undefined;
        checkVk(core.clibs.vma.MapMemory(allocs.vma, idx_staging.allocation, &data)) catch @panic("failed to map memory");
        const idx_dst: [*]u32 = @ptrCast(@alignCast(data));
        @memcpy(idx_dst, self.indices.items);
        core.clibs.vma.UnmapMemory(allocs.vma, idx_staging.allocation);
    }

    vertex_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        vert_alloc_size,
        vk.BUFFER_USAGE_VERTEX_BUFFER_BIT | vk.BUFFER_USAGE_TRANSFER_DST_BIT,
        core.clibs.vma.MEMORY_USAGE_GPU_ONLY,
        0,
    );
    index_buffer = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        idx_alloc_size,
        vk.BUFFER_USAGE_INDEX_BUFFER_BIT | vk.BUFFER_USAGE_TRANSFER_DST_BIT,
        core.clibs.vma.MEMORY_USAGE_GPU_ONLY,
        0,
    );

    const SubmitCtx = struct {
        src: vk.Buffer,
        dst: vk.Buffer,
        size: usize,
        pub fn submit(ctx: @This(), cmd: vk.CommandBuffer) void {
            vk.CmdCopyBuffer(cmd, ctx.src, ctx.dst, 1, &vk.BufferCopy{ .size = ctx.size });
        }
    };

    upload_ctx.immediateSubmit(device, SubmitCtx{
        .src = vert_staging.buffer,
        .dst = vertex_buffer.buffer,
        .size = vert_alloc_size,
    });
    upload_ctx.immediateSubmit(device, SubmitCtx{
        .src = idx_staging.buffer,
        .dst = index_buffer.buffer,
        .size = idx_alloc_size,
    });

    return .{
        .index_buffer = index_buffer,
        .vertex_buffer = vertex_buffer,
    };
}
