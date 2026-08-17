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

pub const Texture = struct {
    sampler: vk.Sampler,
    image_alloc: vma_usage.AllocatedImage,

    pub fn deinit(self: *@This(), vma_a: vma.Allocator, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        self.image_alloc.deinit(vma_a, device, alloc_cbs);
        vk.DestroySampler(device, self.sampler, alloc_cbs);
    }
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
        phys_device: vki.PhysicalDevice,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) core.bindings.vulkan_init.VkError!Texture {
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

        var sampler: vk.Sampler = undefined;
        const ci = vk.SamplerCreateInfo{
            .sType = vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = vk.FILTER_LINEAR,
            .minFilter = vk.FILTER_LINEAR,
            .addressModeU = vk.SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeV = vk.SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeW = vk.SAMPLER_ADDRESS_MODE_REPEAT,
            .anisotropyEnable = vk.TRUE,
            .maxAnisotropy = phys_device.properties.limits.maxSamplerAnisotropy,
            .borderColor = vk.BORDER_COLOR_INT_OPAQUE_BLACK,
            .unnormalizedCoordinates = vk.FALSE,
            .compareEnable = vk.FALSE,
            .compareOp = vk.COMPARE_OP_ALWAYS,
            .mipmapMode = vk.SAMPLER_MIPMAP_MODE_LINEAR,
            .mipLodBias = 0.0,
            .minLod = 0.0,
            .maxLod = 0.0,
        };

        checkVk(vk.CreateSampler(log_device.handle, &ci, null, &sampler)) catch @panic("failed to create sampler");

        return .{
            .image_alloc = image,
            .sampler = sampler,
        };
    }
};

const MaterialEntry = struct {
    library: MaterialLibrary,
    offset: u32,
};

libraries: std.StringHashMapUnmanaged(MaterialEntry),
all_material_names: [][:0]const u8,

pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
    var iter = self.libraries.valueIterator();
    while (iter.next()) |m| {
        m.library.deinit(a);
    }

    a.free(self.all_material_names);
}

pub fn initFromMaterialsFiles(a: std.mem.Allocator, files: []const core.loaders.mtl.MtlFile) std.mem.Allocator.Error!@This() {
    var all_libs = std.StringHashMapUnmanaged(MaterialEntry).empty;
    var all_names = try std.ArrayList([:0]const u8).initCapacity(a, 16);

    var current_mtl_offset: u32 = 0;
    for (files) |mtl| {
        const lib = MaterialLibrary.initFromMaterialFile(a, mtl) catch @panic("failed to create MTL");
        current_mtl_offset += @as(u32, @intCast(lib.metadata.size));
        try all_names.appendSlice(a, lib.material_names);
        try all_libs.put(a, mtl.name, .{
            .library = lib,
            .offset = current_mtl_offset,
        });
    }

    return .{
        .libraries = all_libs,
        .all_material_names = try all_names.toOwnedSlice(a),
    };
}

pub const MaterialLibrary = struct {
    metadata: std.StringHashMapUnmanaged(struct { usize, Metadata }),
    material_names: [][:0]const u8,
    materials_blob: []u8,
    library_name: []u8,

    const Error = std.fmt.BufPrintError || error{FailedToLoadImage};
    const ASSETS_PATH = "assets/";

    pub const AllocatedData = struct {
        textures: []Texture,

        pub fn deinit(
            self: *@This(),
            allocs: core.engine.Engine.Allocators,
            device: vk.Device,
            alloc_cbs: ?*vk.AllocationCallbacks,
        ) void {
            for (self.textures) |*tx| {
                tx.deinit(allocs.vma, device, alloc_cbs);
            }
            allocs.std.free(self.textures);
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

    pub fn getMaterialData(self: @This(), name: []const u8) ?MaterialData {
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

    pub fn upload(
        self: @This(),
        allocs: core.engine.Engine.Allocators,
        upload_ctx: *core.bindings.vulkan_init.UploadContext,
        logical_device: vki.LogicalDevice,
        physical_device: vki.PhysicalDevice,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) AllocatedData {
        var iter = self.metadata.iterator();
        const textures = allocs.std.alloc(core.resources.Materials.Texture, self.metadata.size) catch @panic("OOM");
        while (iter.next()) |entry| {
            const mat = self.getMaterialData(entry.key_ptr.*) orelse @panic("No material found?");
            const idx = entry.value_ptr.@"0";
            const mat_texture = mat.upload(
                allocs.vma,
                upload_ctx,
                logical_device,
                physical_device,
                alloc_cbs,
            ) catch @panic("failed to upload material");
            log.debug(
                \\ Adding {s} as {d}
            , .{ mat.name, idx });
            textures[idx] = mat_texture;
        }

        return .{
            .textures = textures,
        };
    }
};
