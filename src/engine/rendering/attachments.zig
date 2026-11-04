const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../root.zig");
const log = std.log.scoped(.Attachments);
const vma_usage = core.bindings.vma_usage;
const vki = core.bindings.vulkan_init;
const vku = core.bindings.vulkan_util;
const vk = core.clibs.vk;
const checkVk = vki.checkVk;
const vma = core.clibs.vma;
const FrameBufferAttachment = core.engine.Renderer.Swapchain.FrameBufferAttachment;

const AttachmentInfo = struct {
    description: vk.AttachmentDescription,
    usage: vk.ImageUsageFlags,
};
pub const ManagerInfo = struct {
    []const u8,
    AttachmentInfo,
};

pub fn CreateManager(comptime INFOS: []const ManagerInfo) type {
    const Depth = struct {
        var format: ?vk.Format = null;
    };

    return struct {
        pub const Tags = blk: {
            var NAMES: [INFOS.len][]const u8 = undefined;
            var VALUES: [INFOS.len]u32 = undefined;
            for (INFOS, &NAMES, &VALUES, 0..) |in, *f, *v, i| {
                v.* = i;
                f.* = in.@"0";
            }

            break :blk @Enum(u32, .exhaustive, &NAMES, &VALUES);
        };
        pub const ALL_TAGS = std.enums.values(Tags);

        const Plexe = std.EnumArray(Tags, FrameBufferAttachment);

        plexe: Plexe,

        pub fn deinit(
            self: *@This(),
            vma_a: vma.Allocator,
            device: vk.Device,
            alloc_cbs: ?*vk.AllocationCallbacks,
        ) void {
            for (ALL_TAGS) |tag| {
                self.plexe.get(tag).image.deinit(vma_a, device, alloc_cbs);
            }
        }

        pub fn isDepthAttachment(tag: Tags) bool {
            const info = INFOS[@backingInt(tag)];
            return info.@"1".usage == vk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
        }

        /// because attachment 0 is always FINAL color attachment
        pub fn attachmentIdx(tag: Tags) u32 {
            return @backingInt(tag) + 1;
        }

        pub fn imageViews(self: *const @This()) std.EnumArray(Tags, vk.ImageView) {
            var views = std.EnumArray(Tags, vk.ImageView).initUndefined();
            for (ALL_TAGS) |tag| {
                views.set(tag, self.plexe.get(tag).image.view);
            }
            return views;
        }

        pub fn attachmentDescriptions() std.EnumArray(Tags, vk.AttachmentDescription) {
            var descs = std.EnumArray(Tags, vk.AttachmentDescription).initUndefined();
            for (ALL_TAGS) |tag| {
                const info = INFOS[@backingInt(tag)];
                var desc = info.@"1".description;
                if (isDepthAttachment(tag))
                    desc.format = Depth.format.?;

                descs.set(tag, desc);
            }

            return descs;
        }

        pub fn clearValues() std.EnumArray(Tags, vk.ClearValue) {
            var vals = std.EnumArray(Tags, vk.ClearValue).initUndefined();
            inline for (ALL_TAGS) |tag| {
                const clear_color = vk.ClearValue{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
                const clear_depth = vk.ClearValue{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } };

                const clear = if (isDepthAttachment(tag))
                    clear_depth
                else
                    clear_color;

                vals.set(tag, clear);
            }

            return vals;
        }

        fn findDepthFormat(device: vki.PhysicalDevice) vk.Format {
            if (Depth.format) |f| return f;
            Depth.format = device.findSupportedFormat(
                &[_]vk.Format{ vk.FORMAT_D32_SFLOAT, vk.FORMAT_D32_SFLOAT_S8_UINT, vk.FORMAT_D24_UNORM_S8_UINT },
                vk.IMAGE_TILING_OPTIMAL,
                vk.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT,
            ) catch @panic("failed to find depth format");
            return Depth.format.?;
        }

        /// Transitions depth image into DepthStencil format
        /// BAD
        /// (see call site)
        pub fn transitionDepth(
            cmd: vk.CommandBuffer,
            attachment: FrameBufferAttachment,
        ) void {
            vku.transitionImageLayout(
                cmd,
                attachment.image.image,
                vk.IMAGE_LAYOUT_UNDEFINED,
                vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                0,
                vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
                    vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            );
        }

        fn createAttachment(
            vma_a: vma.Allocator,
            logical_device: vk.Device,
            swapchain_extent: vk.Extent2D,
            format: vk.Format,
            usage: vk.ImageUsageFlags,
            vk_alloc_cbs: ?*vk.AllocationCallbacks,
        ) FrameBufferAttachment {
            const extent = vk.Extent3D{
                .depth = 1,
                .height = swapchain_extent.height,
                .width = swapchain_extent.width,
            };
            var image: vma_usage.AllocatedImage = undefined;

            const ci = vk.ImageCreateInfo{
                .sType = vk.STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                .imageType = vk.IMAGE_TYPE_2D,
                .format = format,
                .extent = extent,
                .mipLevels = 1,
                .arrayLayers = 1,
                .samples = vk.SAMPLE_COUNT_1_BIT,
                .tiling = vk.IMAGE_TILING_OPTIMAL,
                .usage = usage | vk.IMAGE_USAGE_INPUT_ATTACHMENT_BIT |
                    // for the debug view
                    vk.IMAGE_USAGE_SAMPLED_BIT,
                .sharingMode = vk.SHARING_MODE_EXCLUSIVE,
                .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
            };

            const ai = vma.AllocationCreateInfo{
                .usage = vma.MEMORY_USAGE_GPU_ONLY,
                .requiredFlags = vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            };

            checkVk(vma.CreateImage(
                vma_a,
                &ci,
                &ai,
                &image.image,
                &image.allocation,
                null,
            )) catch @panic("failed to create image");

            const aspect_mask: u32 =
                switch (usage) {
                    vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT => vk.IMAGE_ASPECT_COLOR_BIT,
                    vk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT => vk.IMAGE_ASPECT_DEPTH_BIT,
                    // | vk.IMAGE_ASPECT_STENCIL_BIT,
                    else => @panic("UNEXPECTED USAGE FLAG"),
                };

            const imvi_ci = vk.ImageViewCreateInfo{
                .sType = vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = image.image,
                .viewType = vk.IMAGE_VIEW_TYPE_2D,
                .format = format,
                .subresourceRange = .{
                    .aspectMask = aspect_mask,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };

            checkVk(vk.CreateImageView(
                logical_device,
                &imvi_ci,
                vk_alloc_cbs,
                &image.view,
            )) catch @panic("Failed to create image view");

            return .{
                .image = image,
                .format = format,
            };
        }

        pub fn init(
            vma_a: vma.Allocator,
            physical_device: vki.PhysicalDevice,
            logical_device: vk.Device,
            swapchain_extent: vk.Extent2D,
            vk_alloc_cbs: ?*vk.AllocationCallbacks,
        ) @This() {
            var plexe = std.EnumArray(Tags, FrameBufferAttachment).initUndefined();
            for (ALL_TAGS) |tag| {
                const info = INFOS[@backingInt(tag)];

                const format = if (isDepthAttachment(tag))
                    findDepthFormat(physical_device)
                else
                    info.@"1".description.format;

                const attachment = createAttachment(
                    vma_a,
                    logical_device,
                    swapchain_extent,
                    format,
                    info.@"1".usage,
                    vk_alloc_cbs,
                );
                plexe.set(tag, attachment);
            }

            return .{
                .plexe = plexe,
            };
        }
    };
}
