const std = @import("std");
const c = @import("clibs.zig");
const vk = c.vk;
const vma_usage = @import("vma_usage.zig");
const vki = @import("vulkan_init.zig");
const checkVk = vki.checkVk;

const log = std.log.scoped(.vulkan_util);

fn hasStencilComponent(format: vk.Format) bool {
    return format == vk.FORMAT_D32_SFLOAT_S8_UINT or format == vk.FORMAT_D24_UNORM_S8_UINT;
}

pub fn copyImageToImage(cmd: vk.CommandBuffer, source: vk.Image, destination: vk.Image, src_size: vk.Extent2D, dst_size: vk.Extent2D) void {
    const blit_region = vk.ImageBlit{
        .srcSubresource = .{
            .aspectMask = vk.IMAGE_ASPECT_COLOR_BIT,
            .baseArrayLayer = 0,
            .layerCount = 1,
            .mipLevel = 0,
        },
        .srcOffsets = .{
            .{ .x = 0, .y = 0, .z = 0 },
            .{
                .x = @intCast(src_size.width),
                .y = @intCast(src_size.height),
                .z = 1,
            },
        },
        .dstSubresource = .{
            .aspectMask = vk.IMAGE_ASPECT_COLOR_BIT,
            .baseArrayLayer = 0,
            .layerCount = 1,
            .mipLevel = 0,
        },
        .dstOffsets = .{
            .{ .x = 0, .y = 0, .z = 0 },
            .{
                .x = @intCast(dst_size.width),
                .y = @intCast(dst_size.height),
                .z = 1,
            },
        },
    };

    vk.CmdBlitImage(
        cmd,
        source,
        vk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        destination,
        vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &blit_region,
        0,
    );
}

/// THis is not good enough, src & dst masks are bad
pub fn transitionImageLayout(
    cmd: vk.CommandBuffer,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_access_mask: vk.AccessFlags,
    dst_access_mask: vk.AccessFlags,
) void {
    const aspect_mask: vk.ImageAspectFlags = if (new_layout == vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL) vk.IMAGE_ASPECT_DEPTH_BIT else vk.IMAGE_ASPECT_COLOR_BIT;

    const barrier = vk.ImageMemoryBarrier{
        .sType = vk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = src_access_mask,
        .dstAccessMask = dst_access_mask,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = vki.imageSubresourceRange(aspect_mask),
    };

    vk.CmdPipelineBarrier(
        cmd,
        // NOT OPTIMAL
        // https://github.com/KhronosGroup/Vulkan-Docs/wiki/Synchronization-Examples
        vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
        vk.PIPELINE_STAGE_ALL_COMMANDS_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}
