//! core Library for zig render
const std = @import("std");
const sdl = clibs.sdl;
pub const shaders = @import("shaders.zig");
pub const terrain = @import("terrain.zig");
pub const mesh = @import("mesh.zig");
pub const frames = @import("frames.zig");
pub const math = @import("math3d.zig");
pub const obj_loader = @import("obj_loader.zig");
pub const mtl_loader = @import("mtl_loader.zig");
pub const clibs = @import("clibs.zig");
pub const vma_usage = @import("vma_usage.zig");
pub const vulkan_init = @import("vulkan_init.zig");
pub const vulkan_util = @import("vulkan_util.zig");
pub const VulkanEngine = @import("VulkanEngine.zig");
pub const Input = @import("Input.zig");
pub const MeshPipeline = @import("pipelines/MeshPipeline.zig");
pub const HudPipeline = @import("pipelines/HudPipeline.zig");
pub const MainComputePipeline = @import("pipelines/MainComputePipeline.zig");
pub const BackgroundPipeline = @import("pipelines/BackgroundPipeline.zig");
pub const Maze = @import("Maze.zig");
pub const Materials = @import("Materials.zig");
pub const Camera = @import("Camera.zig");

/// Panics if returned bool == false
pub fn checkSdl(res: bool) void {
    if (!res) {
        std.log.err("Detected SDL error: {s}", .{sdl.GetError()});
        @panic("SDL error");
    }
}

test {
    std.testing.refAllDecls(@This());
}
