const std = @import("std");
const core = @import("../root.zig");
const vma_usage = core.bindings.vma_usage;
const AllocatedBuffer = vma_usage.AllocatedBuffer;
const checkVk = core.bindings.vulkan_init.checkVk;
const c = core.clibs;
const math_mod = core.lib.math;
const vk = c.vk;
const log = std.log.scoped(.Meshes2D);

pub const MetaData = extern struct {
    material_index: u32,
    _pad0: u32 = 0,
    screen_coordinates: core.lib.math.Vec2,
};

pub const MeshRanges = struct {
    vertex: core.lib.mesh.RangeDesc,
    index: core.lib.mesh.RangeDesc,
};

pub const AllocatedData = struct {
    vertex_buffer: vma_usage.AllocatedBuffer,
    index_buffer: vma_usage.AllocatedBuffer,
    metadata: vma_usage.MappedBuffer,
    descriptor_set: vk.DescriptorSet,

    pub fn deinit(self: @This(), allocs: core.engine.Allocators) void {
        self.vertex_buffer.deinit(allocs.vma);
        self.index_buffer.deinit(allocs.vma);
        self.metadata.deinit(allocs.vma);
    }

    pub fn updateDescriptorSet(
        self: @This(),
        device: vk.Device,
        binding: u32,
    ) std.mem.Allocator.Error!void {
        const metadata_buffer_info = vk.DescriptorBufferInfo{
            .buffer = self.metadata.allocation.buffer,
            .offset = 0,
            .range = vk.WHOLE_SIZE,
        };

        const writes = [_]vk.WriteDescriptorSet{
            .{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = self.descriptor_set,
                .dstBinding = binding,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pBufferInfo = &metadata_buffer_info,
            },
        };

        vk.UpdateDescriptorSets(device, writes.len, &writes, 0, null);
    }
};

vertices: std.ArrayList(core.lib.mesh.Vertex2D),
indices: std.ArrayList(u32),
meta_data: std.ArrayList(MetaData),
ranges: std.ArrayList(MeshRanges),
amt_meshes: usize = 0,

descriptor_set_layout: vk.DescriptorSetLayout = undefined,

pub fn init(a: std.mem.Allocator) std.mem.Allocator.Error!@This() {
    return .{
        .vertices = try std.ArrayList(core.lib.mesh.Vertex2D).initCapacity(a, 64),
        .indices = try std.ArrayList(u32).initCapacity(a, 64),
        .meta_data = try std.ArrayList(MetaData).initCapacity(a, 16),
        .ranges = try std.ArrayList(MeshRanges).initCapacity(a, 16),
    };
}

pub fn deinit(self: *@This(), a: std.mem.Allocator, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    self.vertices.deinit(a);
    self.indices.deinit(a);
    self.meta_data.deinit(a);
    self.ranges.deinit(a);
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
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

pub fn createDescriptorSetLayout(
    self: *@This(),
    binding: u32,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const bindings = &[_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = binding,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        },
    };

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = @as(u32, @intCast(bindings.len)),
        .pBindings = bindings.ptr,
    };

    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.descriptor_set_layout)) catch
        @panic("failed to create main compute descriptor set layout");
}

pub fn appendMesh(
    self: *@This(),
    a: std.mem.Allocator,
    mesh: core.lib.mesh.Mesh2D,
    screen_coordinates: core.lib.math.Vec2,
    material_index: u32,
) std.mem.Allocator.Error!void {
    defer self.amt_meshes += 1;
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
    // indices need to be offset by the current vertex count
    const vertex_offset: u32 = mesh_range.vertex.offset;
    for (mesh.indices) |idx| {
        try self.indices.append(a, idx + vertex_offset);
    }
    try self.meta_data.append(a, .{
        .material_index = material_index,
        .screen_coordinates = screen_coordinates,
    });
    try self.ranges.append(a, mesh_range);
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
    var descriptor_set: vk.DescriptorSet = undefined;

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

    const metadata_alloc = vma_usage.AllocatedBuffer.create(
        allocs.vma,
        @sizeOf(MetaData) * self.amt_meshes,
        vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
        core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
        0,
    );
    metadata = .{ .allocation = metadata_alloc };
    checkVk(core.clibs.vma.MapMemory(
        allocs.vma,
        metadata_alloc.allocation,
        &metadata.mapped,
    )) catch @panic("Failed to map metadata");
    const aligned: [*]MetaData = @ptrCast(@alignCast(metadata.mapped));
    @memcpy(aligned, self.meta_data.items);

    const desc_ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.descriptor_set_layout,
    };
    checkVk(vk.AllocateDescriptorSets(device.handle, &desc_ai, &descriptor_set)) catch
        @panic("failed to allocate main compute descriptor set");

    return .{
        .descriptor_set = descriptor_set,
        .index_buffer = index_buffer,
        .metadata = metadata,
        .vertex_buffer = vertex_buffer,
    };
}
