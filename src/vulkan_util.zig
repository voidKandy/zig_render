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

pub fn transitionImageLayout(
    cmd: vk.CommandBuffer,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
) void {
    const aspect_mask: vk.ImageAspectFlags = if (new_layout == vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL) vk.IMAGE_ASPECT_DEPTH_BIT else vk.IMAGE_ASPECT_COLOR_BIT;
    // const barrier = vk.ImageMemoryBarrier2{
    //     .sType = vk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
    //     .pNext = null,

    //     // NOT OPTIMAL
    //     // https://github.com/KhronosGroup/Vulkan-Docs/wiki/Synchronization-Examples
    //     .srcStageMask = vk.PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
    //     .srcAccessMask = vk.ACCESS_2_MEMORY_WRITE_BIT,
    //     // NOT OPTIMAL
    //     .dstStageMask = vk.PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
    //     .dstAccessMask = vk.ACCESS_2_MEMORY_WRITE_BIT | vk.ACCESS_2_MEMORY_READ_BIT,
    //     .oldLayout = old_layout,
    //     .newLayout = new_layout,
    //     .subresourceRange = vki.imageSubresourceRange(aspect_mask),
    //     .image = image,
    // };

    const barrier = vk.ImageMemoryBarrier{
        .sType = vk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = vk.ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = vk.ACCESS_SHADER_WRITE_BIT | vk.ACCESS_SHADER_READ_BIT,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = vki.imageSubresourceRange(aspect_mask),
    };

    vk.CmdPipelineBarrier(
        cmd,
        vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );

    // const dep_info = vk.DependencyInfo{
    //     .sType = vk.STRUCTURE_TYPE_DEPENDENCY_INFO,
    //     .pNext = null,

    //     .imageMemoryBarrierCount = 1,
    //     .pImageMemoryBarriers = &barrier,
    // };

    // const pVkCmdPipelineBarrier2KHR: vk.PFN_vkVoidFunction = vk.GetDeviceProcAddr(device, "vkCmdPipelineBarrier2KHR");
    // const ptr: vk.PFN_vkCmdPipelineBarrier2KHR = @ptrCast(pVkCmdPipelineBarrier2KHR.?);
    // ptr.?(cmd, &dep_info);

    // vk.CmdPipelineBarrier2(cmd, &dep_info);
}
