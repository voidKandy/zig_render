const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.ResourceManager);
const core = @import("root.zig");
const vma = core.clibs.vma;
const vk = core.clibs.vk;
const vk_init = core.vulkan_init;
const checkVk = vk_init.checkVk;
const vma_usage = core.vma_usage;

/// Instead of writing the methods for managing materials in ResourceManager,
/// I decided to use this struct directly. Mostly for clear separation of concerns,
/// which follows from the decision to write a this instead of adding a
/// material-specific field to ResourceManager
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
        upload_ctx: *vk_init.UploadContext,
        log_device: vk_init.LogicalDevice,
        phys_device: vk_init.PhysicalDevice,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) core.vulkan_init.VkError!Texture {
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

metadata: std.StringHashMapUnmanaged(Metadata),
materials_blob: []u8,
library_name: []u8,

const Error = std.fmt.BufPrintError || error{FailedToLoadImage};
const ASSETS_PATH = "assets/";

pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
    a.free(self.materials_blob);
    a.free(self.library_name);
    self.metadata.deinit(a);
}

pub fn getMaterialData(self: Self, name: []const u8) ?MaterialData {
    return if (self.metadata.get(name)) |met|
        .{
            .name = name,
            .data = self.materials_blob[met.offset .. met.offset + met.range],
            .width = met.width,
            .height = met.height,
            .channels = met.channels,
        }
    else
        null;
}

pub fn initFromMaterialFile(
    a: std.mem.Allocator,
    mtl: core.mtl_loader.MtlFile,
) anyerror!@This() {
    var materials = std.ArrayList(u8){};
    var metadatas = std.StringHashMapUnmanaged(Metadata){};

    for (mtl.materials) |mat| {
        const path = try std.fmt.allocPrint(a, ASSETS_PATH ++ "{s}", .{mat.map_Kd});
        defer a.free(path);

        var width: c_int = undefined;
        var height: c_int = undefined;
        var channels: c_int = undefined;

        // This is just to make the API more zig friendly. Convert to C 0-term string
        // on the stack.
        var buffer: [512]u8 = undefined;
        const filepathz = try std.fmt.bufPrintZ(buffer[0..], ASSETS_PATH ++ "{s}", .{mat.map_Kd});

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
        const offset = Metadata{
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
        try metadatas.put(a, mat.name, offset);
    }
    return .{
        .materials_blob = try materials.toOwnedSlice(a),
        .metadata = metadatas,
        .library_name = try a.dupe(u8, mtl.name),
    };
}
