//! core Library for zig render
const std = @import("std");
pub const clibs = @import("clibs/root.zig");

pub const bindings = struct {
    pub const vma_usage = @import("bindings/vma_usage.zig");
    pub const sdl_usage = @import("bindings/sdl_usage.zig");
    pub const vulkan_init = @import("bindings/vulkan_init.zig");
    pub const vulkan_util = @import("bindings/vulkan_util.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

pub const engine = struct {
    pub const Allocators = struct {
        std: std.mem.Allocator,
        vma: clibs.vma.Allocator = undefined,
    };

    pub const Camera = @import("engine/Camera.zig");
    pub const world = @import("engine/world.zig");
    pub const Engine = @import("engine/Engine.zig");
    pub const frames = @import("engine/frames.zig");
    pub const Input = @import("engine/Input.zig");
    pub const shaders = @import("engine/shaders.zig");

    pub const Physics = @import("engine/Physics.zig");

    pub const systems = struct {
        pub const manager = @import("engine/systems/manager.zig");
        pub const Maze = @import("engine/systems/Maze.zig");
        pub const Debug = @import("engine/systems/Debug.zig");
        pub const Camera = @import("engine/systems/Camera.zig");
        pub const DrawBackground = @import("engine/systems/DrawBackground.zig");
        pub const PhysicsDebug = @import("engine/systems/PhysicsDebug.zig");
        test {
            std.testing.refAllDecls(@This());
        }
    };

    pub const graphics_pipelines = struct {
        pub const Mesh3DPipeline = @import("engine/graphics_pipelines/Mesh3DPipeline.zig");
        pub const Mesh2DPipeline = @import("engine/graphics_pipelines/Mesh2DPipeline.zig");

        const DescriptionOptions = struct {
            Enum: type,
            push_constants: ?struct {
                type,
                clibs.vk.ShaderStageFlags,
            } = null,
        };

        pub fn Description(opts: DescriptionOptions) type {
            _ = @typeInfo(opts.Enum).@"enum";

            return struct {
                pub const Layouts = std.EnumArray(opts.Enum, clibs.vk.DescriptorSetLayout);
                pub const Sets = std.EnumArray(opts.Enum, clibs.vk.DescriptorSet);

                layouts: Layouts,
                device: clibs.vk.Device,
                render_pass: clibs.vk.RenderPass,
                window_extent: clibs.vk.Extent2D,
                vertex_shader: clibs.vk.ShaderModule,
                fragment_shader: clibs.vk.ShaderModule,
                depth_compare_op: ?clibs.vk.CompareOp,

                pub fn createPipelineLayout(
                    layouts: Layouts,
                    device: clibs.vk.Device,
                    alloc_cbs: ?*clibs.vk.AllocationCallbacks,
                ) clibs.vk.PipelineLayout {
                    var layout: clibs.vk.PipelineLayout = undefined;
                    var ci = clibs.vk.PipelineLayoutCreateInfo{
                        .sType = clibs.vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                        .setLayoutCount = layouts.values.len,
                        .pSetLayouts = &layouts.values,
                    };

                    if (opts.push_constants) |pc_opts| {
                        const push_constant = clibs.vk.PushConstantRange{
                            .offset = 0,
                            .size = @sizeOf(pc_opts.@"0"),
                            .stageFlags = pc_opts.@"1",
                        };
                        ci.pushConstantRangeCount = 1;
                        ci.pPushConstantRanges = &push_constant;
                    }

                    bindings.vulkan_init.checkVk(clibs.vk.CreatePipelineLayout(
                        device,
                        &ci,
                        alloc_cbs,
                        &layout,
                    )) catch
                        @panic("failed to create pipeline layout");

                    return layout;
                }
            };
        }

        test {
            std.testing.refAllDecls(@This());
        }
    };

    test {
        std.testing.refAllDecls(@This());
    }
};

pub const lib = struct {
    pub const ecs = @import("lib/ecs.zig");
    pub const math = @import("lib/math.zig");
    pub const Maze = @import("lib/Maze.zig");
    pub const mesh = @import("lib/mesh.zig");
    pub const terrain = @import("lib/terrain.zig");
    // pub const alpha_wrapping = @import("lib/alpha_wrapping.zig");
    pub const delaunay = @import("lib/delaunay.zig");
    pub const physics = @import("lib/physics.zig");
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
