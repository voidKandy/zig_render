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
