//! core Library for zig render
const std = @import("std");
const sdl = clibs.sdl;
pub const shaders = @import("shaders.zig");
pub const mesh = @import("mesh.zig");
pub const frames = @import("frames.zig");
pub const math = @import("math3d.zig");
pub const textures = @import("textures.zig");
pub const descriptor = @import("descriptor.zig");
pub const ResourceManager = @import("ResourceManager.zig");
pub const BoundDescriptor = @import("BoundDescriptor.zig");
pub const obj_loader = @import("obj_loader.zig");
pub const clibs = @import("clibs.zig");
pub const vma_usage = @import("vma_usage.zig");
pub const vulkan_init = @import("vulkan_init.zig");
pub const vulkan_util = @import("vulkan_util.zig");
pub const VulkanEngine = @import("VulkanEngine.zig");
pub const Input = @import("Input.zig");
pub const pipelines = @import("pipelines/root.zig");

/// Panics if returned bool == false
pub fn checkSdl(res: bool) void {
    if (!res) {
        std.log.err("Detected SDL error: {s}", .{sdl.GetError()});
        @panic("SDL error");
    }
}

pub const UniformBufferObject = struct {
    model: math.Mat4,
    view: math.Mat4,
    proj: math.Mat4,
};

test {
    std.testing.refAllDecls(@This());
}
