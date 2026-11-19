//! core Library for zig render

const std = @import("std");
pub const clibs = @import("clibs/root.zig");
pub const bindings = struct {
    pub const vma_usage = @import("bindings/vma_usage.zig");
    pub const sdl_usage = @import("bindings/sdl_usage.zig");
    pub const box3d_usage = @import("bindings/box3d_usage.zig");

    pub const vulkan_usage = @import("bindings/vulkan_usage.zig");

    test {
        std.testing.refAllDecls(@This());
    }
};

pub const engine = struct {
    pub const Allocators = struct {
        std: std.mem.Allocator,
        vma: clibs.vma.Allocator = undefined,
    };

    pub const frames = @import("engine/frames.zig");
    pub const shaders = @import("engine/shaders.zig");
    pub const world = @import("engine/world.zig");
    pub const Engine = @import("engine/Engine.zig");
    pub const Input = @import("engine/Input.zig");
    pub const Physics = @import("engine/Physics.zig");
    pub const Renderer = @import("engine/rendering/Manager.zig");

    pub const systems = @import("engine/systems.zig");
    pub const pipelines = @import("engine/pipelines.zig");

    test {
        std.testing.refAllDecls(@This());
    }
};

pub const lib = struct {
    pub const ecs = @import("lib/ecs.zig");
    pub const math = @import("lib/math.zig");
    pub const Maze = @import("lib/Maze.zig");
    pub const mesh = @import("lib/mesh.zig");
    pub const alpha_wrapping = @import("lib/alpha_wrapping/root.zig");

    // pub const terrain = @import("lib/terrain.zig");

    test {
        std.testing.refAllDecls(@This());
    }
};

pub const loaders = struct {
    pub const obj = @import("loaders/obj.zig");
    pub const mtl = @import("loaders/mtl.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

pub const resources = struct {
    pub const Manager = @import("resources/Manager.zig");
    pub const MappedBuffers = @import("resources/MappedBuffers.zig");
    pub const Materials = @import("resources/Materials.zig");
    pub const Meshes2D = @import("resources/Meshes2D.zig");
    pub const Meshes3D = @import("resources/Meshes3D.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

test {
    std.testing.refAllDecls(@This());
}
