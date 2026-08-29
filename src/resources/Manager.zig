const std = @import("std");
const core = @import("../root.zig");
const vk = core.clibs.vk;
const checkVk = core.bindings.vulkan_init.checkVk;
const Materials = @import("Materials.zig");
const Meshes2D = @import("Meshes2D.zig");
const Meshes3D = @import("Meshes3D.zig");

// TODO
// currently mesh create infos utilize direct material index
//
// This is not ideal because upon creation of meshes these material
// indexes cannot be reliably known
// instead some way of referencing materials should be created
// likely by human readable name
// remember, there needs to be a way to know whether to look for a
// material in a library or just in the flat textures map

pub const Mesh3DCreateInfo = struct {
    create_mesh: union(enum) {
        obj: core.loaders.obj.ObjFile,
        info: struct {
            mesh: core.lib.mesh.Mesh3D,
            material_idx: u32,
        },
    },
    transform: core.lib.math.Mat4 = .IDENTITY,
};

pub const Mesh2DCreateInfo = struct {
    mesh: core.lib.mesh.Mesh2D,
    material_index: u32,
    screen_coordinates: core.lib.math.Vec2,
};

pub const CreateInfo = struct {
    materials_files: ?[]const core.loaders.mtl.MtlFile,
    texture_creates: ?[]const struct { []const u8, Materials.CreateTextureEntry },
    meshes2D: ?[]const Mesh2DCreateInfo,
    meshes3D: ?[]const Mesh3DCreateInfo,
    mapped_buffer_creates: ?[]const struct { []const u8, MappedBufferCreate },
};

// this might be better it its own submodule
pub const MappedBufferCreate = struct {
    alloc_size: usize,
    buffer_usage: core.clibs.vk.BufferUsageFlags,
    mem_usage: core.clibs.vma.MemoryUsage,
    flags: core.clibs.vma.AllocationCreateFlags,
};

materials: Materials,
meshes2D: Meshes2D,
meshes3D: Meshes3D,

mapped_buffers: std.StringHashMapUnmanaged(MappedBufferCreate),

pub fn deinit(
    self: *@This(),
    a: std.mem.Allocator,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.materials.deinit(a, device, alloc_cbs);
    self.meshes3D.deinit(a, device, alloc_cbs);
    self.meshes2D.deinit(a, device, alloc_cbs);
    self.mapped_buffers.deinit(a);
}

pub fn create(a: std.mem.Allocator, ci: CreateInfo) !@This() {
    var materials: Materials = .{};

    if (ci.materials_files) |mtlfls| {
        for (mtlfls) |fl| {
            try materials.addMaterialsFile(a, fl);
        }
    }

    if (ci.texture_creates) |tx_crs| {
        for (tx_crs) |tx_cr| {
            try materials.textures.put(a, tx_cr.@"0", tx_cr.@"1");
        }
    }

    var mapped_buffers: std.StringHashMapUnmanaged(MappedBufferCreate) = .empty;
    if (ci.mapped_buffer_creates) |mp_crs| {
        for (mp_crs) |mp_cr| {
            try mapped_buffers.put(a, mp_cr.@"0", mp_cr.@"1");
        }
    }

    var meshes3D = try Meshes3D.init(a);

    if (ci.meshes3D) |m3ds| {
        for (m3ds) |cm3d| {
            switch (cm3d.create_mesh) {
                .obj => |obj| {
                    const this_mat_lib = materials.libraries.get(obj.material_library_name) orelse std.debug.panic(
                        \\ Failed to get material library "{s}"
                    , .{obj.material_library_name});

                    const mesh = core.lib.mesh.Mesh3D.fromObjFile(a, obj) catch @panic("failed to load mesh");
                    defer mesh.deinit(a);
                    meshes3D.appendMeshWithMaterialLookup(
                        a,
                        mesh,
                        cm3d.transform,
                        this_mat_lib.offset,
                        this_mat_lib.library,
                        obj.objects[0].material_ranges,
                    ) catch @panic("OOM");
                },
                .info => |info| {
                    meshes3D.appendMeshWithMaterialIndex(
                        a,
                        info.mesh,
                        cm3d.transform,
                        info.material_idx,
                    ) catch @panic("OOM");
                },
            }
        }
    }

    var meshes2D = try core.resources.Meshes2D.init(a);
    if (ci.meshes2D) |m2ds| {
        for (m2ds) |cm2d| {
            try meshes2D.appendMesh(
                a,
                cm2d.mesh,
                cm2d.screen_coordinates,
                cm2d.material_index,
            );
        }
    }

    return @This(){
        .materials = materials,
        .meshes3D = meshes3D,
        .meshes2D = meshes2D,
        .mapped_buffers = mapped_buffers,
    };
}

pub const AllocatedData = struct {
    materials: Materials.AllocatedData,
    meshes3D: Meshes3D.AllocatedData,
    meshes2D: Meshes2D.AllocatedData,
    all_mapped_buffers: std.StringHashMapUnmanaged(core.bindings.vma_usage.MappedBuffer) = .empty,

    descriptor_pool: core.clibs.vk.DescriptorPool,

    pub fn deinit(
        self: *@This(),
        allocs: core.engine.Allocators,
        device: core.clibs.vk.Device,
        alloc_cbs: ?*core.clibs.vk.AllocationCallbacks,
    ) void {
        self.materials.deinit(allocs, device, alloc_cbs);
        self.meshes3D.deinit(allocs);
        self.meshes2D.deinit(allocs);
        var iter = self.all_mapped_buffers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocs.vma);
        }
        self.all_mapped_buffers.deinit(allocs.std);

        vk.DestroyDescriptorPool(device, self.descriptor_pool, alloc_cbs);
    }
};

fn createDescriptorPool(
    self: @This(),
    max_sets: u32,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) vk.DescriptorPool {
    var pool: vk.DescriptorPool = undefined;
    const materials_count = self.materials.amountTotalTextures();
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .type = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
            // BAD
            .descriptorCount = 3,
            // .descriptorCount = self.materials.textures.size,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            // .descriptorCount = self.mapped_buffers.size * 2,
            // BAD
            .descriptorCount = 3,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = materials_count,
        },
    };

    const pool_ci = vk.DescriptorPoolCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = max_sets,
        .poolSizeCount = pool_sizes.len,
        .pPoolSizes = &pool_sizes,
    };

    checkVk(vk.CreateDescriptorPool(device, &pool_ci, alloc_cbs, &pool)) catch
        @panic("failed to create main compute descriptor pool");

    return pool;
}

pub fn upload(
    self: *@This(),
    allocs: core.engine.Allocators,
    max_sets: u32,
    upload_ctx: *core.bindings.vulkan_init.UploadContext,
    logical_device: core.bindings.vulkan_init.LogicalDevice,
    physical_device: core.bindings.vulkan_init.PhysicalDevice,
    alloc_cbs: ?*core.clibs.vk.AllocationCallbacks,
) std.mem.Allocator.Error!AllocatedData {
    const pool = self.createDescriptorPool(
        max_sets,
        logical_device.handle,
        alloc_cbs,
    );
    const meshes3D = self.meshes3D.upload(
        allocs,
        pool,
        upload_ctx,
        logical_device,
    );
    const meshes2D = self.meshes2D.upload(
        allocs,
        pool,
        upload_ctx,
        logical_device,
    );
    const materials = try self.materials.upload(
        allocs,
        pool,
        upload_ctx,
        logical_device,
        physical_device,
        alloc_cbs,
    );

    var all_mapped_buffers: std.StringHashMapUnmanaged(core.bindings.vma_usage.MappedBuffer) = .empty;
    var mapped_iter = self.mapped_buffers.iterator();

    while (mapped_iter.next()) |mapped| {
        const ci = mapped.value_ptr;
        const alloc = core.bindings.vma_usage.AllocatedBuffer.create(
            allocs.vma,
            ci.alloc_size,
            ci.buffer_usage,
            ci.mem_usage,
            ci.flags,
        );
        var buf = core.bindings.vma_usage.MappedBuffer{
            .allocation = alloc,
        };

        core.bindings.vulkan_init.checkVk(core.clibs.vma.MapMemory(
            allocs.vma,
            alloc.allocation,
            &buf.mapped,
        )) catch @panic("failed to map buffer");
        try all_mapped_buffers.put(allocs.std, mapped.key_ptr.*, buf);
    }

    return .{
        .meshes3D = meshes3D,
        .meshes2D = meshes2D,
        .materials = materials,
        .all_mapped_buffers = all_mapped_buffers,
        .descriptor_pool = pool,
    };
}
