const std = @import("std");
const core = @import("../root.zig");
const vk = core.clibs.vk;
const checkVk = core.bindings.vulkan_init.checkVk;
const log = std.log.scoped(.MaterialManager);
const Materials = @import("Materials.zig");
const Meshes2D = @import("Meshes2D.zig");
const MappedBuffers = @import("MappedBuffers.zig");
const Meshes3D = @import("Meshes3D.zig");

pub const Mesh3DCreateInfo = struct {
    create_mesh: union(enum) {
        obj: core.loaders.obj.ObjFile,
        info: struct {
            mesh: core.lib.mesh.Mesh3D,
            name: []const u8,
        },
    },
    transform: core.lib.math.Mat4 = .IDENTITY,
};

pub const Mesh2DCreateInfo = struct {
    mesh: core.lib.mesh.Mesh2D,
    name: []const u8,
};

pub const CreateInfo = struct {
    materials_files: ?[]const core.loaders.mtl.MtlFile,
    // texture_creates: ?[]const struct { []const u8, Materials.CreateTextureEntry } = null,
    meshes2D: ?[]const Mesh2DCreateInfo,
    meshes3D: ?[]const Mesh3DCreateInfo,
};

materials: Materials,
meshes2D: Meshes2D,
meshes3D: Meshes3D,
mapped_buffers: MappedBuffers,

subpass_input_attachments: SubpassInputAttachments = .{},

pub fn deinit(
    self: *@This(),
    a: std.mem.Allocator,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.materials.deinit(a, device, alloc_cbs);
    self.meshes3D.deinit(a, device, alloc_cbs);
    self.meshes2D.deinit(a);
    self.mapped_buffers.deinit(a, device, alloc_cbs);
    self.subpass_input_attachments.deinit(device, alloc_cbs);
}

pub fn init(a: std.mem.Allocator, ci: CreateInfo) !@This() {
    var materials: Materials = .{};

    if (ci.materials_files) |mtlfls| {
        for (mtlfls) |fl| {
            try materials.appendMtlLibrary(a, fl);
        }
    }

    const mapped_buffers: MappedBuffers = .{};

    var meshes3D = try Meshes3D.init(a);

    if (ci.meshes3D) |m3ds| {
        for (m3ds) |cm3d| {
            switch (cm3d.create_mesh) {
                .obj => |obj| {
                    const mesh = core.lib.mesh.Mesh3D.fromObjFile(a, obj) catch @panic("failed to load mesh");
                    defer mesh.deinit(a);
                    try meshes3D.appendMesh(a, obj.name, mesh);
                },
                .info => |info| {
                    try meshes3D.appendMesh(a, info.name, info.mesh);
                },
            }
        }
    }

    var meshes2D = try core.resources.Meshes2D.init(a);
    if (ci.meshes2D) |m2ds| {
        for (m2ds) |cm2d| {
            try meshes2D.appendMesh(
                a,
                cm2d.name,
                cm2d.mesh,
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

/// erveryhting about this function is dogshit
pub fn createSamplersAndDescriptorSetLayouts(self: *@This(), device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    self.materials.createSampler(device);

    self.materials.createDescriptorSetLayout(
        Materials.DEFAULT_BINDINGS,
        device,
        alloc_cbs,
    );

    self.meshes3D.createDescriptorSetLayout(
        device,
        alloc_cbs,
    );

    self.subpass_input_attachments.createDescriptorSetLayoutBindings(device, alloc_cbs);
}

// BAD
const SubpassInputAttachments = struct {
    const Attachments = core.engine.Renderer.Attachments;
    const a = @typeInfo(Attachments).@"enum";
    const OPTIONS = union(enum) {
        final: @Enum(u32, .exhaustive, a.field_names[1..], a.field_values[1..]),
        ssao: enum {},
    };

    final: vk.DescriptorSetLayout = undefined,
    ssao: vk.DescriptorSetLayout = undefined,

    const AllocatedData = struct {
        final: vk.DescriptorSet,
        ssao: vk.DescriptorSet,

        pub fn updateDescriptorSet(
            self: @This(),
            swapchain: *const core.engine.Renderer.Swapchain,
            device: vk.Device,
        ) void {
            // BAD
            const count = Attachments.ALL_TAGS.len;

            var writes: [count]vk.WriteDescriptorSet = undefined;
            var infos: [count]vk.DescriptorImageInfo = undefined;

            inline for (
                &writes,
                &infos,
                Attachments.ALL_TAGS,
            ) |*write, *info, tag| {
                const image = swapchain.attachments.plexe.get(tag).image;

                info.* = .{
                    .imageLayout = if (core.engine.Renderer.Attachments.isDepthAttachment(tag))
                        vk.IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
                    else
                        vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    .sampler = null,
                    .imageView = image.view,
                };

                write.* = .{
                    .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstSet = self.final,
                    .dstBinding = @backingInt(tag),
                    .dstArrayElement = 0,
                    .descriptorCount = 1,
                    .descriptorType = vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
                    .pImageInfo = info,
                };
            }

            vk.UpdateDescriptorSets(
                device,
                @intCast(writes.len),
                &writes,
                0,
                null,
            );

            @memset(&writes, undefined);
            @memset(&infos, undefined);

            const image = swapchain.attachments.plexe.get(.depth).image;

            infos[0] = .{
                .imageLayout = if (Attachments.isDepthAttachment(.depth))
                    vk.IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
                else
                    vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .sampler = null,
                .imageView = image.view,
            };

            writes[0] = .{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = self.ssao,
                .dstBinding = @backingInt(Attachments.Tags.depth),
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
                .pImageInfo = &infos[0],
            };

            vk.UpdateDescriptorSets(
                device,
                1,
                &writes[0],
                0,
                null,
            );
        }
    };

    pub fn deinit(
        self: *@This(),
        device: vk.Device,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) void {
        vk.DestroyDescriptorSetLayout(device, self.final, alloc_cbs);
        vk.DestroyDescriptorSetLayout(device, self.ssao, alloc_cbs);
    }

    /// since final isn't used as input attachments
    // const DESCRIPTOR_OFFSET = @backingInt(core.engine.Renderer.Attachments.Tags.depth);

    fn createDescriptorSetLayoutBindings(
        self: *@This(),
        device: vk.Device,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) void {
        const final_layout_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = @backingInt(Attachments.Tags.depth),
                .descriptorType = vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
                .descriptorCount = 1,
                .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
            },
            .{
                .binding = @backingInt(Attachments.Tags.position),
                .descriptorType = vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
                .descriptorCount = 1,
                .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
            },
            .{
                .binding = @backingInt(Attachments.Tags.normal),
                .descriptorType = vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
                .descriptorCount = 1,
                .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
            },
            .{
                .binding = @backingInt(Attachments.Tags.albedo),
                .descriptorType = vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
                .descriptorCount = 1,
                .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
            },
            .{
                .binding = @backingInt(Attachments.Tags.ssao),
                .descriptorType = vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
                .descriptorCount = 1,
                .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
            },
        };
        var ci = vk.DescriptorSetLayoutCreateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .flags = 0,
            .bindingCount = @as(u32, @intCast(final_layout_bindings.len)),
            .pBindings = &final_layout_bindings,
        };

        checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.final)) catch
            @panic("failed to create descriptor set layout");

        const ssao_layout_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = @backingInt(Attachments.Tags.depth),
                .descriptorType = vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
                .descriptorCount = 1,
                .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
            },
        };
        ci = vk.DescriptorSetLayoutCreateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .flags = 0,
            .bindingCount = @as(u32, @intCast(ssao_layout_bindings.len)),
            .pBindings = &ssao_layout_bindings,
        };

        checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.ssao)) catch
            @panic("failed to create descriptor set layout");
    }

    fn upload(
        self: *@This(),
        pool: vk.DescriptorPool,
        device: vk.Device,
    ) @This().AllocatedData {
        var final_set: vk.DescriptorSet = undefined;
        var ssao_set: vk.DescriptorSet = undefined;

        const final_ai = vk.DescriptorSetAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.final,
        };

        const ssao_ai = vk.DescriptorSetAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.ssao,
        };

        checkVk(vk.AllocateDescriptorSets(device, &final_ai, &final_set)) catch |e| {
            log.err(
                \\failed to allocate final descriptor set: {s}
            , .{@errorName(e)});
            @panic("failed to allocate final descriptor set");
        };

        checkVk(vk.AllocateDescriptorSets(device, &ssao_ai, &ssao_set)) catch |e| {
            log.err(
                \\failed to allocate ssao descriptor set: {s}
            , .{@errorName(e)});
            @panic("failed to allocate ssao descriptor set");
        };

        return .{
            .final = final_set,
            .ssao = ssao_set,
        };
    }
};

pub const AllocatedData = struct {
    materials: Materials.AllocatedData,
    meshes3D: Meshes3D.AllocatedData,
    meshes2D: Meshes2D.AllocatedData,
    mapped_buffers: MappedBuffers.AllocatedData,

    subpass_input_attachments: SubpassInputAttachments.AllocatedData,

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
        self.mapped_buffers.deinit(allocs);
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
    const materials_count = self.materials.creates.items.len;
    // TODO
    // derive these sizes!
    // currently these are being manually changed until the program runs
    // VERY FRAGILE
    // VERY BAD
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .type = vk.DESCRIPTOR_TYPE_SAMPLER,
            .descriptorCount = 1,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .descriptorCount = 8,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
            .descriptorCount = 8,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 8,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 4,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .descriptorCount = @as(u32, @intCast(materials_count)),
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
        upload_ctx,
        logical_device,
    );
    const materials = try self.materials.upload(
        allocs,
        pool,
        upload_ctx,
        logical_device,
        alloc_cbs,
    );

    const mapped_buffers = try self.mapped_buffers.upload(
        allocs,
        pool,
        logical_device.handle,
    );

    const input_attachments = self.subpass_input_attachments.upload(
        pool,
        logical_device.handle,
    );

    return .{
        .meshes3D = meshes3D,
        .meshes2D = meshes2D,
        .materials = materials,
        .mapped_buffers = mapped_buffers,
        .descriptor_pool = pool,
        .subpass_input_attachments = input_attachments,
    };
}
