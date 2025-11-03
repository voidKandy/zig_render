//! core Library for zig render
const std = @import("std");
const sdl = clibs.sdl;
pub const shaders = @import("shaders.zig");
pub const mesh = @import("mesh.zig");
pub const math = @import("math3d.zig");
pub const clibs = @import("clibs.zig");
pub const vma_usage = @import("vma_usage.zig");
pub const vulkan_init = @import("vulkan_init.zig");
pub const VulkanEngine = @import("VulkanEngine.zig");
pub const OldVulkanEngine = @import("OldVulkanEngine.zig");

/// Panics if returned bool == false
pub fn checkSdl(res: bool) void {
    if (!res) {
        std.log.err("Detected SDL error: {s}", .{sdl.GetError()});
        @panic("SDL error");
    }
}

/// BAD!
/// Conflicts with Vertex
/// This is the 2D version of that
/// A nanme change is advised
pub const Vertex = struct {
    position: math.Vec2,
    color: math.Vec3,

    pub fn getBindingDescription() clibs.vk.VertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(@This()),
            .inputRate = clibs.vk.VERTEX_INPUT_RATE_VERTEX,
        };
    }

    /// An attribute description struct describes how to extract a vertex attribute from a chunk of vertex data originating from a binding description.
    /// We have two attributes, position and color, so we need two attribute description structs.
    pub fn getAttributeDescriptions() [2]clibs.vk.VertexInputAttributeDescription {
        return .{
            clibs.vk.VertexInputAttributeDescription{
                .binding = 0,
                .location = 0,
                .format = clibs.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(@This(), "position"),
            },
            clibs.vk.VertexInputAttributeDescription{
                .binding = 0,
                .location = 1,
                .format = clibs.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(@This(), "color"),
            },
        };
    }
};
