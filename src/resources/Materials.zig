const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.Materials);
const core = @import("../root.zig");
const vma = core.clibs.vma;
const vk = core.clibs.vk;
const vki = core.bindings.vulkan_init;
const checkVk = vki.checkVk;
const vma_usage = core.bindings.vma_usage;

const Self = @This();

const Metadata = struct {
    offset: usize,
    range: usize,
    height: c_int,
    width: c_int,
    channels: c_int,
};

pub const MaterialData = struct {
    data: []const u8,
    name: []const u8,
    height: c_int,
    width: c_int,
    channels: c_int,

    pub fn upload(
        self: @This(),
        vma_a: vma.Allocator,
        upload_ctx: *vki.UploadContext,
        log_device: vki.LogicalDevice,
        // TODO
        // remove this
        _: vki.PhysicalDevice,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) core.bindings.vulkan_init.VkError!vma_usage.AllocatedImage {
        const image_size = @as(vk.DeviceSize, @intCast(self.width * self.height * 4));

        const staging_buffer = vma_usage.AllocatedBuffer.create(
            vma_a,
            image_size,
            vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
            vma.MEMORY_USAGE_CPU_ONLY,
            0,
        );
        defer vma.DestroyBuffer(vma_a, staging_buffer.buffer, staging_buffer.allocation);

        var img_data_slice: []const u8 = undefined;
        img_data_slice.ptr = @as([*]const u8, @ptrCast(self.data));
        img_data_slice.len = @as(usize, image_size);

        var data: ?*anyopaque = null;
        try checkVk(vma.MapMemory(vma_a, staging_buffer.allocation, &data));
        @memcpy(@as([*]u8, @ptrCast(data orelse unreachable)), img_data_slice);

        vma.UnmapMemory(vma_a, staging_buffer.allocation);

        const extent = vk.Extent3D{
            .width = @as(c_uint, @intCast(self.width)),
            .height = @as(c_uint, @intCast(self.height)),
            .depth = 1,
        };
        var image = vma_usage.AllocatedImage.init(
            vma_a,
            vk.FORMAT_R8G8B8A8_SRGB,
            extent,
            vk.IMAGE_USAGE_TRANSFER_DST_BIT | vk.IMAGE_USAGE_SAMPLED_BIT,
        );

        upload_ctx.immediateSubmit(log_device, struct {
            image: vk.Image,
            extent: vk.Extent3D,
            staging_buffer: vma_usage.AllocatedBuffer,

            pub fn submit(this: @This(), cmd: vk.CommandBuffer) void {
                const range = vk.ImageSubresourceRange{
                    .aspectMask = vk.IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                };

                const barrier_to_transfer = vk.ImageMemoryBarrier{
                    .sType = vk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                    .srcAccessMask = 0,
                    .dstAccessMask = vk.ACCESS_TRANSFER_WRITE_BIT,
                    .oldLayout = vk.IMAGE_LAYOUT_UNDEFINED,
                    .newLayout = vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .image = this.image,
                    .subresourceRange = range,
                };

                vk.CmdPipelineBarrier(
                    cmd,
                    vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                    vk.PIPELINE_STAGE_TRANSFER_BIT,
                    0,
                    0,
                    null,
                    0,
                    null,
                    1,
                    &barrier_to_transfer,
                );

                const copy_region = vk.BufferImageCopy{
                    .bufferOffset = 0,
                    .bufferRowLength = 0,
                    .bufferImageHeight = 0,
                    .imageSubresource = .{
                        .aspectMask = vk.IMAGE_ASPECT_COLOR_BIT,
                        .mipLevel = 0,
                        .baseArrayLayer = 0,
                        .layerCount = 1,
                    },
                    .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                    .imageExtent = this.extent,
                };

                vk.CmdCopyBufferToImage(
                    cmd,
                    this.staging_buffer.buffer,
                    this.image,
                    vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    1,
                    &copy_region,
                );

                const barrier_to_shader_read = vk.ImageMemoryBarrier{
                    .sType = vk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                    .srcAccessMask = vk.ACCESS_TRANSFER_WRITE_BIT,
                    .dstAccessMask = vk.ACCESS_SHADER_READ_BIT,
                    .oldLayout = vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    .newLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .image = this.image,
                    .subresourceRange = range,
                };

                vk.CmdPipelineBarrier(
                    cmd,
                    vk.PIPELINE_STAGE_TRANSFER_BIT,
                    vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                    0,
                    0,
                    null,
                    0,
                    null,
                    1,
                    &barrier_to_shader_read,
                );
            }
        }{
            .image = image.image,
            .extent = extent,
            .staging_buffer = staging_buffer,
        });

        const image_view_ci = vk.ImageViewCreateInfo{
            .sType = vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .viewType = vk.IMAGE_VIEW_TYPE_2D,
            .image = image.image,
            .format = vk.FORMAT_R8G8B8A8_SRGB,
            .components = .{
                .r = vk.COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = vk.IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        checkVk(vk.CreateImageView(log_device.handle, &image_view_ci, alloc_cbs, &image.view)) catch @panic("Failed to create image view");

        return image;
    }
};

const MaterialLibraryEntry = struct {
    library: MaterialLibrary,
    offset: u32,
};

pub const CreateTextureEntry = struct {
    extent: vk.Extent3D,
    format: vk.Format,
    usages: vk.ImageUsageFlags,
    aspect_flags: vk.ImageAspectFlags,
    /// expected to call immediateSubmit
    initial_transition_function: ?*const fn (vki.LogicalDevice, *vki.UploadContext, vk.Image) void,
};

libraries: std.StringHashMapUnmanaged(MaterialLibraryEntry) = .empty,
/// these are textures that are written to via compute shaders
/// or other means
/// specifically for non-static data
textures: std.StringHashMapUnmanaged(CreateTextureEntry) = .empty,
/// currently every texture uses the sampelr
sampler: vk.Sampler = undefined,

all_textures_descriptor_set_layout: vk.DescriptorSetLayout = undefined,
/// certain systems require writable access to certain textures
writable_textures_descriptor_set_layouts: std.StringHashMapUnmanaged(WritableTextureSetLayout) = .empty,

const WritableTextureSetLayout = struct {
    layout: vk.DescriptorSetLayout,
    names: []const []const u8,
};

pub fn initSampler(
    self: *@This(),
    device: vk.Device,
    sampler_ci: vk.SamplerCreateInfo,
) void {
    var sampler: vk.Sampler = undefined;
    checkVk(vk.CreateSampler(device, &sampler_ci, null, &sampler)) catch @panic("failed to create sampler");
    self.sampler = sampler;
}

pub fn deinit(
    self: *@This(),
    a: std.mem.Allocator,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    var libs_iter = self.libraries.valueIterator();
    while (libs_iter.next()) |m| {
        m.library.deinit(a);
    }
    self.textures.deinit(a);

    var writable_tx_iter = self.writable_textures_descriptor_set_layouts.valueIterator();
    while (writable_tx_iter.next()) |layout| {
        vk.DestroyDescriptorSetLayout(device, layout.layout, alloc_cbs);
    }
    self.writable_textures_descriptor_set_layouts.deinit(a);

    vk.DestroyDescriptorSetLayout(device, self.all_textures_descriptor_set_layout, alloc_cbs);
}

pub fn addMaterialsFile(self: *@This(), a: std.mem.Allocator, file: core.loaders.mtl.MtlFile) std.mem.Allocator.Error!void {
    const lib = MaterialLibrary.initFromMaterialFile(a, file) catch @panic("failed to create MTL");
    const offset = self.amountTotalTextures();
    try self.libraries.put(a, file.name, .{
        .library = lib,
        .offset = offset,
    });
}

pub fn amountTotalTextures(self: Self) u32 {
    var count = self.textures.size;
    var iter = self.libraries.valueIterator();

    while (iter.next()) |v|
        count += @as(u32, @intCast(v.library.material_names.len));

    return count;
}

/// only call once all materials have been added
pub fn createDescriptorSetLayout(
    self: *Self,
    binding: u32,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    if (binding == 0) @panic(
        \\ 0 binding is reserved for sampler!!
    );
    const count = self.amountTotalTextures();

    const tx_bind = vk.DescriptorSetLayoutBinding{
        .binding = binding,
        .descriptorType = vk.DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .descriptorCount = @as(u32, @intCast(count)),
        .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = null,
    };

    const sampler_bind = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptorType = vk.DESCRIPTOR_TYPE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = &self.sampler,
    };

    const bindings = [_]vk.DescriptorSetLayoutBinding{
        sampler_bind,
        tx_bind,
    };

    const layout_ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .pBindings = &bindings,
        .bindingCount = bindings.len,
    };

    checkVk(vk.CreateDescriptorSetLayout(
        device,
        &layout_ci,
        alloc_cbs,
        &self.all_textures_descriptor_set_layout,
    )) catch @panic("Failed to create descriptor set layout");
}

pub fn createAndRegisterWritableTextureSetLayout(
    self: *Self,
    a: std.mem.Allocator,
    set_name: []const u8,
    writable_texture_names: []const []const u8,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) std.mem.Allocator.Error!void {
    const get_or_put = try self.writable_textures_descriptor_set_layouts.getOrPut(a, set_name);
    if (get_or_put.found_existing) std.debug.panic(
        \\ SET for '{s}' already exists!
    , .{set_name});
    const layout = self.createWritableTextureSetLayout(writable_texture_names, device, alloc_cbs);
    get_or_put.value_ptr.* = .{
        .layout = layout,
        .names = writable_texture_names,
    };
}

/// Builds a storage-image descriptor set layout with one binding per name,
/// in the order given. Caller is responsible for remembering that order
/// (e.g. index 0 = names[0]) to know which binding maps to which texture
/// later, both for the write pass and for shader-side binding numbers.
fn createWritableTextureSetLayout(
    self: Self,
    names: []const []const u8,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) vk.DescriptorSetLayout {
    std.debug.assert(names.len <= 32); // or heap-alloc if you need more
    var bindings_buf: [32]vk.DescriptorSetLayoutBinding = undefined;

    for (names, 0..) |name, i| {
        // fail fast if caller passed a name that doesn't exist —
        // catches typos/renames at layout-creation time, not at draw time
        if (!self.textures.contains(name)) std.debug.panic(
            \\ did not find texture with name: '{s}'
        , .{name});

        bindings_buf[i] = .{
            .binding = @intCast(i),
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
        };
    }

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = @intCast(names.len),
        .pBindings = &bindings_buf,
    };

    var layout: vk.DescriptorSetLayout = undefined;
    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &layout)) catch
        @panic("failed to create writable-texture descriptor set layout");
    return layout;
}

pub fn upload(
    self: @This(),
    allocs: core.engine.Allocators,
    pool: vk.DescriptorPool,
    upload_ctx: *core.bindings.vulkan_init.UploadContext,
    logical_device: vki.LogicalDevice,
    physical_device: vki.PhysicalDevice,
    alloc_cbs: ?*vk.AllocationCallbacks,
) std.mem.Allocator.Error!AllocatedData {
    var all_names = try std.ArrayList([:0]const u8).initCapacity(allocs.std, self.amountTotalTextures());

    var libs = std.StringHashMapUnmanaged(MaterialLibrary.AllocatedData).empty;
    var mat_libs_iter = self.libraries.iterator();
    while (mat_libs_iter.next()) |mat| {
        const uploaded = mat.value_ptr.library.upload(
            allocs,
            upload_ctx,
            logical_device,
            physical_device,
            alloc_cbs,
        );
        libs.put(allocs.std, mat.key_ptr.*, uploaded) catch @panic("OOM");
        all_names.appendSliceAssumeCapacity(mat.value_ptr.library.material_names);
    }

    var textures = std.StringHashMapUnmanaged(vma_usage.AllocatedImage).empty;
    try textures.ensureTotalCapacity(allocs.std, self.textures.size);
    var tx_iter = self.textures.iterator();
    while (tx_iter.next()) |entry| {
        const ci = entry.value_ptr;

        if (ci.extent.width == 0 or ci.extent.height == 0 or ci.extent.depth == 0)
            std.debug.panic(
                \\ allocating image with 0 width/height/depth??
                \\ extent:
                \\   width: {d} 
                \\   height: {d} 
                \\   depth: {d} 
            , .{ ci.extent.width, ci.extent.height, ci.extent.depth });
        var image = vma_usage.AllocatedImage.init(
            allocs.vma,
            ci.format,
            ci.extent,
            ci.usages,
        );
        const view_ci = vki.imageViewCreateInfo(image.format, image.image, ci.aspect_flags);
        checkVk(vk.CreateImageView(logical_device.handle, &view_ci, alloc_cbs, &image.view)) catch
            @panic("failed to create maze image view");

        if (ci.initial_transition_function) |func| func(logical_device, upload_ctx, image.image);

        textures.putAssumeCapacity(entry.key_ptr.*, image);
        all_names.appendAssumeCapacity(try allocs.std.dupeZ(u8, entry.key_ptr.*));
    }

    var tx_set: vk.DescriptorSet = undefined;
    const tx_ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.all_textures_descriptor_set_layout,
    };

    checkVk(vk.AllocateDescriptorSets(logical_device.handle, &tx_ai, &tx_set)) catch |e| {
        log.err(
            \\failed to allocate texture descriptor set: {s}
        , .{@errorName(e)});
        @panic("failed to allocate texture descriptor set");
    };

    var writable_sets: std.StringHashMapUnmanaged(AllocatedData.WritableTextureSet) = .empty;
    var writable_layouts_iter = self.writable_textures_descriptor_set_layouts.iterator();
    while (writable_layouts_iter.next()) |entry| {
        var set: vk.DescriptorSet = undefined;
        const ai = vk.DescriptorSetAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &entry.value_ptr.layout,
        };

        checkVk(vk.AllocateDescriptorSets(logical_device.handle, &ai, &set)) catch |e| {
            log.err(
                \\failed to allocate texture descriptor set: {s}
            , .{@errorName(e)});
            @panic("failed to allocate texture descriptor set");
        };

        try writable_sets.put(allocs.std, entry.key_ptr.*, .{
            .set = set,
            .names = entry.value_ptr.names,
        });
    }

    return .{
        .libraries = libs,
        .textures = textures,
        .sampler = self.sampler,
        .all_material_names = try all_names.toOwnedSlice(allocs.std),
        .all_textures_descriptor_set = tx_set,
        .writable_textures_descriptor_sets = writable_sets,
    };
}

pub const AllocatedData = struct {
    libraries: std.StringHashMapUnmanaged(MaterialLibrary.AllocatedData),
    textures: std.StringHashMapUnmanaged(vma_usage.AllocatedImage),
    sampler: vk.Sampler,
    all_material_names: [][:0]const u8,

    /// name is slightly innacurate,
    /// this set provides read access to ALL materials in a single array
    all_textures_descriptor_set: vk.DescriptorSet,

    writable_textures_descriptor_sets: std.StringHashMapUnmanaged(WritableTextureSet),

    const WritableTextureSet = struct {
        set: vk.DescriptorSet,
        names: []const []const u8,
    };

    pub fn deinit(
        self: *@This(),
        allocs: core.engine.Allocators,
        device: core.clibs.vk.Device,
        alloc_cbs: ?*core.clibs.vk.AllocationCallbacks,
    ) void {
        var lib_iter = self.libraries.valueIterator();
        while (lib_iter.next()) |m|
            m.deinit(allocs, device, alloc_cbs);
        self.libraries.deinit(allocs.std);

        var tx_iter = self.textures.valueIterator();
        while (tx_iter.next()) |t|
            t.deinit(allocs.vma, device, alloc_cbs);
        self.textures.deinit(allocs.std);

        for (self.all_material_names) |n|
            allocs.std.free(n);

        allocs.std.free(self.all_material_names);
        self.writable_textures_descriptor_sets.deinit(allocs.std);

        vk.DestroySampler(device, self.sampler, alloc_cbs);
    }

    pub fn updateStaticTextureSet(
        self: @This(),
        a: std.mem.Allocator,
        device: vk.Device,
        binding: u32,
    ) std.mem.Allocator.Error!void {
        const texture_count = self.all_material_names.len;

        var image_infos = try a.alloc(vk.DescriptorImageInfo, texture_count);
        defer a.free(image_infos);

        var lib_iter = self.libraries.valueIterator();

        var i: usize = 0;
        while (lib_iter.next()) |val| {
            for (val.images) |img| {
                image_infos[i] = .{
                    .sampler = self.sampler,
                    .imageView = img.view,
                    .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                };
                i += 1;
            }
        }

        var tx_iter = self.textures.iterator();
        while (tx_iter.next()) |entry| {
            const img = entry.value_ptr;
            image_infos[i] = .{
                .sampler = self.sampler,
                .imageView = img.view,
                .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            i += 1;
        }

        std.debug.assert(i == texture_count);

        const texture_write = vk.WriteDescriptorSet{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.all_textures_descriptor_set,
            .dstBinding = binding,
            .dstArrayElement = 0,
            .descriptorCount = @as(u32, @intCast(texture_count)),
            .descriptorType = vk.DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .pImageInfo = image_infos.ptr,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };

        const write_sets = [_]vk.WriteDescriptorSet{
            texture_write,
        };

        vk.UpdateDescriptorSets(
            device,
            write_sets.len,
            &write_sets,
            0,
            null,
        );
    }

    pub fn updateWritableTextureSet(
        self: @This(),
        device: vk.Device,
        set_name: []const u8,
    ) void {
        const set_entry = self.writable_textures_descriptor_sets.get(set_name) orelse std.debug.panic(
            \\ tried to update set '{s}' but it does not exist
        , .{set_name});

        std.debug.assert(set_entry.names.len <= 32); // or heap-alloc if you need more
        var writes: [32]vk.WriteDescriptorSet = undefined;
        var image_infos: [32]vk.DescriptorImageInfo = undefined;

        for (set_entry.names, 0..) |name, i| {
            const img = self.textures.get(name) orelse
                std.debug.panic("writable texture \"{s}\" not uploaded", .{name});
            image_infos[i] = .{
                .imageLayout = vk.IMAGE_LAYOUT_GENERAL,
                .imageView = img.view,
            };
            writes[i] = .{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = set_entry.set,
                .dstBinding = @intCast(i),
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
                .pImageInfo = &image_infos[i],
            };
        }
        vk.UpdateDescriptorSets(device, @intCast(set_entry.names.len), writes[0..set_entry.names.len].ptr, 0, null);
    }
};

pub const MaterialLibrary = struct {
    metadata: std.StringHashMapUnmanaged(struct { usize, Metadata }),
    material_names: [][:0]const u8,
    materials_blob: []u8,
    library_name: []u8,

    const Error = std.fmt.BufPrintError || error{FailedToLoadImage};
    const ASSETS_PATH = "assets/";

    const AllocatedData = struct {
        images: []vma_usage.AllocatedImage,
        // sampler: vk.Sampler,
        // textures: []Texture,

        pub fn deinit(
            self: *@This(),
            allocs: core.engine.Allocators,
            device: vk.Device,
            alloc_cbs: ?*vk.AllocationCallbacks,
        ) void {
            for (self.images) |*img| {
                img.deinit(allocs.vma, device, alloc_cbs);
            }
            allocs.std.free(self.images);
        }
    };

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        a.free(self.materials_blob);
        a.free(self.library_name);
        for (self.material_names) |n| {
            a.free(n);
        }
        a.free(self.material_names);
        self.metadata.deinit(a);
    }

    fn getMaterialData(self: @This(), name: []const u8) ?MaterialData {
        return if (self.metadata.get(name)) |tup|
            .{
                .name = name,
                .data = self.materials_blob[tup.@"1".offset .. tup.@"1".offset + tup.@"1".range],
                .width = tup.@"1".width,
                .height = tup.@"1".height,
                .channels = tup.@"1".channels,
            }
        else
            null;
    }

    fn initFromMaterialFile(
        a: std.mem.Allocator,
        mtl: core.loaders.mtl.MtlFile,
    ) anyerror!@This() {
        var materials = std.ArrayList(u8).empty;
        var metadatas = std.StringHashMapUnmanaged(struct { usize, Metadata }){};
        var material_names = std.ArrayList([:0]const u8).empty;

        for (mtl.materials) |mat| {
            if (mat.map_Kd) |basename| {
                const path = try std.fmt.allocPrint(a, ASSETS_PATH ++ "{s}", .{basename});
                defer a.free(path);

                var width: c_int = undefined;
                var height: c_int = undefined;
                var channels: c_int = undefined;

                // This is just to make the API more zig friendly. Convert to C 0-term string
                // on the stack.
                var buffer: [512]u8 = undefined;
                const filepathz = try std.fmt.bufPrintZ(buffer[0..], ASSETS_PATH ++ "{s}", .{basename});

                log.info("Attempting to load image from: {s}", .{filepathz});

                const image_data = core.clibs.stbi.load(
                    filepathz.ptr,
                    &width,
                    &height,
                    &channels,
                    core.clibs.stbi.rgb_alpha,
                );
                if (image_data == null) {
                    return error.FailedToLoadImage;
                }
                const byte_count: usize = @intCast(width * height * core.clibs.stbi.rgb_alpha);
                const md = Metadata{
                    .offset = materials.items.len,
                    .range = byte_count,
                    .channels = channels,
                    .height = height,
                    .width = width,
                };
                defer core.clibs.stbi.image_free(image_data);
                log.debug(
                    \\ Material '{s}' loaded
                , .{mat.name});

                try materials.appendSlice(a, image_data[0..byte_count]);
                try metadatas.put(a, mat.name, .{ metadatas.size, md });
                try material_names.append(a, try a.dupeZ(u8, mat.name));
            } else if (mat.Kd) |kd| {
                const pixel = [4]u8{
                    @intFromFloat(kd[0] * 255.0),
                    @intFromFloat(kd[1] * 255.0),
                    @intFromFloat(kd[2] * 255.0),
                    255,
                };
                const md = Metadata{
                    .offset = materials.items.len,
                    .range = 4,
                    .channels = 4,
                    .height = 1,
                    .width = 1,
                };
                try materials.appendSlice(a, &pixel);
                try metadatas.put(a, mat.name, .{ metadatas.size, md });
                try material_names.append(a, try a.dupeZ(u8, mat.name));
                log.debug("Material '{s}' loaded as flat color", .{mat.name});
            }
        }
        return .{
            .materials_blob = try materials.toOwnedSlice(a),
            .metadata = metadatas,
            .material_names = try material_names.toOwnedSlice(a),
            .library_name = try a.dupe(u8, mtl.name),
        };
    }

    fn upload(
        self: @This(),
        allocs: core.engine.Allocators,
        upload_ctx: *core.bindings.vulkan_init.UploadContext,
        logical_device: vki.LogicalDevice,
        physical_device: vki.PhysicalDevice,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) @This().AllocatedData {
        var iter = self.metadata.iterator();
        const images = allocs.std.alloc(vma_usage.AllocatedImage, self.metadata.size) catch @panic("OOM");
        while (iter.next()) |entry| {
            const mat = self.getMaterialData(entry.key_ptr.*) orelse @panic("No material found?");
            const idx = entry.value_ptr.@"0";
            const mat_img = mat.upload(
                allocs.vma,
                upload_ctx,
                logical_device,
                physical_device,
                alloc_cbs,
            ) catch @panic("failed to upload material");
            log.debug(
                \\ Adding {s} as {d}
            , .{ mat.name, idx });
            images[idx] = mat_img;
        }

        return .{
            .images = images,
        };
    }
};
